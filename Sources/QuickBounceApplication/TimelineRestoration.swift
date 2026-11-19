import QuickBounceDomain
import QuickBounceProTools

enum TimelineRestoration {
    static func restore(_ state: TimelineState?, legacySelection: SampleRange? = nil,
                        using proTools: any ProToolsControlling) async throws {
        if let state {
            try await proTools.setTimelineState(state)
            guard try await proTools.currentTimelineState() == state else {
                throw QuickBounceError.restoreFailed(
                    "Timeline Selection, playback marker or pre/post roll did not match the saved snapshot")
            }
        } else if let legacySelection {
            // Old journals did not capture the other fields. Do not invent
            // historical values or claim that those settings were restored.
            try await proTools.setTimelineSelection(legacySelection)
            guard try await proTools.currentTimelineSelection() == legacySelection else {
                throw QuickBounceError.restoreFailed("Timeline Selection did not match the saved snapshot")
            }
        }
    }
}
