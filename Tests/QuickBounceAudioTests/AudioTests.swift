import Foundation
@testable import QuickBounceAudio
import QuickBounceDomain
import QuickBounceTestSupport
import Testing

@Test func artifactInspectorReadsValidStereoWAV() async throws {
    let directory = try TestWorkspace.freshDirectory("inspect-wav")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Tone.wav"))
    let artifact = TestWorkspace.artifact(for: url, state: .candidate)
    let inspected = try await ArtifactInspector().inspect(artifact)

    #expect(inspected.state == .completed)
    #expect(inspected.sampleRate == 48_000)
    #expect(inspected.channelCount == 2)
    #expect(inspected.frameCount == 24_000)
    #expect(inspected.durationSeconds == 0.5)
    #expect(inspected.bitDepth == 16)
}

@Test func artifactInspectorEnforcesBounceNameFormatAndMetadata() async throws {
    let directory = try TestWorkspace.freshDirectory("artifact-expectation")
    let wav = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Expected Mix.wav"),
        sampleRate: 48_000,
        channelCount: 1,
        durationSeconds: 1
    )
    let artifact = TestWorkspace.artifact(for: wav, state: .candidate)
    let expectation = ArtifactExpectation(
        kind: .wav,
        baseFileName: "Expected Mix",
        sampleRate: 48_000,
        bitDepth: 16,
        channelCount: 1,
        durationSeconds: 1,
        durationToleranceSeconds: 0.001
    )

    let inspected = try await ArtifactInspector().inspect(artifact, expectation: expectation)

    #expect(inspected.state == .completed)
    #expect(inspected.name == "Expected Mix.wav")

    var wrongName = expectation
    wrongName.baseFileName = "Another Mix"
    await #expect(throws: QuickBounceError.self) {
        try await ArtifactInspector().inspect(artifact, expectation: wrongName)
    }

    var wrongDuration = expectation
    wrongDuration.durationSeconds = 2
    await #expect(throws: QuickBounceError.self) {
        try await ArtifactInspector().inspect(artifact, expectation: wrongDuration)
    }
}

@Test func artifactInspectorRejectsWAVPayloadDisguisedAsMP3() async throws {
    let directory = try TestWorkspace.freshDirectory("artifact-container")
    let wav = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Source.wav"))
    let disguised = directory.appendingPathComponent("Source.mp3")
    try Data(contentsOf: wav).write(to: disguised, options: .atomic)
    let artifact = TestWorkspace.artifact(for: disguised, kind: .mp3, state: .candidate)
    let expectation = ArtifactExpectation(
        kind: .mp3,
        baseFileName: "Source",
        sampleRate: 48_000,
        durationSeconds: 0.5,
        durationToleranceSeconds: 0.15
    )

    await #expect(throws: QuickBounceError.self) {
        try await ArtifactInspector().inspect(artifact, expectation: expectation)
    }
}

@Test func waveformPyramidPreservesEveryChannelAndResolution() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Four Channel.wav"),
        channelCount: 4,
        durationSeconds: 0.2
    )
    let artifact = TestWorkspace.artifact(for: url)
    let pyramid = try await WaveformAnalyzer().analyze(
        artifact: artifact,
        blockSizes: [64, 256, 1_024]
    )

    #expect(pyramid.levels.count == 3)
    #expect(pyramid.levels.allSatisfy { $0.channels.count == 4 })
    #expect(pyramid.levels.map(\.blockSize) == [64, 256, 1_024])
    #expect(pyramid.levels[0].channels.allSatisfy { !$0.isEmpty })
}

@Test func acceleratedWaveformReductionPreservesBlockExtrema() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform-accelerated-extrema")
    let url = try TestWorkspace.makeConstantWAV(
        at: directory.appendingPathComponent("Constant.wav"),
        channelCount: 2,
        durationSeconds: 0.25,
        amplitude: -0.25
    )
    let pyramid = try await WaveformAnalyzer().analyze(
        artifact: TestWorkspace.artifact(for: url),
        blockSizes: [257, 1_028]
    )

    #expect(pyramid.levels.map(\.blockSize) == [257, 1_028])
    for envelope in pyramid.levels {
        for channel in envelope.channels {
            #expect(channel.allSatisfy {
                abs($0.minimum - (-0.25)) < 0.001
                    && abs($0.maximum - (-0.25)) < 0.001
            })
        }
    }
}

@Test func adaptiveWaveformPyramidBoundsCacheWhileImprovingZoomDetail() {
    let short = WaveformAnalyzer.adaptiveBlockSizes(
        frameCount: 144_000,
        channelCount: 2
    )
    let fiveMinutes = WaveformAnalyzer.adaptiveBlockSizes(
        frameCount: 14_400_000,
        channelCount: 2
    )

    #expect(short.first == 2)
    #expect(short.last == 128)
    #expect(fiveMinutes.first == 128)
    #expect(fiveMinutes.last == 8_192)
    let finestTotalBins = Int(ceil(14_400_000.0 / Double(fiveMinutes[0]))) * 2
    #expect(finestTotalBins <= 262_144)
}

@Test func defaultWaveformAnalysisUsesAdaptiveFinestLevel() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform-adaptive-default")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Short Stereo.wav"),
        channelCount: 2,
        durationSeconds: 0.25
    )
    let artifact = TestWorkspace.artifact(for: url)

    let pyramid = try await WaveformAnalyzer().analyze(artifact: artifact)

    #expect(pyramid.levels.first?.blockSize == 1)
    #expect(pyramid.levels.last?.blockSize == 16)
    #expect(pyramid.levels.allSatisfy { $0.channels.count == 2 })
    #expect(pyramid.levels.first?.channels.allSatisfy { $0.count == 12_000 } == true)
}

@Test func longMultichannelWaveformSelectsUsefulFitAndZoomLevels() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform-long")
    let url = try TestWorkspace.makeSparseSilentWAV(
        at: directory.appendingPathComponent("Long Six Channel.wav"),
        channelCount: 6,
        durationSeconds: 30
    )
    let artifact = TestWorkspace.artifact(for: url)
    let pyramid = try await WaveformAnalyzer().analyze(
        artifact: artifact,
        blockSizes: [256, 2_048, 16_384]
    )
    let frameCount = try #require(pyramid.levels.first?.frameCount)
    let fit = try #require(pyramid.bestLevel(forVisibleFrames: frameCount, pixelWidth: 900))
    let zoom = try #require(
        pyramid.bestLevel(forVisibleFrames: frameCount / 32, pixelWidth: 900)
    )

    #expect(pyramid.levels.allSatisfy { $0.channels.count == 6 })
    #expect(fit.blockSize == 256)
    #expect(zoom.blockSize == 256)
}

@Test func waveformCacheNeverCreatesMOVData() async throws {
    let directory = try TestWorkspace.freshDirectory("mov-waveform")
    let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
    let cache = try WaveformCache(directory: cacheDirectory)
    let mov = TestWorkspace.artifact(
        for: directory.appendingPathComponent("Picture.mov"),
        kind: .mov
    )
    let empty = WaveformPyramid(artifactID: mov.id, levels: [])

    try await cache.save(empty, for: mov)
    #expect(try await cache.load(for: mov) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).isEmpty)
    await #expect(throws: QuickBounceError.self) {
        try await WaveformAnalyzer().analyze(artifact: mov)
    }
}

@Test func waveformCacheCanBeClearedWithoutDeletingDeliveredAudio() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform-clear")
    let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
    let cache = try WaveformCache(directory: cacheDirectory)
    let firstURL = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("First.wav"))
    let secondURL = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Second.wav"))
    let first = TestWorkspace.artifact(for: firstURL)
    let second = TestWorkspace.artifact(for: secondURL)
    let firstPyramid = try await WaveformAnalyzer().analyze(artifact: first, blockSizes: [256])
    let secondPyramid = try await WaveformAnalyzer().analyze(artifact: second, blockSizes: [256])
    try await cache.save(firstPyramid, for: first)
    try await cache.save(secondPyramid, for: second)

    try await cache.removeAll()

    #expect(try await cache.load(for: first) == nil)
    #expect(try await cache.load(for: second) == nil)
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
}

@Test func waveformCacheInvalidatesWhenDeliveredFileChanges() async throws {
    let directory = try TestWorkspace.freshDirectory("waveform-fingerprint")
    let cache = try WaveformCache(directory: directory.appendingPathComponent("cache"))
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Mix.wav"), amplitude: 0.1)
    let artifact = TestWorkspace.artifact(for: url)
    let pyramid = try await WaveformAnalyzer().analyze(artifact: artifact, blockSizes: [256])
    try await cache.save(pyramid, for: artifact)
    let cacheFiles = try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("cache"),
        includingPropertiesForKeys: nil
    )
    let cacheFile = try #require(cacheFiles.first)
    #expect(cacheFile.pathExtension == "waveform")
    #expect(try Data(contentsOf: cacheFile).starts(with: Data("bplist00".utf8)))
    #expect(try await cache.load(for: artifact) != nil)

    try await Task.sleep(for: .milliseconds(20))
    try TestWorkspace.makeWAV(at: url, durationSeconds: 0.75, amplitude: 0.5)

    #expect(try await cache.load(for: artifact) == nil)
}

@Test func audioQCMeasuresPeakLoudnessAndAlgorithmMetadata() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-tone")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Tone.wav"),
        durationSeconds: 4,
        amplitude: 0.5
    )
    let artifact = TestWorkspace.artifact(for: url)
    let analyzer = AudioQCAnalyzer()

    let result = try await analyzer.analyze(artifact: artifact)

    #expect(result.analyzerID == AudioQCAnalyzer.analyzerID)
    #expect(result.algorithmVersion == AudioQCAnalyzer.algorithmVersion)
    #expect(abs((result.metrics.samplePeakDBFS ?? 0) - (-6.02)) < 0.15)
    // Reference values were cross-checked against FFmpeg's independent
    // libavfilter ebur128 implementation for this deterministic stereo vector.
    #expect(abs((result.metrics.truePeakDBTP ?? 0) - (-6.02)) < 0.20)
    #expect(abs((result.metrics.integratedLUFS ?? 0) - (-6.5)) < 0.20)
    #expect(result.metrics.maxMomentaryLUFS != nil)
    #expect(result.metrics.maxShortTermLUFS != nil)
    #expect(abs((result.metrics.loudnessRangeLU ?? -1) - 0) < 0.05)
    #expect(result.metrics.isAllSilent == false)
    #expect(result.metrics.suspectedClipping == false)
    #expect(try await analyzer.cachedResultIsCurrent(result, for: artifact))
}

@Test func audioQCSamplePeakUsesMaximumAcrossAllChannels() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-channel-peak")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Asymmetric Stereo.wav"),
        channelCount: 2,
        durationSeconds: 1,
        channelAmplitudes: [0.1, 0.5]
    )

    let result = try await AudioQCAnalyzer().analyze(
        artifact: TestWorkspace.artifact(for: url)
    )

    // Left peaks at -20 dBFS and right peaks at -6.02 dBFS. The product-facing
    // SP value is intentionally the maximum absolute sample across channels.
    #expect(abs((result.metrics.samplePeakDBFS ?? 0) - (-6.02)) < 0.15)
}

@Test func audioQCCalibrationToneMatchesBS1770ReferenceLoudness() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-bs1770")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("1 kHz -23 LUFS.wav"),
        sampleRate: 48_000,
        channelCount: 1,
        durationSeconds: 10,
        frequency: 1_000,
        amplitude: 0.1
    )

    let result = try await AudioQCAnalyzer().analyze(
        artifact: TestWorkspace.artifact(for: url)
    )

    // A mono 1 kHz sine with 0.1 sample peak is the BS.1770 calibration
    // vector: -20 dBFS sample peak and approximately -23.0 LKFS/LUFS.
    #expect(abs((result.metrics.samplePeakDBFS ?? 0) - (-20.0)) < 0.05)
    #expect(abs((result.metrics.integratedLUFS ?? 0) - (-23.0)) < 0.20)
    #expect(abs((result.metrics.maxMomentaryLUFS ?? 0) - (-23.0)) < 0.20)
    #expect(abs((result.metrics.maxShortTermLUFS ?? 0) - (-23.0)) < 0.20)
    #expect(abs((result.metrics.loudnessRangeLU ?? -1) - 0) < 0.05)
}

@Test func audioQCDetectsKnownIntersampleTruePeak() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-true-peak")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("12 kHz Intersample.wav"),
        sampleRate: 48_000,
        channelCount: 1,
        durationSeconds: 4,
        frequency: 12_000,
        amplitude: 0.99,
        phaseOffset: .pi / 4
    )

    let result = try await AudioQCAnalyzer().analyze(
        artifact: TestWorkspace.artifact(for: url)
    )
    let samplePeak = try #require(result.metrics.samplePeakDBFS)
    let truePeak = try #require(result.metrics.truePeakDBTP)

    // Fs/4 at π/4 has samples at ±A/√2 (-3.10 dBFS here), while the
    // reconstructed sinusoid reaches A (-0.09 dBTP). This validates that TP
    // is measured from 4x reconstruction rather than copied from sample peak.
    #expect(abs(samplePeak - (-3.10)) < 0.08)
    #expect(abs(truePeak - (-0.09)) < 0.35)
    #expect(truePeak - samplePeak > 2.5)
}

@Test func audioQCFlagsSilenceAndClipping() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-findings")
    let silentURL = try TestWorkspace.makeConstantWAV(
        at: directory.appendingPathComponent("Silent.wav"),
        amplitude: 0
    )
    let clippedURL = try TestWorkspace.makeConstantWAV(
        at: directory.appendingPathComponent("Clipped.wav"),
        amplitude: 1
    )
    let analyzer = AudioQCAnalyzer()

    let silent = try await analyzer.analyze(artifact: TestWorkspace.artifact(for: silentURL))
    let clipped = try await analyzer.analyze(artifact: TestWorkspace.artifact(for: clippedURL))

    #expect(silent.metrics.isAllSilent == true)
    #expect(silent.findings.contains { $0.code == "all-silent" && $0.severity == .fail })
    #expect(clipped.metrics.suspectedClipping == true)
    #expect((clipped.metrics.clippedSampleCount ?? 0) > 0)
    #expect(clipped.findings.contains { $0.code == "suspected-clipping" })
}

@Test func audioQCReportsLongLeadingAndTrailingSilenceRanges() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-edge-silence")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Silence Edges.wav"),
        channelCount: 1,
        durationSeconds: 7,
        frequency: 1_000,
        amplitude: 0.25,
        audibleRangeSeconds: 2.5..<3.5
    )

    let result = try await AudioQCAnalyzer().analyze(
        artifact: TestWorkspace.artifact(for: url)
    )
    let leading = try #require(result.findings.first { $0.code == "leading-silence" })
    let trailing = try #require(result.findings.first { $0.code == "trailing-silence" })

    #expect(abs((result.metrics.leadingSilenceSeconds ?? 0) - 2.5) < 0.001)
    #expect(abs((result.metrics.trailingSilenceSeconds ?? 0) - 3.5) < 0.001)
    #expect(abs((leading.endSeconds ?? 0) - 2.5) < 0.001)
    #expect(abs((trailing.startSeconds ?? 0) - 3.5) < 0.001)
}

@Test func audioQCCacheFingerprintRejectsChangedFile() async throws {
    let directory = try TestWorkspace.freshDirectory("audio-qc-cache")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Mix.wav"))
    let artifact = TestWorkspace.artifact(for: url)
    let analyzer = AudioQCAnalyzer()
    let result = try await analyzer.analyze(artifact: artifact)
    #expect(try await analyzer.cachedResultIsCurrent(result, for: artifact))

    try await Task.sleep(for: .milliseconds(20))
    try TestWorkspace.makeWAV(at: url, durationSeconds: 0.75, amplitude: 0.4)

    #expect(try await !analyzer.cachedResultIsCurrent(result, for: artifact))
}

@Test func localLAMETranscoderCreatesDecodableCBRMP3() async throws {
    let directory = try TestWorkspace.freshDirectory("mp3")
    let wav = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Source.wav"),
        durationSeconds: 1
    )
    let mp3 = directory.appendingPathComponent("Output.mp3")
    let transcoder = MP3Transcoder()
    try await transcoder.transcode(
        source: wav,
        destination: mp3,
        bitRateKbps: 192,
        quality: .highest
    )
    let inspected = try await ArtifactInspector().inspect(
        TestWorkspace.artifact(for: mp3, kind: .mp3, state: .candidate)
    )
    let fileSize = try mp3.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let analysis = try await AudioQCAnalyzer().analyze(artifact: inspected)

    #expect(inspected.state == .completed)
    #expect(inspected.channelCount == 2)
    #expect(inspected.durationSeconds != nil)
    #expect(inspected.bitDepth == 16)
    #expect(fileSize > 20_000 && fileSize < 30_000)
    #expect(MP3Transcoder.encoderVersion.contains("3.100"))
    #expect(analysis.metrics.samplePeakDBFS != nil)
    #expect(analysis.metrics.integratedLUFS != nil)
    #expect(analysis.fileFingerprint.isEmpty == false)
}

@MainActor
@Test func reviewEngineEnforcesMixCompareAndStemAudibility() throws {
    let directory = try TestWorkspace.freshDirectory("review-engine")
    let firstURL = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("A.wav"))
    let secondURL = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("B.wav"),
        frequency: 880
    )
    let first = TestWorkspace.artifact(for: firstURL)
    let second = TestWorkspace.artifact(for: secondURL)
    let mov = TestWorkspace.artifact(
        for: directory.appendingPathComponent("Picture.mov"),
        kind: .mov
    )
    let engine = AudioReviewEngine()
    defer { engine.shutdown() }

    try engine.load([first, second, mov], mode: .mixCompare)
    #expect(engine.audibleArtifactIDs == [first.id])
    engine.selectMix(second.id)
    #expect(engine.audibleArtifactIDs == [second.id])

    try engine.load([first, second, mov], mode: .stemsCheck)
    #expect(engine.audibleArtifactIDs == Set([first.id, second.id]))
    engine.setStemState(StemPlaybackState(artifactID: first.id, isSolo: true))
    #expect(engine.audibleArtifactIDs == [first.id])
    engine.setStemState(StemPlaybackState(artifactID: first.id, isSolo: true, isMuted: true))
    #expect(engine.audibleArtifactIDs.isEmpty)
}

@MainActor
@Test func reviewEngineRunsRealtimeMeterTapWithoutActorViolation() async throws {
    let directory = try TestWorkspace.freshDirectory("review-realtime-meter")
    let url = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("Meter Tone.wav"),
        durationSeconds: 2,
        amplitude: 0.5
    )
    let engine = AudioReviewEngine()
    defer { engine.shutdown() }

    try engine.load([TestWorkspace.artifact(for: url)], mode: .mixCompare)
    engine.monitorTrimDB = -80
    try engine.play()
    #expect(engine.currentPositionSeconds >= 0)
    var reading = engine.meterReading()
    for _ in 0..<30 where reading.peakLeft == 0 || reading.peakRight == 0 {
        try await Task.sleep(for: .milliseconds(50))
        reading = engine.meterReading()
    }
    #expect(engine.isPlaying)
    #expect(reading.peakLeft > 0)
    #expect(reading.peakRight > 0)
}

@MainActor
@Test func reviewEngineRetainsStateAcrossAudioDeviceReconfiguration() throws {
    let directory = try TestWorkspace.freshDirectory("review-device-change")
    let firstURL = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("A.wav"))
    let secondURL = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("B.wav"), frequency: 880)
    let first = TestWorkspace.artifact(for: firstURL)
    let second = TestWorkspace.artifact(for: secondURL)
    let engine = AudioReviewEngine()
    defer { engine.shutdown() }

    try engine.load([first, second], mode: .mixCompare)
    engine.selectMix(second.id)
    try engine.seek(to: 0.1)
    engine.recoverFromAudioDeviceChange()

    #expect(engine.audibleArtifactIDs == [second.id])
    #expect(abs(engine.currentPositionSeconds - 0.1) < 0.001)
    #expect(!engine.isPlaying)
}

@MainActor
@Test func reviewEngineCanRemoveLoadedArtifactWhileEngineWasRunning() async throws {
    let directory = try TestWorkspace.freshDirectory("review-remove-running")
    let firstURL = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("A.wav"),
        durationSeconds: 0.5
    )
    let secondURL = try TestWorkspace.makeWAV(
        at: directory.appendingPathComponent("B.wav"),
        durationSeconds: 0.5,
        frequency: 880
    )
    let first = TestWorkspace.artifact(for: firstURL)
    let second = TestWorkspace.artifact(for: secondURL)
    let engine = AudioReviewEngine()
    defer { engine.shutdown() }

    try engine.load([first, second], mode: .mixCompare)
    try engine.play()
    try await Task.sleep(for: .milliseconds(80))
    try engine.load([second], mode: .mixCompare)

    #expect(!engine.isPlaying)
    #expect(engine.audibleArtifactIDs == [second.id])
}

@MainActor
@Test func mixCompareUsesActiveSongDurationWhileStemsShareLongestDuration() throws {
    let directory = try TestWorkspace.freshDirectory("review-independent-durations")
    let short = TestWorkspace.artifact(for: try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Short.wav"), durationSeconds: 0.25))
    let long = TestWorkspace.artifact(for: try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Long.wav"), durationSeconds: 1))
    let engine = AudioReviewEngine()
    defer { engine.shutdown() }
    try engine.load([short, long], mode: .mixCompare)
    #expect(engine.durationSeconds == 0.25)
    engine.selectMix(long.id)
    #expect(engine.durationSeconds == 1)
    try engine.seek(to: 0.75)
    engine.selectMix(short.id)
    #expect(engine.currentPositionSeconds == 0)
    #expect(engine.audibleArtifactIDs == [short.id])
    try engine.seek(to: 2)
    #expect(engine.currentPositionSeconds == 0.25)
    try engine.load([short, long], mode: .stemsCheck)
    #expect(engine.durationSeconds == 1)
    engine.selectMix(short.id)
    #expect(engine.durationSeconds == 1)
    #expect(engine.audibleArtifactIDs == [short.id, long.id])
}
