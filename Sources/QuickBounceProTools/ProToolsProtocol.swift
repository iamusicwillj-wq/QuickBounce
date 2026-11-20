import Foundation
import QuickBounceDomain

public struct PTSLCapabilities: Codable, Hashable, Sendable {
    public var trackIDSetters: Bool
    public var trackStateSetters: Bool
    public var trackStateEvents: Bool
    public var exportTimeRange: Bool
    public var audioEncodingOptions: Bool
    public var openSessionBehaviorOptions: Bool
    public var batchJobs: Bool
    public var importToNewTrackAtSamples: Bool

    public init(
        trackIDSetters: Bool,
        trackStateSetters: Bool = true,
        trackStateEvents: Bool,
        exportTimeRange: Bool,
        audioEncodingOptions: Bool,
        openSessionBehaviorOptions: Bool,
        batchJobs: Bool,
        importToNewTrackAtSamples: Bool
    ) {
        self.trackIDSetters = trackIDSetters
        self.trackStateSetters = trackStateSetters
        self.trackStateEvents = trackStateEvents
        self.exportTimeRange = exportTimeRange
        self.audioEncodingOptions = audioEncodingOptions
        self.openSessionBehaviorOptions = openSessionBehaviorOptions
        self.batchJobs = batchJobs
        self.importToNewTrackAtSamples = importToNewTrackAtSamples
    }

    public static let ptsl2026_04 = PTSLCapabilities(
        trackIDSetters: true,
        trackStateSetters: true,
        trackStateEvents: true,
        exportTimeRange: true,
        audioEncodingOptions: true,
        openSessionBehaviorOptions: true,
        batchJobs: true,
        importToNewTrackAtSamples: true
    )

    /// Capabilities exposed by the PTSL contract available in a Host release.
    /// These are deliberately user-facing capabilities, not a statement that
    /// every command is identical across releases.  The adapter still uses
    /// legacy request bodies where required.
    public static func forHostRelease(_ release: PTSLHostRelease) -> PTSLCapabilities {
        PTSLCapabilities(
            trackIDSetters: release >= .v2025_12,
            trackStateSetters: release >= .v2023_12,
            trackStateEvents: release >= .v2025_10,
            exportTimeRange: release >= .v2025_06,
            audioEncodingOptions: release >= .v2025_06,
            openSessionBehaviorOptions: release >= .v2025_06,
            batchJobs: release >= .v2025_10,
            importToNewTrackAtSamples: release >= .v2023_06
        )
    }
}

/// Normalized Pro Tools/PTSL Host release.  Before 2025.06 the Host reports
/// the protocol generation (1…5), so the adapter maps those generations to
/// their corresponding release for capability decisions.
public struct PTSLHostRelease: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let revision: Int

    public init(year: Int, month: Int, revision: Int = 0) {
        self.year = year
        self.month = month
        self.revision = revision
    }

    public static let v2023_06 = PTSLHostRelease(year: 2023, month: 6)
    public static let v2023_12 = PTSLHostRelease(year: 2023, month: 12)
    public static let v2024_03 = PTSLHostRelease(year: 2024, month: 3)
    public static let v2024_06 = PTSLHostRelease(year: 2024, month: 6)
    public static let v2024_10 = PTSLHostRelease(year: 2024, month: 10)
    public static let v2025_06 = PTSLHostRelease(year: 2025, month: 6)
    public static let v2025_10 = PTSLHostRelease(year: 2025, month: 10)
    public static let v2025_12 = PTSLHostRelease(year: 2025, month: 12)
    public static let v2026_04 = PTSLHostRelease(year: 2026, month: 4)

    public static func < (lhs: PTSLHostRelease, rhs: PTSLHostRelease) -> Bool {
        (lhs.year, lhs.month, lhs.revision) < (rhs.year, rhs.month, rhs.revision)
    }

    public var description: String {
        revision == 0 ? String(format: "%d.%02d", year, month)
            : String(format: "%d.%02d.%d", year, month, revision)
    }

    public var requestVersion: PTSLProtocolVersion {
        if year >= 2025 {
            return PTSLProtocolVersion(
                major: Int32(year), minor: Int32(month), revision: Int32(revision)
            )
        }
        let protocolMajor: Int32 = switch (year, month) {
        case (2024, 10): 5
        case (2024, 6): 4
        case (2024, 3): 3
        case (2023, 12): 2
        default: 1
        }
        return PTSLProtocolVersion(major: protocolMajor, minor: 0, revision: 0)
    }

    public static func fromHostResponse(
        major: Int32,
        minor: Int32,
        revision: Int32
    ) -> PTSLHostRelease? {
        if major >= 2025 {
            return PTSLHostRelease(year: Int(major), month: Int(minor), revision: Int(revision))
        }
        switch major {
        case 5: return .v2024_10
        case 4: return .v2024_06
        case 3: return .v2024_03
        case 2: return .v2023_12
        case 1: return PTSLHostRelease(year: 2022, month: 12)
        default: return nil
        }
    }

    public static func fromDisplayString(_ value: String) -> PTSLHostRelease? {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return PTSLHostRelease(
            year: parts[0],
            month: parts[1],
            revision: parts.count > 2 ? parts[2] : 0
        )
    }

    public var unavailableUserFeatures: [String] {
        var features: [String] = []
        if self < .v2025_06 { features.append("Cross-Session Bounce") }
        if self < .v2025_06 { features.append("MP3-only encoding options") }
        return features
    }
}

public struct ProToolsConnection: Codable, Hashable, Sendable {
    public var status: ConnectionStatus
    public var connectionID: String
    public var ptslVersion: String
    public var capabilities: PTSLCapabilities

    public init(
        status: ConnectionStatus,
        connectionID: String,
        ptslVersion: String,
        capabilities: PTSLCapabilities
    ) {
        self.status = status
        self.connectionID = connectionID
        self.ptslVersion = ptslVersion
        self.capabilities = capabilities
    }
}

public enum ProToolsVideoExportMode: Hashable, Sendable {
    case sameAsSource
    case transcodeH264
}

public struct ProToolsExportRequest: Hashable, Sendable {
    public var plan: BouncePlan
    public var stagingDirectory: URL
    public var baseFileName: String
    public var kind: ArtifactKind
    public var videoMode: ProToolsVideoExportMode

    public init(
        plan: BouncePlan,
        stagingDirectory: URL,
        baseFileName: String,
        kind: ArtifactKind,
        videoMode: ProToolsVideoExportMode = .sameAsSource
    ) {
        self.plan = plan
        self.stagingDirectory = stagingDirectory
        self.baseFileName = baseFileName
        self.kind = kind
        self.videoMode = videoMode
    }
}

public struct ProToolsExportResult: Hashable, Sendable {
    public var taskID: String
    public var candidateURLs: [URL]

    public init(taskID: String, candidateURLs: [URL]) {
        self.taskID = taskID
        self.candidateURLs = candidateURLs
    }
}

public struct ImportAudioRequest: Hashable, Sendable {
    public var fileURL: URL
    public var spotSamples: Int64
    public var trackName: String

    public init(fileURL: URL, spotSamples: Int64, trackName: String) {
        self.fileURL = fileURL
        self.spotSamples = spotSamples
        self.trackName = trackName
    }
}

public struct ProToolsMixSource: Codable, Hashable, Identifiable, Sendable {
    public var type: MixSourceType
    public var name: String

    public init(type: MixSourceType, name: String) {
        self.type = type
        self.name = name
    }

    public var id: String { "\(type.rawValue):\(name)" }
    public var displayName: String { "\(name) — \(type.displayName)" }
}

public struct SessionContext: Sendable {
    public var info: SessionInfo
    public var trackStates: [TrackState]
}

public struct ProToolsMixCapture: Sendable {
    public var session: SessionInfo
    public var trackStates: [TrackState]
    public var range: SampleRange
    public var mixSources: [ProToolsMixSource]
}

public protocol ProToolsControlling: Sendable {
    func connect() async throws -> ProToolsConnection
    func disconnect() async
    func currentSessionInfo() async throws -> SessionInfo
    func currentSessionIdentity() async throws -> SessionIdentity
    func currentSessionContext() async throws -> SessionContext
    func currentTimelineSelection() async throws -> SampleRange
    func setTimelineSelection(_ range: SampleRange) async throws
    func currentTimelineState() async throws -> TimelineState
    func setTimelineState(_ state: TimelineState) async throws
    func trackStates() async throws -> [TrackState]
    func exportMixSources() async throws -> [ProToolsMixSource]
    @discardableResult
    func apply(trackStates: [TrackState]) async throws -> [TrackState]
    func exportMix(_ request: ProToolsExportRequest) async throws -> ProToolsExportResult
    func cancelActiveExport() async
    func waitUntilReady() async throws
    func importAudio(_ request: ImportAudioRequest) async throws
    func saveSession() async throws
    func closeSession() async throws
    func openSession(at url: URL) async throws
}

extension ProToolsControlling {
    public func currentSessionIdentity() async throws -> SessionIdentity {
        try await currentSessionInfo().identity
    }

    public func currentSessionContext() async throws -> SessionContext {
        var info = try await currentSessionInfo()
        let tracks = try await trackStates()
        info.trackCount = tracks.count
        return SessionContext(info: info, trackStates: tracks)
    }

    /// One fresh track snapshot shared with Session Info. Never reuse a previous
    /// Add Mix snapshot: the user may have changed any Solo/Mute in Pro Tools.
    public func captureMix() async throws -> ProToolsMixCapture {
        let context = try await currentSessionContext()
        let range = try await currentTimelineSelection()
        let sources = try await exportMixSources()
        let after = try await currentSessionIdentity()
        guard after.instanceID == context.info.identity.instanceID,
              after.path == context.info.identity.path else {
            throw QuickBounceError.sessionIdentityMismatch
        }
        return ProToolsMixCapture(
            session: context.info, trackStates: context.trackStates,
            range: range, mixSources: sources
        )
    }
}
