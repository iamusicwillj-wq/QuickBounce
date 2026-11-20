import Dispatch
import Foundation
@preconcurrency import QuickBouncePTSLBridge

public enum PTSLCommand: Int32, CaseIterable, Sendable {
    case openSession = 1
    case importAudio = 2
    case getTrackList = 3
    case hostReadyCheck = 13
    case closeSession = 17
    case saveSession = 18
    case exportMix = 28
    case getSessionAudioFormat = 34
    case getSessionSampleRate = 35
    case getSessionBitDepth = 36
    case getSessionTimeCodeRate = 38
    case getSessionName = 42
    case getSessionPath = 43
    case getSessionLength = 45
    case getPTSLVersion = 55
    case registerConnection = 70
    case createNewTracks = 72
    case setTimelineSelection = 81
    case getTimelineSelection = 82
    case setTrackMuteState = 85
    case setTrackSoloState = 86
    case getSessionIDs = 97
    case getMainCounterFormat = 102
    case getTimeAsType = 118
    case importAudioToClipList = 123
    case spotClipsByID = 124
    case getExportMixSourceList = 128
    case subscribeToEvents = 132
    case pollEvents = 135
    case cancelBatchJob = 138
}

public struct PTSLProtocolVersion: Hashable, Sendable {
    public var major: Int32
    public var minor: Int32
    public var revision: Int32

    public init(major: Int32 = 2026, minor: Int32 = 4, revision: Int32 = 0) {
        self.major = major
        self.minor = minor
        self.revision = revision
    }

    public static let v2026_04 = PTSLProtocolVersion()
    /// Version used by the pre-2025 PTSL request envelope.  Newer Hosts also
    /// accept this version, which lets the connection bootstrap before the
    /// Host's release is known.
    public static let v1 = PTSLProtocolVersion(major: 1, minor: 0, revision: 0)
    public static let v3 = PTSLProtocolVersion(major: 3, minor: 0, revision: 0)
    public static let v4 = PTSLProtocolVersion(major: 4, minor: 0, revision: 0)
    public static let v5 = PTSLProtocolVersion(major: 5, minor: 0, revision: 0)
}

public struct PTSLRawResponse: Hashable, Sendable {
    public var commandID: Int32
    public var status: Int32
    public var progress: Int32
    public var taskID: String
    public var bodyJSON: String
    public var bodyJSONChunks: [String]
    public var errorJSON: String
    public var headerJSON: String
    public var version: PTSLProtocolVersion
    public var queueMilliseconds: Double = 0
    public var transportMilliseconds: Double = 0

    public var completed: Bool { status == 3 }
}

private final class PTSLBridgeStorage: @unchecked Sendable {
    let pointer: QBPTSLClientRef

    init(address: String, allowHostLaunch: Bool) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let created = address.withCString { addressPointer in
            qb_ptsl_client_create(addressPointer, allowHostLaunch, &errorPointer)
        }
        guard let created else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unable to create PTSL client"
            if let errorPointer { qb_ptsl_string_dispose(errorPointer) }
            throw PTSLTransportError.bridge(message)
        }
        pointer = created
    }

    deinit {
        qb_ptsl_client_destroy(pointer)
    }
}

public enum PTSLTransportError: Error, LocalizedError, Sendable {
    case bridge(String)
    case command(status: Int32, message: String)

    public var indicatesProToolsIsNotAvailable: Bool {
        let message: String = switch self {
        case .bridge(let message), .command(_, let message): message
        }
        return message.contains("OS_ProToolsIsNotAvailable")
    }

    var indicatesInsufficientDiskSpace: Bool {
        commandErrors.contains { error in
            guard (error["is_warning"] as? Bool) != true else { return false }
            let code = error["command_error_type"]
            return (code as? Int) == 6 || (code as? String) == "CEType_OS_DiskSpace"
                || (code as? String) == "OS_DiskSpace"
        }
    }

    public var canRetryWithVideoTranscode: Bool {
        guard case .command(status: 4, _) = self else { return false }
        let errors = commandErrors
        func rejectsSameAsSource(_ message: String) -> Bool {
            message.contains("not supported for same as source export")
                || message.contains("same as source option will be disabled")
                || message.contains("long gop video requires the first frame of the file")
        }

        guard errors.contains(where: { error in
            rejectsSameAsSource((error["command_error_message"] as? String ?? "").lowercased())
        }) else { return false }

        // Pro Tools can bundle this warning with an independent failure,
        // including an unwritable audio volume. Retry only the video failure.
        return errors.allSatisfy { error in
            if (error["is_warning"] as? Bool) == true { return true }
            let message = (error["command_error_message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return rejectsSameAsSource(message)
                || message == "failed to procede with bounce. refer to error dialog."
                || message == "failed to proceed with bounce. refer to error dialog."
        }
    }

    private var commandErrors: [[String: Any]] {
        guard case .command(_, let message) = self,
              let payload = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let errors = payload["errors"] as? [[String: Any]] else { return [] }
        return errors
    }

    public var errorDescription: String? {
        switch self {
        case .bridge(let message): message
        case .command(let status, let message): "PTSL status \(status): \(message)"
        }
    }
}

protocol PTSLCommandSending: Sendable {
    func send(_ command: PTSLCommand, bodyJSON: String, sessionID: String,
              version: PTSLProtocolVersion, headerJSON: String) async throws -> PTSLRawResponse
    func cancel(wait: Bool)
}

public final class PTSLRawClient: PTSLCommandSending, @unchecked Sendable {
    private let storage: PTSLBridgeStorage
    private let queue: DispatchQueue

    public init(label: String, address: String = "localhost:31416", allowHostLaunch: Bool = false) throws {
        storage = try PTSLBridgeStorage(address: address, allowHostLaunch: allowHostLaunch)
        queue = DispatchQueue(label: "com.quickbounce.ptsl.\(label)", qos: .userInitiated)
    }

    public func send(
        _ command: PTSLCommand,
        bodyJSON: String = "{}",
        sessionID: String = "",
        version: PTSLProtocolVersion = .v2026_04,
        headerJSON: String = "{}"
    ) async throws -> PTSLRawResponse {
        let queued = DiagnosticTimer()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [storage] in
                let queueMilliseconds = queued.milliseconds
                let transport = DiagnosticTimer()
                do {
                    var response = try Self.performSend(
                        storage: storage,
                        command: command,
                        bodyJSON: bodyJSON,
                        sessionID: sessionID,
                        version: version,
                        headerJSON: headerJSON
                    )
                    response.queueMilliseconds = queueMilliseconds
                    response.transportMilliseconds = transport.milliseconds
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func cancel(wait: Bool = false) {
        qb_ptsl_client_cancel(storage.pointer, wait)
    }

    public static var bridgeSDKVersion: String {
        String(cString: qb_ptsl_bridge_sdk_version())
    }

    private static func performSend(
        storage: PTSLBridgeStorage,
        command: PTSLCommand,
        bodyJSON: String,
        sessionID: String,
        version: PTSLProtocolVersion,
        headerJSON: String
    ) throws -> PTSLRawResponse {
        var raw = bodyJSON.withCString { bodyPointer in
            sessionID.withCString { sessionPointer in
                headerJSON.withCString { headerPointer in
                    qb_ptsl_client_send(
                        storage.pointer,
                        command.rawValue,
                        bodyPointer,
                        sessionPointer,
                        version.major,
                        version.minor,
                        version.revision,
                        headerPointer
                    )
                }
            }
        }
        defer { qb_ptsl_response_dispose(&raw) }

        if let bridgeError = raw.bridge_error {
            throw PTSLTransportError.bridge(String(cString: bridgeError))
        }
        var bodyJSONChunks: [String] = []
        if raw.body_json_chunk_count > 0, let chunks = raw.body_json_chunks {
            bodyJSONChunks.reserveCapacity(Int(raw.body_json_chunk_count))
            for index in 0..<Int(raw.body_json_chunk_count) {
                if let chunk = chunks[index] {
                    bodyJSONChunks.append(String(cString: chunk))
                }
            }
        }
        return PTSLRawResponse(
            commandID: raw.command_id,
            status: raw.status,
            progress: raw.progress,
            taskID: raw.task_id.map { String(cString: $0) } ?? "",
            bodyJSON: raw.body_json.map { String(cString: $0) } ?? "",
            bodyJSONChunks: bodyJSONChunks,
            errorJSON: raw.error_json.map { String(cString: $0) } ?? "",
            headerJSON: raw.header_json.map { String(cString: $0) } ?? "",
            version: PTSLProtocolVersion(
                major: raw.version_major,
                minor: raw.version_minor,
                revision: raw.version_revision
            )
        )
    }
}
