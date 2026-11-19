import AVFoundation
import AudioToolbox
import CoreAudio

/// Honor the default device's speaker configuration, not merely its physical
/// socket count (an 18-output interface can still be configured for stereo).
enum MonitorOutputFormat {
    static func current(output: AVAudioOutputNode) -> AVAudioFormat? {
        let hardware = output.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        if let unit = output.audioUnit {
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr {
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelLayout,
                    mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
                size = 0
                if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! {
                    let memory = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioChannelLayout>.size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                    defer { memory.deallocate() }
                    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr {
                        let layout = AVAudioChannelLayout(layout: memory.assumingMemoryBound(to: AudioChannelLayout.self))
                        if layout.channelCount > 0, layout.channelCount <= 2 {
                            return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: layout.channelCount)
                        }
                        if layout.channelCount > 2, layout.channelCount <= hardware.channelCount,
                           AudioChannelLayoutInfo.hasKnownSpeakerPositions(layout, count: Int(layout.channelCount)) {
                            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, interleaved: false, channelLayout: layout)
                        }
                    }
                }
            }
        }
        // No speaker assignment means no trustworthy surround map. Use the
        // device's conventional stereo path instead of guessing speaker order.
        return AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: min(2, hardware.channelCount))
    }
}
