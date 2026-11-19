import AVFoundation
import AudioToolbox

/// Explicit speaker mapping avoids Core Audio dropping rear/side surrounds
/// when two valid 5.1 layouts name their surround pair differently.
enum MonitorChannelRouting {
    static func coefficients(input: AVAudioFormat, output: AVAudioFormat) -> [Float]? {
        let inputs = speakerLabels(input)
        let outputs = speakerLabels(output)
        var destinations = inputs.map { outputs.firstIndex(of: $0) }
        var occupied = Set(destinations.compactMap { $0 })
        for index in inputs.indices where destinations[index] == nil {
            let equivalents: Set<AudioChannelLabel>
            switch inputs[index] {
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft:
                equivalents = [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft]
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight:
                equivalents = [kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight]
            default: equivalents = []
            }
            guard let destination = outputs.indices.first(where: { !occupied.contains($0) && equivalents.contains(outputs[$0]) }) else { return nil }
            destinations[index] = destination
            occupied.insert(destination)
        }
        var matrix = Array(repeating: Float(0), count: inputs.count * outputs.count)
        for index in inputs.indices {
            guard let destination = destinations[index] else { return nil }
            matrix[index * outputs.count + destination] = 1
        }
        return matrix
    }

    private static func speakerLabels(_ format: AVAudioFormat) -> [AudioChannelLabel] {
        if format.channelCount == 1 { return [kAudioChannelLabel_Center] }
        if format.channelCount == 2 { return [kAudioChannelLabel_Left, kAudioChannelLabel_Right] }
        return AudioChannelLayoutInfo.labels(format.channelLayout, count: Int(format.channelCount))
    }
}
