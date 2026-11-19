import Combine
import QuickBounceDomain
@testable import QuickBounceApp
import Testing

@MainActor
@Test func playbackTicksDoNotInvalidateTheWorkspaceOrMeterUnnecessarily() {
    let model = AppModel(initializeServices: false)
    var workspaceUpdates = 0
    var playbackUpdates = 0
    var meterUpdates = 0
    let root = model.objectWillChange.sink { workspaceUpdates += 1 }
    let clock = model.playbackClock.objectWillChange.sink { playbackUpdates += 1 }
    let meter = model.reviewMeter.objectWillChange.sink { meterUpdates += 1 }
    for frame in 1...120 {
        model.playbackClock.update(position: Double(frame) / 20, isPlaying: true)
        model.reviewMeter.update(ProgramMeterReading(peakLeft: Float(frame) / 120, peakRight: 0.2))
    }
    #expect(workspaceUpdates == 0)
    #expect(playbackUpdates == 120 && meterUpdates == 120)
    #expect(model.playbackPosition == 6)
    model.playbackClock.update(position: 6, isPlaying: true)
    #expect(playbackUpdates == 120)
    model.playbackClock.update(position: 1, isPlaying: false)
    #expect(model.playbackPosition == 1 && !model.playbackClock.sample.isPlaying)
    // Structural changes still invalidate the workspace when appropriate.
    model.isPlaying = true
    #expect(workspaceUpdates == 1)
    withExtendedLifetime((root, clock, meter)) {}
}
