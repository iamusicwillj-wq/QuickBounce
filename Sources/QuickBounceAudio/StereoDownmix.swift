import AVFoundation
import AudioToolbox
import QuickBounceDomain

/// Lo/Ro preview: L/R unity, center and surrounds -3 dB, LFE omitted.
/// Height speakers fold into their corresponding left/right or center plane.
/// No normalization or changes to the source file/analysis are performed.
enum StereoDownmix {
    static func coefficients(labels: [AudioChannelLabel]) -> [Float] {
        let side: Float = sqrt(0.5)
        return labels.flatMap { label -> [Float] in
            switch label {
            case kAudioChannelLabel_Left: [1, 0]
            case kAudioChannelLabel_Right: [0, 1]
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: [0, 0]
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftCenter,
                 kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_TopBackLeft:
                [side, 0]
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
                 kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightCenter,
                 kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackRight:
                [0, side]
            default: [side, side]
            }
        }
    }

    static func apply(to mixer: AVAudioMixerNode, bus: AVAudioNodeBus, input: AVAudioFormat) throws {
        let matrix = coefficients(labels: AudioChannelLayoutInfo.labels(input.channelLayout, count: Int(input.channelCount)))
        try apply(matrix: matrix, to: mixer, bus: bus)
    }

    static func apply(matrix: [Float], to mixer: AVAudioMixerNode, bus: AVAudioNodeBus) throws {
        guard let bridge = mixer.auAudioUnit as? AUAudioUnitV2Bridge else {
            throw QuickBounceError.artifactInvalid("Monitor channel routing is unavailable")
        }
        let result = matrix.withUnsafeBytes {
            AudioUnitSetProperty(bridge.audioUnit, kAudioUnitProperty_MatrixLevels, kAudioUnitScope_Input,
                UInt32(bus), $0.baseAddress, UInt32($0.count))
        }
        guard result == noErr else {
            throw QuickBounceError.artifactInvalid("Monitor channel routing failed: \(result)")
        }
    }
}
