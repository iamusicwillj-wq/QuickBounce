import Foundation

/// Sample positions returned by GetTimelineSelection, including the independent
/// playback marker and roll boundaries. These are not timecode/frame positions.
public struct TimelineState: Codable, Hashable, Sendable {
    public var selection: SampleRange
    public var playStartMarker: Int64
    public var preRollStart: Int64
    public var postRollStop: Int64
    public var preRollEnabled: Bool
    public var postRollEnabled: Bool

    public init(selection: SampleRange, playStartMarker: Int64,
                preRollStart: Int64, postRollStop: Int64,
                preRollEnabled: Bool, postRollEnabled: Bool) {
        self.selection = selection
        self.playStartMarker = playStartMarker
        self.preRollStart = preRollStart
        self.postRollStop = postRollStop
        self.preRollEnabled = preRollEnabled
        self.postRollEnabled = postRollEnabled
    }

    /// Deliberate zero-roll state used while checking/bouncing a saved Mix.
    public static func forBounce(_ range: SampleRange) -> TimelineState {
        TimelineState(selection: range, playStartMarker: range.start,
                      preRollStart: range.start, postRollStop: range.end,
                      preRollEnabled: false, postRollEnabled: false)
    }
}
