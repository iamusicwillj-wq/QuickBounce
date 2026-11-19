import Foundation

public enum ExportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case wav
    case mp3
    case wavAndMP3
    case mov

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wav: "WAV"
        case .mp3: "MP3"
        case .wavAndMP3: "WAV + MP3"
        case .mov: "MOV"
        }
    }

    public var supportsImportAfterBounce: Bool { self != .mov }
}

public enum MOVAudioCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case pcm
    case aac

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
    public static let aacSampleRates = [44_100, 48_000]
}

public enum AudioFileLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case mono
    case multipleMono
    case interleaved

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mono: "Mono"
        case .multipleMono: "Multiple Mono"
        case .interleaved: "Interleaved"
        }
    }
}

public enum MP3EncodingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case fastest
    case standard
    case highest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fastest: "Fast"
        case .standard: "Standard"
        case .highest: "Highest"
        }
    }
}

public enum MixSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case physicalOutput
    case bus
    case trackOutput

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .physicalOutput: "Physical Output"
        case .bus: "Bus"
        case .trackOutput: "Output"
        }
    }
}

public struct BounceSettings: Codable, Hashable, Sendable {
    public var exportType: ExportType
    public var sampleRate: Int
    public var bitDepth: Int
    public var fileLayout: AudioFileLayout
    public var movAudioCodec: MOVAudioCodec
    public var mp3Quality: MP3EncodingQuality
    public var mp3ConstantBitRateKbps: Int
    public var importAfterBounce: Bool
    public var offlineBounce: Bool
    public var padToFrameBoundary: Bool
    public var fileDestination: String
    public var mixSourceType: MixSourceType
    public var mixSource: String

    public init(
        exportType: ExportType = .wav,
        sampleRate: Int = 48_000,
        bitDepth: Int = 24,
        fileLayout: AudioFileLayout = .interleaved,
        movAudioCodec: MOVAudioCodec = .pcm,
        mp3Quality: MP3EncodingQuality = .highest,
        mp3ConstantBitRateKbps: Int = 320,
        importAfterBounce: Bool = false,
        offlineBounce: Bool = true,
        padToFrameBoundary: Bool = true,
        fileDestination: String,
        mixSourceType: MixSourceType = .physicalOutput,
        mixSource: String = "Output 1–2"
    ) {
        self.exportType = exportType
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileLayout = fileLayout
        self.movAudioCodec = movAudioCodec
        self.mp3Quality = mp3Quality
        self.mp3ConstantBitRateKbps = mp3ConstantBitRateKbps
        self.importAfterBounce = importAfterBounce && exportType.supportsImportAfterBounce
        self.offlineBounce = offlineBounce
        self.padToFrameBoundary = padToFrameBoundary
        self.fileDestination = URL(fileURLWithPath: fileDestination).standardizedFileURL.path
        self.mixSourceType = mixSourceType
        self.mixSource = mixSource
    }

    private enum CodingKeys: String, CodingKey {
        case exportType
        case sampleRate
        case bitDepth
        case fileLayout
        case movAudioCodec
        case mp3Quality
        case mp3ConstantBitRateKbps
        case importAfterBounce
        case offlineBounce
        case padToFrameBoundary
        case fileDestination
        case mixSourceType
        case mixSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            exportType: try container.decodeIfPresent(ExportType.self, forKey: .exportType) ?? .wav,
            sampleRate: try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000,
            bitDepth: try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 24,
            fileLayout: try container.decodeIfPresent(AudioFileLayout.self, forKey: .fileLayout) ?? .interleaved,
            movAudioCodec: try container.decodeIfPresent(MOVAudioCodec.self, forKey: .movAudioCodec) ?? .pcm,
            mp3Quality: try container.decodeIfPresent(MP3EncodingQuality.self, forKey: .mp3Quality) ?? .highest,
            mp3ConstantBitRateKbps: try container.decodeIfPresent(Int.self, forKey: .mp3ConstantBitRateKbps) ?? 320,
            importAfterBounce: try container.decodeIfPresent(Bool.self, forKey: .importAfterBounce) ?? false,
            offlineBounce: try container.decodeIfPresent(Bool.self, forKey: .offlineBounce) ?? true,
            padToFrameBoundary: try container.decodeIfPresent(Bool.self, forKey: .padToFrameBoundary) ?? true,
            fileDestination: try container.decode(String.self, forKey: .fileDestination),
            mixSourceType: try container.decodeIfPresent(MixSourceType.self, forKey: .mixSourceType) ?? .physicalOutput,
            mixSource: try container.decodeIfPresent(String.self, forKey: .mixSource) ?? "Output 1–2"
        )
    }
}

public struct BouncePlan: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var bouncePresetID: UUID?
    public var note: String
    public var session: SessionIdentity
    public var targetTrackStates: [TrackState]
    public var range: SampleRange
    /// Timeline sample positions are expressed in the Session sample rate,
    /// which can differ from the requested output sample rate. Optional keeps
    /// V0.1 plans decodable while V0.2 captures the exact source rate.
    public var sourceSampleRate: Int?
    /// Captured with the Mix so cross-Session validation uses the originating
    /// Session's frame cadence rather than whichever Session is currently open.
    public var sourceTimeCodeRate: SessionTimeCodeRate?
    public var settings: BounceSettings
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        bouncePresetID: UUID? = nil,
        note: String = "",
        session: SessionIdentity,
        targetTrackStates: [TrackState],
        range: SampleRange,
        sourceSampleRate: Int? = nil,
        sourceTimeCodeRate: SessionTimeCodeRate? = nil,
        settings: BounceSettings,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bouncePresetID = bouncePresetID
        self.note = note
        self.session = session
        self.targetTrackStates = targetTrackStates
        self.range = range
        self.sourceSampleRate = sourceSampleRate
        self.sourceTimeCodeRate = sourceTimeCodeRate
        self.settings = settings
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct SessionSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var jobID: UUID
    public var session: SessionIdentity
    public var trackStates: [TrackState]
    public var timelineSelection: SampleRange?
    /// Added in 0.6.5. Older journals retain their In/Out-only recovery path.
    public var timelineState: TimelineState?
    public var createdAt: Date
    public var restoreRequired: Bool
    public var verifiedAt: Date?
    /// Optional for backward-compatible decoding of V0.1 development journals
    /// written before cross-Session recovery recorded its Save requirement.
    public var saveAfterRestore: Bool?

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        session: SessionIdentity,
        trackStates: [TrackState],
        timelineSelection: SampleRange? = nil,
        timelineState: TimelineState? = nil,
        createdAt: Date = Date(),
        restoreRequired: Bool = true,
        verifiedAt: Date? = nil,
        saveAfterRestore: Bool = false
    ) {
        self.id = id
        self.jobID = jobID
        self.session = session
        self.trackStates = trackStates
        self.timelineSelection = timelineState?.selection ?? timelineSelection
        self.timelineState = timelineState
        self.createdAt = createdAt
        self.restoreRequired = restoreRequired
        self.verifiedAt = verifiedAt
        self.saveAfterRestore = saveAfterRestore
    }
}
