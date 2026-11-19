import Darwin
import Foundation
import QuickBounceDomain
import QuickBounceProTools

@main
struct QuickBounceContractHarness {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let adapter = RealProToolsAdapter()
            let connection = try await adapter.connect()

            // The first PTSL query after registration reads path/IDs only. Do
            // not enumerate tracks until the canonical path is allowlisted.
            let identity = try await adapter.currentSessionIdentity()
            let actualPath = canonical(identity.path)
            let allowedPaths = Set(options.allowedSessionPaths.map(canonical))
            guard allowedPaths.contains(actualPath) else {
                await adapter.disconnect()
                throw HarnessError.sessionNotAllowed(actual: actualPath, allowed: allowedPaths.sorted())
            }

            let info = try await adapter.currentSessionInfo()
            let tracks = try await adapter.trackStates()
            var warnings: [String] = []
            let timeline: SampleRange?
            do { timeline = try await adapter.currentTimelineSelection() }
            catch {
                timeline = nil
                warnings.append("Timeline Selection: \(error.localizedDescription)")
            }
            let sources: [ProToolsMixSource]
            do { sources = try await adapter.exportMixSources() }
            catch {
                sources = []
                warnings.append("Export Mix Sources: \(error.localizedDescription)")
            }

            let report = InspectionReport(
                generatedAt: Date(),
                mode: "read-only",
                connection: connection,
                session: info,
                canonicalSessionPath: actualPath,
                allowedSessionPaths: allowedPaths.sorted(),
                timelineSelection: timeline,
                tracks: tracks,
                exportMixSources: sources,
                warnings: warnings
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            await adapter.disconnect()
        } catch {
            FileHandle.standardError.write(Data("QuickBounce Contract Harness: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private struct Options {
    var allowedSessionPaths: [String]

    init(arguments: [String]) throws {
        guard arguments.first == "inspect" else { throw HarnessError.usage }
        var allowed: [String] = []
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--allow-session", index + 1 < arguments.count else {
                throw HarnessError.usage
            }
            allowed.append(arguments[index + 1])
            index += 2
        }
        guard !allowed.isEmpty else { throw HarnessError.usage }
        allowedSessionPaths = allowed
    }
}

private struct InspectionReport: Codable {
    var generatedAt: Date
    var mode: String
    var connection: ProToolsConnection
    var session: SessionInfo
    var canonicalSessionPath: String
    var allowedSessionPaths: [String]
    var timelineSelection: SampleRange?
    var tracks: [TrackState]
    var exportMixSources: [ProToolsMixSource]
    var warnings: [String]
}

private enum HarnessError: Error, LocalizedError {
    case usage
    case sessionNotAllowed(actual: String, allowed: [String])

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: QuickBounceContractHarness inspect --allow-session /absolute/session.ptx [--allow-session /absolute/session.ptx]"
        case .sessionNotAllowed(let actual, let allowed):
            "Current Session is outside the test allowlist. Actual: \(actual). Allowed: \(allowed.joined(separator: ", "))"
        }
    }
}
