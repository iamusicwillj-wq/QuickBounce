import Combine
import Foundation
import QuickBounceDomain

/// Only the transport and playhead observe this clock. Publishing it through
/// AppModel invalidates every list and waveform row while the user scrolls.
@MainActor
final class ReviewPlaybackClock: ObservableObject {
    struct Sample: Equatable {
        var position: Double = 0
        var isPlaying = false
    }
    @Published private(set) var sample = Sample()

    func update(position: Double, isPlaying: Bool) {
        let next = Sample(position: position, isPlaying: isPlaying)
        if sample != next { sample = next }
    }
}

@MainActor
final class ReviewMeterState: ObservableObject {
    @Published private(set) var reading = ProgramMeterReading()

    func update(_ value: ProgramMeterReading) {
        if reading != value { reading = value }
    }
}
