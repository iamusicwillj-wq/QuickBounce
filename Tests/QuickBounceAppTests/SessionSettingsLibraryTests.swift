import Foundation
import QuickBounceDomain
@testable import QuickBounceApp
import Testing

private func settingsDocument(_ name: String = "Full Mix", sessionPath: String = "/Sessions/Song.ptx") throws -> SessionSettingsDocument {
    let session = SessionIdentity(path: sessionPath, originID: "song", instanceID: "instance", proToolsVersion: "2026.4", ptslVersion: "2026.4")
    let track = TrackState(track: TrackReference(id: "track", name: "Music", index: 0, kind: "Audio"), isSolo: true, isMuted: false)
    return try SessionSettingsDocument(plans: [BouncePlan(name: name, session: session,
        targetTrackStates: [track], range: SampleRange(start: 123, end: 48_123),
        sourceSampleRate: 48_000, settings: BounceSettings(fileDestination: "/Delivery"))])
}

private func settingsLibrary() throws -> SessionSettingsLibrary {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QB-Settings-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return SessionSettingsLibrary(directory: directory)
}

@Test func sessionSettingsHistoryPersistsAdditionOrderAndSearchesBeyondFive() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    for index in 0..<8 {
        let request = try library.prepareSave(name: index == 0 ? "歌曲 Café" : "Song \(index)",
            document: settingsDocument(), now: Date(timeIntervalSince1970: Double(index)))
        try library.save(request)
    }
    let reopened = SessionSettingsLibrary(directory: library.directory)
    let entries = try reopened.entries()
    #expect(entries.map(\.name) == ["Song 7", "Song 6", "Song 5", "Song 4", "Song 3", "Song 2", "Song 1", "歌曲 Café"])
    #expect(SessionSettingsLibrary.visibleEntries(entries, query: "", searching: false).count == 5)
    #expect(SessionSettingsLibrary.visibleEntries(entries, query: "", searching: true).count == 8)
    #expect(SessionSettingsLibrary.visibleEntries(entries, query: "CAFE", searching: true).map(\.name) == ["歌曲 Café"])
    #expect(SessionSettingsLibrary.visibleEntries(entries, query: "missing", searching: true).isEmpty)
    #expect(try reopened.load(entries[0]).plans[0].range.start == 123)
}

@Test func sessionSettingsReplacementRequiresConfirmationAndKeepsAddedDate() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let first = try library.save(library.prepareSave(name: "Song", document: settingsDocument(), now: Date(timeIntervalSince1970: 1)))
    try library.save(library.prepareSave(name: "Other", document: settingsDocument(), now: Date(timeIntervalSince1970: 2)))
    let request = try library.prepareSave(name: "song", document: settingsDocument("Revision"))
    #expect(request.requiresReplacement)
    #expect(throws: QuickBounceError.self) { try library.save(request) }
    #expect(try library.load(first).plans[0].name == "Full Mix")
    try library.save(request, replacing: true)
    #expect(try library.entries().map(\.name) == ["Other", "Song"])
    #expect(try library.entries().last?.addedAt == first.addedAt)
    #expect(try library.load(first).plans[0].name == "Revision")
}

@Test func sessionSettingsConfirmationCannotOverwriteConcurrentFinderChanges() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let entry = try library.save(library.prepareSave(name: "Song", document: settingsDocument()))
    let request = try library.prepareSave(name: "Song", document: settingsDocument("New"))
    let changed = try JSONEncoder().encode(settingsDocument("External edit"))
    try changed.write(to: entry.url, options: .atomic)
    #expect(throws: QuickBounceError.self) { try library.save(request, replacing: true) }
    #expect(try library.load(entry).plans[0].name == "External edit")
    try FileManager.default.removeItem(at: entry.url)
    #expect(throws: QuickBounceError.self) { try library.save(request, replacing: true) }
    #expect(try library.entries().isEmpty)
}

@Test func sessionSettingsFolderSupportsLegacyDocumentsRenamesAndDeletion() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let legacy = library.directory.appendingPathComponent("Old.quickbounce.json")
    try JSONEncoder().encode(settingsDocument()).write(to: legacy)
    var entries = try library.entries()
    #expect(entries[0].name == "Old")
    #expect(try library.load(entries[0]).plans[0].targetTrackStates[0].isSolo == true)
    let renamed = library.directory.appendingPathComponent("Renamed.quickbounce.json")
    try FileManager.default.moveItem(at: legacy, to: renamed)
    try Data("broken".utf8).write(to: library.directory.appendingPathComponent("Broken.json"))
    entries = try library.entries()
    #expect(Set(entries.map(\.name)) == ["Renamed", "Broken"])
    #expect(throws: (any Error).self) { try library.load(entries.first { $0.name == "Broken" }!) }
    #expect(try library.load(entries.first { $0.name == "Renamed" }!).plans[0].name == "Full Mix")
    try FileManager.default.removeItem(at: renamed)
    #expect(try library.entries().count == 1)
}

@Test func sessionSettingsRejectsUnsafeNamesAndSymlinkTargets() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let document = try settingsDocument()
    for name in ["", " ", "../Song", "A/B", "A:B", ".hidden", "A\nB", String(repeating: "x", count: 201)] {
        #expect(throws: QuickBounceError.self) { try library.prepareSave(name: name, document: document) }
    }
    let target = library.directory.appendingPathComponent("Target.json")
    try JSONEncoder().encode(document).write(to: target)
    try FileManager.default.createSymbolicLink(at: library.directory.appendingPathComponent("Link.quickbounce.json"), withDestinationURL: target)
    #expect(try library.entries().map(\.name) == ["Target"])
    #expect(throws: QuickBounceError.self) { try library.prepareSave(name: "Link", document: document) }
}

@MainActor
@Test func sessionSettingsSaveCapturesOnlySelectedSessionAndRemainsAfterQueueClears() throws {
    let library = try settingsLibrary()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let model = AppModel(initializeServices: false, sessionSettingsDirectory: library.directory)
    let first = try settingsDocument().plans[0]
    let other = try settingsDocument("Other Mix", sessionPath: "/Sessions/Other.ptx").plans[0]
    model.plans = [first, other]
    model.selectedPlanIDs = [first.id]
    model.beginSavingSessionSettings()
    let draft = try #require(model.sessionSettingsSaveDraft)
    #expect(draft.document.plans.map(\.name) == ["Full Mix"])
    model.selectedPlanIDs = [other.id]
    let request = try library.prepareSave(name: "Saved Song", document: draft.document)
    #expect(model.commitSessionSettingsSave(request, session: draft.session))
    #expect(model.sessionSettingsHistory.map(\.name) == ["Saved Song"])
    model.plans = []
    let relaunched = AppModel(initializeServices: false, sessionSettingsDirectory: library.directory)
    relaunched.refreshSessionSettingsHistory()
    #expect(relaunched.sessionSettingsHistory.map(\.name) == ["Saved Song"])
    #expect(try library.load(relaunched.sessionSettingsHistory[0]).plans[0].session.path == first.session.path)
}
