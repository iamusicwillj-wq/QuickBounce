import Foundation

public enum BounceJobState: String, Codable, CaseIterable, Sendable {
    case draft
    case validating
    case connecting
    case snapshotting
    case applyingTrackState
    case verifyingTrackState
    case exporting
    case waitingForArtifact
    case transcoding
    case validatingArtifact
    case restoring
    case verifyingRestore
    case savingSession
    case closingSession
    case importing
    case analyzing
    case reviewReady
    case cancelRequested
    case cancelling
    case cancelled
    case failed
    case recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .reviewReady, .cancelled, .failed, .recoveryRequired: true
        default: false
        }
    }

    public var isRestorationState: Bool {
        self == .restoring || self == .verifyingRestore || self == .savingSession || self == .closingSession
    }
}

public enum ArtifactState: String, Codable, CaseIterable, Sendable {
    case candidate
    case completed
    case partial
    case invalid
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case wav
    case mp3
    case mov

    public var hasWaveform: Bool { self != .mov }
}

public struct AudioMetrics: Codable, Hashable, Sendable {
    public var samplePeakDBFS: Double?
    public var truePeakDBTP: Double?
    public var integratedLUFS: Double?
    public var loudnessRangeLU: Double?
    public var maxMomentaryLUFS: Double?
    public var maxShortTermLUFS: Double?
    public var isAllSilent: Bool?
    public var suspectedClipping: Bool?
    public var clippedSampleCount: Int?
    public var leadingSilenceSeconds: Double?
    public var trailingSilenceSeconds: Double?

    public init(
        samplePeakDBFS: Double? = nil,
        truePeakDBTP: Double? = nil,
        integratedLUFS: Double? = nil,
        loudnessRangeLU: Double? = nil,
        maxMomentaryLUFS: Double? = nil,
        maxShortTermLUFS: Double? = nil,
        isAllSilent: Bool? = nil,
        suspectedClipping: Bool? = nil,
        clippedSampleCount: Int? = nil,
        leadingSilenceSeconds: Double? = nil,
        trailingSilenceSeconds: Double? = nil
    ) {
        self.samplePeakDBFS = samplePeakDBFS
        self.truePeakDBTP = truePeakDBTP
        self.integratedLUFS = integratedLUFS
        self.loudnessRangeLU = loudnessRangeLU
        self.maxMomentaryLUFS = maxMomentaryLUFS
        self.maxShortTermLUFS = maxShortTermLUFS
        self.isAllSilent = isAllSilent
        self.suspectedClipping = suspectedClipping
        self.clippedSampleCount = clippedSampleCount
        self.leadingSilenceSeconds = leadingSilenceSeconds
        self.trailingSilenceSeconds = trailingSilenceSeconds
    }
}

public enum QCFindingSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case fail

    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .fail: 2
        }
    }
}

public struct AudioQCFinding: Codable, Hashable, Identifiable, Sendable {
    public var code: String
    public var severity: QCFindingSeverity
    public var title: String
    public var detail: String
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(
        code: String,
        severity: QCFindingSeverity,
        title: String,
        detail: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var id: String { code }
}

public struct AudioAnalysisResult: Codable, Hashable, Sendable {
    public var artifactID: UUID
    public var analyzerID: String
    public var algorithmVersion: String
    public var thresholdVersion: String
    public var fileFingerprint: String
    public var metrics: AudioMetrics
    public var findings: [AudioQCFinding]
    public var analyzedAt: Date

    public init(
        artifactID: UUID,
        analyzerID: String,
        algorithmVersion: String,
        thresholdVersion: String,
        fileFingerprint: String,
        metrics: AudioMetrics,
        findings: [AudioQCFinding],
        analyzedAt: Date = Date()
    ) {
        self.artifactID = artifactID
        self.analyzerID = analyzerID
        self.algorithmVersion = algorithmVersion
        self.thresholdVersion = thresholdVersion
        self.fileFingerprint = fileFingerprint
        self.metrics = metrics
        self.findings = findings
        self.analyzedAt = analyzedAt
    }

    public var highestSeverity: QCFindingSeverity? {
        findings.max { $0.severity.rank < $1.severity.rank }?.severity
    }
}

public enum ReviewDecisionStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case approved
    case needsAttention
}

/// A human Review decision is deliberately separate from automatic QC. An
/// artifact with warnings can still be approved by the operator, while a
/// technically clean artifact can be marked as needing attention after a
/// listening check.
public struct ReviewDecision: Codable, Hashable, Identifiable, Sendable {
    public var artifactID: UUID
    public var status: ReviewDecisionStatus
    public var note: String
    public var reviewedAt: Date?

    public init(
        artifactID: UUID,
        status: ReviewDecisionStatus = .unreviewed,
        note: String = "",
        reviewedAt: Date? = nil
    ) {
        self.artifactID = artifactID
        self.status = status
        self.note = note
        self.reviewedAt = reviewedAt
    }

    public var id: UUID { artifactID }
}

public struct AudioArtifact: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var jobID: UUID
    public var planID: UUID
    public var name: String
    public var path: String
    public var kind: ArtifactKind
    public var state: ArtifactState
    public var sampleRate: Double?
    public var channelCount: Int?
    public var channelNames: [String]?
    public var frameCount: Int64?
    public var durationSeconds: Double?
    public var bitDepth: Int?
    public var metrics: AudioMetrics?
    public var analysis: AudioAnalysisResult?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        planID: UUID,
        name: String,
        path: String,
        kind: ArtifactKind,
        state: ArtifactState,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        frameCount: Int64? = nil,
        durationSeconds: Double? = nil,
        bitDepth: Int? = nil,
        metrics: AudioMetrics? = nil,
        analysis: AudioAnalysisResult? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.planID = planID
        self.name = name
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.kind = kind
        self.state = state
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
        self.bitDepth = bitDepth
        self.metrics = metrics
        self.analysis = analysis
        self.createdAt = createdAt
    }

    public var fileURL: URL { URL(fileURLWithPath: path) }
    public var canReviewAudio: Bool { state == .completed && kind.hasWaveform }
    public var canPreviewVideo: Bool { state == .completed && kind == .mov }
}

public struct BounceJob: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var planIDs: [UUID]
    public var state: BounceJobState
    public var completedPlanCount: Int
    public var totalPlanCount: Int
    public var currentPlanID: UUID?
    public var cancellationRequested: Bool
    public var failureMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        planIDs: [UUID],
        state: BounceJobState = .draft,
        completedPlanCount: Int = 0,
        currentPlanID: UUID? = nil,
        cancellationRequested: Bool = false,
        failureMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.planIDs = planIDs
        self.state = state
        self.completedPlanCount = completedPlanCount
        self.totalPlanCount = planIDs.count
        self.currentPlanID = currentPlanID
        self.cancellationRequested = cancellationRequested
        self.failureMessage = failureMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var progress: Double {
        guard totalPlanCount > 0 else { return 0 }
        return min(1, max(0, Double(completedPlanCount) / Double(totalPlanCount)))
    }
}

public struct JobEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var jobID: UUID
    public var timestamp: Date
    public var state: BounceJobState
    public var message: String
    public var correlationID: String

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        timestamp: Date = Date(),
        state: BounceJobState,
        message: String,
        correlationID: String = UUID().uuidString
    ) {
        self.id = id
        self.jobID = jobID
        self.timestamp = timestamp
        self.state = state
        self.message = message
        self.correlationID = correlationID
    }
}
