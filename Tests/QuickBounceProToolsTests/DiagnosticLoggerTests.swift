import Foundation
import QuickBounceDomain
@testable import QuickBounceProTools
import QuickBounceTestSupport
import Testing

@Test func diagnosticExportRedactsSensitivePTSLAndTrackValuesBeforeWriting() async throws {
    let workspace = try TestWorkspace.freshDirectory("diagnostic-redaction")
    let logs = workspace.appendingPathComponent("Logs", isDirectory: true)
    let destination = workspace.appendingPathComponent("QuickBounce Diagnostic Log.zip")
    let logger = try DiagnosticLogger(
        directory: logs,
        configuration: DiagnosticLogConfiguration(
            appVersion: "0.6.0",
            appBuild: "35",
            maximumBytes: 2 * 1_024 * 1_024
        )
    )

    let sessionPath = "/Users/recording-engineer/Client Album/Secret Song.ptx"
    let trackID = "{00000000-2a000000-b824bce6-081666c4}"
    let trackName = "Lead Vocal"
    let state = TrackState(
        track: TrackReference(
            id: trackID,
            name: trackName,
            index: 11,
            kind: "TT_Audio"
        ),
        isSolo: false,
        isMuted: true
    )

    await logger.recordTrackStates(
        action: "mix_captured",
        states: [state],
        correlationID: "capture-correlation",
        fields: [
            "session_path": sessionPath,
            "plan_name": "MMO"
        ]
    )
    await logger.recordPTSLRequest(
        command: "setTrackMuteState",
        version: PTSLProtocolVersion(major: 2025, minor: 10, revision: 0),
        bodyJSON: """
        {"track_names":["\(trackName)"],"enabled":false,"session_path":"\(sessionPath)"}
        """,
        correlationID: "ptsl-correlation"
    )

    _ = try await logger.export(to: destination)
    let extracted = workspace.appendingPathComponent("Extracted", isDirectory: true)
    try extractZIP(destination, to: extracted)
    let package = extracted.appendingPathComponent("QuickBounce Diagnostic Log", isDirectory: true)
    let logURLs = try FileManager.default.contentsOfDirectory(
        at: package.appendingPathComponent("Logs", isDirectory: true),
        includingPropertiesForKeys: nil
    )
    let content = try logURLs
        .filter { $0.pathExtension == "jsonl" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

    #expect(!content.contains(sessionPath))
    #expect(!content.contains("recording-engineer"))
    #expect(!content.contains(trackID))
    #expect(!content.contains(trackName))
    #expect(!content.contains("MMO"))
    #expect(content.contains("<Path-"))
    #expect(content.contains("<Track-"))
    #expect(content.contains("<ID-"))
    #expect(content.contains("mix_captured"))
    #expect(content.contains("setTrackMuteState"))

    for line in content.split(separator: "\n") {
        _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
    }
}

@Test func diagnosticExportContainsOnlyRedactedLogsAndDocumentation() async throws {
    let workspace = try TestWorkspace.freshDirectory("diagnostic-package")
    let logger = try DiagnosticLogger(
        directory: workspace.appendingPathComponent("Logs", isDirectory: true),
        configuration: DiagnosticLogConfiguration(appVersion: "0.6.0", appBuild: "35")
    )
    await logger.recordLaunch()
    let destination = workspace.appendingPathComponent("Diagnostics.zip")
    _ = try await logger.export(to: destination)

    let extracted = workspace.appendingPathComponent("Extracted", isDirectory: true)
    try extractZIP(destination, to: extracted)
    let package = extracted.appendingPathComponent("QuickBounce Diagnostic Log", isDirectory: true)
    let entries = recursiveRelativePaths(in: package)

    #expect(entries.contains("Manifest.json"))
    #expect(entries.contains("README.txt"))
    #expect(entries.contains(where: { $0.hasPrefix("Logs/") && $0.hasSuffix(".jsonl") }))
    #expect(!entries.contains(where: {
        let lower = $0.lowercased()
        return lower.hasSuffix(".sqlite") || lower.hasSuffix(".ptx") ||
            lower.hasSuffix(".wav") || lower.hasSuffix(".mp3") || lower.hasSuffix(".mov")
    }))

    let manifestData = try Data(contentsOf: package.appendingPathComponent("Manifest.json"))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    #expect(manifest["quickBounceVersion"] as? String == "0.6.0")
    #expect(manifest["quickBounceBuild"] as? String == "35")
}

private func extractZIP(_ source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", source.path, destination.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DiagnosticLogError.exportFailed("Test ZIP extraction failed")
    }
}

@Test func compactDiagnosticsPreserveProtocolTextAndReportSeparateTimings() async throws {
    let directory = try TestWorkspace.freshDirectory("compact-diagnostics")
    let logger = try DiagnosticLogger(directory: directory,
        configuration: .init(appVersion: "0.6.0", appBuild: "35"))
    let states = (0..<500).map { index in
        TrackState(track: TrackReference(id: "private-id-\(index)",
            name: index == 0 ? "cl" : "Secret Track \(index)", index: index, kind: "TT_Audio"),
            isSolo: index == 1, isMuted: index == 2)
    }
    await logger.recordTrackStates(action: "mix_captured", states: states)
    for _ in 0..<12 {
        await logger.recordTrackStates(action: "get_track_list_parsed", states: states)
    }
    let warning = """
    {"errors":[{"command_error_type":"CEType_PT_UnknownError","command_error_message":"cl: Secret Track 1 failed at /Users/secret/Session.ptx","is_warning":true}]}
    """
    let response = PTSLRawResponse(commandID: 3, status: 3, progress: 100, taskID: "task",
        bodyJSON: "{\"track_list\":[]}", bodyJSONChunks: ["{\"track_list\":[]}"],
        errorJSON: warning, headerJSON: "{}", version: .v2026_04,
        queueMilliseconds: 2, transportMilliseconds: 4)
    await logger.recordPTSLResponse(command: "getTrackList", response: response,
        correlationID: "test", roundTripMilliseconds: 7)
    await logger.record(category: "ptsl", action: "request", fields: ["command": "closeSession"])
    let events = try diagnosticEvents(in: directory)
    let compact = events.filter { $0["action"] as? String == "get_track_list_parsed" }
    #expect(compact.count == 12)
    for event in compact {
        #expect((event["payloads"] as? [String: String])?.isEmpty == true)
        let fields = try #require(event["fields"] as? [String: String])
        #expect(fields["track_count"] == "500")
        #expect(fields["state_hash"]?.count == 64)
        #expect(Double(fields["log_prepare_ms"] ?? "") != nil)
    }
    let reply = try #require(events.first { $0["action"] as? String == "response" })
    let fields = try #require(reply["fields"] as? [String: String])
    #expect(fields["round_trip_ms"] == "7.000")
    #expect(fields["client_queue_ms"] == "2.000")
    #expect(fields["transport_ms"] == "4.000")
    let payloads = try #require(reply["payloads"] as? [String: String])
    #expect(payloads["final_body"] == nil)
    #expect(payloads["body_chunk_000"] == nil)
    #expect(payloads["error"]?.contains("CEType_PT_UnknownError") == true)
    #expect(payloads["error"]?.contains("Secret Track") == false)
    #expect(payloads["error"]?.contains("/Users/secret") == false)
    #expect((events.last?["fields"] as? [String: String])?["command"] == "closeSession")
    let compactBytes = try compact.reduce(0) { try $0 + JSONSerialization.data(withJSONObject: $1).count }
    #expect(compactBytes < 16_000)
}

@Test func diagnosticRotationKeepsRecordingLaterFailures() async throws {
    let directory = try TestWorkspace.freshDirectory("rotating-diagnostics")
    let logger = try DiagnosticLogger(directory: directory,
        configuration: .init(appVersion: "0.6.0", appBuild: "35", maximumBytes: 2_000))
    for index in 0..<50 {
        await logger.record(category: "test", action: "progress", fields: ["step": String(index)])
    }
    await logger.record(category: "review_analysis", action: "waveform_failed",
        fields: ["error": "Cannot read /Users/private/Source.wav"])
    let events = try diagnosticEvents(in: directory)
    #expect(events.contains { $0["action"] as? String == "recording_rotated" })
    let failure = try #require(events.first { $0["action"] as? String == "waveform_failed" })
    #expect((failure["fields"] as? [String: String])?["error"]?.contains("/Users/private") == false)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.filter { $0.pathExtension == "jsonl" }.count == 2)
    for file in files { #expect(try Data(contentsOf: file).count < 2_500) }
}

private func diagnosticEvents(in directory: URL) throws -> [[String: Any]] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
        .flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
            }
        }
}

private func recursiveRelativePaths(in root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
    return enumerator.compactMap { $0 as? String }
}
