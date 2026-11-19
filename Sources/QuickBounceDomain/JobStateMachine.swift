import Foundation

public struct BounceJobStateMachine: Sendable {
    public private(set) var state: BounceJobState

    public init(state: BounceJobState = .draft) {
        self.state = state
    }

    public mutating func transition(to next: BounceJobState) throws {
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw QuickBounceError.persistence("Illegal job transition: \(state.rawValue) → \(next.rawValue)")
        }
        state = next
    }

    public static let allowedTransitions: [BounceJobState: Set<BounceJobState>] = [
        .draft: [.validating],
        .validating: [.connecting, .failed, .cancelRequested],
        .connecting: [.snapshotting, .failed, .cancelRequested],
        .snapshotting: [.applyingTrackState, .failed, .cancelRequested, .recoveryRequired],
        .applyingTrackState: [.verifyingTrackState, .restoring, .cancelRequested, .failed],
        .verifyingTrackState: [.exporting, .restoring, .cancelRequested, .failed],
        .exporting: [.waitingForArtifact, .cancelRequested, .restoring, .failed],
        .waitingForArtifact: [.transcoding, .validatingArtifact, .cancelRequested, .restoring, .failed],
        .transcoding: [.validatingArtifact, .cancelRequested, .restoring, .failed],
        .validatingArtifact: [.applyingTrackState, .restoring, .cancelRequested, .failed],
        .restoring: [.verifyingRestore, .recoveryRequired],
        .verifyingRestore: [.savingSession, .importing, .analyzing, .snapshotting, .cancelled, .failed, .recoveryRequired],
        .savingSession: [.closingSession, .snapshotting, .analyzing, .cancelled, .failed, .recoveryRequired],
        .closingSession: [.snapshotting, .analyzing, .cancelled, .failed, .recoveryRequired],
        .importing: [.analyzing, .failed, .recoveryRequired],
        .analyzing: [.reviewReady, .failed],
        .cancelRequested: [.cancelling, .restoring],
        .cancelling: [.restoring, .recoveryRequired],
        .failed: [.restoring, .recoveryRequired],
        .reviewReady: [],
        .cancelled: [],
        .recoveryRequired: []
    ]
}
