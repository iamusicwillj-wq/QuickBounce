import Foundation
import QuickBounceApplication
import QuickBounceDomain
import QuickBouncePersistence
import QuickBounceProTools
import QuickBounceTestSupport
import Testing

private func namingFixture(_ label: String) throws -> (URL, SessionInfo, BouncePlan) {
    let root = try TestWorkspace.freshDirectory(label)
    var session = FakeProToolsAdapter.demoSession
    session.identity.path = root.appendingPathComponent("Song.ptx").path
    let destination = root.appendingPathComponent("Bounced Files")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let plan = BouncePlan(name: "Main", session: session.identity,
                          targetTrackStates: FakeProToolsAdapter.demoTracks,
                          range: SampleRange(start: 0, end: 24_000), sourceSampleRate: 48_000,
                          settings: BounceSettings(exportType: .wavAndMP3, fileDestination: destination.path))
    return (destination, session, plan)
}

@Test func defaultOutputNamingChecksAllFormatsAndReservesQueueNames() throws {
    let (directory, _, plan) = try namingFixture("numbered-output")
    for name in ["MAIN.WAV", "Main_1.mp3", "Main_2.mov"] {
        try Data("existing".utf8).write(to: directory.appendingPathComponent(name))
    }
    var second = plan
    second.name = "main"
    let prepared = try BounceOutputNaming.preparing([plan, second])
    #expect(prepared.map(\.name) == ["Main_3", "main_4"])
    #expect(plan.name == "Main")
    #expect(prepared[0].id == plan.id)
    #expect(prepared[0].targetTrackStates == plan.targetTrackStates)
    #expect(prepared[0].settings == plan.settings)
}

@Test func namingRespectsCustomDestinationsAndSanitizedUnicodeNames() throws {
    let (directory, _, original) = try namingFixture("numbered-paths")
    var plan = original
    plan.name = "Cafe\u{301}/Mix"
    try Data().write(to: directory.appendingPathComponent("Café-Mix.wav"))
    #expect(try BounceOutputNaming.preparing([plan]).first?.name == "Cafe\u{301}-Mix_1")
    plan.settings.fileDestination = directory.deletingLastPathComponent().appendingPathComponent("Custom").path
    #expect(try BounceOutputNaming.preparing([plan]).first?.name == plan.name)
    var disabled = original
    disabled.isEnabled = false
    #expect(try BounceOutputNaming.preparing([disabled, original]).map(\.name) == ["Main", "Main"])
}

@Test func repeatedBounceKeepsOriginalFilesAndUsesSameNumberForWAVAndMP3() async throws {
    let (directory, session, plan) = try namingFixture("repeated-numbered-bounce")
    let originalFile = directory.appendingPathComponent("Main.wav")
    let originalData = Data("previous delivery".utf8)
    try originalData.write(to: originalFile)
    let root = directory.deletingLastPathComponent()
    let store = try SQLiteStore(url: root.appendingPathComponent("db.sqlite"))
    let adapter = FakeProToolsAdapter(sessionInfo: session, operationDelay: .zero)
    let coordinator = try BounceCoordinator(proTools: adapter, store: store, workDirectory: root.appendingPathComponent("staging"))
    #expect(try await coordinator.existingOutputCollisions(for: [plan]).isEmpty)
    for number in 1...2 {
        let job = await coordinator.run(plans: [plan], crossSession: false)
        #expect(job.state == .reviewReady)
        let snapshot = await coordinator.snapshot()
        #expect(Set(snapshot.artifacts.map(\.name)) == ["Main_\(number).wav", "Main_\(number).mp3"])
        #expect(snapshot.artifacts.allSatisfy { $0.planID == plan.id })
    }
    #expect(try Data(contentsOf: originalFile) == originalData)
    #expect(try await adapter.trackStates() == FakeProToolsAdapter.demoTracks)
}
