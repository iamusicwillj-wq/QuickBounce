import Foundation
import QuickBounceDomain
import Testing

@Test func movCodecPersistsAndLegacySettingsDefaultToPCM() throws {
    let settings = BounceSettings(exportType: .mov, movAudioCodec: .aac, fileDestination: "/tmp")
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(BounceSettings.self, from: data).movAudioCodec == .aac)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "movAudioCodec")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    #expect(try JSONDecoder().decode(BounceSettings.self, from: legacyData).movAudioCodec == .pcm)
}

private func fixture() -> (BouncePlan, SessionInfo, [TrackState]) {
    let session = SessionIdentity(path: "/Sessions/Song/Song.ptx", originID: "original", instanceID: "old", proToolsVersion: "2026.4", ptslVersion: "2026.4")
    let folder = TrackState(track: TrackReference(id: "folder", name: "Band", index: 0, kind: "TT_BasicFolder"), isSolo: true, isMuted: false)
    let vocal = TrackState(track: TrackReference(id: "vocal", name: "Vocal", index: 1, kind: "TT_Audio", parentFolderID: "folder"), isSolo: false, isMuted: true)
    let plan = BouncePlan(name: "Instrumental", note: "revision", session: session,
                          targetTrackStates: [folder, vocal], range: SampleRange(start: 100, end: 96_100),
                          sourceSampleRate: 48_000, sourceTimeCodeRate: .fps25,
                          settings: BounceSettings(exportType: .wavAndMP3, sampleRate: 96_000, bitDepth: 24,
                                                   offlineBounce: false, padToFrameBoundary: false,
                                                   fileDestination: "/Sessions/Song/Bounced Files"))
    var identity = session
    identity.instanceID = "reopened"
    identity.path = "/Sessions/Revision/Revision.ptx"
    let info = SessionInfo(identity: identity, name: "Revision", sampleRate: 48_000, bitDepth: 24,
                           fileFormat: "WAV", trackCount: 2, lengthSamples: 100_000, timeCodeRate: .fps25)
    let current = [
        TrackState(track: TrackReference(id: "new-folder", name: "Band", index: 0, kind: "BasicFolder"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "new-vocal", name: "Vocal", index: 1, kind: "Audio", parentFolderID: "new-folder"), isSolo: true, isMuted: false)
    ]
    return (plan, info, current)
}

@Test func sessionSettingsRecallRebindsTracksAndPreservesMixChoices() throws {
    let (plan, info, tracks) = fixture()
    let document = try SessionSettingsDocument(plans: [plan])
    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(SessionSettingsDocument.self, from: encoded)
    let restored = try #require(decoded.restoredPlans(session: info, tracks: tracks).first)
    #expect(restored.id != plan.id)
    #expect(restored.session == info.identity)
    #expect(restored.name == plan.name && restored.note == plan.note)
    #expect(restored.range == plan.range)
    #expect(restored.settings.sampleRate == 96_000)
    #expect(!restored.settings.offlineBounce && !restored.settings.padToFrameBoundary)
    #expect(restored.settings.fileDestination == "/Sessions/Revision/Bounced Files")
    #expect(restored.targetTrackStates[0].isSolo)
    #expect(restored.targetTrackStates[1].isMuted)
    #expect(restored.targetTrackStates[1].track.id == "new-vocal")
    #expect(restored.targetTrackStates[1].track.parentFolderID == "new-folder")
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(json.keys) == ["formatVersion", "plans"])
}

@Test func sessionSettingsRejectsChangedAndAmbiguousTrackLayouts() throws {
    let (plan, info, tracks) = fixture()
    let document = try SessionSettingsDocument(plans: [plan])
    var renamed = tracks
    renamed[1].track.name = "New vocal"
    var changedType = tracks
    changedType[1].track.kind = "Aux"
    var moved = tracks
    moved[1].track.parentFolderID = nil
    var duplicate = tracks
    duplicate[1].track.name = "Band"
    for mismatch in [Array(tracks.dropLast()), tracks + [tracks[0]], renamed, changedType, moved, duplicate] {
        #expect(throws: QuickBounceError.self) { try document.restoredPlans(session: info, tracks: mismatch) }
    }
    var wrongRate = info
    wrongRate.sampleRate = 96_000
    #expect(throws: QuickBounceError.self) { try document.restoredPlans(session: wrongRate, tracks: tracks) }
    var future = document
    future.formatVersion = 999
    #expect(throws: QuickBounceError.self) { try future.restoredPlans(session: info, tracks: tracks) }
}

@Test func sessionSettingsDoesNotTrustRecycledIDsOrChangeCustomDestination() throws {
    var (plan, info, tracks) = fixture()
    tracks[1].track = TrackReference(id: "folder", name: "Vocal", index: 1, kind: "Audio", parentFolderID: "new-folder")
    plan.settings.fileDestination = "/Delivery/Client"
    let restored = try #require(SessionSettingsDocument(plans: [plan]).restoredPlans(session: info, tracks: tracks).first)
    #expect(restored.targetTrackStates[1].isMuted)
    #expect(!restored.targetTrackStates[1].isSolo)
    #expect(restored.settings.fileDestination == "/Delivery/Client")
}

@Test func presetsKeepEachMixDestinationAndAllOtherExportChoices() throws {
    let (plan, _, _) = fixture()
    let preset = BounceSettingsPreset(name: "Delivery", settings: plan.settings)
    for folder in ["/Sessions/A/Bounced Files", "/Sessions/B/Bounced Files"] {
        let applied = preset.applying(to: BounceSettings(fileDestination: folder))
        #expect(applied.fileDestination == folder)
        var expected = preset.settings
        expected.fileDestination = folder
        #expect(applied == expected)
    }
}

@Test func sessionSettingsRetainsEachMixNameWithItsOwnSoloMuteSnapshot() throws {
    let (first, info, tracks) = fixture()
    var second = BouncePlan(name: "Full Mix", note: "second version", session: first.session,
                            targetTrackStates: first.targetTrackStates, range: first.range,
                            sourceSampleRate: first.sourceSampleRate, settings: first.settings)
    second.targetTrackStates[0].isSolo = false
    second.targetTrackStates[1].isMuted = false
    let encoded = try JSONEncoder().encode(SessionSettingsDocument(plans: [first, second]))
    let saved = try JSONDecoder().decode(SessionSettingsDocument.self, from: encoded)
    let restored = try saved.restoredPlans(session: info, tracks: tracks)
    #expect(restored.map(\.name) == ["Instrumental", "Full Mix"])
    #expect(restored[0].targetTrackStates[0].isSolo)
    #expect(restored[0].targetTrackStates[1].isMuted)
    #expect(!restored[1].targetTrackStates[0].isSolo)
    #expect(!restored[1].targetTrackStates[1].isMuted)
}

@Test func updatingPresetKeepsIdentityNameAndDefaultAndDoesNotChangeOtherPresets() throws {
    let (plan, _, _) = fixture()
    let first = BounceSettingsPreset(name: "Main", settings: plan.settings)
    let other = BounceSettingsPreset(name: "Other", settings: plan.settings)
    var library = BouncePresetLibrary()
    library.presets = [first, other]
    library.defaultPresetID = first.id
    var changed = first.settings
    changed.sampleRate = 44_100
    changed.offlineBounce.toggle()
    try library.update(id: first.id, settings: changed)
    #expect(library.presets[0].id == first.id)
    #expect(library.presets[0].name == "Main")
    #expect(library.defaultPreset?.settings == changed)
    #expect(library.presets[1] == other)
    #expect(throws: QuickBounceError.self) { try library.update(id: UUID(), settings: changed) }
    #expect(library.presets.count == 2)
}

@Test func presetAssociationRoundTripsSessionSettingsAndOldDocumentsRemainReadable() throws {
    var (plan, info, tracks) = fixture()
    let oldData = try JSONEncoder().encode(SessionSettingsDocument(plans: [plan]))
    let oldDocument = try JSONDecoder().decode(SessionSettingsDocument.self, from: oldData)
    #expect(oldDocument.plans[0].bouncePresetID == nil)
    plan.bouncePresetID = UUID()
    let data = try JSONEncoder().encode(SessionSettingsDocument(plans: [plan]))
    let document = try JSONDecoder().decode(SessionSettingsDocument.self, from: data)
    let restored = try document.restoredPlans(session: info, tracks: tracks)
    #expect(restored[0].bouncePresetID == plan.bouncePresetID)
    #expect(restored[0].name == plan.name)
}

@Test func savedSettingsWithAnOldChannelEstimateStillDecode() throws {
    let (plan, _, _) = fixture()
    let data = try JSONEncoder().encode(plan.settings)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy["estimatedOutputChannels"] = 6
    let decoded = try JSONDecoder().decode(BounceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded == plan.settings)
}
