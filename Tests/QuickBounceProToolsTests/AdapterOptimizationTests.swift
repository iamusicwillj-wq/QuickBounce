import Foundation
import QuickBounceDomain
@testable import QuickBounceProTools
import Testing

/// A stateful Host simulator at the transport boundary. It models pagination,
/// X-OR Solo, Folder-derived readback, external edits and dropped commands.
private actor TestPTSLHost: PTSLCommandSending {
    struct Request: Sendable {
        var command: PTSLCommand
        var json: String
        var version: PTSLProtocolVersion
    }
    private(set) var requests: [Request] = []
    private var states: [TrackState]
    private var release: PTSLHostRelease
    private var ignoredSetters: Int
    private var readCount = 0
    private var switchSessionOnRead: Int?
    private var addTrackOnRead: Int?
    private var sessionID = "original-session"
    private let exportErrorCodeJSON: String?

    init(states: [TrackState], release: PTSLHostRelease = .v2026_04,
         ignoredSetters: Int = 0, switchSessionOnRead: Int? = nil, addTrackOnRead: Int? = nil,
         exportErrorCodeJSON: String? = nil) {
        self.states = states
        self.release = release
        self.ignoredSetters = ignoredSetters
        self.switchSessionOnRead = switchSessionOnRead
        self.addTrackOnRead = addTrackOnRead
        self.exportErrorCodeJSON = exportErrorCodeJSON
    }

    nonisolated func cancel(wait: Bool) {}

    func externallyMute(_ index: Int) { states[index].isMuted = true }
    func clearRequests() { requests.removeAll() }

    func send(_ command: PTSLCommand, bodyJSON: String, sessionID: String,
              version: PTSLProtocolVersion, headerJSON: String) async throws -> PTSLRawResponse {
        requests.append(Request(command: command, json: bodyJSON, version: version))
        let request = try JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any] ?? [:]
        var body: [String: Any] = [:]
        switch command {
        case .exportMix where exportErrorCodeJSON != nil:
            let detail = "{\"errors\":[{\"command_error_type\":\(exportErrorCodeJSON ?? "null"),\"is_warning\":false}]}"
            return PTSLRawResponse(commandID: command.rawValue, status: 4, progress: 0,
                taskID: "task", bodyJSON: "{}", bodyJSONChunks: [], errorJSON: detail,
                headerJSON: "{}", version: version)
        case .registerConnection: body = ["session_id": "test-connection"]
        case .getPTSLVersion: body = ["version": release.year, "version_minor": release.month]
        case .getSessionIDs: body = ["origin_id": "test-origin", "instance_id": self.sessionID]
        case .getSessionPath: body = ["session_path": ["path": "/test/Session.ptx"]]
        case .getSessionName: body = ["session_name": "Test"]
        case .getSessionSampleRate: body = ["sample_rate": "SR_48000"]
        case .getSessionBitDepth: body = ["current_setting": "BDepth_24"]
        case .getSessionAudioFormat: body = ["current_setting": "SAFormat_WAVE"]
        case .getSessionTimeCodeRate: body = ["current_setting": "STCRate_Fps25"]
        case .getSessionLength: body = ["session_length": "480000"]
        case .getTimelineSelection: body = ["in_time": "48000", "out_time": "144000"]
        case .getExportMixSourceList: body = ["source_list": ["Main Out"]]
        case .getTrackList:
            let pagination = request["pagination_request"] as? [String: Int] ?? [:]
            let offset = pagination["offset"] ?? 0
            let limit = pagination["limit"] ?? 256
            if offset == 0 { readCount += 1 }
            if switchSessionOnRead == readCount { self.sessionID = "other-session" }
            if addTrackOnRead == readCount {
                states.append(contentsOf: testTracks(1, prefix: "Added"))
                addTrackOnRead = nil
            }
            let soloedFolders = Set(states.filter { $0.isSolo && $0.track.kind.contains("Folder") }.map(\.track.id))
            let rows: [[String: Any]] = states.dropFirst(offset).prefix(limit).map { state in
                ["id": state.track.id, "name": state.track.name, "index": state.track.index,
                 "type": state.track.kind, "parent_folder_id": state.track.parentFolderID ?? NSNull(),
                 "track_attributes": ["is_muted": state.isMuted,
                     "is_soloed": state.isSolo || state.track.parentFolderID.map(soloedFolders.contains) == true,
                     "is_inactive": state.isInactive == true ? "TAState_SetExplicitly" : "TAState_None"]]
            }
            body = ["track_list": rows, "pagination_response": ["total": states.count]]
        case .setTrackMuteState, .setTrackSoloState:
            if ignoredSetters > 0 { ignoredSetters -= 1; break }
            let ids = Set(request["track_ids"] as? [String] ?? [])
            let names = Set(request["track_names"] as? [String] ?? [])
            let enabled = request["enabled"] as? Bool == true
            let addressed = states.indices.filter { ids.contains(states[$0].track.id) || names.contains(states[$0].track.name) }
            if addressed.contains(where: {
                states[$0].track.kind.contains("Master") || states[$0].track.kind.contains("Video") || states[$0].isInactive == true
            }) {
                throw PTSLTransportError.command(status: 4, message: "Forbidden track type")
            }
            if command == .setTrackSoloState, enabled {
                // X-OR: enabling one set replaces the previous set.
                for index in states.indices { states[index].isSolo = false }
            }
            for index in addressed {
                if command == .setTrackMuteState { states[index].isMuted = enabled }
                else { states[index].isSolo = enabled }
            }
        default: break
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        return PTSLRawResponse(commandID: command.rawValue, status: 3, progress: 100,
            taskID: "task", bodyJSON: json, bodyJSONChunks: [json], errorJSON: "",
            headerJSON: "{}", version: version)
    }
}

private func testTracks(_ count: Int, prefix: String = "Track") -> [TrackState] {
    (0..<count).map { index in
        TrackState(track: TrackReference(id: "\(prefix)-id-\(index)", name: "\(prefix) \(index)",
            index: index, kind: "TT_Audio"), isSolo: false, isMuted: false)
    }
}

@Test func inactiveEnumsFollowEachHostContractAndUnknownIsNotAssumedInactive() {
    #expect(RealProToolsAdapter.inactiveAttribute(1, modernEnums: true) == false)
    #expect(RealProToolsAdapter.inactiveAttribute(0, modernEnums: true) == nil)
    #expect(RealProToolsAdapter.inactiveAttribute(0, modernEnums: false) == false)
    #expect(RealProToolsAdapter.inactiveAttribute(1, modernEnums: false) == true)
    #expect(RealProToolsAdapter.inactiveAttribute("2", modernEnums: true) == true)
    #expect(RealProToolsAdapter.inactiveAttribute("TAState_None", modernEnums: true) == false)
    #expect(RealProToolsAdapter.inactiveAttribute("SetImplicitly", modernEnums: false) == true)
    #expect(RealProToolsAdapter.inactiveAttribute("TAState_Unknown", modernEnums: true) == nil)
    #expect(RealProToolsAdapter.inactiveAttribute(nil, modernEnums: true) == nil)
}

private func connect(_ host: TestPTSLHost) async throws -> RealProToolsAdapter {
    let adapter = RealProToolsAdapter(clientFactory: { _ in host })
    _ = try await adapter.connect()
    await host.clearRequests()
    return adapter
}

@Test(arguments: [124, 183, 229, 500], [PTSLHostRelease.v2025_10, .v2025_12, .v2026_04])
func captureUsesOneCompleteFreshTrackEnumeration(count: Int, release: PTSLHostRelease) async throws {
    let host = TestPTSLHost(states: testTracks(count), release: release)
    let adapter = try await connect(host)
    let first = try await adapter.captureMix()
    #expect(first.session.trackCount == count)
    #expect(first.trackStates.count == count)
    #expect(first.range == SampleRange(start: 48_000, end: 144_000))
    #expect(first.session.fileFormat == "WAV")
    var requests = await host.requests
    #expect(requests.filter { $0.command == .getTrackList }.count == (count + 255) / 256)
    #expect(requests.allSatisfy { $0.version == release.requestVersion })
    await host.externallyMute(count - 1)
    await host.clearRequests()
    let second = try await adapter.captureMix()
    #expect(second.trackStates.last?.isMuted == true)
    requests = await host.requests
    #expect(requests.filter { $0.command == .getTrackList }.count == (count + 255) / 256)
}

@Test(arguments: [PTSLHostRelease.v2025_10, .v2025_12, .v2026_04])
func sparseApplyReadsBeforeAndAfterAndDetectsExternalEdits(release: PTSLHostRelease) async throws {
    let original = testTracks(229)
    let host = TestPTSLHost(states: original, release: release)
    let adapter = try await connect(host)
    let unchanged = try await adapter.apply(trackStates: original)
    #expect(unchanged.count == 229)
    #expect(await host.requests.filter { $0.command == .getTrackList }.count == 2)
    #expect(await host.requests.filter { $0.command == .setTrackMuteState || $0.command == .setTrackSoloState }.isEmpty)

    await host.externallyMute(100)
    await host.clearRequests()
    let restored = try await adapter.apply(trackStates: original)
    #expect(restored[100].isMuted == false)
    let requests = await host.requests
    let mutations = requests.filter { $0.command == .setTrackMuteState || $0.command == .setTrackSoloState }
    #expect(mutations.count == 1)
    let mutation = try #require(mutations.first)
    let body = try #require(JSONSerialization.jsonObject(with: Data(mutation.json.utf8)) as? [String: Any])
    let key = release >= .v2025_12 ? "track_ids" : "track_names"
    #expect((body[key] as? [String])?.count == 1)
    #expect(requests.filter { $0.command == .getTrackList }.count == 2)
}

@Test func soloSendsCompleteTargetSetUnderXORAndPreservesFolderSemantics() async throws {
    var original = testTracks(8)
    original[0].isSolo = true
    original[2].track.kind = "TT_RoutingFolder"
    original[3].track.parentFolderID = original[2].track.id
    original[4].track.kind = "TT_BasicFolder"
    original[5].track.kind = "TT_Aux"
    original[6].track.kind = "TT_Master"
    original[7].track.kind = "TT_Video"
    let host = TestPTSLHost(states: original)
    let adapter = try await connect(host)
    var target = original
    target[1].isSolo = true
    target[2].isSolo = true
    target[4].isSolo = true
    target[5].isMuted = true
    let readback = try await adapter.apply(trackStates: target)
    #expect(readback[0].isSolo && readback[1].isSolo && readback[2].isSolo && readback[3].isSolo && readback[4].isSolo)
    #expect(readback[5].isMuted)
    #expect(TrackStateVerification.firstIssue(expected: target, actual: readback) == nil)
    #expect(await host.requests.filter { $0.command == .getTrackList }.count == 2)
}

@Test func unchangedInactiveTracksAreSkippedButChangedInactiveStateIsNotSilentlyAccepted() async throws {
    var states = testTracks(3)
    states[0].isInactive = true
    let host = TestPTSLHost(states: states)
    let adapter = try await connect(host)
    var target = states
    target[1].isSolo = true
    _ = try await adapter.apply(trackStates: target)
    target[0].isMuted = true
    await #expect(throws: PTSLTransportError.self) { try await adapter.apply(trackStates: target) }
}

@Test func failedDeltaGetsOneFullFallbackAndPersistentMismatchStillFails() async throws {
    let original = testTracks(4)
    var target = original
    target[1].isMuted = true
    let transient = TestPTSLHost(states: original, ignoredSetters: 1)
    let adapter = try await connect(transient)
    let readback = try await adapter.apply(trackStates: target)
    #expect(readback[1].isMuted)
    #expect(await transient.requests.filter { $0.command == .getTrackList }.count == 3)

    let persistent = TestPTSLHost(states: original, ignoredSetters: 100)
    let failing = try await connect(persistent)
    await #expect(throws: QuickBounceError.self) { try await failing.apply(trackStates: target) }
    #expect(await persistent.requests.filter { $0.command == .getTrackList }.count == 3)
}

@Test func duplicateSoloNamesAreRejectedOnNewHostsBeforeMutation() async throws {
    var states = testTracks(2)
    states[1].track.name = states[0].track.name
    let host = TestPTSLHost(states: states)
    let adapter = try await connect(host)
    await #expect(throws: QuickBounceError.self) { try await adapter.apply(trackStates: states) }
    #expect(await host.requests.filter { $0.command == .setTrackMuteState || $0.command == .setTrackSoloState }.isEmpty)
}

@Test func sessionSwitchAndTrackChangesInvalidateCaptureOrApply() async throws {
    let states = testTracks(3)
    let switched = TestPTSLHost(states: states, switchSessionOnRead: 1)
    let adapter = try await connect(switched)
    await #expect(throws: QuickBounceError.self) { try await adapter.captureMix() }
    let changed = TestPTSLHost(states: states, addTrackOnRead: 2)
    let applying = try await connect(changed)
    await #expect(throws: QuickBounceError.self) { try await applying.apply(trackStates: states) }
}

@Test(arguments: ["\"CEType_OS_DiskSpace\"", "6"])
func exportMixRecognizesProToolsDiskSpaceErrors(code: String) async throws {
    let adapter = try await connect(TestPTSLHost(states: [], exportErrorCodeJSON: code))
    let plan = BouncePlan(name: "Disk full", session: FakeProToolsAdapter.demoSession.identity,
        targetTrackStates: [], range: SampleRange(start: 0, end: 48_000), sourceSampleRate: 48_000,
        settings: BounceSettings(fileDestination: "/tmp/Delivery"))
    let request = ProToolsExportRequest(plan: plan, stagingDirectory: URL(fileURLWithPath: "/tmp/Staging"),
        baseFileName: plan.name, kind: .wav)
    do {
        _ = try await adapter.exportMix(request)
        Issue.record("Pro Tools reported a failed export")
    } catch {
        #expect(error.localizedDescription.hasPrefix("Not enough disk space:"))
    }
}
