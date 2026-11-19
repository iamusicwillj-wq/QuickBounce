import AVFoundation
import AudioToolbox
import Foundation

/// Resolve tags, bitmaps and explicit descriptions without guessing surround
/// positions from the channel count. Unknown/discrete channels retain numbers.
public enum AudioChannelLayoutInfo {
    public static func labels(_ layout: AVAudioChannelLayout?, count: Int) -> [AudioChannelLabel] {
        guard let layout else { return Array(repeating: kAudioChannelLabel_Unknown, count: count) }
        let pointer = layout.layout
        if pointer.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let n = Int(pointer.pointee.mNumberChannelDescriptions)
            guard n == count else { return Array(repeating: kAudioChannelLabel_Unknown, count: count) }
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descriptions = UnsafeRawPointer(pointer).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<n).map { descriptions[$0].mChannelLabel }
        }
        var specifier = pointer.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? pointer.pointee.mChannelBitmap.rawValue : pointer.pointee.mChannelLayoutTag
        let property = pointer.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, 4, &specifier, &size) == noErr else {
            return Array(repeating: kAudioChannelLabel_Unknown, count: count)
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioFormatGetProperty(property, 4, &specifier, &size, storage) == noErr else {
            return Array(repeating: kAudioChannelLabel_Unknown, count: count)
        }
        // AVAudioChannelLayout(layout:) may canonicalize descriptions back to
        // a tag. Read the expanded Core Audio buffer before that happens.
        let expanded = storage.assumingMemoryBound(to: AudioChannelLayout.self)
        guard expanded.pointee.mNumberChannelDescriptions == count else {
            return Array(repeating: kAudioChannelLabel_Unknown, count: count)
        }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descriptions = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }

    static func hasKnownSpeakerPositions(_ layout: AVAudioChannelLayout?, count: Int) -> Bool {
        let supported: Set<AudioChannelLabel> = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            kAudioChannelLabel_CenterSurround, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter,
            kAudioChannelLabel_TopCenterSurround, kAudioChannelLabel_VerticalHeightLeft,
            kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_VerticalHeightRight,
            kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight
        ]
        return count > 0 && labels(layout, count: count).allSatisfy { supported.contains($0) }
    }

    static func preservingFormat(_ input: AVAudioFormat, sampleRate: Double) -> AVAudioFormat? {
        guard let layout = input.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | input.channelCount) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    public static func names(_ layout: AVAudioChannelLayout?, count: Int) -> [String] {
        labels(layout, count: count).enumerated().map { index, label in
            switch label {
            case kAudioChannelLabel_Left: "L"
            case kAudioChannelLabel_Right: "R"
            case kAudioChannelLabel_Center: count == 1 ? "M" : "C"
            case kAudioChannelLabel_LFEScreen: "LFE"
            case kAudioChannelLabel_LFE2: "LFE2"
            case kAudioChannelLabel_LeftSurround: "Ls"
            case kAudioChannelLabel_RightSurround: "Rs"
            case kAudioChannelLabel_LeftSurroundDirect: "Lsd"
            case kAudioChannelLabel_RightSurroundDirect: "Rsd"
            case kAudioChannelLabel_RearSurroundLeft: "Lrs"
            case kAudioChannelLabel_RearSurroundRight: "Rrs"
            case kAudioChannelLabel_CenterSurround: "Cs"
            case kAudioChannelLabel_LeftCenter: "Lc"
            case kAudioChannelLabel_RightCenter: "Rc"
            case kAudioChannelLabel_TopCenterSurround: "Tc"
            case kAudioChannelLabel_VerticalHeightLeft: "Ltf"
            case kAudioChannelLabel_VerticalHeightCenter: "Ctf"
            case kAudioChannelLabel_VerticalHeightRight: "Rtf"
            case kAudioChannelLabel_TopBackLeft: "Ltr"
            case kAudioChannelLabel_TopBackCenter: "Ctr"
            case kAudioChannelLabel_TopBackRight: "Rtr"
            default: count == 1 ? "M" : count == 2 ? (index == 0 ? "L" : "R") : "CH \(index + 1)"
            }
        }
    }

    static func loudnessWeights(_ layout: AVAudioChannelLayout?, count: Int) -> [Double] {
        labels(layout, count: count).map { label in
            switch label {
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: 0
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                 kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                 kAudioChannelLabel_CenterSurround: 1.41
            default: 1
            }
        }
    }
}
