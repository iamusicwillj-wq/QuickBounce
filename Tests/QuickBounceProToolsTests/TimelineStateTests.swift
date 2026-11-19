import Foundation
import QuickBounceDomain
@testable import QuickBounceProTools
import Testing

private let fullTimelineJSON = """
{"in_time":"9007199254740993","out_time":"9007199254840993",
 "play_start_marker_time":"9007199254700001","pre_roll_start_time":"9007199254600002",
 "post_roll_stop_time":"9007199254900003","pre_roll_enabled":true,"post_roll_enabled":false}
"""

@Test func timelineParserPreservesLargeSamplesAndIndependentMarkers() throws {
    let object = try #require(JSONSerialization.jsonObject(with: Data(fullTimelineJSON.utf8)) as? [String: Any])
    let state = try PTSLTimelineState.decode(object)
    #expect(state.selection.start == 9_007_199_254_740_993)
    #expect(state.playStartMarker == 9_007_199_254_700_001)
    #expect(state.preRollStart == 9_007_199_254_600_002)
    #expect(state.postRollStop == 9_007_199_254_900_003)
    let body = try PTSLRequestBodyFactory.setTimelineState(state)
    #expect(body["play_start_marker_time"] as? String == "9007199254700001")
    #expect(body["pre_roll_start_time"] as? String == "9007199254600002")
    #expect(body["post_roll_stop_time"] as? String == "9007199254900003")
    #expect(body["pre_roll_enabled"] as? String == "TB_True")
    #expect(body["post_roll_enabled"] as? String == "TB_False")
}

@Test(arguments: ["play_start_marker_time", "pre_roll_start_time", "post_roll_stop_time"])
func timelineParserRejectsMissingOrInvalidMarkers(field: String) throws {
    let source = try #require(JSONSerialization.jsonObject(with: Data(fullTimelineJSON.utf8)) as? [String: Any])
    for invalid in [nil, "", "1.5", "9223372036854775808"] as [String?] {
        var object = source
        object[field] = invalid
        #expect(throws: QuickBounceError.self) { try PTSLTimelineState.decode(object) }
    }
}

@Test func timelineParserAcceptsOmittedFalseButRejectsCoercedFlags() throws {
    var object = try #require(JSONSerialization.jsonObject(with: Data(fullTimelineJSON.utf8)) as? [String: Any])
    object.removeValue(forKey: "pre_roll_enabled")
    object.removeValue(forKey: "post_roll_enabled")
    #expect(try PTSLTimelineState.decode(object).preRollEnabled == false)
    for invalid: Any in ["true", 1, NSNull()] {
        object["pre_roll_enabled"] = invalid
        #expect(throws: QuickBounceError.self) { try PTSLTimelineState.decode(object) }
    }
}

@Test func oldRecoveryJournalDecodesWithoutInventingFullTimeline() throws {
    let old = SessionSnapshot(jobID: UUID(), session: FakeProToolsAdapter.demoSession.identity,
        trackStates: [], timelineSelection: SampleRange(start: 123, end: 456))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object.removeValue(forKey: "timelineState")
    let decoded = try JSONDecoder().decode(SessionSnapshot.self,
        from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.timelineState == nil)
    #expect(decoded.timelineSelection == old.timelineSelection)
}

private actor TimelineContractHost: PTSLCommandSending {
    let release: PTSLHostRelease
    var timeline = fullTimelineJSON
    var requests: [(PTSLCommand, String)] = []
    init(release: PTSLHostRelease) { self.release = release }
    nonisolated func cancel(wait: Bool) {}
    func send(_ command: PTSLCommand, bodyJSON: String, sessionID: String,
              version: PTSLProtocolVersion, headerJSON: String) async throws -> PTSLRawResponse {
        requests.append((command, bodyJSON))
        var body = "{}"
        switch command {
        case .registerConnection: body = #"{"session_id":"timeline-test"}"#
        case .getPTSLVersion:
            body = "{\"version\":\(release.year),\"version_minor\":\(release.month)}"
        case .getTimelineSelection: body = timeline
        case .setTimelineSelection:
            var object = try #require(JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any])
            object["pre_roll_enabled"] = (object["pre_roll_enabled"] as? String == "TB_True")
            object["post_roll_enabled"] = (object["post_roll_enabled"] as? String == "TB_True")
            timeline = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        default: break
        }
        return PTSLRawResponse(commandID: command.rawValue, status: 3, progress: 100,
            taskID: "timeline", bodyJSON: body, bodyJSONChunks: [body], errorJSON: "",
            headerJSON: "{}", version: version)
    }
}

@Test(arguments: [PTSLHostRelease.v2025_10, .v2025_12, .v2026_04])
func realAdapterRoundTripsFullTimelineAtTransportBoundary(release: PTSLHostRelease) async throws {
    let host = TimelineContractHost(release: release)
    let adapter = RealProToolsAdapter(clientFactory: { _ in host })
    _ = try await adapter.connect()
    let original = try await adapter.currentTimelineState()
    try await adapter.setTimelineSelection(SampleRange(start: 48_000, end: 144_000))
    #expect(try await adapter.currentTimelineState().preRollEnabled == false)
    try await adapter.setTimelineState(original)
    #expect(try await adapter.currentTimelineState() == original)
    let reads = await host.requests.filter { $0.0 == .getTimelineSelection }
    #expect(reads.allSatisfy { $0.1.contains("TLType_Samples") })
}
