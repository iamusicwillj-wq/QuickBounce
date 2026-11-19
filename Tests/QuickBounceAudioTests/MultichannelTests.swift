import AVFoundation
import Foundation
@testable import QuickBounceAudio
import QuickBounceDomain
import QuickBounceTestSupport
import Testing

@Test(arguments: [6, 8, 12, 16])
func multichannelInspectionWaveformAndQC(channels: Int) async throws {
    let directory = try TestWorkspace.freshDirectory("multichannel-\(channels)")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Surround.wav"), channelCount: channels, durationSeconds: 1)
    let artifact = try await ArtifactInspector().inspect(TestWorkspace.artifact(for: url))
    #expect(artifact.channelCount == channels)
    let waveform = try await WaveformAnalyzer().analyze(artifact: artifact)
    #expect(waveform.levels.allSatisfy { $0.channels.count == channels })
    let qc = try await AudioQCAnalyzer().analyze(artifact: artifact)
    #expect(qc.metrics.truePeakDBTP != nil)
}

private func addChannelMask(to url: URL, mask: UInt32) throws {
    let original = try Data(contentsOf: url)
    func le<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
    var data = Data("RIFF".utf8)
    data.append(le(UInt32(original.count - 8 + 24)))
    data.append(Data("WAVEfmt ".utf8))
    data.append(le(UInt32(40)))
    data.append(le(UInt16(0xfffe)))
    data.append(original[22..<36])
    data.append(le(UInt16(22)))
    data.append(le(UInt16(16)))
    data.append(le(mask))
    data.append(contentsOf: [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
    data.append(original[36...])
    try data.write(to: url)
}

private func peaks(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
    let data = try #require(buffer.floatChannelData)
    return (0..<Int(buffer.format.channelCount)).map { ch in
        (0..<Int(buffer.frameLength)).map { abs(data[ch][$0]) }.max() ?? 0
    }
}

@MainActor
@Test func multichannelPlaybackDownmixAndNativeGraph() async throws {
    let directory = try TestWorkspace.freshDirectory("surround-playback")
    for count in [6, 8, 12, 16] {
        for activeChannel in 0..<count {
            var amplitudes = Array(repeating: 0.0, count: count)
            amplitudes[activeChannel] = 0.25
            let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("\(count)-\(activeChannel).wav"), channelCount: count, durationSeconds: 0.2, channelAmplitudes: amplitudes)
            try addChannelMask(to: url, mask: [6: UInt32(0x3f), 8: 0x63f, 12: 0x2d63f, 16: 0xffff][count]!)
            let file = try AVAudioFile(forReading: url)
            for stereo in [true, false] {
                let format = stereo ? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)! : file.processingFormat
                let engine = AudioReviewEngine(outputFormat: format)
                defer { engine.shutdown() }
                try engine.load([TestWorkspace.artifact(for: url)], mode: .mixCompare)
                let result = try peaks(engine.renderOffline(frameCount: 4096))
                if stereo {
                    // QuickBounce's explicit Lo/Ro matrix omits the LFE feed.
                    if activeChannel != 3 { #expect(result.max()! > 0.01, "count=\(count) channel=\(activeChannel)") }
                    if activeChannel == 3 { #expect(result.allSatisfy { $0 < 0.00001 }) }
                    if activeChannel == 2 { #expect(abs(result[0] - 0.25 * sqrt(0.5)) < 0.001) }
                    if activeChannel == 2 { #expect(abs(result[0] - result[1]) < 0.0001) }
                } else {
                    for ch in 0..<count {
                        #expect(abs(result[ch] - (ch == activeChannel ? 0.25 : 0)) < 0.001)
                    }
                }
                #expect(engine.isDownmixing == stereo)
                // Let concurrent realtime tests sample their meters before short fixtures end.
                await Task.yield()
            }
        }
    }
}

@Test func multichannelLayoutsWeightsAndLFEPeak() async throws {
    let directory = try TestWorkspace.freshDirectory("surround-layouts")
    for (count, mask) in [(6, UInt32(0x3f)), (8, UInt32(0x63f)), (12, UInt32(0x2d63f)), (16, UInt32(0xffff))] {
        var amplitudes = Array(repeating: 0.0, count: count)
        amplitudes[3] = 0.5
        let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("LFE-\(count).wav"), channelCount: count, durationSeconds: 1, channelAmplitudes: amplitudes)
        try addChannelMask(to: url, mask: mask)
        let file = try AVAudioFile(forReading: url)
        let weights = AudioChannelLayoutInfo.loudnessWeights(file.fileFormat.channelLayout, count: count)
        #expect(weights[3] == 0)
        #expect(weights[4] == 1.41)
        let artifact = try await ArtifactInspector().inspect(TestWorkspace.artifact(for: url))
        #expect(artifact.channelNames?[3] == "LFE")
        let qc = try await AudioQCAnalyzer().analyze(artifact: artifact)
        #expect(qc.metrics.integratedLUFS == nil)
        #expect(abs((qc.metrics.truePeakDBTP ?? 0) + 6.02) < 0.2)
        #expect(qc.metrics.isAllSilent == false)
        #expect(!qc.findings.contains { $0.code == "unknown-channel-layout" })
        let waveform = try await WaveformAnalyzer().analyze(artifact: artifact)
        for ch in 0..<count {
            let maximum = waveform.levels[0].channels[ch].map(\.maximum).max()!
            #expect(abs(maximum - (ch == 3 ? 0.5 : 0)) < 0.001)
        }
    }
}

@Test func multichannelSurroundLoudnessUsesLayoutWeight() async throws {
    let directory = try TestWorkspace.freshDirectory("surround-weight")
    var results: [Double] = []
    for channel in [0, 4] {
        var amplitudes = Array(repeating: 0.0, count: 6)
        amplitudes[channel] = 0.25
        let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Channel-\(channel).wav"), channelCount: 6, durationSeconds: 1, frequency: 1000 / Double(channel + 1), channelAmplitudes: amplitudes)
        try addChannelMask(to: url, mask: 0x3f)
        let qc = try await AudioQCAnalyzer().analyze(artifact: TestWorkspace.artifact(for: url))
        results.append(try #require(qc.metrics.integratedLUFS))
    }
    #expect(abs(results[1] - results[0] - 10 * log10(1.41)) < 0.03)
}

@MainActor
@Test func multichannelUnknownLayoutNeverSilentlyDropsChannels() async throws {
    let directory = try TestWorkspace.freshDirectory("surround-unknown")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Discrete.wav"), channelCount: 6, durationSeconds: 1)
    let artifact = TestWorkspace.artifact(for: url)
    let engine = AudioReviewEngine(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
    defer { engine.shutdown() }
    try engine.load([artifact], mode: .mixCompare)
    #expect(engine.audibleArtifactIDs.isEmpty)
    #expect(!engine.warnings.isEmpty)
    let qc = try await AudioQCAnalyzer().analyze(artifact: artifact)
    #expect(qc.metrics.integratedLUFS == nil)
    #expect(qc.metrics.truePeakDBTP != nil)
    #expect(qc.findings.contains { $0.code == "unknown-channel-layout" })
}

@MainActor
@Test func multichannelCompareAndStemsKeepEveryChannel() throws {
    let directory = try TestWorkspace.freshDirectory("surround-modes")
    var artifacts: [AudioArtifact] = []
    for active in [2, 4] {
        var amplitudes = Array(repeating: 0.0, count: 6)
        amplitudes[active] = 0.25
        let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Part-\(active).wav"), channelCount: 6, durationSeconds: 1, channelAmplitudes: amplitudes)
        try addChannelMask(to: url, mask: 0x3f)
        artifacts.append(TestWorkspace.artifact(for: url))
    }
    let file = try AVAudioFile(forReading: artifacts[0].fileURL)
    for mode in [ReviewMode.mixCompare, .stemsCheck] {
        let engine = AudioReviewEngine(outputFormat: file.processingFormat)
        defer { engine.shutdown() }
        try engine.load(artifacts, mode: mode)
        if mode == .mixCompare { engine.selectMix(artifacts[1].id) }
        let result = try peaks(engine.renderOffline(frameCount: 4096))
        #expect(abs(result[4] - 0.25) < 0.001)
        #expect(abs(result[2] - (mode == .stemsCheck ? 0.25 : 0)) < 0.001)
        #expect(result[0] == 0 && result[1] == 0 && result[3] == 0 && result[5] == 0)
    }
}

@Test(arguments: [96000, 192000])
func multichannelHighSampleRateQC(rate: Int) async throws {
    let directory = try TestWorkspace.freshDirectory("surround-rate-\(rate)")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Eight.wav"), sampleRate: rate, channelCount: 8, durationSeconds: 0.5)
    try addChannelMask(to: url, mask: 0x63f)
    let qc = try await AudioQCAnalyzer().analyze(artifact: TestWorkspace.artifact(for: url))
    #expect(qc.metrics.truePeakDBTP != nil)
    #expect(qc.metrics.integratedLUFS != nil)
}

@MainActor
@Test func multichannelNativeOutputMapsSpeakerOrder() async throws {
    let directory = try TestWorkspace.freshDirectory("surround-order")
    // WAV order L R C LFE Ls Rs -> MPEG 5.1 B order L R Ls Rs C LFE.
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B))
    let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout))
    for (source, destination) in [0, 1, 4, 5, 2, 3].enumerated() {
        var amplitudes = Array(repeating: 0.0, count: 6)
        amplitudes[source] = 0.25
        let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Channel-\(source).wav"), channelCount: 6, durationSeconds: 0.2, channelAmplitudes: amplitudes)
        try addChannelMask(to: url, mask: 0x3f)
        let engine = AudioReviewEngine(outputFormat: output)
        defer { engine.shutdown() }
        try engine.load([TestWorkspace.artifact(for: url)], mode: .mixCompare)
        let result = try peaks(engine.renderOffline(frameCount: 4096))
        for channel in 0..<6 {
            #expect(abs(result[channel] - (channel == destination ? 0.25 : 0)) < 0.001, "source=\(source), destination=\(destination), result=\(result)")
        }
        await Task.yield()
    }
}

@MainActor
@Test func multichannelAndStereoStemsShareDownmixBus() throws {
    let directory = try TestWorkspace.freshDirectory("surround-stereo-stems")
    let stereo = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Stereo.wav"), channelCount: 2, durationSeconds: 0.2, channelAmplitudes: [0.1, 0])
    let surround = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Surround.wav"), channelCount: 6, durationSeconds: 0.2, channelAmplitudes: [0, 0, 0, 0, 0, 0.25])
    try addChannelMask(to: surround, mask: 0x3f)
    let engine = AudioReviewEngine(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
    defer { engine.shutdown() }
    try engine.load([TestWorkspace.artifact(for: stereo), TestWorkspace.artifact(for: surround)], mode: .stemsCheck)
    let result = try peaks(engine.renderOffline(frameCount: 4096))
    #expect(abs(result[0] - 0.1) < 0.001)
    #expect(abs(result[1] - 0.25 * sqrt(0.5)) < 0.001)
}

@MainActor
@Test func multichannelInsufficientSpeakerLayoutFallsBackToStereo() throws {
    let directory = try TestWorkspace.freshDirectory("surround-fallback")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Seven-One.wav"), channelCount: 8, durationSeconds: 0.2, channelAmplitudes: [0, 0, 0, 0, 0, 0, 0.25, 0])
    try addChannelMask(to: url, mask: 0x63f)
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B))
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout))
    let engine = AudioReviewEngine(outputFormat: format)
    defer { engine.shutdown() }
    try engine.load([TestWorkspace.artifact(for: url)], mode: .mixCompare)
    #expect(engine.isDownmixing)
    #expect(engine.monitorChannelCount == 2)
    let result = try peaks(engine.renderOffline(frameCount: 4096))
    #expect(result.count == 2)
    #expect(abs(result[0] - 0.25 * sqrt(0.5)) < 0.001)
    #expect(result[1] < 0.00001)
}
