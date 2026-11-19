import QuickBounceDomain
import QuickBounceProTools

/// The reversible Pro Tools state captured immediately before the user checks
/// a Mix. A zero-length Timeline range represents the user's insertion point.
public struct MixCheckSessionState: Equatable, Sendable {
    public var trackStates: [TrackState]
    public var timelineState: TimelineState
    public var timelineSelection: SampleRange { timelineState.selection }

    public init(trackStates: [TrackState], timelineSelection: SampleRange) {
        self.trackStates = trackStates
        self.timelineState = .forBounce(timelineSelection)
    }

    public init(trackStates: [TrackState], timelineState: TimelineState) {
        self.trackStates = trackStates
        self.timelineState = timelineState
    }
}

/// Keeps the Pro Tools mutations used by Add Mix Check consistent and
/// independently testable. UI state remains owned by AppModel.
public enum MixCheckWorkflow {
    public static func capture(
        using proTools: any ProToolsControlling
    ) async throws -> MixCheckSessionState {
        let trackStates = try await proTools.trackStates()
        let timelineState = try await proTools.currentTimelineState()
        return MixCheckSessionState(
            trackStates: trackStates,
            timelineState: timelineState
        )
    }

    public static func apply(
        _ plan: BouncePlan,
        using proTools: any ProToolsControlling
    ) async throws {
        guard plan.range.isValid else {
            throw QuickBounceError.invalidPlan("Mix Check requires a non-empty Timeline Selection")
        }
        try await proTools.apply(trackStates: plan.targetTrackStates)
        try await proTools.setTimelineSelection(plan.range)
    }

    public static func restore(
        _ state: MixCheckSessionState,
        using proTools: any ProToolsControlling
    ) async throws {
        try await proTools.apply(trackStates: state.trackStates)
        try await TimelineRestoration.restore(state.timelineState, using: proTools)
    }
}
