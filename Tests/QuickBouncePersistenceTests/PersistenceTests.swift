import Foundation
import QuickBounceDomain
import QuickBouncePersistence
import QuickBounceSQLiteShim
import QuickBounceTestSupport
import Testing

@Test func sqliteRoundTripsPlansJobsArtifactsAndEvents() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-roundtrip")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let plan = makePlan(destination: directory.path)
    let job = BounceJob(planIDs: [plan.id], state: .exporting)
    let artifact = AudioArtifact(
        jobID: job.id,
        planID: plan.id,
        name: "Mix.wav",
        path: directory.appendingPathComponent("Mix.wav").path,
        kind: .wav,
        state: .completed
    )
    let event = JobEvent(jobID: job.id, state: job.state, message: "Exporting")

    try await store.save(plan: plan)
    try await store.save(job: job)
    try await store.save(artifact: artifact)
    try await store.append(event: event)

    #expect(try await store.loadPlans() == [plan])
    #expect(try await store.loadJobs() == [job])
    #expect(try await store.loadArtifacts(jobID: job.id) == [artifact])
    #expect(try await store.events(jobID: job.id) == [event])
}

@Test func restoreJournalSurvivesStoreReopen() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-recovery")
    let databaseURL = directory.appendingPathComponent("quickbounce.sqlite")
    let snapshot = SessionSnapshot(
        jobID: UUID(),
        session: sessionIdentity,
        trackStates: []
    )
    do {
        let store = try SQLiteStore(url: databaseURL)
        try await store.save(snapshot: snapshot)
    }
    let reopened = try SQLiteStore(url: databaseURL)
    #expect(try await reopened.pendingSnapshots() == [snapshot])

    var restored = snapshot
    restored.restoreRequired = false
    restored.verifiedAt = Date()
    try await reopened.save(snapshot: restored)
    #expect(try await reopened.pendingSnapshots().isEmpty)
}

@Test func freshLaunchClearsUserWorkspaceButPreservesPendingRecovery() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-fresh-launch")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let plan = makePlan(destination: directory.path)
    let job = BounceJob(planIDs: [plan.id], state: .reviewReady)
    let bouncedFile = directory.appendingPathComponent("Delivered Mix.wav")
    try Data("delivered audio stays on disk".utf8).write(to: bouncedFile)
    let artifact = AudioArtifact(
        jobID: job.id,
        planID: plan.id,
        name: bouncedFile.lastPathComponent,
        path: bouncedFile.path,
        kind: .wav,
        state: .completed
    )
    let event = JobEvent(jobID: job.id, state: .reviewReady, message: "Review is ready")
    let pendingRecovery = SessionSnapshot(
        jobID: job.id,
        session: sessionIdentity,
        trackStates: []
    )
    var completedRecovery = SessionSnapshot(
        jobID: UUID(),
        session: sessionIdentity,
        trackStates: []
    )
    completedRecovery.restoreRequired = false
    completedRecovery.verifiedAt = Date()

    try await store.save(plan: plan)
    try await store.save(job: job)
    try await store.save(artifact: artifact)
    try await store.append(event: event)
    try await store.save(snapshot: pendingRecovery)
    try await store.save(snapshot: completedRecovery)

    try await store.clearTransientWorkspace()

    #expect(try await store.loadPlans().isEmpty)
    #expect(try await store.loadJobs().isEmpty)
    #expect(try await store.loadArtifacts().isEmpty)
    #expect(try await store.events(jobID: job.id).isEmpty)
    #expect(try await store.pendingSnapshots() == [pendingRecovery])
    #expect(FileManager.default.fileExists(atPath: bouncedFile.path))
}

@Test func discardingRecoveryDeletesOnlySelectedJournalMetadata() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-discard-recovery")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let first = SessionSnapshot(jobID: UUID(), session: sessionIdentity, trackStates: [])
    var secondIdentity = sessionIdentity
    secondIdentity.path = "/Sessions/keep.ptx"
    let second = SessionSnapshot(jobID: UUID(), session: secondIdentity, trackStates: [])
    try await store.save(snapshot: first)
    try await store.save(snapshot: second)

    try await store.discardSnapshots(ids: [first.id])

    #expect(try await store.pendingSnapshots() == [second])
}

@Test func deletingArtifactRecordKeepsDeliveredFile() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-delete-artifact")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let file = directory.appendingPathComponent("Keep Me.wav")
    try Data("not deleted".utf8).write(to: file)
    let artifact = AudioArtifact(
        jobID: UUID(),
        planID: UUID(),
        name: file.lastPathComponent,
        path: file.path,
        kind: .wav,
        state: .completed
    )
    try await store.save(artifact: artifact)

    try await store.deleteArtifact(id: artifact.id)

    #expect(try await store.loadArtifacts().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func reviewDecisionIsIndependentFromAutomaticQCAndDeletedWithRecord() async throws {
    let directory = try TestWorkspace.freshDirectory("review-decision")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let file = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Mix.wav"))
    let artifact = AudioArtifact(
        jobID: UUID(),
        planID: UUID(),
        name: file.lastPathComponent,
        path: file.path,
        kind: .wav,
        state: .completed,
        metrics: AudioMetrics(suspectedClipping: true)
    )
    let decision = ReviewDecision(
        artifactID: artifact.id,
        status: .approved,
        note: "Intentional limiter ceiling",
        reviewedAt: Date()
    )
    try await store.save(artifact: artifact)
    try await store.save(reviewDecision: decision)

    #expect(try await store.loadReviewDecisions() == [decision])
    #expect((try await store.loadArtifacts()).first?.metrics?.suspectedClipping == true)

    try await store.deleteArtifact(id: artifact.id)

    #expect(try await store.loadReviewDecisions().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func sqliteReadsLegacyISO8601Payloads() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-legacy-date")
    let databaseURL = directory.appendingPathComponent("quickbounce.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let plan = makePlan(destination: directory.path)

    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .iso8601
    let payload = try legacyEncoder.encode(plan)
    try insertLegacyPlan(plan, payload: payload, databaseURL: databaseURL)

    let loaded = try await store.loadPlans()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == plan.id)
    #expect(loaded.first?.name == plan.name)
}

@Test func sqliteReadsLegacyPlanWithProToolsCompatibleBounceDefaults() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-legacy-offline")
    let databaseURL = directory.appendingPathComponent("quickbounce.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let plan = makePlan(destination: directory.path)
    let encoded = try JSONEncoder().encode(plan)
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var settings = try #require(payload["settings"] as? [String: Any])
    settings.removeValue(forKey: "offlineBounce")
    settings.removeValue(forKey: "padToFrameBoundary")
    payload["settings"] = settings
    let legacyPayload = try JSONSerialization.data(withJSONObject: payload)
    try insertLegacyPlan(plan, payload: legacyPayload, databaseURL: databaseURL)

    let loaded = try await store.loadPlans()

    #expect(loaded.count == 1)
    #expect(loaded.first?.settings.offlineBounce == true)
    #expect(loaded.first?.settings.padToFrameBoundary == true)
}

@Test func updatingPlanSettingsDoesNotReorderQueueAfterReload() async throws {
    let directory = try TestWorkspace.freshDirectory("persistence-plan-order")
    let store = try SQLiteStore(url: directory.appendingPathComponent("quickbounce.sqlite"))
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var first = BouncePlan(
        name: "First",
        session: sessionIdentity,
        targetTrackStates: [],
        range: SampleRange(start: 0, end: 48_000),
        settings: BounceSettings(fileDestination: directory.path),
        createdAt: start
    )
    let second = BouncePlan(
        name: "Second",
        session: sessionIdentity,
        targetTrackStates: [],
        range: SampleRange(start: 0, end: 48_000),
        settings: BounceSettings(fileDestination: directory.path),
        createdAt: start.addingTimeInterval(1)
    )
    try await store.save(plan: first)
    try await store.save(plan: second)
    first.settings.sampleRate = 96_000
    first.settings.offlineBounce = false
    first.settings.padToFrameBoundary = false
    try await store.save(plan: first)

    let loaded = try await store.loadPlans()

    #expect(loaded.map(\.id) == [first.id, second.id])
    #expect(loaded.first?.settings.sampleRate == 96_000)
    #expect(loaded.first?.settings.offlineBounce == false)
    #expect(loaded.first?.settings.padToFrameBoundary == false)
    #expect(loaded.last?.settings.offlineBounce == true)
    #expect(loaded.last?.settings.padToFrameBoundary == true)
}

private let sessionIdentity = SessionIdentity(
    path: "/Sessions/test.ptx",
    originID: "origin",
    instanceID: "instance",
    proToolsVersion: "2026.04",
    ptslVersion: "2026.4.0"
)

private func makePlan(destination: String) -> BouncePlan {
    BouncePlan(
        name: "Mix",
        session: sessionIdentity,
        targetTrackStates: [],
        range: SampleRange(start: 0, end: 48_000),
        settings: BounceSettings(fileDestination: destination)
    )
}

private func insertLegacyPlan(_ plan: BouncePlan, payload: Data, databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        throw QuickBounceError.persistence("Unable to open legacy fixture database")
    }
    defer { sqlite3_close(database) }

    let sql = """
    INSERT INTO bounce_plans(id, session_instance_id, payload, updated_at)
    VALUES(?, ?, ?, ?);
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw QuickBounceError.persistence("Unable to prepare legacy fixture insert")
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = plan.id.uuidString.withCString {
        sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    _ = plan.session.instanceID.withCString {
        sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    _ = payload.withUnsafeBytes {
        sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
    }
    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw QuickBounceError.persistence("Unable to insert legacy fixture")
    }
}

@Test func savedPresetsSurviveRelaunchWhileQueueAndArtifactsAreCleared() async throws {
    let directory = try TestWorkspace.freshDirectory("saved-presets")
    let url = directory.appendingPathComponent("QuickBounce.sqlite")
    let store = try SQLiteStore(url: url)
    let plan = makePlan(destination: directory.path)
    var library = BouncePresetLibrary()
    let preset = BounceSettingsPreset(name: "Delivery", settings: plan.settings)
    library.presets = [preset]
    library.defaultPresetID = preset.id
    try await store.save(presetLibrary: library)
    try await store.appendPlans([plan])
    try await store.clearTransientWorkspace()
    let reopened = try SQLiteStore(url: url)
    let loaded = try await reopened.loadPresetLibrary()
    #expect(loaded.defaultPreset == preset)
    #expect(loaded.presets == [preset])
    #expect(try await reopened.loadPlans().isEmpty)
    #expect(try await reopened.loadArtifacts().isEmpty)
}

@Test func presetUpdatePersistsWithoutChangingPreviouslyQueuedMixSettings() async throws {
    let directory = try TestWorkspace.freshDirectory("preset-update")
    let url = directory.appendingPathComponent("QuickBounce.sqlite")
    let store = try SQLiteStore(url: url)
    var plan = makePlan(destination: directory.path)
    let preset = BounceSettingsPreset(name: "Main", settings: plan.settings)
    plan.bouncePresetID = preset.id
    var library = BouncePresetLibrary()
    library.presets = [preset]
    library.defaultPresetID = preset.id
    try await store.save(presetLibrary: library, associating: [plan])
    var changed = preset.settings
    changed.sampleRate = 96_000
    try library.update(id: preset.id, settings: changed)
    try await store.save(presetLibrary: library)
    let reopened = try SQLiteStore(url: url)
    #expect(try await reopened.loadPresetLibrary().defaultPreset?.settings.sampleRate == 96_000)
    #expect(try await reopened.loadPlans() == [plan])
}
