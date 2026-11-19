import Foundation
import QuickBounceAudio
import QuickBounceDomain
import QuickBouncePersistence
import QuickBounceProTools

public typealias AvailableCapacityProvider = @Sendable (_ directory: URL) -> Int64?

public enum VolumeAvailableCapacity {
    public static func resolve(
        importantUsageBytes: Int64?,
        volumeBytes: Int64?,
        fileSystemBytes: Int64?
    ) -> Int64? {
        let candidates = [importantUsageBytes, volumeBytes, fileSystemBytes]
        if let positive = candidates.compactMap({ $0 }).first(where: { $0 > 0 }) {
            return positive
        }
        return candidates.contains(0) ? 0 : nil
    }

    public static func read(
        for directory: URL,
        fileManager: FileManager = .default
    ) -> Int64? {
        var existing = directory
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            existing = parent
        }

        let values = try? existing.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let fileSystemBytes = try? fileManager.attributesOfFileSystem(
            forPath: existing.path
        )[.systemFreeSize] as? NSNumber

        return resolve(
            importantUsageBytes: values?.volumeAvailableCapacityForImportantUsage,
            volumeBytes: values?.volumeAvailableCapacity.map(Int64.init),
            fileSystemBytes: fileSystemBytes?.int64Value
        )
    }
}

public struct ExistingOutputCollision: Hashable, Identifiable, Sendable {
    public var planID: UUID
    public var planName: String
    public var fileURL: URL
    public var pathKey: String

    public init(planID: UUID, planName: String, fileURL: URL, pathKey: String) {
        self.planID = planID
        self.planName = planName
        self.fileURL = fileURL
        self.pathKey = pathKey
    }

    public var id: String { pathKey }
}

public struct BounceCoordinatorSnapshot: Sendable {
    public var job: BounceJob?
    public var artifacts: [AudioArtifact]
    public var events: [JobEvent]
    public var batchDestinations: [URL]
    public var completedPlanIDs: [UUID]

    public var completedPlanIDsToRemove: [UUID] {
        switch job?.state {
        case .reviewReady, .cancelled: completedPlanIDs
        default: []
        }
    }

    public init(
        job: BounceJob?,
        artifacts: [AudioArtifact],
        events: [JobEvent],
        batchDestinations: [URL] = [],
        completedPlanIDs: [UUID] = []
    ) {
        self.job = job
        self.artifacts = artifacts
        self.events = events
        self.batchDestinations = batchDestinations
        self.completedPlanIDs = completedPlanIDs
    }
}

public actor BounceCoordinator {
    private struct SessionGroup {
        var session: SessionIdentity
        var plans: [BouncePlan]
    }

    private let proTools: any ProToolsControlling
    private let store: SQLiteStore
    private let inspector: ArtifactInspector
    private let locator: ArtifactLocator
    private let transcoder: MP3Transcoder
    private let movAACTranscoder = MOVAACTranscoder()
    private let lease: SessionMutationLease
    private let workDirectory: URL
    private let availableCapacity: AvailableCapacityProvider
    private let diagnostics: DiagnosticLogger?
    private let outputResolver = OutputDirectoryResolver()

    private var currentJob: BounceJob?
    private var artifacts: [AudioArtifact] = []
    private var events: [JobEvent] = []
    private var batchDestinations: [URL] = []
    private var completedPlanIDs: [UUID] = []
    private var cancellationRequested = false
    private var continuations: [UUID: AsyncStream<BounceCoordinatorSnapshot>.Continuation] = [:]

    public init(
        proTools: any ProToolsControlling,
        store: SQLiteStore,
        workDirectory: URL,
        diagnostics: DiagnosticLogger? = nil,
        inspector: ArtifactInspector = ArtifactInspector(),
        locator: ArtifactLocator = ArtifactLocator(),
        transcoder: MP3Transcoder = MP3Transcoder(),
        lease: SessionMutationLease = SessionMutationLease(),
        availableCapacity: @escaping AvailableCapacityProvider = { directory in
            VolumeAvailableCapacity.read(for: directory)
        }
    ) throws {
        self.proTools = proTools
        self.store = store
        self.workDirectory = workDirectory.standardizedFileURL
        self.diagnostics = diagnostics
        self.inspector = inspector
        self.locator = locator
        self.transcoder = transcoder
        self.lease = lease
        self.availableCapacity = availableCapacity
        try StagingDirectoryLifecycle.prepareRoot(self.workDirectory)
    }

    public func snapshots() -> AsyncStream<BounceCoordinatorSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    public func snapshot() -> BounceCoordinatorSnapshot {
        BounceCoordinatorSnapshot(
            job: currentJob,
            artifacts: artifacts,
            events: events,
            batchDestinations: batchDestinations,
            completedPlanIDs: completedPlanIDs
        )
    }

    /// Removes only QuickBounce's Review record. The delivered file is never
    /// touched, and active Bounce work cannot be edited underneath the runner.
    public func removeArtifactRecord(id: UUID) async throws {
        if let currentJob, !currentJob.state.isTerminal {
            throw QuickBounceError.invalidPlan(
                "Wait for the current Bounce to finish before removing Review records"
            )
        }
        try await store.deleteArtifact(id: id)
        artifacts.removeAll { $0.id == id }
    }

    public func requestCancel() async {
        guard var job = currentJob, !job.state.isTerminal, job.state != .importing else { return }
        cancellationRequested = true
        job.cancellationRequested = true
        job.updatedAt = Date()

        if job.state.isRestorationState {
            currentJob = job
            try? await persist(
                job: job,
                message: "Cancellation queued; Session safety steps will finish first"
            )
            publish()
            return
        }

        job.state = .cancelRequested
        currentJob = job
        try? await persist(job: job, message: "Cancellation requested")
        publish()
        await transcoder.cancel()
        await movAACTranscoder.cancel()
        await proTools.cancelActiveExport()
    }

    /// Returns existing on-disk outputs after also checking that no two Plans
    /// resolve to the same target. This is read-only and is intended for the UI
    /// confirmation shown before any Pro Tools access or Session mutation.
    public func existingOutputCollisions(
        for allPlans: [BouncePlan]
    ) throws -> [ExistingOutputCollision] {
        let outputs = try plannedOutputs(for: BounceOutputNaming.preparing(allPlans.filter(\.isEnabled)))
        return try outputs.filter {
            guard FileManager.default.fileExists(atPath: $0.fileURL.path) else { return false }
            try validateReplaceableOutput($0.fileURL)
            return true
        }
    }

    @discardableResult
    public func run(
        plans allPlans: [BouncePlan],
        crossSession: Bool,
        authorizedOverwritePaths: Set<String> = []
    ) async -> BounceJob {
        var plans = allPlans.filter(\.isEnabled)
        var job = BounceJob(planIDs: plans.map(\.id))
        currentJob = job
        artifacts = []
        events = []
        batchDestinations = outputResolver.uniqueDestinations(for: plans)
        completedPlanIDs = []
        cancellationRequested = false
        publish()

        await diagnostics?.record(
            category: "bounce",
            action: "queue_started",
            correlationID: job.id.uuidString,
            fields: [
                "job_id": job.id.uuidString,
                "plan_count": String(plans.count),
                "cross_session": String(crossSession)
            ]
        )
        for plan in plans {
            await diagnostics?.recordTrackStates(
                action: "plan_queued",
                states: plan.targetTrackStates,
                correlationID: job.id.uuidString,
                fields: [
                    "job_id": job.id.uuidString,
                    "plan_id": plan.id.uuidString,
                    "plan_name": plan.name,
                    "export_type": plan.settings.exportType.rawValue,
                    "offline_bounce": String(plan.settings.offlineBounce),
                    "pad_to_frame_boundary": String(plan.settings.padToFrameBoundary),
                    "timecode_fps": plan.sourceTimeCodeRate.map {
                        String(format: "%.3f", $0.framesPerSecond)
                    } ?? "unknown"
                ]
            )
        }

        defer {
            try? StagingDirectoryLifecycle.removeJob(in: workDirectory, jobID: job.id)
        }

        do {
            plans = try BounceOutputNaming.preparing(plans)
            try StagingDirectoryLifecycle.prepareJob(in: workDirectory, jobID: job.id)
            try await lease.acquire(for: job.id)
            try await transition(&job, to: .validating, message: "Validating \(plans.count) Bounce Plans")
            try outputResolver.validate(plans, crossSession: crossSession)
            try preflightSessionFiles(plans, crossSession: crossSession)
            try preflightDestinations(batchDestinations)
            try preflightOutputCollisions(
                plans,
                authorizedOverwritePaths: authorizedOverwritePaths
            )
            try checkCancellation()

            try await transition(&job, to: .connecting, message: "Connecting to Pro Tools")
            let connection = try await proTools.connect()
            try validateCapabilities(
                connection.capabilities,
                plans: plans,
                crossSession: crossSession
            )

            var groups = orderedSessionGroups(plans)
            if crossSession,
               let current = try? await proTools.currentSessionIdentity() {
                groups = currentSessionFirst(
                    groups,
                    currentSessionPath: current.path
                )
            }
            var processedSession = false
            for (groupIndex, group) in groups.enumerated() {
                try checkCancellation()
                try await activate(
                    group: group,
                    crossSession: crossSession,
                    hasProcessedSession: processedSession
                )
                let context = try await proTools.currentSessionContext()
                let info = context.info
                try verifySession(expected: group.session, actual: info.identity, crossSession: crossSession)
                try validateFramePadding(
                    for: group.plans,
                    activeSessionTimeCodeRate: info.timeCodeRate
                )
                try validateMixSources(
                    for: group.plans,
                    available: try await proTools.exportMixSources()
                )

                try await transition(&job, to: .snapshotting, message: "Snapshotting \(info.name)")
                let initialStates = context.trackStates
                await diagnostics?.recordTrackStates(
                    action: "session_snapshot",
                    states: initialStates,
                    correlationID: job.id.uuidString,
                    fields: [
                        "job_id": job.id.uuidString,
                        "session_path": info.identity.path
                    ]
                )
                try validatePlanTracks(group.plans, against: initialStates)
                // A failed read cannot become an apparently valid snapshot:
                // every Bounce changes the selection, so capture it first.
                let timelineState = try await proTools.currentTimelineState()
                var snapshot = SessionSnapshot(
                    jobID: job.id,
                    session: info.identity,
                    trackStates: initialStates,
                    timelineState: timelineState,
                    saveAfterRestore: crossSession
                )
                // This durable journal entry must exist before the first Session mutation.
                try await store.save(snapshot: snapshot)

                var pendingImports: [ImportAudioRequest] = []
                do {
                    for plan in group.plans {
                        try checkCancellation()
                        let active = try await proTools.currentSessionIdentity()
                        guard active.instanceID == snapshot.session.instanceID,
                              active.path == snapshot.session.path else {
                            throw QuickBounceError.sessionIdentityMismatch
                        }
                        job.currentPlanID = plan.id
                        currentJob = job
                        try await transition(
                            &job,
                            to: .applyingTrackState,
                            message: "Applying \(plan.name) track state"
                        )
                        await diagnostics?.recordTrackStates(
                            action: "plan_apply_started",
                            states: plan.targetTrackStates,
                            correlationID: job.id.uuidString,
                            fields: [
                                "job_id": job.id.uuidString,
                                "plan_id": plan.id.uuidString,
                                "plan_name": plan.name
                            ]
                        )
                        let readback = try await proTools.apply(trackStates: plan.targetTrackStates)
                        try checkCancellation()
                        try validatePlanTracks([plan], against: readback)
                        try verify(
                            expected: plan.targetTrackStates,
                            actual: readback,
                            restoration: false
                        )
                        try checkCancellation()
                        try await transition(
                            &job,
                            to: .verifyingTrackState,
                            message: "Verified \(plan.name) track state"
                        )
                        await diagnostics?.record(
                            category: "bounce",
                            action: "plan_state_verified",
                            correlationID: job.id.uuidString,
                            fields: [
                                "job_id": job.id.uuidString,
                                "plan_id": plan.id.uuidString,
                                "plan_name": plan.name
                            ]
                        )

                        let output = try await executePlan(
                            plan,
                            activeSessionTimeCodeRate: info.timeCodeRate,
                            job: &job,
                            authorizedOverwritePaths: authorizedOverwritePaths
                        )
                        pendingImports.append(contentsOf: importRequests(for: plan, artifacts: output))
                        completedPlanIDs.append(plan.id)
                        job.completedPlanCount += 1
                        job.cancellationRequested = job.cancellationRequested || cancellationRequested
                        job.updatedAt = Date()
                        currentJob = job
                        try await store.save(job: job)
                        publish()
                        await diagnostics?.record(
                            category: "bounce",
                            action: "plan_completed",
                            correlationID: job.id.uuidString,
                            fields: [
                                "job_id": job.id.uuidString,
                                "plan_id": plan.id.uuidString,
                                "plan_name": plan.name,
                                "artifact_count": String(output.count)
                            ]
                        )
                    }
                } catch {
                    let bounceFailure = error
                    let wasCancellation = cancellationRequested || error is CancellationError ||
                        (error as? QuickBounceError) == .exportCancelled
                    if wasCancellation {
                        await prepareCancellation(job: &job)
                    }
                    do {
                        if wasCancellation {
                            try await proTools.waitUntilReady()
                        }
                        try await restore(snapshot: &snapshot, job: &job, crossSession: crossSession)
                        // A failed/cancelled queue stops here. Leave the
                        // restored current Session open for the user.
                    } catch {
                        return await finishRecoveryRequired(job: &job, error: error, interruptedBy: bounceFailure)
                    }
                    throw bounceFailure
                }

                do {
                    try await restore(snapshot: &snapshot, job: &job, crossSession: crossSession)
                    if crossSession, groupIndex < groups.count - 1, !cancellationRequested {
                        try await closeCurrentSession(job: &job)
                    }
                } catch {
                    return await finishRecoveryRequired(job: &job, error: error)
                }

                // Cancellation during recovery must let recovery finish, but
                // must not start a new mutation such as Import After Bounce.
                try checkCancellation()
                if !crossSession, groupIndex == groups.count - 1, !pendingImports.isEmpty {
                    try await transition(
                        &job,
                        to: .importing,
                        message: "Importing bounced audio after Session restore"
                    )
                    for request in pendingImports {
                        try await proTools.importAudio(request)
                    }
                }
                processedSession = true
            }

            try checkCancellation()
            try await transition(
                &job,
                to: .analyzing,
                message: "Preparing completed files for Review"
            )
            try await transition(&job, to: .reviewReady, message: "Review is ready")
        } catch {
            await diagnostics?.record(
                category: "bounce",
                action: "queue_failed",
                correlationID: job.id.uuidString,
                fields: [
                    "job_id": job.id.uuidString,
                    "job_state": job.state.rawValue,
                    "error": error.localizedDescription
                ]
            )
            let wasCancellation = cancellationRequested || error is CancellationError ||
                (error as? QuickBounceError) == .exportCancelled
            if wasCancellation && QuickBounceError.diskSpaceFailure(for: error) == nil {
                await finishCancelled(job: &job)
            } else if job.state != .recoveryRequired {
                await finishFailed(job: &job, error: error)
            }
        }

        await lease.release(for: job.id)
        currentJob = job
        publish()
        await diagnostics?.record(
            category: "bounce",
            action: "queue_finished",
            correlationID: job.id.uuidString,
            fields: [
                "job_id": job.id.uuidString,
                "job_state": job.state.rawValue,
                "completed_plan_count": String(job.completedPlanCount)
            ]
        )
        return job
    }

    public func recoverPendingSnapshots() async throws -> [SessionSnapshot] {
        let pending = try await store.pendingSnapshots()
        for var snapshot in pending {
            let current = try await proTools.currentSessionIdentity()
            let currentPath = outputResolver.canonicalURL(for: current.path).path
            let snapshotPath = outputResolver.canonicalURL(for: snapshot.session.path).path
            guard current.instanceID == snapshot.session.instanceID,
                  currentPath == snapshotPath else { continue }
            let readback = try await proTools.apply(trackStates: snapshot.trackStates)
            try verify(
                expected: snapshot.trackStates,
                actual: readback,
                restoration: true
            )
            try await TimelineRestoration.restore(snapshot.timelineState,
                legacySelection: snapshot.timelineSelection, using: proTools)
            if snapshot.saveAfterRestore == true {
                do {
                    try await proTools.saveSession()
                } catch {
                    throw QuickBounceError.diskSpaceFailure(for: error) ?? QuickBounceError.saveFailed(error.localizedDescription)
                }
            }
            snapshot.restoreRequired = false
            snapshot.verifiedAt = Date()
            try await store.save(snapshot: snapshot)
        }
        return try await store.pendingSnapshots()
    }

    public func discardPendingSnapshots(ids: [UUID]) async throws -> [SessionSnapshot] {
        try await store.discardSnapshots(ids: ids)
        return try await store.pendingSnapshots()
    }

    private func activate(
        group: SessionGroup,
        crossSession: Bool,
        hasProcessedSession: Bool
    ) async throws {
        guard crossSession else { return }
        let current = try? await proTools.currentSessionIdentity()
        let expectedURL = outputResolver.canonicalURL(for: group.session.path)
        let currentURL = current.map { outputResolver.canonicalURL(for: $0.path) }
        if currentURL?.path == expectedURL.path { return }

        if !hasProcessedSession, current != nil {
            throw QuickBounceError.invalidPlan(
                "Close the unrelated active Session before starting this cross-Session queue"
            )
        }
        try await proTools.openSession(at: expectedURL)
    }

    private func executePlan(
        _ plan: BouncePlan,
        activeSessionTimeCodeRate: SessionTimeCodeRate?,
        job: inout BounceJob,
        authorizedOverwritePaths: Set<String>
    ) async throws -> [AudioArtifact] {
        let staging = workDirectory
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
            .appendingPathComponent(plan.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let baseName = sanitizedFileName(plan.name, planID: plan.id)
        let bounceKind: ArtifactKind = switch plan.settings.exportType {
        case .wav, .wavAndMP3: .wav
        case .mp3: .mp3
        case .mov: .mov
        }
        let bounceExpectation = artifactExpectation(
            for: bounceKind,
            baseFileName: baseName,
            plan: plan,
            activeSessionTimeCodeRate: activeSessionTimeCodeRate
        )

        // Older PTSL Hosts do not accept ExportMix.start_time/end_time. Set
        // the selection explicitly so the same BouncePlan remains precise;
        // modern Hosts receive both this selection and the direct fields.
        try await proTools.setTimelineSelection(plan.range)
        try await transition(&job, to: .exporting, message: "Bouncing \(plan.name)")
        let result = try await proTools.exportMix(
            ProToolsExportRequest(
                plan: plan,
                stagingDirectory: staging,
                baseFileName: baseName,
                kind: bounceKind
            )
        )
        try checkCancellation()
        try await transition(
            &job,
            to: .waitingForArtifact,
            message: "Waiting for \(plan.name) output"
        )

        var candidates = result.candidateURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if candidates.isEmpty {
            candidates = try await locator.expectedCandidates(
                in: staging,
                baseName: baseName,
                kind: bounceKind,
                allowsMultipleMonoSuffixes: bounceExpectation.allowsMultipleMonoSuffixes
            )
        }
        guard !candidates.isEmpty else { throw QuickBounceError.artifactMissing(staging.path) }
        if !bounceExpectation.allowsMultipleMonoSuffixes, candidates.count != 1 {
            throw QuickBounceError.artifactInvalid(
                "Expected one \(bounceKind.rawValue.uppercased()) file for \(plan.name), found \(candidates.count)"
            )
        }

        for url in candidates {
            try await inspector.waitUntilStable(url: url)
            _ = try await inspector.inspect(
                AudioArtifact(
                    jobID: job.id,
                    planID: plan.id,
                    name: url.lastPathComponent,
                    path: url.path,
                    kind: bounceKind,
                    state: .candidate
                ),
                expectation: bounceExpectation
            )
        }

        let destination = outputResolver.canonicalURL(for: plan.settings.fileDestination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: [AudioArtifact] = []

        let needsLocalMP3 = plan.settings.exportType == .wavAndMP3
        let needsLocalAAC = bounceKind == .mov && plan.settings.movAudioCodec == .aac
        var deliveryExpectation = bounceExpectation
        if needsLocalMP3 {
            try await transition(&job, to: .transcoding, message: "Transcoding \(plan.name) to MP3")
        } else if needsLocalAAC {
            try await transition(&job, to: .transcoding, message: "Converting \(plan.name) MOV audio to AAC")
            try checkCancellation()
            let encodedDirectory = staging.appendingPathComponent("AAC", isDirectory: true)
            try FileManager.default.createDirectory(at: encodedDirectory, withIntermediateDirectories: true)
            var encoded: [URL] = []
            for source in candidates {
                try checkCancellation()
                let output = encodedDirectory.appendingPathComponent(source.lastPathComponent)
                try await movAACTranscoder.transcode(source: source, destination: output)
                try checkCancellation()
                encoded.append(output)
            }
            candidates = encoded
            deliveryExpectation.movAudioCodec = .aac
            deliveryExpectation.bitDepth = nil
            try await transition(
                &job,
                to: .validatingArtifact,
                message: "Validating \(plan.name) AAC audio"
            )
        } else {
            try await transition(
                &job,
                to: .validatingArtifact,
                message: "Validating \(plan.name) files"
            )
        }

        if plan.settings.exportType == .wavAndMP3 {
            for source in candidates {
                let artifact = try await commit(
                    source: source,
                    kind: .wav,
                    destination: destination,
                    plan: plan,
                    jobID: job.id,
                    expectation: bounceExpectation,
                    authorizedOverwritePaths: authorizedOverwritePaths
                )
                completed.append(artifact)
            }
        }

        if needsLocalMP3 {
            var mp3Files: [URL] = []
            for wav in candidates {
                try checkCancellation()
                let mp3 = wav.deletingPathExtension().appendingPathExtension("mp3")
                try await transcoder.transcode(
                    source: wav,
                    destination: mp3,
                    bitRateKbps: plan.settings.mp3ConstantBitRateKbps,
                    quality: plan.settings.mp3Quality
                )
                try await inspector.waitUntilStable(url: mp3)
                mp3Files.append(mp3)
            }
            try await transition(
                &job,
                to: .validatingArtifact,
                message: "Validating \(plan.name) MP3 output"
            )
            for mp3 in mp3Files {
                let mp3Expectation = artifactExpectation(
                    for: .mp3,
                    baseFileName: baseName,
                    plan: plan,
                    activeSessionTimeCodeRate: activeSessionTimeCodeRate
                )
                let artifact = try await commit(
                    source: mp3,
                    kind: .mp3,
                    destination: destination,
                    plan: plan,
                    jobID: job.id,
                    expectation: mp3Expectation,
                    authorizedOverwritePaths: authorizedOverwritePaths
                )
                completed.append(artifact)
            }
        } else {
            for source in candidates {
                try checkCancellation()
                let artifact = try await commit(
                    source: source,
                    kind: bounceKind,
                    destination: destination,
                    plan: plan,
                    jobID: job.id,
                    expectation: deliveryExpectation,
                    authorizedOverwritePaths: authorizedOverwritePaths
                )
                completed.append(artifact)
            }
        }
        try StagingDirectoryLifecycle.removePlanDirectory(staging)
        return completed
    }

    private func commit(
        source: URL,
        kind: ArtifactKind,
        destination: URL,
        plan: BouncePlan,
        jobID: UUID,
        expectation: ArtifactExpectation,
        authorizedOverwritePaths: Set<String>
    ) async throws -> AudioArtifact {
        let finalURL = destination.appendingPathComponent(source.lastPathComponent)
        let finalPathKey = collisionKey(for: finalURL)
        let exists = FileManager.default.fileExists(atPath: finalURL.path)
        guard !exists || authorizedOverwritePaths.contains(finalPathKey) else {
            throw QuickBounceError.exportFailed("Refusing to overwrite \(finalURL.path)")
        }
        if exists { try validateReplaceableOutput(finalURL) }

        // Validate the staged file before replacing a known-good delivery.
        _ = try await inspector.inspect(
            AudioArtifact(
                jobID: jobID,
                planID: plan.id,
                name: source.lastPathComponent,
                path: source.path,
                kind: kind,
                state: .candidate
            ),
            expectation: expectation
        )
        // The actual staged file size is authoritative even when the source
        // channel count/video bitrate was unavailable during preflight.
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw QuickBounceError.artifactInvalid("Cannot determine staged file size")
        }
        try requireCapacity(Int64(size), at: destination)
        try install(
            source: source,
            at: finalURL,
            replacingExisting: exists
        )
        var artifact = AudioArtifact(
            jobID: jobID,
            planID: plan.id,
            name: finalURL.lastPathComponent,
            path: finalURL.path,
            kind: kind,
            state: .candidate
        )
        try await store.save(artifact: artifact)
        do {
            artifact = try await inspector.inspect(artifact, expectation: expectation)
            try await store.save(artifact: artifact)
            artifacts.append(artifact)
            publish()
            return artifact
        } catch {
            artifact.state = .invalid
            try? await store.save(artifact: artifact)
            artifacts.append(artifact)
            publish()
            throw error
        }
    }

    private func artifactExpectation(
        for kind: ArtifactKind,
        baseFileName: String,
        plan: BouncePlan,
        activeSessionTimeCodeRate: SessionTimeCodeRate?
    ) -> ArtifactExpectation {
        let sourceRate = max(1, plan.sourceSampleRate ?? plan.settings.sampleRate)
        let unpaddedDuration = Double(plan.range.length) / Double(sourceRate)
        let frameRate = activeSessionTimeCodeRate ?? plan.sourceTimeCodeRate
        let duration: Double
        if plan.settings.padToFrameBoundary, let frameRate {
            duration = frameRate.paddedDuration(for: plan.range, sampleRate: sourceRate)
        } else {
            duration = unpaddedDuration
        }
        let outputRate = Double(plan.settings.sampleRate)
        let baseTolerance: Double = switch kind {
        case .wav: max(0.01, 2 / outputRate)
        case .mp3: max(0.15, 2_304 / outputRate)
        case .mov: 0.10
        }
        // The exact padded duration is the primary expectation. One physical
        // video frame of tolerance accommodates sample quantization and Host
        // differences without accepting the nearly two-frame range expansion
        // when padding is disabled.
        let tolerance = if plan.settings.padToFrameBoundary, let frameRate {
            max(baseTolerance, frameRate.frameDurationSeconds)
        } else {
            baseTolerance
        }
        let discreteMono = plan.settings.fileLayout == .mono
            || plan.settings.fileLayout == .multipleMono
        return ArtifactExpectation(
            kind: kind,
            baseFileName: baseFileName,
            allowsMultipleMonoSuffixes: plan.settings.fileLayout == .multipleMono,
            sampleRate: outputRate,
            bitDepth: kind == .mp3 ? nil : plan.settings.bitDepth,
            channelCount: discreteMono ? 1 : nil,
            durationSeconds: duration,
            durationToleranceSeconds: tolerance,
            requiresVideoTrack: kind == .mov,
            requiresAudioTrack: kind == .mov,
            movAudioCodec: kind == .mov ? .pcm : nil
        )
    }

    private func restore(
        snapshot: inout SessionSnapshot,
        job: inout BounceJob,
        crossSession: Bool
    ) async throws {
        try await transition(&job, to: .restoring, message: "Restoring Session state")
        let current = try await proTools.currentSessionIdentity()
        guard current.instanceID == snapshot.session.instanceID,
              current.path == snapshot.session.path else {
            throw QuickBounceError.sessionIdentityMismatch
        }
        let readback = try await proTools.apply(trackStates: snapshot.trackStates)
        try await TimelineRestoration.restore(snapshot.timelineState,
            legacySelection: snapshot.timelineSelection, using: proTools)
        try await transition(
            &job,
            to: .verifyingRestore,
            message: "Verifying restored Session state"
        )
        try verify(
            expected: snapshot.trackStates,
            actual: readback,
            restoration: true
        )

        if crossSession {
            try await transition(&job, to: .savingSession, message: "Saving restored Session")
            do {
                try await proTools.saveSession()
            } catch {
                throw QuickBounceError.diskSpaceFailure(for: error) ?? QuickBounceError.saveFailed(error.localizedDescription)
            }
        }

        snapshot.restoreRequired = false
        snapshot.verifiedAt = Date()
        try await store.save(snapshot: snapshot)
    }

    private func closeCurrentSession(job: inout BounceJob) async throws {
        try await transition(&job, to: .closingSession, message: "Closing restored Session")
        try await proTools.closeSession()
    }

    private func importRequests(
        for plan: BouncePlan,
        artifacts: [AudioArtifact]
    ) -> [ImportAudioRequest] {
        guard plan.settings.importAfterBounce else { return [] }
        let desiredKind: ArtifactKind = switch plan.settings.exportType {
        case .mp3: .mp3
        case .wav, .wavAndMP3: .wav
        case .mov: .mov
        }
        guard desiredKind != .mov else { return [] }
        return artifacts.filter { $0.kind == desiredKind && $0.state == .completed }.map {
            ImportAudioRequest(
                fileURL: $0.fileURL,
                spotSamples: plan.range.start,
                trackName: plan.name
            )
        }
    }

    private func transition(
        _ job: inout BounceJob,
        to state: BounceJobState,
        message: String
    ) async throws {
        if job.state != state {
            var machine = BounceJobStateMachine(state: job.state)
            try machine.transition(to: state)
            job.state = machine.state
        }
        job.cancellationRequested = job.cancellationRequested || cancellationRequested
        job.updatedAt = Date()
        currentJob = job
        try await persist(job: job, message: message)
        publish()
    }

    private func persist(job: BounceJob, message: String) async throws {
        try await store.save(job: job)
        let event = JobEvent(jobID: job.id, state: job.state, message: message)
        try await store.append(event: event)
        events.append(event)
        await diagnostics?.record(
            category: "bounce_state",
            action: "transition",
            correlationID: event.correlationID,
            fields: [
                "job_id": job.id.uuidString,
                "job_state": job.state.rawValue,
                "current_plan_id": job.currentPlanID?.uuidString ?? "",
                "message": message
            ]
        )
    }

    private func prepareCancellation(job: inout BounceJob) async {
        if job.state != .cancelRequested {
            job.state = .cancelRequested
            job.cancellationRequested = true
            job.updatedAt = Date()
            currentJob = job
            try? await persist(job: job, message: "Cancellation acknowledged")
        }
        if job.state == .cancelRequested {
            try? await transition(&job, to: .cancelling, message: "Stopping current Bounce safely")
        }
    }

    private func finishCancelled(job: inout BounceJob) async {
        job.state = .cancelled
        job.cancellationRequested = true
        job.failureMessage = nil
        job.updatedAt = Date()
        currentJob = job
        try? await persist(
            job: job,
            message: "Bounce cancelled; completed files were retained"
        )
    }

    private func finishFailed(job: inout BounceJob, error: Error) async {
        job.state = .failed
        let failure = (QuickBounceError.diskSpaceFailure(for: error) ?? error).localizedDescription
        job.failureMessage = failure
        job.updatedAt = Date()
        currentJob = job
        try? await persist(job: job, message: "Bounce failed: \(failure)")
    }

    private func finishRecoveryRequired(
        job: inout BounceJob, error: Error, interruptedBy bounceFailure: Error? = nil
    ) async -> BounceJob {
        job.state = .recoveryRequired
        job.cancellationRequested = job.cancellationRequested || cancellationRequested
        let restorationFailure = (QuickBounceError.diskSpaceFailure(for: error) ?? error).localizedDescription
        let failure: String
        if let bounceFailure, let diskSpace = QuickBounceError.diskSpaceFailure(for: bounceFailure) {
            failure = "\(diskSpace.localizedDescription)\n\(restorationFailure)"
        } else {
            failure = restorationFailure
        }
        job.failureMessage = failure
        job.updatedAt = Date()
        currentJob = job
        try? await persist(job: job, message: "Manual recovery required: \(failure)")
        await lease.release(for: job.id)
        publish()
        return job
    }

    private func verify(
        expected: [TrackState],
        actual: [TrackState],
        restoration: Bool
    ) throws {
        guard let issue = TrackStateVerification.firstIssue(
            expected: expected,
            actual: actual
        ) else { return }
        switch issue {
        case let .missingTrack(name):
            throw QuickBounceError.trackMissing(name)
        case let .ambiguousTrack(name):
            throw QuickBounceError.ambiguousTrackName(name)
        case let .stateMismatch(name):
            if restoration {
                throw QuickBounceError.restoreFailed(name)
            }
            throw QuickBounceError.stateVerificationFailed(name)
        }
    }

    private func verifySession(
        expected: SessionIdentity,
        actual: SessionIdentity,
        crossSession: Bool
    ) throws {
        if !crossSession {
            guard actual.instanceID == expected.instanceID else {
                throw QuickBounceError.sessionIdentityMismatch
            }
            return
        }
        let expectedPath = outputResolver.canonicalURL(for: expected.path).path
        let actualPath = outputResolver.canonicalURL(for: actual.path).path
        guard expectedPath == actualPath else { throw QuickBounceError.sessionIdentityMismatch }
        if !expected.originID.isEmpty, !actual.originID.isEmpty,
           expected.originID != actual.originID {
            throw QuickBounceError.sessionIdentityMismatch
        }
    }

    private func orderedSessionGroups(_ plans: [BouncePlan]) -> [SessionGroup] {
        var order: [String] = []
        var groups: [String: SessionGroup] = [:]
        for plan in plans {
            let key = outputResolver.canonicalURL(for: plan.session.path).path
            if var existing = groups[key] {
                existing.plans.append(plan)
                groups[key] = existing
            } else {
                order.append(key)
                groups[key] = SessionGroup(session: plan.session, plans: [plan])
            }
        }
        return order.compactMap { groups[$0] }
    }

    private func currentSessionFirst(
        _ groups: [SessionGroup],
        currentSessionPath: String
    ) -> [SessionGroup] {
        let currentPath = outputResolver.canonicalURL(for: currentSessionPath).path
        guard let index = groups.firstIndex(where: {
            outputResolver.canonicalURL(for: $0.session.path).path == currentPath
        }), index != groups.startIndex else { return groups }
        var reordered = groups
        let current = reordered.remove(at: index)
        reordered.insert(current, at: 0)
        return reordered
    }

    private func preflightDestinations(_ destinations: [URL]) throws {
        for destination in destinations {
            var values = try? destination.resourceValues(forKeys: [.isDirectoryKey])
            if values != nil, values?.isDirectory != true {
                throw QuickBounceError.invalidPlan("Destination is not a directory: \(destination.path)")
            }

            var writableAncestor = destination
            while !FileManager.default.fileExists(atPath: writableAncestor.path) {
                let parent = writableAncestor.deletingLastPathComponent()
                if parent.path == writableAncestor.path { break }
                writableAncestor = parent
            }
            values = try? writableAncestor.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  FileManager.default.isWritableFile(atPath: writableAncestor.path) else {
                throw QuickBounceError.permissionDenied(destination.path)
            }
        }
    }

    private func requireCapacity(_ bytes: Int64, at directory: URL) throws {
        guard let available = availableCapacity(directory), available < bytes else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        throw QuickBounceError.insufficientDiskSpace(
            "\(directory.path) needs \(formatter.string(fromByteCount: bytes)); \(formatter.string(fromByteCount: available)) is available"
        )
    }

    private func preflightOutputCollisions(
        _ plans: [BouncePlan],
        authorizedOverwritePaths: Set<String>
    ) throws {
        for output in try plannedOutputs(for: plans)
        where FileManager.default.fileExists(atPath: output.fileURL.path)
            && !authorizedOverwritePaths.contains(output.pathKey) {
            throw QuickBounceError.exportFailed(
                "Refusing to overwrite \(output.fileURL.path)"
            )
        }
        for output in try plannedOutputs(for: plans)
        where FileManager.default.fileExists(atPath: output.fileURL.path) {
            try validateReplaceableOutput(output.fileURL)
        }
    }

    private func plannedOutputs(
        for plans: [BouncePlan]
    ) throws -> [ExistingOutputCollision] {
        var plannedOutputs: [String: String] = [:]
        var outputs: [ExistingOutputCollision] = []
        for plan in plans {
            let destination = outputResolver.canonicalURL(for: plan.settings.fileDestination)
            let baseName = sanitizedFileName(plan.name, planID: plan.id)
            let kinds: [ArtifactKind] = switch plan.settings.exportType {
            case .wav: [.wav]
            case .mp3: [.mp3]
            case .wavAndMP3: [.wav, .mp3]
            case .mov: [.mov]
            }
            for kind in kinds {
                let expected = destination.appendingPathComponent("\(baseName).\(kind.rawValue)")
                let key = collisionKey(for: expected)
                if let existingPlan = plannedOutputs[key] {
                    throw QuickBounceError.invalidPlan(
                        "\(plan.name) and \(existingPlan) resolve to the same output: \(expected.path)"
                    )
                }
                plannedOutputs[key] = plan.name
                outputs.append(
                    ExistingOutputCollision(
                        planID: plan.id,
                        planName: plan.name,
                        fileURL: expected,
                        pathKey: key
                    )
                )
            }
        }
        return outputs
    }

    private func collisionKey(for url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func validateReplaceableOutput(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw QuickBounceError.invalidPlan(
                "Existing output is not a replaceable regular file: \(url.path)"
            )
        }
    }

    private func install(
        source: URL,
        at finalURL: URL,
        replacingExisting: Bool
    ) throws {
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".quickbounce-\(UUID().uuidString)-\(finalURL.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: source, to: temporaryURL)
        if replacingExisting {
            _ = try FileManager.default.replaceItemAt(
                finalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        }
    }

    private func preflightSessionFiles(_ plans: [BouncePlan], crossSession: Bool) throws {
        guard crossSession else { return }
        var checked = Set<String>()
        for plan in plans {
            let sessionURL = outputResolver.canonicalURL(for: plan.session.path)
            guard checked.insert(sessionURL.path).inserted else { continue }
            guard sessionURL.pathExtension.lowercased() == "ptx" else {
                throw QuickBounceError.invalidPlan(
                    "Cross-Session source is not a .ptx file: \(sessionURL.path)"
                )
            }
            guard FileManager.default.fileExists(atPath: sessionURL.path) else {
                throw QuickBounceError.invalidPlan(
                    "Cross-Session source does not exist: \(sessionURL.path)"
                )
            }
            let values = try? sessionURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: sessionURL.path) else {
                throw QuickBounceError.permissionDenied(
                    "Cross-Session source is not readable: \(sessionURL.path)"
                )
            }
            let parent = sessionURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: sessionURL.path),
                  FileManager.default.isWritableFile(atPath: parent.path) else {
                throw QuickBounceError.permissionDenied(
                    "Cross-Session source cannot be saved in place: \(sessionURL.path)"
                )
            }
        }
    }

    private func validateCapabilities(
        _ capabilities: PTSLCapabilities,
        plans: [BouncePlan],
        crossSession: Bool
    ) throws {
        guard capabilities.trackStateSetters else {
            throw QuickBounceError.capabilityMissing("Solo/Mute setters")
        }
        if plans.contains(where: { $0.settings.exportType == .mp3 }) &&
           !capabilities.audioEncodingOptions {
            throw QuickBounceError.capabilityMissing("direct MP3 export options")
        }
        if crossSession, !capabilities.openSessionBehaviorOptions {
            throw QuickBounceError.capabilityMissing("cross-Session OpenSession behavior options")
        }
        if plans.contains(where: { $0.settings.importAfterBounce }),
           !capabilities.importToNewTrackAtSamples {
            throw QuickBounceError.capabilityMissing("Import to a new track at an exact sample position")
        }
    }

    private func validateFramePadding(
        for plans: [BouncePlan],
        activeSessionTimeCodeRate: SessionTimeCodeRate?
    ) throws {
        guard activeSessionTimeCodeRate == nil,
              plans.contains(where: {
                  $0.settings.padToFrameBoundary && $0.sourceTimeCodeRate == nil
              }) else {
            return
        }
        throw QuickBounceError.invalidPlan(
            "Pro Tools did not report the Session frame rate required by Pad To Frame Boundary"
        )
    }

    private func validateMixSources(
        for plans: [BouncePlan],
        available: [ProToolsMixSource]
    ) throws {
        // GetExportMixSourceList was added in 2025.06. Older Hosts can still
        // accept the legacy mix_source_list field, but cannot enumerate it.
        guard !available.isEmpty else { return }
        let availableSet = Set(available)
        for plan in plans {
            let requested = ProToolsMixSource(
                type: plan.settings.mixSourceType,
                name: plan.settings.mixSource
            )
            guard !requested.name.isEmpty, availableSet.contains(requested) else {
                let alternatives = available
                    .filter { $0.type == requested.type }
                    .map(\.name)
                    .sorted()
                    .joined(separator: ", ")
                let detail = alternatives.isEmpty ? "none available" : alternatives
                throw QuickBounceError.invalidPlan(
                    "\(plan.name) requests \(requested.type.displayName) “\(requested.name)”; available: \(detail)"
                )
            }
        }
    }

    private func validatePlanTracks(_ plans: [BouncePlan], against actual: [TrackState]) throws {
        for plan in plans {
            let expectedByID = Dictionary(grouping: plan.targetTrackStates, by: { $0.track.id })
            guard expectedByID.values.allSatisfy({ $0.count == 1 }) else {
                throw QuickBounceError.invalidPlan("\(plan.name) contains duplicate Track IDs")
            }
            let resolved = try TrackStateResolver.resolve(
                expected: plan.targetTrackStates,
                against: actual
            )
            for (expected, current) in zip(plan.targetTrackStates, resolved) {
                guard current.track.name == expected.track.name else {
                    throw QuickBounceError.invalidPlan(
                        "Track “\(expected.track.name)” was renamed to “\(current.track.name)” after \(plan.name) was captured"
                    )
                }
            }
            let resolvedIDs = Set(resolved.map(\.track.id))
            let unexpected = actual.filter { !resolvedIDs.contains($0.track.id) }
            if let added = unexpected.first {
                throw QuickBounceError.invalidPlan(
                    "Track “\(added.track.name)” was added after \(plan.name) was captured; capture the Mix again"
                )
            }
        }
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw CancellationError() }
    }

    private func sanitizedFileName(_ name: String, planID: UUID) -> String {
        BounceOutputNaming.sanitized(name, planID: planID)
    }

    private func publish() {
        let value = snapshot()
        for continuation in continuations.values { continuation.yield(value) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
