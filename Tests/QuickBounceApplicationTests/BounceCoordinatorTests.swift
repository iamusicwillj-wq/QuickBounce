@preconcurrency import AVFoundation
import Foundation
import Darwin
import QuickBounceApplication
import QuickBounceAudio
import QuickBounceDomain
import QuickBouncePersistence
import QuickBounceProTools
import QuickBounceTestSupport
import Testing

@Test(arguments: [MOVAudioCodec.pcm, .aac], AACBitRateMode.allCases)
func movBounceDeliversRequestedCodecWithoutMovingPictureOrSound(codec: MOVAudioCodec, bitRateMode: AACBitRateMode) async throws {
    // H.264 with B-frames, a timecode track and a PCM track that begins
    // 160 ms into the movie. The first audible marker is at 410 ms.
    let source = try #require(Bundle.module.url(
        forResource: "delayed-audio", withExtension: "mov", subdirectory: "Fixtures"
    ))
    let environment = try await makeEnvironment("mov-codec-\(codec.rawValue)-\(bitRateMode.rawValue)", exportWriter: { _, output in
        try FileManager.default.copyItem(at: source, to: output)
    })
    let plan = makePlan(name: "Picture", settings: BounceSettings(
        exportType: .mov, bitDepth: 16, movAudioCodec: codec, movAACBitRateMode: bitRateMode,
        padToFrameBoundary: false, fileDestination: environment.output.path
    ))
    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    #expect(job.state == .reviewReady, "Failure: \(job.failureMessage ?? "none")")
    let requests = await environment.adapter.trace().exportRequests
    #expect(requests.count == 1)
    let staging = try #require(requests.first?.stagingDirectory)
    #expect(staging.deletingLastPathComponent().path == environment.output.path)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    let artifact = try #require(await environment.coordinator.snapshot().artifacts.first)
    let output = artifact.fileURL
    #expect(output.lastPathComponent == "Picture.mov")
    if codec == .pcm {
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
        return
    }

    let movie = AVURLAsset(url: output)
    let tracks = try await movie.loadTracks(withMediaType: .audio)
    let audio = try #require(tracks.first)
    let descriptions = try await audio.load(.formatDescriptions)
    #expect(descriptions.first?.mediaSubType.rawValue == kAudioFormatMPEG4AAC)
    #expect(artifact.channelCount == 1)
    #expect(artifact.sampleRate == 48_000)
    for type in [AVMediaType.video, .timecode] {
        let before = try await movieSamples(source, type: type)
        let after = try await movieSamples(output, type: type)
        #expect(!before.isEmpty && after == before)
    }
    let markerBefore = try await firstAudibleSample(source)
    let markerAfter = try await firstAudibleSample(output)
    #expect(abs(markerBefore - 0.410) < 0.001)
    #expect(abs(markerAfter - markerBefore) < 0.001)
}

@Test(arguments: [false, true])
func movRetriesOnlyForSameAsSourceRejection(volumeError: Bool) async throws {
    let source = try #require(Bundle.module.url(
        forResource: "delayed-audio", withExtension: "mov", subdirectory: "Fixtures"
    ))
    let reason = volumeError
        ? #"Can't create bounce files because \"Macintosh HD\" is not an audio playback volume.."#
        : "Failed to procede with bounce. Refer to error dialog."
    let environment = try await makeEnvironment("mov-video-retry", exportWriter: { request, output in
        if request.videoMode == .sameAsSource {
            // Some failed host exports leave a partial file.
            try Data("partial MOV".utf8).write(to: output)
            throw PTSLTransportError.command(status: 4, message: """
            {"errors":[
              {"command_error_type":"CEType_PT_UnknownError","command_error_message":"Long GOP video requires the first frame of the file to be included in the bounce range.","is_warning":true},
              {"command_error_type":"CEType_PT_UnknownError","command_error_message":"\(reason)","is_warning":false}
            ]}
            """)
        }
        try FileManager.default.copyItem(at: source, to: output)
    })
    let plan = makePlan(name: "Picture", settings: BounceSettings(
        exportType: .mov, bitDepth: 16, movAudioCodec: .aac,
        padToFrameBoundary: false, fileDestination: environment.output.path
    ))
    let originalTimeline = try await environment.adapter.currentTimelineState()
    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let requests = await environment.adapter.trace().exportRequests
    let expectedModes: [ProToolsVideoExportMode] = volumeError ? [.sameAsSource] : [.sameAsSource, .transcodeH264]
    #expect(requests.map(\.videoMode) == expectedModes)
    #expect(requests.allSatisfy { $0.plan.range == plan.range })
    #expect(requests.allSatisfy { !FileManager.default.fileExists(atPath: $0.stagingDirectory.path) })
    #expect(try await environment.adapter.currentTimelineState() == originalTimeline)
    if volumeError {
        #expect(job.state == .failed)
        #expect(job.failureMessage?.contains("is not an audio playback volume") == true)
        #expect((await environment.coordinator.snapshot()).completedPlanIDsToRemove.isEmpty)
    } else {
        #expect(job.state == .reviewReady, "Failure: \(job.failureMessage ?? "none")")
        let artifact = try #require((await environment.coordinator.snapshot()).artifacts.first)
        #expect(artifact.fileURL.deletingLastPathComponent().path == environment.output.path)
    }
}

private struct MovieSample: Equatable {
    let presentationTime: CMTime
    let decodeTime: CMTime
    let bytes: Data
}

private func movieSamples(
    _ url: URL, type: AVMediaType, settings: [String: Any]? = nil
) async throws -> [MovieSample] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: type)
    let track = try #require(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    try #require(reader.startReading())
    var samples: [MovieSample] = []
    while let sample = output.copyNextSampleBuffer() {
        // AVFoundation emits empty buffers to signal edit boundaries.
        guard sample.numSamples > 0 else { continue }
        let block = try #require(sample.dataBuffer)
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        try #require(status == noErr)
        samples.append(MovieSample(presentationTime: sample.presentationTimeStamp,
            decodeTime: sample.decodeTimeStamp, bytes: bytes))
    }
    try #require(reader.status == .completed)
    return samples
}

private func firstAudibleSample(_ url: URL) async throws -> Double {
    let samples = try await movieSamples(url, type: .audio, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false
    ])
    for sample in samples {
        let index = sample.bytes.withUnsafeBytes { bytes in
            (0..<(bytes.count / MemoryLayout<Float>.size)).first {
                abs(bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)) > 0.1
            }
        }
        if let index { return sample.presentationTime.seconds + Double(index) / 48_000 }
    }
    throw QuickBounceError.artifactInvalid("The audio marker was not found")
}

@Test func bounceRestoresIndependentMarkerAndRolls() async throws {
    let environment = try await makeEnvironment("full-timeline-restore")
    let original = TimelineState(selection: SampleRange(start: 96_123, end: 240_456),
        playStartMarker: 72_321, preRollStart: 48_111, postRollStop: 288_999,
        preRollEnabled: true, postRollEnabled: true)
    try await environment.adapter.setTimelineState(original)
    let plan = makePlan(name: "Restore All", settings: BounceSettings(fileDestination: environment.output.path))
    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    #expect(job.state == .reviewReady)
    #expect(try await environment.adapter.currentTimelineState() == original)
}

@Test func actualFileSizeIsCheckedBeforeReplacingDelivery() async throws {
    let environment = try await makeEnvironment("capacity-drop", availableCapacity: { _ in 0 })
    let original = TimelineState(selection: SampleRange(start: 123, end: 456),
        playStartMarker: 78, preRollStart: 12, postRollStop: 789,
        preRollEnabled: true, postRollEnabled: true)
    try await environment.adapter.setTimelineState(original)
    let plan = makePlan(name: "Preserved", settings: BounceSettings(fileDestination: environment.output.path))
    try FileManager.default.createDirectory(at: environment.output, withIntermediateDirectories: true)
    let delivery = environment.output.appendingPathComponent("Preserved.wav")
    let existing = Data("prior delivery must remain intact".utf8)
    try existing.write(to: delivery)
    let collisions = try await environment.coordinator.existingOutputCollisions(for: [plan])
    let job = await environment.coordinator.run(plans: [plan], crossSession: false,
        authorizedOverwritePaths: Set(collisions.map(\.pathKey)))
    #expect(job.state == .failed)
    #expect(job.failureMessage?.contains("Not enough disk space") == true, "Failure: \(job.failureMessage ?? "nil")")
    #expect(await environment.adapter.trace().exportRequests.count == 1)
    #expect(try Data(contentsOf: delivery) == existing)
    #expect(try await environment.adapter.currentTimelineState() == original)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
    #expect(await environment.adapter.trace().importRequests.isEmpty)
}

@Test(arguments: [false, true])
func crashRecoveryRestoresFullTimelineOrRetainsJournalOnRollMismatch(mismatch: Bool) async throws {
    let environment = try await makeEnvironment("full-timeline-recovery-\(mismatch)")
    _ = try await environment.adapter.connect()
    let original = TimelineState(selection: SampleRange(start: 172_800_123, end: 172_800_123),
        playStartMarker: 172_700_000, preRollStart: 172_600_000, postRollStop: 172_900_000,
        preRollEnabled: true, postRollEnabled: true)
    let journal = SessionSnapshot(jobID: UUID(), session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks, timelineState: original, saveAfterRestore: true)
    try await environment.store.save(snapshot: journal)
    let roundTrip = try #require(try await environment.store.pendingSnapshots().first)
    #expect(roundTrip.timelineState == original)
    if mismatch { await environment.adapter.injectFailure(.timelineRollReadbackMismatch) }
    if mismatch {
        await #expect(throws: QuickBounceError.self) { try await environment.coordinator.recoverPendingSnapshots() }
        #expect(try await environment.store.pendingSnapshots().count == 1)
        #expect(await environment.adapter.trace().saveCount == 0)
    } else {
        #expect(try await environment.coordinator.recoverPendingSnapshots().isEmpty)
        #expect(try await environment.adapter.currentTimelineState() == original)
        #expect(await environment.adapter.trace().saveCount == 1)
    }
}

@Test func wavAndMP3UsesOneBounceAndImportsOnlyWAV() async throws {
    let environment = try await makeEnvironment("wav-mp3")
    var settings = BounceSettings(
        exportType: .wavAndMP3,
        importAfterBounce: true,
        fileDestination: environment.output.path
    )
    settings.mp3ConstantBitRateKbps = 192
    let plan = makePlan(name: "Main Mix", settings: settings)

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let snapshot = await environment.coordinator.snapshot()
    let trace = await environment.adapter.trace()

    #expect(job.state == .reviewReady)
    #expect(trace.exportRequests.count == 1)
    #expect(trace.exportRequests.first?.kind == .wav)
    #expect(Set(snapshot.artifacts.map(\.kind)) == Set([.wav, .mp3]))
    #expect(snapshot.artifacts.allSatisfy { $0.state == .completed })
    #expect(snapshot.completedPlanIDs == [plan.id])
    #expect(trace.importRequests.count == 1)
    #expect(trace.importRequests.first?.fileURL.pathExtension.lowercased() == "wav")
    #expect(trace.importRequests.first?.spotSamples == plan.range.start)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
}

@Test func coordinatorReusesVerifiedReadbackAndDoesNotEnumerateAgainPerMix() async throws {
    let environment = try await makeEnvironment("shared-readback")
    let plan = makePlan(name: "Shared", settings: BounceSettings(fileDestination: environment.output.path))
    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    #expect(job.state == .reviewReady)
    let trace = await environment.adapter.trace()
    // The Fake adapter returns its readback from apply, so the only separate
    // enumeration is the Session context shared with the durable snapshot.
    #expect(trace.trackReadCount == 1)
}

@Test func mismatchedApplyReadbackPreventsExportAndStillRestoresSnapshot() async throws {
    let environment = try await makeEnvironment("readback-mismatch")
    await environment.adapter.injectFailure(.applyReadbackMismatch)
    var plan = makePlan(name: "Wrong State", settings: BounceSettings(fileDestination: environment.output.path))
    plan.targetTrackStates[0].isMuted.toggle()
    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    #expect(job.state == .failed)
    #expect(await environment.adapter.trace().exportRequests.isEmpty)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test func framePaddedWAVPassesIntegrityCheckWhenGrowthExceedsOneFrame() async throws {
    let environment = try await makeEnvironment("frame-padded-wav")
    var plan = makePlan(
        name: "Frame Padded",
        settings: BounceSettings(
            exportType: .wav,
            padToFrameBoundary: true,
            fileDestination: environment.output.path
        )
    )
    // At 25 fps this selection grows by almost two frames: In rounds from
    // sample 1919 to 0 and Out rounds from 48001 to 49920.
    plan.range = SampleRange(start: 1_919, end: 48_001)
    plan.sourceTimeCodeRate = .fps25

    let rawDuration = Double(plan.range.length) / 48_000
    let paddedDuration = SessionTimeCodeRate.fps25.paddedDuration(
        for: plan.range,
        sampleRate: 48_000
    )
    #expect(paddedDuration - rawDuration > SessionTimeCodeRate.fps25.frameDurationSeconds)

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let artifact = try #require((await environment.coordinator.snapshot()).artifacts.first)

    #expect(job.state == .reviewReady)
    #expect(abs((artifact.durationSeconds ?? 0) - paddedDuration) < 0.000_001)
}

@Test func framePaddedWAVFailsStrictIntegrityCheckWhenPaddingIsOff() async throws {
    let range = SampleRange(start: 1_919, end: 48_001)
    let paddedDuration = SessionTimeCodeRate.fps25.paddedDuration(
        for: range,
        sampleRate: 48_000
    )
    let environment = try await makeEnvironment(
        "unexpected-frame-padding",
        exportWriter: { request, outputURL in
            try TestWorkspace.makeWAV(
                at: outputURL,
                sampleRate: request.plan.settings.sampleRate,
                durationSeconds: paddedDuration
            )
        }
    )
    var plan = makePlan(
        name: "Strict Selection",
        settings: BounceSettings(
            exportType: .wav,
            bitDepth: 16,
            padToFrameBoundary: false,
            fileDestination: environment.output.path
        )
    )
    plan.range = range
    plan.sourceTimeCodeRate = .fps25

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)

    #expect(job.state == .failed)
    let failureMessage = try #require(job.failureMessage)
    #expect(failureMessage.contains("Duration is"))
}

@Test func mp3OnlyUsesDirectProToolsExportAndImportsMP3() async throws {
    let environment = try await makeEnvironment(
        "mp3-direct",
        exportWriter: { request, outputURL in
            let sourceRate = request.plan.sourceSampleRate ?? request.plan.settings.sampleRate
            let duration = Double(request.plan.range.length) / Double(max(1, sourceRate))
            let source = outputURL.appendingPathExtension("source.wav")
            try TestWorkspace.makeWAV(
                at: source,
                sampleRate: request.plan.settings.sampleRate,
                channelCount: request.plan.settings.fileLayout == .interleaved ? 2 : 1,
                durationSeconds: duration
            )
            try await MP3Transcoder().transcode(
                source: source,
                destination: outputURL,
                bitRateKbps: request.plan.settings.mp3ConstantBitRateKbps,
                quality: request.plan.settings.mp3Quality
            )
        }
    )
    let plan = makePlan(
        name: "Direct MP3",
        settings: BounceSettings(
            exportType: .mp3,
            mp3ConstantBitRateKbps: 256,
            importAfterBounce: true,
            fileDestination: environment.output.path
        )
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let snapshot = await environment.coordinator.snapshot()
    let trace = await environment.adapter.trace()

    #expect(job.state == .reviewReady)
    #expect(trace.exportRequests.count == 1)
    #expect(trace.exportRequests.first?.kind == .mp3)
    #expect(snapshot.artifacts.map(\.kind) == [.mp3])
    #expect(snapshot.completedPlanIDs == [plan.id])
    #expect(trace.importRequests.count == 1)
    #expect(trace.importRequests.first?.fileURL.pathExtension.lowercased() == "mp3")
}

@Test func failedMP3TranscodeRetainsCompletedWAVAndRestores() async throws {
    let environment = try await makeEnvironment("mp3-failure")
    let settings = BounceSettings(
        exportType: .wavAndMP3,
        mp3ConstantBitRateKbps: 999,
        importAfterBounce: true,
        fileDestination: environment.output.path
    )
    let plan = makePlan(name: "Keep WAV", settings: settings)

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let snapshot = await environment.coordinator.snapshot()
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(snapshot.artifacts.count == 1)
    #expect(snapshot.artifacts.first?.kind == .wav)
    #expect(snapshot.artifacts.first?.state == .completed)
    #expect(snapshot.completedPlanIDs.isEmpty)
    #expect(trace.importRequests.isEmpty)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(FileManager.default.fileExists(atPath: environment.output.appendingPathComponent("Keep WAV.wav").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: environment.staging.path).isEmpty)
}

@Test func cancelStopsCurrentBounceRestoresAndDoesNotImport() async throws {
    let environment = try await makeEnvironment("cancel", operationDelay: .milliseconds(500))
    let settings = BounceSettings(
        exportType: .wav,
        importAfterBounce: true,
        fileDestination: environment.output.path
    )
    let plan = makePlan(name: "Cancel Me", settings: settings)
    let stream = await environment.coordinator.snapshots()

    let runTask = Task {
        await environment.coordinator.run(plans: [plan], crossSession: false)
    }
    var iterator = stream.makeAsyncIterator()
    while let value = await iterator.next() {
        if value.job?.state == .exporting { break }
    }
    await environment.coordinator.requestCancel()
    let job = await runTask.value
    let trace = await environment.adapter.trace()

    #expect(job.state == .cancelled)
    #expect(trace.cancelCount == 1)
    #expect(trace.importRequests.isEmpty)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try FileManager.default.contentsOfDirectory(atPath: environment.staging.path).isEmpty)
}

@Test func cancellationDuringRestorationRetainsDeliveryWithoutImportingIt() async throws {
    let environment = try await makeEnvironment("cancel-during-restore", operationDelay: .milliseconds(150))
    let plan = makePlan(name: "Completed Before Cancel", settings: BounceSettings(
        importAfterBounce: true,
        fileDestination: environment.output.path
    ))
    let originalSelection = SampleRange(start: 123, end: 456)
    try await environment.adapter.setTimelineSelection(originalSelection)
    let stream = await environment.coordinator.snapshots()
    let runTask = Task { await environment.coordinator.run(plans: [plan], crossSession: false) }
    var iterator = stream.makeAsyncIterator()
    while let snapshot = await iterator.next() {
        if snapshot.job?.state == .restoring { break }
    }
    await environment.coordinator.requestCancel()
    var acknowledged = false
    while let snapshot = await iterator.next() {
        if snapshot.job?.cancellationRequested == true { acknowledged = true }
        if acknowledged { #expect(snapshot.job?.cancellationRequested == true) }
        if snapshot.job?.state.isTerminal == true { break }
    }
    let job = await runTask.value
    let trace = await environment.adapter.trace()
    let snapshot = await environment.coordinator.snapshot()

    #expect(job.state == .cancelled)
    #expect(trace.importRequests.isEmpty)
    #expect(trace.cancelCount == 0) // Recovery must not be interrupted by export cancellation.
    #expect(acknowledged)
    #expect(job.cancellationRequested)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await environment.adapter.currentTimelineSelection() == originalSelection)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
    #expect(snapshot.artifacts.count == 1 && snapshot.artifacts[0].state == .completed)
    #expect(FileManager.default.fileExists(atPath: environment.output.appendingPathComponent("Completed Before Cancel.wav").path))
}

@Test func successfulBounceDeletesStagingAndKeepsDeliveredFiles() async throws {
    let environment = try await makeEnvironment("staging-success")
    let plan = makePlan(
        name: "Delivered Mix",
        settings: BounceSettings(
            exportType: .wavAndMP3,
            fileDestination: environment.output.path
        )
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)

    #expect(job.state == .reviewReady)
    #expect(FileManager.default.fileExists(
        atPath: environment.output.appendingPathComponent("Delivered Mix.wav").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: environment.output.appendingPathComponent("Delivered Mix.mp3").path
    ))
    #expect(try FileManager.default.contentsOfDirectory(atPath: environment.staging.path).isEmpty)
}

@Test func completedArtifactIsPublishedBeforeLaterBounceFinishes() async throws {
    let environment = try await makeEnvironment(
        "live-review-pipeline",
        operationDelay: .milliseconds(40)
    )
    let settings = BounceSettings(fileDestination: environment.output.path)
    let first = makePlan(name: "Pipeline First", settings: settings)
    let second = makePlan(name: "Pipeline Second", settings: settings)
    let stream = await environment.coordinator.snapshots()
    let runTask = Task {
        await environment.coordinator.run(plans: [first, second], crossSession: false)
    }

    var observedLiveArtifact = false
    var iterator = stream.makeAsyncIterator()
    while let snapshot = await iterator.next() {
        if snapshot.artifacts.contains(where: {
            $0.planID == first.id && $0.state == .completed
        }) {
            observedLiveArtifact = snapshot.job?.state.isTerminal == false
            break
        }
        if snapshot.job?.state.isTerminal == true { break }
    }
    let job = await runTask.value

    #expect(job.state == .reviewReady)
    #expect(observedLiveArtifact)
}

@Test func cancellingLaterMixKeepsEarlierDeliveryAndDeletesAllStaging() async throws {
    let environment = try await makeEnvironment(
        "staging-cancel-after-delivery",
        operationDelay: .milliseconds(350)
    )
    let settings = BounceSettings(fileDestination: environment.output.path)
    let first = makePlan(name: "Completed Before Cancel", settings: settings)
    let second = makePlan(name: "Cancelled In Progress", settings: settings)
    let stream = await environment.coordinator.snapshots()
    let runTask = Task {
        await environment.coordinator.run(plans: [first, second], crossSession: false)
    }
    var iterator = stream.makeAsyncIterator()
    while let value = await iterator.next() {
        if value.job?.currentPlanID == second.id,
           value.job?.state == .exporting {
            break
        }
    }

    await environment.coordinator.requestCancel()
    let job = await runTask.value

    #expect(job.state == .cancelled)
    #expect(FileManager.default.fileExists(
        atPath: environment.output.appendingPathComponent("Completed Before Cancel.wav").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: environment.output.appendingPathComponent("Cancelled In Progress.wav").path
    ))
    #expect(try FileManager.default.contentsOfDirectory(atPath: environment.staging.path).isEmpty)
}

@Test func stagingStartupCleanupRemovesAbandonedJobsAndPreservesLiveOwner() throws {
    let root = try TestWorkspace.freshDirectory("staging-startup-cleanup")
    let legacyJob = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let deadJob = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let liveJob = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for directory in [legacyJob, deadJob, liveJob] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("temporary export".utf8).write(
            to: directory.appendingPathComponent("candidate.wav")
        )
    }
    try Data("40404\n".utf8).write(
        to: deadJob.appendingPathComponent(StagingDirectoryLifecycle.ownerFileName)
    )
    try Data("50505\n".utf8).write(
        to: liveJob.appendingPathComponent(StagingDirectoryLifecycle.ownerFileName)
    )

    try StagingDirectoryLifecycle.prepareRoot(root) { $0 == 50_505 }

    #expect(!FileManager.default.fileExists(atPath: legacyJob.path))
    #expect(!FileManager.default.fileExists(atPath: deadJob.path))
    #expect(FileManager.default.fileExists(atPath: liveJob.path))
}

@Test func startupCleanupDoesNotDiscardPendingSessionRecovery() async throws {
    let root = try TestWorkspace.freshDirectory("staging-recovery-independent")
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let abandoned = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data("incomplete".utf8).write(to: abandoned.appendingPathComponent("partial.wav"))
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks
    )
    try await store.save(snapshot: snapshot)

    _ = try BounceCoordinator(
        proTools: FakeProToolsAdapter(),
        store: store,
        workDirectory: staging
    )

    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(try await store.pendingSnapshots() == [snapshot])
}

@Test func legacyDatabaseMigrationPreservesPendingSessionRecovery() async throws {
    let root = try TestWorkspace.freshDirectory("legacy-database-migration")
    let legacyDatabase = root
        .appendingPathComponent("legacy", isDirectory: true)
        .appendingPathComponent("QuickBounce.sqlite")
    let destinationDatabase = root
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("QuickBounce.sqlite")
    var legacyStore: SQLiteStore? = try SQLiteStore(url: legacyDatabase)
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks
    )
    try await legacyStore?.save(snapshot: snapshot)
    legacyStore = nil

    let installed = try LegacyInternalDataMigration.installDatabaseIfNeeded(
        from: legacyDatabase,
        to: destinationDatabase
    )
    let migratedStore = try SQLiteStore(url: destinationDatabase)

    #expect(installed)
    #expect(try await migratedStore.pendingSnapshots() == [snapshot])
    #expect(try !LegacyInternalDataMigration.installDatabaseIfNeeded(
        from: legacyDatabase,
        to: destinationDatabase
    ))
}

@Test func cancelDoesNotAttemptRestoreUntilHostIsReady() async throws {
    let environment = try await makeEnvironment("cancel-host-not-ready", operationDelay: .milliseconds(250))
    await environment.adapter.injectFailure(.hostReady)
    let plan = makePlan(
        name: "Host Busy",
        settings: BounceSettings(fileDestination: environment.output.path)
    )
    let stream = await environment.coordinator.snapshots()
    let runTask = Task {
        await environment.coordinator.run(plans: [plan], crossSession: false)
    }
    var iterator = stream.makeAsyncIterator()
    while let value = await iterator.next() {
        if value.job?.state == .exporting { break }
    }

    await environment.coordinator.requestCancel()
    let job = await runTask.value
    let trace = await environment.adapter.trace()

    #expect(job.state == .recoveryRequired)
    #expect(trace.cancelCount == 1)
    #expect(trace.appliedStates.count == 1)
    #expect(try await environment.store.pendingSnapshots().count == 1)
}

@Test func restoreFailureLeavesDurableRecoveryJournal() async throws {
    let environment = try await makeEnvironment("restore-failure")
    await environment.adapter.injectFailure(.restore)
    let plan = makePlan(
        name: "Recovery",
        settings: BounceSettings(fileDestination: environment.output.path)
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)

    #expect(job.state == .recoveryRequired)
    #expect(try await environment.store.pendingSnapshots().count == 1)
}

@Test func crashRecoveryRestoresAndSavesCrossSessionJournal() async throws {
    let environment = try await makeEnvironment("cross-session-crash-recovery")
    _ = try await environment.adapter.connect()
    var changed = FakeProToolsAdapter.demoTracks
    changed[0].isSolo = true
    try await environment.adapter.apply(trackStates: changed)
    await environment.adapter.resetTrace()
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks,
        saveAfterRestore: true
    )
    try await environment.store.save(snapshot: snapshot)

    let remaining = try await environment.coordinator.recoverPendingSnapshots()
    let trace = await environment.adapter.trace()

    #expect(remaining.isEmpty)
    #expect(trace.operations == ["apply", "save"])
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test(arguments: [false, true])
func crashRecoveryRestoresOriginalTimelineSelectionBeforeClearingJournal(saveAfterRestore: Bool) async throws {
    let environment = try await makeEnvironment("crash-recovery-timeline-\(saveAfterRestore)")
    _ = try await environment.adapter.connect()
    let originalSelection = SampleRange(start: 12_345, end: 67_890)
    try await environment.adapter.setTimelineSelection(SampleRange(start: 48_000, end: 96_000))
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks,
        timelineSelection: originalSelection,
        saveAfterRestore: saveAfterRestore
    )
    try await environment.store.save(snapshot: snapshot)

    let remaining = try await environment.coordinator.recoverPendingSnapshots()

    #expect(try await environment.adapter.currentTimelineSelection() == originalSelection)
    #expect(remaining.isEmpty)
    #expect(await environment.adapter.trace().saveCount == (saveAfterRestore ? 1 : 0))
}

@Test(arguments: [
    FakeProToolsAdapter.InjectedFailure.timelineWrite,
    .timelineRead,
    .timelineReadbackMismatch
])
func failedCrashRecoveryTimelineKeepsJournalAndDoesNotSave(failure: FakeProToolsAdapter.InjectedFailure) async throws {
    let environment = try await makeEnvironment("recovery-timeline-failure-\(failure)")
    _ = try await environment.adapter.connect()
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks,
        timelineSelection: SampleRange(start: 100, end: 200),
        saveAfterRestore: true
    )
    try await environment.store.save(snapshot: snapshot)
    await environment.adapter.injectFailure(failure)

    await #expect(throws: QuickBounceError.self) {
        try await environment.coordinator.recoverPendingSnapshots()
    }

    #expect(try await environment.store.pendingSnapshots().map(\.id) == [snapshot.id])
    #expect(await environment.adapter.trace().saveCount == 0)
}

@Test func failedTimelineCapturePreventsAllBounceMutations() async throws {
    let environment = try await makeEnvironment("timeline-capture-failed")
    await environment.adapter.injectFailure(.timelineRead)
    let plan = makePlan(name: "Do Not Mutate", settings: BounceSettings(fileDestination: environment.output.path))

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.appliedStates.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test(arguments: [
    FakeProToolsAdapter.InjectedFailure.timelineRead,
    .timelineWrite,
    .timelineReadbackMismatch
])
func normalRestoreFailureKeepsRecoveryJournal(failure: FakeProToolsAdapter.InjectedFailure) async throws {
    let environment = try await makeEnvironment("normal-restore-timeline-\(failure)", operationDelay: .milliseconds(150))
    let plan = makePlan(name: "Keep Recovery", settings: BounceSettings(fileDestination: environment.output.path))
    let originalSelection = SampleRange(start: 123, end: 456)
    try await environment.adapter.setTimelineSelection(originalSelection)
    let stream = await environment.coordinator.snapshots()
    let runTask = Task { await environment.coordinator.run(plans: [plan], crossSession: false) }
    for await snapshot in stream {
        if snapshot.job?.state == .restoring { break }
    }
    await environment.adapter.injectFailure(failure)
    let job = await runTask.value

    #expect(job.state == .recoveryRequired)
    let journal = try #require(try await environment.store.pendingSnapshots().first)
    #expect(journal.timelineSelection == originalSelection)
    #expect(journal.restoreRequired && journal.verifiedAt == nil)
    #expect(await environment.adapter.trace().saveCount == 0)
}

@Test func cancellationIsNotLostWhenRestorationThenFails() async throws {
    let environment = try await makeEnvironment("cancel-then-restore-failure", operationDelay: .milliseconds(150))
    let plan = makePlan(name: "Keep Cancel Request", settings: BounceSettings(
        importAfterBounce: true,
        fileDestination: environment.output.path
    ))
    let stream = await environment.coordinator.snapshots()
    let runTask = Task { await environment.coordinator.run(plans: [plan], crossSession: false) }
    for await snapshot in stream {
        if snapshot.job?.state == .restoring { break }
    }
    await environment.adapter.injectFailure(.timelineRead)
    await environment.coordinator.requestCancel()
    let job = await runTask.value
    let snapshot = await environment.coordinator.snapshot()
    let journal = try #require(try await environment.store.pendingSnapshots().first)

    #expect(job.state == .recoveryRequired) // Failure takes precedence over Cancelled.
    #expect(job.cancellationRequested)
    #expect(snapshot.job?.cancellationRequested == true)
    #expect(journal.restoreRequired && journal.verifiedAt == nil)
    #expect(await environment.adapter.trace().importRequests.isEmpty)
}

@Test(arguments: [SessionTimeCodeRate.fps23_976, .fps25, .fps29_97], [
    SampleRange(start: 172_800_123, end: 172_800_123),
    SampleRange(start: 172_800_123, end: 172_880_456)
])
func recoveryPreservesExactSamplePositionsAtEveryFrameRate(rate: SessionTimeCodeRate, range: SampleRange) async throws {
    let environment = try await makeEnvironment("recovery-exact-samples-\(rate.numerator)-\(range.end)", timeCodeRate: rate)
    _ = try await environment.adapter.connect()
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: FakeProToolsAdapter.demoTracks,
        timelineSelection: range
    )
    try await environment.store.save(snapshot: snapshot)

    #expect(try await environment.coordinator.recoverPendingSnapshots().isEmpty)
    #expect(try await environment.adapter.currentTimelineSelection() == range)
}

@Test func recoveryRebindsTrackIDsChangedSinceSnapshotCapture() async throws {
    let environment = try await makeEnvironment("recovery-stale-track-ids")
    _ = try await environment.adapter.connect()
    var captured = FakeProToolsAdapter.demoTracks
    for index in captured.indices {
        let old = captured[index].track
        captured[index].track = TrackReference(
            id: "stale-\(index)",
            name: old.name,
            index: old.index,
            kind: old.kind,
            parentFolderID: old.parentFolderID
        )
    }
    captured[0].isSolo = true
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: FakeProToolsAdapter.demoSession.identity,
        trackStates: captured
    )
    try await environment.store.save(snapshot: snapshot)

    let remaining = try await environment.coordinator.recoverPendingSnapshots()
    let live = try await environment.adapter.trackStates()

    #expect(remaining.isEmpty)
    #expect(live[0].track.id == FakeProToolsAdapter.demoTracks[0].track.id)
    #expect(live[0].isSolo)
}

@Test func crossSessionRestoresAndSavesEverySessionButLeavesTheLastOneOpen() async throws {
    let root = try TestWorkspace.freshDirectory("cross-session")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let firstSessionURL = root.appendingPathComponent("First.ptx")
    let secondSessionURL = root.appendingPathComponent("Second.ptx")
    try Data("first".utf8).write(to: firstSessionURL)
    try Data("second".utf8).write(to: secondSessionURL)
    var sessionOne = FakeProToolsAdapter.demoSession
    sessionOne.identity.path = firstSessionURL.path
    let adapter = FakeProToolsAdapter(sessionInfo: sessionOne, operationDelay: .milliseconds(5))
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    var secondIdentity = sessionOne.identity
    secondIdentity.path = secondSessionURL.path
    secondIdentity.originID = ""
    secondIdentity.instanceID = "captured-second-instance"
    let settings = BounceSettings(fileDestination: output.path)
    let first = makePlan(name: "Session One", settings: settings, session: sessionOne.identity)
    let second = makePlan(name: "Session Two", settings: settings, session: secondIdentity)

    let job = await coordinator.run(plans: [first, second], crossSession: true)
    let trace = await adapter.trace()

    #expect(job.state == .reviewReady)
    #expect(trace.saveCount == 2)
    #expect(trace.closeCount == 1)
    #expect(try await adapter.currentSessionIdentity().path == secondIdentity.path)
    #expect(try await adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await store.pendingSnapshots().isEmpty)
    #expect(trace.openedSessionURLs.map(\.path) == [secondIdentity.path])
    let firstSave = trace.operations.firstIndex(of: "save")
    let firstClose = trace.operations.firstIndex(of: "close")
    let openSecond = trace.operations.firstIndex(of: "open:\(secondIdentity.path)")
    #expect(firstSave != nil && firstClose != nil && openSecond != nil)
    #expect(firstSave! < firstClose! && firstClose! < openSecond!)
}

@Test func crossSessionStartsWithCurrentlyOpenSessionThenReturnsToListOrder() async throws {
    let root = try TestWorkspace.freshDirectory("cross-session-current-first")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let firstSessionURL = root.appendingPathComponent("First.ptx")
    let secondSessionURL = root.appendingPathComponent("Second.ptx")
    try Data("first".utf8).write(to: firstSessionURL)
    try Data("second".utf8).write(to: secondSessionURL)

    var activeSecond = FakeProToolsAdapter.demoSession
    activeSecond.identity.path = secondSessionURL.path
    activeSecond.name = "Second"
    let adapter = FakeProToolsAdapter(sessionInfo: activeSecond, operationDelay: .milliseconds(5))
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    var firstIdentity = activeSecond.identity
    firstIdentity.path = firstSessionURL.path
    firstIdentity.originID = ""
    firstIdentity.instanceID = "captured-first-instance"
    let settings = BounceSettings(fileDestination: output.path)
    let first = makePlan(name: "First Mix", settings: settings, session: firstIdentity)
    let second = makePlan(name: "Second Mix", settings: settings, session: activeSecond.identity)

    let job = await coordinator.run(plans: [first, second], crossSession: true)
    let trace = await adapter.trace()

    #expect(job.state == .reviewReady)
    #expect(trace.exportRequests.map(\.plan.name) == ["Second Mix", "First Mix"])
    #expect(trace.openedSessionURLs.map(\.path) == [firstSessionURL.path])
    #expect(trace.saveCount == 2)
    #expect(trace.closeCount == 1)
    #expect(try await adapter.currentSessionIdentity().path == firstSessionURL.path)
}

@Test func importFailureKeepsCompletedArtifactAndRestoredSession() async throws {
    let environment = try await makeEnvironment("import-failure")
    await environment.adapter.injectFailure(.importAudio)
    let plan = makePlan(
        name: "Import Failure",
        settings: BounceSettings(
            exportType: .wav,
            importAfterBounce: true,
            fileDestination: environment.output.path
        )
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let snapshot = await environment.coordinator.snapshot()
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(snapshot.artifacts.count == 1)
    #expect(snapshot.artifacts.first?.state == .completed)
    #expect(trace.importRequests.isEmpty)
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test func crossSessionSaveFailureStopsBeforeCloseAndKeepsRecoveryJournal() async throws {
    let fixture = try await makeCrossSessionFixture("cross-save-failure")
    await fixture.adapter.injectFailure(.save)

    let job = await fixture.coordinator.run(plans: fixture.plans, crossSession: true)
    let trace = await fixture.adapter.trace()

    #expect(job.state == .recoveryRequired)
    #expect(trace.saveCount == 0)
    #expect(trace.closeCount == 0)
    #expect(trace.openedSessionURLs.isEmpty)
    #expect(try await fixture.store.pendingSnapshots().count == 1)
}

@Test func crossSessionFailureLeavesRestoredCurrentSessionOpen() async throws {
    let fixture = try await makeCrossSessionFixture("cross-failure-open")
    await fixture.adapter.injectFailure(.export)
    let job = await fixture.coordinator.run(plans: fixture.plans, crossSession: true)
    let trace = await fixture.adapter.trace()
    #expect(job.state == .failed)
    #expect(trace.saveCount == 1 && trace.closeCount == 0)
    #expect(try await fixture.adapter.currentSessionIdentity().path == fixture.plans[0].session.path)
    #expect(try await fixture.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await fixture.store.pendingSnapshots().isEmpty)
}

@Test func crossSessionCancelLeavesRestoredCurrentSessionOpen() async throws {
    let fixture = try await makeCrossSessionFixture("cross-cancel-open", operationDelay: .milliseconds(200))
    let stream = await fixture.coordinator.snapshots()
    let task = Task { await fixture.coordinator.run(plans: fixture.plans, crossSession: true) }
    for await value in stream {
        if value.job?.state == .exporting { break }
    }
    await fixture.coordinator.requestCancel()
    let job = await task.value
    let trace = await fixture.adapter.trace()
    #expect(job.state == .cancelled)
    #expect(trace.saveCount == 1 && trace.closeCount == 0)
    #expect(try await fixture.adapter.currentSessionIdentity().path == fixture.plans[0].session.path)
    #expect(try await fixture.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await fixture.store.pendingSnapshots().isEmpty)
}

@Test func crossSessionCloseFailureStopsBeforeOpeningNextSession() async throws {
    let fixture = try await makeCrossSessionFixture("cross-close-failure")
    await fixture.adapter.injectFailure(.close)

    let job = await fixture.coordinator.run(plans: fixture.plans, crossSession: true)
    let trace = await fixture.adapter.trace()

    #expect(job.state == .recoveryRequired)
    #expect(trace.saveCount == 1)
    #expect(trace.closeCount == 0)
    #expect(trace.openedSessionURLs.isEmpty)
    #expect(try await fixture.store.pendingSnapshots().isEmpty)
}

@Test func crossSessionOpenFailureRetainsFirstSessionOutputAndStopsQueue() async throws {
    let fixture = try await makeCrossSessionFixture("cross-open-failure")
    await fixture.adapter.injectFailure(.open)

    let job = await fixture.coordinator.run(plans: fixture.plans, crossSession: true)
    let trace = await fixture.adapter.trace()
    let snapshot = await fixture.coordinator.snapshot()

    #expect(job.state == .failed)
    #expect(job.completedPlanCount == 1)
    #expect(snapshot.artifacts.count == 1)
    #expect(snapshot.artifacts.first?.state == .completed)
    #expect(snapshot.completedPlanIDs == [fixture.plans[0].id])
    #expect(trace.saveCount == 1)
    #expect(trace.closeCount == 1)
    #expect(trace.openedSessionURLs.isEmpty)
    #expect(try await fixture.store.pendingSnapshots().isEmpty)
}

@Test func sessionIdentityMismatchPerformsNoProToolsWrites() async throws {
    let root = try TestWorkspace.freshDirectory("identity-mismatch")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    var wrongSession = FakeProToolsAdapter.demoSession
    wrongSession.identity.instanceID = "unexpected-instance"
    let adapter = FakeProToolsAdapter(sessionInfo: wrongSession)
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    let plan = makePlan(
        name: "Guarded",
        settings: BounceSettings(fileDestination: output.path)
    )

    let job = await coordinator.run(plans: [plan], crossSession: false)
    let trace = await adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(trace.importRequests.isEmpty)
    #expect(try await store.pendingSnapshots().isEmpty)
}

@Test func outputCollisionFailsBeforeConnectingOrMutatingSession() async throws {
    let environment = try await makeEnvironment("output-collision")
    try FileManager.default.createDirectory(at: environment.output, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: environment.output.appendingPathComponent("Collision.wav"))
    let plan = makePlan(
        name: "Collision",
        settings: BounceSettings(fileDestination: environment.output.path)
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
}

@Test func confirmedOutputCollisionAtomicallyReplacesOnlyAuthorizedFile() async throws {
    let environment = try await makeEnvironment("authorized-output-collision")
    try FileManager.default.createDirectory(at: environment.output, withIntermediateDirectories: true)
    let existing = environment.output.appendingPathComponent("Collision.wav")
    try Data("existing delivery".utf8).write(to: existing)
    let plan = makePlan(
        name: "Collision",
        settings: BounceSettings(fileDestination: environment.output.path)
    )

    let collisions = try await environment.coordinator.existingOutputCollisions(for: [plan])
    let job = await environment.coordinator.run(
        plans: [plan],
        crossSession: false,
        authorizedOverwritePaths: Set(collisions.map(\.pathKey))
    )
    let data = try Data(contentsOf: existing)

    #expect(collisions.count == 1)
    #expect(collisions.first?.planID == plan.id)
    #expect(job.state == .reviewReady)
    #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
}

@Test func twoPlansResolvingToSameOutputFailBeforeSessionAccess() async throws {
    let environment = try await makeEnvironment("planned-output-collision")
    let settings = BounceSettings(fileDestination: environment.output.path)
    let first = makePlan(name: "Same/Name", settings: settings)
    let second = makePlan(name: "Same:Name", settings: settings)

    let job = await environment.coordinator.run(plans: [first, second], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test func unavailableMixSourceFailsBeforeSnapshotOrTrackMutation() async throws {
    let environment = try await makeEnvironment("missing-mix-source")
    let settings = BounceSettings(
        fileDestination: environment.output.path,
        mixSourceType: .bus,
        mixSource: "Missing Print Bus"
    )
    let plan = makePlan(name: "Wrong Source", settings: settings)

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

@Test func missingTrackFailsBeforeSnapshotOrTrackMutation() async throws {
    let root = try TestWorkspace.freshDirectory("missing-track")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let adapter = FakeProToolsAdapter(trackStates: Array(FakeProToolsAdapter.demoTracks.dropLast()))
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    let plan = makePlan(
        name: "Stale Tracks",
        settings: BounceSettings(fileDestination: output.path)
    )

    let job = await coordinator.run(plans: [plan], crossSession: false)
    let trace = await adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(try await store.pendingSnapshots().isEmpty)
}

@Test func missingRequiredCapabilityFailsBeforeSessionAccess() async throws {
    let root = try TestWorkspace.freshDirectory("missing-capability")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    var capabilities = PTSLCapabilities.ptsl2026_04
    capabilities.trackStateSetters = false
    let adapter = FakeProToolsAdapter(capabilities: capabilities)
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    let plan = makePlan(
        name: "Unsupported",
        settings: BounceSettings(fileDestination: output.path)
    )

    let job = await coordinator.run(plans: [plan], crossSession: false)
    let trace = await adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(try await store.pendingSnapshots().isEmpty)
}

@Test func missingCrossSessionFileFailsWholeBatchBeforeFirstExport() async throws {
    let root = try TestWorkspace.freshDirectory("cross-session-preflight")
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let firstURL = root.appendingPathComponent("First.ptx")
    try Data("first".utf8).write(to: firstURL)
    var firstSession = FakeProToolsAdapter.demoSession
    firstSession.identity.path = firstURL.path
    let adapter = FakeProToolsAdapter(sessionInfo: firstSession)
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    var missingSession = firstSession.identity
    missingSession.path = root.appendingPathComponent("Missing.ptx").path
    missingSession.originID = ""
    let settings = BounceSettings(fileDestination: output.path)
    let plans = [
        makePlan(name: "First", settings: settings, session: firstSession.identity),
        makePlan(name: "Missing", settings: settings, session: missingSession)
    ]

    let job = await coordinator.run(plans: plans, crossSession: true)
    let trace = await adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
    #expect(try await store.pendingSnapshots().isEmpty)
}

@Test func fileDestinationThatIsNotDirectoryFailsBeforeSessionAccess() async throws {
    let environment = try await makeEnvironment("invalid-destination")
    let fileURL = environment.output.deletingLastPathComponent().appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: fileURL)
    let plan = makePlan(
        name: "Invalid Destination",
        settings: BounceSettings(fileDestination: fileURL.path)
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
}

@Test func outputDirectoryResolverDeduplicatesSymlinkEquivalentPaths() throws {
    let root = try TestWorkspace.freshDirectory("destinations")
    let real = root.appendingPathComponent("Bounced Files", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("Alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let resolver = OutputDirectoryResolver()
    let first = makePlan(
        name: "A",
        settings: BounceSettings(fileDestination: real.path)
    )
    let second = makePlan(
        name: "B",
        settings: BounceSettings(fileDestination: link.path)
    )

    #expect(resolver.uniqueDestinations(for: [first, second]).count == 1)
}

private actor DiskWriteGate {
    private(set) var isFull = true

    func freeSpace() { isFull = false }
}

@Test func diskFullAfterFirstMixRetainsQueueAndAllowsRetry() async throws {
    let disk = DiskWriteGate()
    let environment = try await makeEnvironment("disk-full-retry", exportWriter: { request, url in
        if request.plan.name == "Second", await disk.isFull {
            let noSpace = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: [NSUnderlyingErrorKey: noSpace, NSFilePathErrorKey: url.path])
        }
        _ = try TestWorkspace.makeWAV(at: url, durationSeconds: 1)
    })
    let settings = BounceSettings(bitDepth: 16, padToFrameBoundary: false, fileDestination: environment.output.path)
    let plans = [makePlan(name: "First", settings: settings), makePlan(name: "Second", settings: settings)]
    try await environment.store.appendPlans(plans)
    let timeline = try await environment.adapter.currentTimelineState()

    let failed = await environment.coordinator.run(plans: plans, crossSession: false)
    #expect(failed.state == .failed)
    #expect(failed.failureMessage?.hasPrefix("Not enough disk space:") == true)
    let snapshot = await environment.coordinator.snapshot()
    #expect(snapshot.completedPlanIDs == [plans[0].id])
    #expect(snapshot.completedPlanIDsToRemove.isEmpty)
    let saved = try await environment.store.loadPlans()
    #expect(saved == plans)
    #expect(try await environment.adapter.currentTimelineState() == timeline)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
    let delivered = environment.output.appendingPathComponent("First.wav")
    #expect(FileManager.default.fileExists(atPath: delivered.path))
    #expect(!FileManager.default.fileExists(atPath: environment.output.appendingPathComponent("Second.wav").path))

    await disk.freeSpace()
    let collisions = try await environment.coordinator.existingOutputCollisions(for: saved)
    let retry = await environment.coordinator.run(plans: saved, crossSession: false,
        authorizedOverwritePaths: Set(collisions.map(\.pathKey)))
    #expect(retry.state == .reviewReady)
    #expect((await environment.coordinator.snapshot()).completedPlanIDsToRemove == plans.map(\.id))
}

@Test func availableCapacityFallsBackWhenImportantUsageIsZero() {
    let t9FreeBytes: Int64 = 557_116_030_976

    #expect(VolumeAvailableCapacity.resolve(
        importantUsageBytes: 0,
        volumeBytes: t9FreeBytes,
        fileSystemBytes: t9FreeBytes
    ) == t9FreeBytes)
}

@Test func availableCapacityPreservesRealZeroCapacity() {
    #expect(VolumeAvailableCapacity.resolve(
        importantUsageBytes: 0,
        volumeBytes: 0,
        fileSystemBytes: 0
    ) == 0)
}

@Test func availableCapacityRemainsUnknownWhenEverySourceIsUnavailable() {
    #expect(VolumeAvailableCapacity.resolve(
        importantUsageBytes: nil,
        volumeBytes: nil,
        fileSystemBytes: nil
    ) == nil)
}

@Test func readOnlyDestinationFailsBeforeConnectingOrMutatingSession() async throws {
    let environment = try await makeEnvironment("read-only-destination")
    try FileManager.default.createDirectory(
        at: environment.output,
        withIntermediateDirectories: true
    )
    guard chmod(environment.output.path, S_IRUSR | S_IXUSR) == 0 else {
        throw QuickBounceError.permissionDenied("Unable to create read-only test directory")
    }
    defer { _ = chmod(environment.output.path, S_IRWXU) }
    let plan = makePlan(
        name: "Read Only",
        settings: BounceSettings(fileDestination: environment.output.path)
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)
    let trace = await environment.adapter.trace()

    #expect(job.state == .failed)
    #expect(trace.operations.isEmpty)
    #expect(trace.exportRequests.isEmpty)
}

@Test func proToolsExitDuringExportLeavesDurableRecoveryJournal() async throws {
    let environment = try await makeEnvironment("host-exit")
    await environment.adapter.injectFailure(.hostExitDuringExport)
    let plan = makePlan(
        name: "Host Exit",
        settings: BounceSettings(fileDestination: environment.output.path)
    )

    let job = await environment.coordinator.run(plans: [plan], crossSession: false)

    #expect(job.state == .recoveryRequired)
    #expect(try await environment.store.pendingSnapshots().count == 1)
    #expect((await environment.coordinator.snapshot()).artifacts.isEmpty)
}

@Test func longQueueCompletesEveryPlanAndRestoresSessionOnce() async throws {
    let environment = try await makeEnvironment("long-queue", operationDelay: .zero)
    let settings = BounceSettings(fileDestination: environment.output.path)
    let plans = (1...12).map {
        makePlan(name: String(format: "Long Queue %02d", $0), settings: settings)
    }

    let job = await environment.coordinator.run(plans: plans, crossSession: false)
    let snapshot = await environment.coordinator.snapshot()

    #expect(job.state == .reviewReady)
    #expect(job.completedPlanCount == plans.count)
    #expect(snapshot.artifacts.count == plans.count)
    #expect(Set(snapshot.completedPlanIDs) == Set(plans.map(\.id)))
    #expect(try await environment.adapter.trackStates() == FakeProToolsAdapter.demoTracks)
    #expect(try await environment.store.pendingSnapshots().isEmpty)
}

private struct Environment {
    let output: URL
    let staging: URL
    let adapter: FakeProToolsAdapter
    let store: SQLiteStore
    let coordinator: BounceCoordinator
}

private struct CrossSessionFixture {
    let adapter: FakeProToolsAdapter
    let store: SQLiteStore
    let coordinator: BounceCoordinator
    let plans: [BouncePlan]
}

private func makeEnvironment(
    _ label: String,
    operationDelay: Duration = .milliseconds(5),
    exportWriter: FakeExportWriter? = nil,
    timeCodeRate: SessionTimeCodeRate = .fps25,
    availableCapacity: @escaping AvailableCapacityProvider = { _ in Int64.max }
) async throws -> Environment {
    let root = try TestWorkspace.freshDirectory(label)
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    var sessionInfo = FakeProToolsAdapter.demoSession
    sessionInfo.timeCodeRate = timeCodeRate
    let adapter = FakeProToolsAdapter(
        sessionInfo: sessionInfo,
        operationDelay: operationDelay,
        exportWriter: exportWriter
    )
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: staging,
        availableCapacity: availableCapacity
    )
    return Environment(
        output: output,
        staging: staging,
        adapter: adapter,
        store: store,
        coordinator: coordinator
    )
}

private func makeCrossSessionFixture(_ label: String, operationDelay: Duration = .milliseconds(5)) async throws -> CrossSessionFixture {
    let root = try TestWorkspace.freshDirectory(label)
    let output = root.appendingPathComponent("Bounced Files", isDirectory: true)
    let firstSessionURL = root.appendingPathComponent("First.ptx")
    let secondSessionURL = root.appendingPathComponent("Second.ptx")
    try Data("first".utf8).write(to: firstSessionURL)
    try Data("second".utf8).write(to: secondSessionURL)
    var firstSession = FakeProToolsAdapter.demoSession
    firstSession.identity.path = firstSessionURL.path
    let adapter = FakeProToolsAdapter(sessionInfo: firstSession, operationDelay: operationDelay)
    let store = try SQLiteStore(url: root.appendingPathComponent("quickbounce.sqlite"))
    let coordinator = try BounceCoordinator(
        proTools: adapter,
        store: store,
        workDirectory: root.appendingPathComponent("staging", isDirectory: true)
    )
    var secondIdentity = firstSession.identity
    secondIdentity.path = secondSessionURL.path
    secondIdentity.originID = ""
    secondIdentity.instanceID = "captured-second-instance"
    let settings = BounceSettings(fileDestination: output.path)
    return CrossSessionFixture(
        adapter: adapter,
        store: store,
        coordinator: coordinator,
        plans: [
            makePlan(name: "Session One", settings: settings, session: firstSession.identity),
            makePlan(name: "Session Two", settings: settings, session: secondIdentity)
        ]
    )
}

private func makePlan(
    name: String,
    settings: BounceSettings,
    session: SessionIdentity = FakeProToolsAdapter.demoSession.identity
) -> BouncePlan {
    var target = FakeProToolsAdapter.demoTracks
    target[0].isSolo = true
    return BouncePlan(
        name: name,
        session: session,
        targetTrackStates: target,
        range: SampleRange(start: 48_000, end: 96_000),
        sourceSampleRate: 48_000,
        settings: settings
    )
}
