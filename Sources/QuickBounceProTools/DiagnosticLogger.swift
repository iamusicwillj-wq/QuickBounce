import Foundation
import CryptoKit
import QuickBounceDomain

public struct DiagnosticTimer: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var milliseconds: Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    public var field: String { String(format: "%.3f", milliseconds) }
}

public struct DiagnosticLogConfiguration: Sendable {
    public var appVersion: String
    public var appBuild: String
    public var maximumBytes: Int
    public var retainedLaunchCount: Int

    public init(
        appVersion: String,
        appBuild: String,
        maximumBytes: Int = 32 * 1_024 * 1_024,
        retainedLaunchCount: Int = 3
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.maximumBytes = maximumBytes
        self.retainedLaunchCount = retainedLaunchCount
    }
}

public enum DiagnosticLogError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Diagnostic logging is unavailable: \(detail)"
        case .exportFailed(let detail):
            "Could not export the diagnostic log: \(detail)"
        }
    }
}

/// A bounded, persistent diagnostic recorder for PTSL compatibility issues.
/// Sensitive values are replaced before a byte reaches disk. The aliases are
/// stable within one launch, allowing two Mix captures to be compared without
/// exposing Session paths, Track names, Track IDs, or output file names.
public actor DiagnosticLogger {
    private struct StoredEvent: Codable, Sendable {
        var timestamp: String
        var sequence: UInt64
        var launchID: String
        var category: String
        var action: String
        var correlationID: String?
        var fields: [String: String]
        var payloads: [String: String]
    }

    private struct ExportManifest: Codable, Sendable {
        var formatVersion: Int
        var generatedAt: String
        var quickBounceVersion: String
        var quickBounceBuild: String
        var operatingSystem: String
        var architecture: String
        var includedLogs: [String]
        var privacy: [String]
        var excludedData: [String]
    }

    private let directory: URL
    private let logURL: URL
    private let configuration: DiagnosticLogConfiguration
    private let launchID: String
    private var handle: FileHandle?
    private var sequence: UInt64 = 0
    private var bytesWritten = 0
    private var rotationCount = 0
    private var lastWriteMilliseconds: Double = 0
    private var aliases: [String: String] = [:]
    private var rawAliases: [String: String] = [:]
    private var replacementExpression: NSRegularExpression?
    private var replacementCacheIsDirty = false
    private var aliasCounts: [String: Int] = [:]

    public init(directory: URL, configuration: DiagnosticLogConfiguration) throws {
        self.directory = directory.standardizedFileURL
        self.configuration = configuration
        launchID = UUID().uuidString
        logURL = self.directory.appendingPathComponent(
            "QuickBounce-Diagnostic-\(launchID).jsonl"
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try Self.pruneOldLogs(
            in: self.directory,
            keeping: max(1, configuration.retainedLaunchCount - 1)
        )
        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
            throw DiagnosticLogError.unavailable("Could not create the local log file")
        }
        handle = try FileHandle(forWritingTo: logURL)
    }

    deinit {
        try? handle?.close()
    }

    public func recordLaunch() {
        record(
            category: "application",
            action: "launch",
            fields: [
                "quickbounce_version": configuration.appVersion,
                "quickbounce_build": configuration.appBuild,
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": Self.runtimeArchitecture,
                "process_id": String(ProcessInfo.processInfo.processIdentifier),
                "privacy_mode": "redacted_before_write"
            ]
        )
    }

    public func record(
        category: String,
        action: String,
        correlationID: String? = nil,
        fields: [String: String] = [:]
    ) {
        append(
            category: category,
            action: action,
            correlationID: correlationID,
            fields: fields,
            payloads: [:]
        )
    }

    public func recordTrackStates(
        action: String,
        states: [TrackState],
        correlationID: String? = nil,
        fields: [String: String] = [:]
    ) {
        let timer = DiagnosticTimer()
        let rows: [[String: Any]] = states.map { state in
            [
                "track_id": state.track.id,
                "track_name": state.track.name,
                "track_type": state.track.kind,
                "track_index": state.track.index,
                "parent_folder_id": state.track.parentFolderID ?? NSNull(),
                "is_soloed": state.isSolo,
                "is_muted": state.isMuted,
                "is_inactive": state.isInactive ?? false
            ]
        }
        var summary = fields
        summary["track_count"] = String(states.count)
        summary["soloed_count"] = String(states.filter(\.isSolo).count)
        summary["muted_count"] = String(states.filter(\.isMuted).count)
        // Keep reconstructable snapshots at user/safety boundaries. Routine
        // readbacks use the hash plus compact Solo/Mute ID sets, not repeated
        // copies of every Track's metadata.
        let canonical = sanitizedJSONObject(rows)
        summary["state_hash"] = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        summary["soloed_track_ids"] = states.filter(\.isSolo)
            .map { alias($0.track.id, prefix: "ID") }.joined(separator: ",")
        summary["muted_track_ids"] = states.filter(\.isMuted)
            .map { alias($0.track.id, prefix: "ID") }.joined(separator: ",")
        summary["log_prepare_ms"] = timer.field
        let detailed = ["mix_captured", "session_snapshot", "apply_requested", "apply_failed_readback"]
            .contains(action)
        append(
            category: "track_state",
            action: action,
            correlationID: correlationID,
            fields: summary,
            payloads: detailed ? ["track_states": canonical] : [:]
        )
    }

    func recordPTSLRequest(
        command: String,
        version: PTSLProtocolVersion,
        bodyJSON: String,
        correlationID: String
    ) {
        let timer = DiagnosticTimer()
        let payload = sanitizedJSON(bodyJSON)
        append(
            category: "ptsl",
            action: "request",
            correlationID: correlationID,
            fields: [
                "command": command,
                "version": "\(version.major).\(version.minor).\(version.revision)",
                "log_prepare_ms": timer.field
            ],
            payloads: ["request_body": payload]
        )
    }

    func recordPTSLResponse(
        command: String,
        response: PTSLRawResponse,
        correlationID: String,
        roundTripMilliseconds: Double = 0
    ) {
        let timer = DiagnosticTimer()
        var payloads: [String: String] = [:]
        let summarizeTracks = command == "getTrackList" && response.completed
        if !summarizeTracks, !response.bodyJSON.isEmpty {
            payloads["final_body"] = sanitizedJSON(response.bodyJSON)
        }
        for (index, chunk) in response.bodyJSONChunks.enumerated()
            where !summarizeTracks && chunk != response.bodyJSON {
            payloads[String(format: "body_chunk_%03d", index)] = sanitizedJSON(chunk)
        }
        if !response.errorJSON.isEmpty {
            payloads["error"] = sanitizedJSON(response.errorJSON)
        }
        if !response.headerJSON.isEmpty {
            payloads["response_header"] = sanitizedJSON(response.headerJSON)
        }
        append(
            category: "ptsl",
            action: "response",
            correlationID: correlationID,
            fields: [
                "command": command,
                "status": String(response.status),
                "progress": String(response.progress),
                "task_id": response.taskID,
                "version": "\(response.version.major).\(response.version.minor).\(response.version.revision)",
                "body_chunk_count": String(response.bodyJSONChunks.count),
                "response_bytes": String(response.bodyJSON.utf8.count),
                "round_trip_ms": String(format: "%.3f", roundTripMilliseconds),
                "client_queue_ms": String(format: "%.3f", response.queueMilliseconds),
                "transport_ms": String(format: "%.3f", response.transportMilliseconds),
                "log_prepare_ms": timer.field
            ],
            payloads: payloads
        )
    }

    func recordPTSLTransportFailure(
        command: String,
        error: Error,
        correlationID: String
    ) {
        append(
            category: "ptsl",
            action: "transport_failure",
            correlationID: correlationID,
            fields: [
                "command": command,
                "error": error.localizedDescription
            ],
            payloads: [:]
        )
    }

    /// Produces a ZIP containing only redacted JSONL logs, a manifest, and a
    /// plain-language README. No database, Session, audio, video, or Bounce
    /// output is read while this method runs.
    @discardableResult
    public func export(to destination: URL) throws -> URL {
        guard destination.isFileURL else {
            throw DiagnosticLogError.exportFailed("Choose a local file destination")
        }
        try handle?.synchronize()

        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "QuickBounce-Diagnostic-Export-\(UUID().uuidString)",
            isDirectory: true
        )
        let packageName = "QuickBounce Diagnostic Log"
        let package = temporaryRoot.appendingPathComponent(packageName, isDirectory: true)
        let logsDirectory = package.appendingPathComponent("Logs", isDirectory: true)
        let candidate = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let logs = try Self.availableLogs(in: directory)
                .suffix(max(1, configuration.retainedLaunchCount))
            for source in logs {
                try fileManager.copyItem(
                    at: source,
                    to: logsDirectory.appendingPathComponent(source.lastPathComponent)
                )
            }

            let manifest = ExportManifest(
                formatVersion: 1,
                generatedAt: Self.timestamp(),
                quickBounceVersion: configuration.appVersion,
                quickBounceBuild: configuration.appBuild,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: Self.runtimeArchitecture,
                includedLogs: logs.map(\.lastPathComponent),
                privacy: [
                    "Session paths are replaced with stable aliases before logging.",
                    "Track, Session, source, and file names are replaced with stable aliases before logging.",
                    "Track, Session, task, and PTSL connection IDs are replaced with stable aliases before logging."
                ],
                excludedData: [
                    "Audio and video files",
                    "Pro Tools Session files",
                    "QuickBounce SQLite databases",
                    "Waveform caches",
                    "Bounce output files"
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(
                to: package.appendingPathComponent("Manifest.json"),
                options: .atomic
            )
            try Self.exportReadme.write(
                to: package.appendingPathComponent("README.txt"),
                atomically: true,
                encoding: .utf8
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                package.path, candidate.path
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(
                    decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                throw DiagnosticLogError.exportFailed(
                    detail.isEmpty ? "ZIP creation failed" : detail
                )
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: candidate)
            } else {
                try fileManager.moveItem(at: candidate, to: destination)
            }
            try? fileManager.removeItem(at: temporaryRoot)
            return destination
        } catch {
            try? fileManager.removeItem(at: candidate)
            try? fileManager.removeItem(at: temporaryRoot)
            if let diagnosticError = error as? DiagnosticLogError {
                throw diagnosticError
            }
            throw DiagnosticLogError.exportFailed(error.localizedDescription)
        }
    }

    private func append(
        category: String,
        action: String,
        correlationID: String?,
        fields: [String: String],
        payloads: [String: String]
    ) {
        guard handle != nil else { return }
        sequence += 1
        for (key, value) in fields {
            registerSensitiveValue(value, forKey: key)
        }
        var event = StoredEvent(
            timestamp: Self.timestamp(),
            sequence: sequence,
            launchID: launchID,
            category: category,
            action: action,
            correlationID: correlationID.map { alias($0, prefix: "Correlation") },
            fields: Dictionary(uniqueKeysWithValues: fields.map { key, value in
                (key, sanitize(value, forKey: key))
            }),
            payloads: Dictionary(uniqueKeysWithValues: payloads.map { key, value in
                (key, bounded(value))
            })
        )
        event.fields["previous_write_ms"] = String(format: "%.3f", lastWriteMilliseconds)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(0x0A)
            if bytesWritten + data.count > configuration.maximumBytes {
                try rotateLog()
            }
            let timer = DiagnosticTimer()
            try handle?.write(contentsOf: data)
            bytesWritten += data.count
            lastWriteMilliseconds = timer.milliseconds
        } catch {
            try? handle?.close()
            handle = nil
        }
    }

    private func rotateLog() throws {
        try handle?.synchronize()
        try handle?.close()
        let previous = directory.appendingPathComponent("QuickBounce-Diagnostic-\(launchID)-previous.jsonl")
        if FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.removeItem(at: previous)
        }
        try FileManager.default.moveItem(at: logURL, to: previous)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: logURL)
        rotationCount += 1
        let marker = "{\"action\":\"recording_rotated\",\"category\":\"diagnostics\",\"rotation\":\(rotationCount)}\n"
        let data = Data(marker.utf8)
        try handle?.write(contentsOf: data)
        bytesWritten = data.count
    }

    private func sanitizedJSON(_ json: String) -> String {
        guard !json.isEmpty else { return "{}" }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return bounded(sanitizeText(json))
        }
        return sanitizedJSONObject(object)
    }

    private func sanitizedJSONObject(_ object: Any) -> String {
        registerSensitiveValues(in: object, key: nil)
        let sanitized = sanitizeJSONObject(object, key: nil)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return "{}"
        }
        return bounded(String(decoding: data, as: UTF8.self))
    }

    private func sanitizeJSONObject(_ value: Any, key: String?) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { childKey, childValue in
                (childKey, sanitizeJSONObject(childValue, key: childKey))
            })
        case let array as [Any]:
            return array.map { sanitizeJSONObject($0, key: key) }
        case let string as String:
            return sanitize(string, forKey: key ?? "")
        case let number as NSNumber:
            return number
        case _ as NSNull:
            return NSNull()
        default:
            return sanitizeText(String(describing: value))
        }
    }

    private func sanitize(_ value: String, forKey key: String) -> String {
        // These sets have already been anonymized above.
        if key == "soloed_track_ids" || key == "muted_track_ids" { return value }
        if let prefix = sensitiveAliasPrefix(for: value, key: key) {
            return alias(value, prefix: prefix)
        }
        // Protocol enums, command identifiers and numbers are not free text.
        // Searching all historical names for each one was both quadratic and
        // capable of corrupting "closeSession" when a Track was named "cl".
        if ["error", "issue", "message", "command_error_message", "detail"].contains(key) {
            return sanitizeText(value)
        }
        return value
    }

    private func registerSensitiveValues(in value: Any, key: String?) {
        switch value {
        case let dictionary as [String: Any]:
            for (childKey, childValue) in dictionary {
                registerSensitiveValues(in: childValue, key: childKey)
            }
        case let array as [Any]:
            for child in array {
                registerSensitiveValues(in: child, key: key)
            }
        case let string as String:
            registerSensitiveValue(string, forKey: key ?? "")
        default:
            break
        }
    }

    private func registerSensitiveValue(_ value: String, forKey key: String) {
        if key == "soloed_track_ids" || key == "muted_track_ids" { return }
        if let prefix = sensitiveAliasPrefix(for: value, key: key) {
            _ = alias(value, prefix: prefix)
        }
    }

    private func sensitiveAliasPrefix(for value: String, key: String) -> String? {
        let normalized = key.lowercased()
        if value.hasPrefix("/"), !value.hasPrefix("//") {
            return "Path"
        }
        if normalized.contains("path") || normalized == "directory" ||
            normalized == "file_list" || normalized == "file_destination_path" {
            return "Path"
        }
        if normalized.contains("track") && normalized.contains("name") {
            return "Track"
        }
        if normalized == "session_name" {
            return "Session"
        }
        if normalized == "file_name" || normalized == "name" ||
            normalized == "source_list" || normalized.hasSuffix("_name") {
            return "Name"
        }
        if normalized == "id" || normalized.hasSuffix("_id") ||
            normalized.hasSuffix("_ids") {
            return value.isEmpty ? nil : "ID"
        }
        return nil
    }

    private func sanitizeText(_ value: String) -> String {
        var result = value
        if replacementCacheIsDirty {
            let alternatives = rawAliases.keys.filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            replacementExpression = alternatives.isEmpty ? nil : try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{N}_])"
            )
            replacementCacheIsDirty = false
        }
        if let expression = replacementExpression {
            let original = result as NSString
            let mutable = NSMutableString(string: result)
            for match in expression.matches(in: result, range: NSRange(location: 0, length: original.length)).reversed() {
                if let replacement = rawAliases[original.substring(with: match.range)] {
                    mutable.replaceCharacters(in: match.range, with: replacement)
                }
            }
            result = mutable as String
        }
        result = replacingMatches(
            in: result,
            pattern: #"\{[0-9A-Fa-f-]{16,}\}"#,
            with: "<ID>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"/(?:Users|Volumes|private|tmp)/[^\n\r\"']+"#,
            with: "<Path>"
        )
        return result
    }

    private func alias(_ value: String, prefix: String) -> String {
        guard !value.isEmpty else { return "" }
        let key = "\(prefix)|\(value)"
        if let existing = aliases[key] { return existing }
        let next = (aliasCounts[prefix] ?? 0) + 1
        aliasCounts[prefix] = next
        let replacement = "<\(prefix)-\(next)>"
        aliases[key] = replacement
        // Also replace the raw value if it appears later inside an error text.
        rawAliases[value] = replacement
        replacementCacheIsDirty = true
        return replacement
    }

    private func bounded(_ value: String) -> String {
        let maximumCharacters = 4_000_000
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "…<payload truncated>"
    }

    private func replacingMatches(in value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    private static func availableLogs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix("QuickBounce-Diagnostic-") &&
                $0.pathExtension == "jsonl"
        }
        .sorted { lhs, rhs in
            let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
    }

    private static func pruneOldLogs(in directory: URL, keeping count: Int) throws {
        let logs = try availableLogs(in: directory)
        guard logs.count > count else { return }
        for url in logs.prefix(logs.count - count) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static let exportReadme = """
    QuickBounce Diagnostic Log

    This package is intended for troubleshooting QuickBounce and Pro Tools PTSL compatibility.

    Privacy:
    - Session paths, Track names, Track IDs, Session names, source names, and file names were replaced with stable aliases before they were written to disk.
    - The same alias within one launch represents the same original value, which allows state changes to be compared without revealing the value.

    This package does not contain audio, video, Pro Tools Session files, QuickBounce databases, waveform caches, or Bounce output files.
    """
}
