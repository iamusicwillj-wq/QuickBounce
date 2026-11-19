@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import Foundation
import QuickBounceDomain

public actor AudioQCAnalyzer {
    public static let analyzerID = "com.quickbounce.audio-qc"
    public static let algorithmVersion = "1.2.0-bs1770-multichannel-4x"
    public static let thresholdVersion = "v1"

    public init() {}

    public func analyze(artifact: AudioArtifact) async throws -> AudioAnalysisResult {
        guard artifact.canReviewAudio else {
            throw QuickBounceError.artifactInvalid("Only completed WAV and MP3 files enter audio QC")
        }
        let fingerprint = try Self.fileFingerprint(for: artifact.fileURL)
        let artifactID = artifact.id
        let url = artifact.fileURL
        let worker = Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url)
            let inputFormat = file.processingFormat
            let channelCount = Int(inputFormat.channelCount)
            let sampleRate = inputFormat.sampleRate
            guard channelCount > 0, sampleRate > 0, file.length > 0 else {
                throw QuickBounceError.artifactInvalid("Audio QC requires a non-empty decodable file")
            }

            let reader = try PCMChunkReader(file: file)
            let truePeakMeter = try StreamingTruePeakMeter(
                inputFormat: inputFormat,
                maximumInputFrames: reader.capacity
            )
            var channelFilters = (0..<channelCount).map { index in
                KWeightingFilter(sampleRate: sampleRate, channelIndex: index)
            }
            let channelWeights = Self.channelWeights(
                count: channelCount,
                channelLayout: file.fileFormat.channelLayout
            )
            let blockFrames = max(1, Int((0.1 * sampleRate).rounded()))
            var pendingEnergy = Array(repeating: 0.0, count: channelCount)
            var pendingFrames = 0
            var blockEnergies: [Double] = []
            blockEnergies.reserveCapacity(max(1, Int(file.length) / blockFrames))

            var samplePeak: Double = 0
            var clippedSampleCount = 0
            let silenceAmplitude = Self.amplitude(fromDB: -70)
            var firstAudibleFrame: Int64?
            var lastAudibleFrame: Int64?
            var absoluteFrame: Int64 = 0

            while let buffer = try reader.read() {
                try Task.checkCancellation()
                try truePeakMeter.process(buffer)
                guard let channels = buffer.floatChannelData else {
                    throw QuickBounceError.artifactInvalid("Audio QC decoding did not produce Float32 PCM")
                }
                for frame in 0..<Int(buffer.frameLength) {
                    var audible = false
                    for channel in 0..<channelCount {
                        let sample = Double(channels[channel][frame])
                        let magnitude = abs(sample)
                        samplePeak = max(samplePeak, magnitude)
                        // Integer PCM positive full scale decodes just below
                        // 1.0 (for example Int16.max is 0.999969), so use a
                        // tight tolerance instead of requiring an impossible
                        // floating-point value of exactly 1.0.
                        if magnitude >= 0.9999 { clippedSampleCount += 1 }
                        if magnitude > silenceAmplitude { audible = true }
                        let weighted = channelFilters[channel].process(sample)
                        pendingEnergy[channel] += weighted * weighted
                    }
                    if audible {
                        if firstAudibleFrame == nil { firstAudibleFrame = absoluteFrame }
                        lastAudibleFrame = absoluteFrame
                    }
                    pendingFrames += 1
                    absoluteFrame += 1
                    if pendingFrames == blockFrames {
                        blockEnergies.append(Self.weightedMeanSquare(
                            sums: pendingEnergy,
                            frameCount: pendingFrames,
                            channelWeights: channelWeights
                        ))
                        for channel in pendingEnergy.indices { pendingEnergy[channel] = 0 }
                        pendingFrames = 0
                    }
                }
            }
            if pendingFrames > 0 {
                blockEnergies.append(Self.weightedMeanSquare(
                    sums: pendingEnergy,
                    frameCount: pendingFrames,
                    channelWeights: channelWeights
                ))
            }

            let loudness = Self.loudnessMetrics(blockEnergies: blockEnergies)
            let truePeak = try truePeakMeter.finish()
            let duration = Double(file.length) / sampleRate
            let leadingSilence = Double(firstAudibleFrame ?? file.length) / sampleRate
            let trailingSilence: Double
            if let lastAudibleFrame {
                trailingSilence = max(0, duration - Double(lastAudibleFrame + 1) / sampleRate)
            } else {
                trailingSilence = duration
            }
            let isSilent = firstAudibleFrame == nil
            let suspectedClipping = clippedSampleCount > 0 || truePeak >= 1
            let knownLayout = channelCount <= 2 || AudioChannelLayoutInfo.hasKnownSpeakerPositions(file.fileFormat.channelLayout, count: channelCount)
            let metrics = AudioMetrics(
                samplePeakDBFS: Self.decibels(samplePeak),
                truePeakDBTP: Self.decibels(truePeak),
                integratedLUFS: knownLayout ? loudness.integrated : nil,
                loudnessRangeLU: knownLayout ? loudness.range : nil,
                maxMomentaryLUFS: knownLayout ? loudness.maxMomentary : nil,
                maxShortTermLUFS: knownLayout ? loudness.maxShortTerm : nil,
                isAllSilent: isSilent,
                suspectedClipping: suspectedClipping,
                clippedSampleCount: clippedSampleCount,
                leadingSilenceSeconds: leadingSilence,
                trailingSilenceSeconds: trailingSilence
            )
            var findings = Self.findings(metrics: metrics, duration: duration)
            if !knownLayout {
                findings.append(AudioQCFinding(code: "unknown-channel-layout", severity: .warning,
                    title: "Unknown channel layout", detail: "Channel positions are missing. Loudness is unavailable; waveform and peaks include every channel."))
            }
            return AudioAnalysisResult(
                artifactID: artifactID,
                analyzerID: Self.analyzerID,
                algorithmVersion: Self.algorithmVersion,
                thresholdVersion: Self.thresholdVersion,
                fileFingerprint: fingerprint,
                metrics: metrics,
                findings: findings
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func cachedResultIsCurrent(_ result: AudioAnalysisResult, for artifact: AudioArtifact) throws -> Bool {
        let fingerprint = try Self.fileFingerprint(for: artifact.fileURL)
        return result.artifactID == artifact.id
            && result.analyzerID == Self.analyzerID
            && result.algorithmVersion == Self.algorithmVersion
            && result.thresholdVersion == Self.thresholdVersion
            && result.fileFingerprint == fingerprint
    }

    public nonisolated static func fileFingerprint(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isRegularFileKey
        ])
        guard values.isRegularFile != false, let size = values.fileSize else {
            throw QuickBounceError.artifactMissing(url.path)
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let resource = values.fileResourceIdentifier.map { String(describing: $0) } ?? "no-id"
        return "\(resource)|\(size)|\(modified.bitPattern)"
    }

    private nonisolated static func loudnessMetrics(blockEnergies: [Double]) -> (
        integrated: Double?, range: Double?, maxMomentary: Double?, maxShortTerm: Double?
    ) {
        guard !blockEnergies.isEmpty else { return (nil, nil, nil, nil) }
        let momentary = windowEnergies(blockEnergies, blockCount: 4)
        let shortTerm = windowEnergies(blockEnergies, blockCount: 30)
        let absoluteGate = energy(fromLUFS: -70)
        let absoluteGated = momentary.filter { $0 > absoluteGate }
        guard !absoluteGated.isEmpty else { return (nil, nil, nil, nil) }
        let ungatedMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeGate = energy(fromLUFS: loudness(ungatedMean) - 10)
        let relativeGated = absoluteGated.filter { $0 > relativeGate }
        let integrated = relativeGated.isEmpty
            ? nil
            : loudness(relativeGated.reduce(0, +) / Double(relativeGated.count))
        let momentaryLUFS = momentary.map(loudness).filter(\.isFinite)
        let shortTermLUFS = shortTerm.map(loudness).filter(\.isFinite)
        let lraValues = shortTermLUFS.filter { $0 > -70 }
        let lra: Double?
        if lraValues.count >= 2 {
            let relativeThreshold = (integrated ?? -70) - 20
            let gated = lraValues.filter { $0 > relativeThreshold }.sorted()
            lra = gated.count >= 2 ? percentile(gated, 0.95) - percentile(gated, 0.10) : 0
        } else {
            lra = lraValues.isEmpty ? nil : 0
        }
        return (integrated, lra, momentaryLUFS.max(), shortTermLUFS.max())
    }

    private nonisolated static func findings(metrics: AudioMetrics, duration: Double) -> [AudioQCFinding] {
        var findings: [AudioQCFinding] = []
        if metrics.isAllSilent == true {
            findings.append(AudioQCFinding(
                code: "all-silent",
                severity: .fail,
                title: "Entire file is silent",
                detail: "No sample exceeded -70 dBFS."
            ))
        }
        if metrics.suspectedClipping == true {
            findings.append(AudioQCFinding(
                code: "suspected-clipping",
                severity: .warning,
                title: "Suspected clipping",
                detail: "\(metrics.clippedSampleCount ?? 0) samples reached full scale or the 4x true peak reached 0 dBTP."
            ))
        }
        if let seconds = metrics.leadingSilenceSeconds, seconds >= 2, seconds < duration {
            findings.append(AudioQCFinding(
                code: "leading-silence",
                severity: .info,
                title: "Long leading silence",
                detail: String(format: "%.2f seconds before the first audible sample.", seconds),
                startSeconds: 0,
                endSeconds: seconds
            ))
        }
        if let seconds = metrics.trailingSilenceSeconds, seconds >= 2, seconds < duration {
            findings.append(AudioQCFinding(
                code: "trailing-silence",
                severity: .info,
                title: "Long trailing silence",
                detail: String(format: "%.2f seconds after the last audible sample.", seconds),
                startSeconds: max(0, duration - seconds),
                endSeconds: duration
            ))
        }
        return findings
    }

    private nonisolated static func channelWeights(
        count: Int,
        channelLayout: AVAudioChannelLayout?
    ) -> [Double] {
        AudioChannelLayoutInfo.loudnessWeights(channelLayout, count: count)
    }

    private nonisolated static func weightedMeanSquare(
        sums: [Double],
        frameCount: Int,
        channelWeights: [Double]
    ) -> Double {
        guard frameCount > 0 else { return 0 }
        return zip(sums, channelWeights).reduce(0) { result, pair in
            result + pair.0 / Double(frameCount) * pair.1
        }
    }

    private nonisolated static func windowEnergies(_ blocks: [Double], blockCount: Int) -> [Double] {
        guard !blocks.isEmpty else { return [] }
        let count = min(blockCount, blocks.count)
        var sum = blocks.prefix(count).reduce(0, +)
        var result = [sum / Double(count)]
        guard blocks.count > count else { return result }
        for index in count..<blocks.count {
            sum += blocks[index] - blocks[index - count]
            result.append(sum / Double(count))
        }
        return result
    }

    private nonisolated static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        if sorted.count == 1 { return first }
        let position = max(0, min(1, fraction)) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = min(sorted.count - 1, lower + 1)
        if lower == upper { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private nonisolated static func loudness(_ energy: Double) -> Double {
        energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity
    }

    private nonisolated static func energy(fromLUFS loudness: Double) -> Double {
        pow(10, (loudness + 0.691) / 10)
    }

    private nonisolated static func decibels(_ amplitude: Double) -> Double? {
        amplitude > 0 ? 20 * log10(amplitude) : nil
    }

    private nonisolated static func amplitude(fromDB decibels: Double) -> Double {
        pow(10, decibels / 20)
    }
}

private final class PCMChunkReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let capacity: AVAudioFrameCount

    init(file: AVAudioFile, capacity: AVAudioFrameCount = 65_536) throws {
        self.file = file
        self.capacity = capacity
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw QuickBounceError.artifactInvalid("Unable to allocate audio QC read buffer")
        }
        self.buffer = buffer
    }

    func read() throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        buffer.frameLength = 0
        let remaining = file.length - file.framePosition
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
        guard buffer.frameLength > 0, buffer.floatChannelData != nil else { return nil }
        return buffer
    }
}

/// Feeds the same decoded buffers used by the EBU R128 pass into the existing
/// mastering-quality 4x converter. This keeps the established true-peak
/// result while removing the former second decode/read of the entire file.
private final class StreamingTruePeakMeter {
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var peak: Float = 0
    private var isFinished = false

    init(inputFormat: AVAudioFormat, maximumInputFrames: AVAudioFrameCount) throws {
        guard let outputFormat = AudioChannelLayoutInfo.preservingFormat(inputFormat, sampleRate: inputFormat.sampleRate * 4), let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
           let output = AVAudioPCMBuffer(
               pcmFormat: outputFormat,
               frameCapacity: maximumInputFrames * 4 + 256
           ) else {
            throw QuickBounceError.artifactInvalid("Unable to create the 4x true-peak oversampler")
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        self.converter = converter
        self.output = output
    }

    func process(_ input: AVAudioPCMBuffer) throws {
        guard !isFinished else {
            throw QuickBounceError.artifactInvalid("True-peak input arrived after end of stream")
        }
        var suppliedInput = false
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var converterError: NSError?
            let status = converter.convert(to: output, error: &converterError) { _, statusPointer in
                guard !suppliedInput else {
                    statusPointer.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                statusPointer.pointee = .haveData
                return input
            }
            try consumeOutput(status: status, converterError: converterError)
            switch status {
            case .inputRanDry, .endOfStream:
                return
            case .haveData:
                continue
            case .error:
                throw QuickBounceError.artifactInvalid("True-peak sample-rate conversion failed")
            @unknown default:
                throw QuickBounceError.artifactInvalid("Unknown true-peak converter state")
            }
        }
    }

    func finish() throws -> Double {
        guard !isFinished else { return Double(peak) }
        isFinished = true
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var converterError: NSError?
            let status = converter.convert(to: output, error: &converterError) { _, statusPointer in
                statusPointer.pointee = .endOfStream
                return nil
            }
            try consumeOutput(status: status, converterError: converterError)
            switch status {
            case .endOfStream:
                return Double(peak)
            case .haveData:
                continue
            case .inputRanDry:
                if output.frameLength == 0 { return Double(peak) }
            case .error:
                throw QuickBounceError.artifactInvalid("True-peak sample-rate conversion failed")
            @unknown default:
                throw QuickBounceError.artifactInvalid("Unknown true-peak converter state")
            }
        }
    }

    private func consumeOutput(
        status: AVAudioConverterOutputStatus,
        converterError: NSError?
    ) throws {
        if let converterError {
            throw QuickBounceError.artifactInvalid(
                "True-peak conversion failed (\(converterError.domain) \(converterError.code)): \(converterError.localizedDescription)"
            )
        }
        guard status != .error else {
            throw QuickBounceError.artifactInvalid("True-peak sample-rate conversion failed")
        }
        guard output.frameLength > 0, let channels = output.floatChannelData else { return }
        for channel in 0..<Int(output.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(
                channels[channel],
                1,
                &channelPeak,
                vDSP_Length(output.frameLength)
            )
            peak = max(peak, channelPeak)
        }
    }
}

private struct Biquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    private var x1: Double = 0
    private var x2: Double = 0
    private var y1: Double = 0
    private var y2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ value: Double) -> Double {
        let output = b0 * value + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = value
        y2 = y1
        y1 = output
        return output
    }
}

private struct KWeightingFilter {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double, channelIndex: Int) {
        _ = channelIndex
        shelf = Self.highShelf(sampleRate: sampleRate)
        highPass = Self.highPass(sampleRate: sampleRate)
    }

    mutating func process(_ value: Double) -> Double {
        highPass.process(shelf.process(value))
    }

    private static func highShelf(sampleRate: Double) -> Biquad {
        let frequency = 1_681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * frequency / sampleRate)
        let highGain = pow(10, gain / 20)
        let transitionGain = pow(highGain, 0.499666774155)
        let denominator = 1 + k / q + k * k
        let b0 = (highGain + transitionGain * k / q + k * k) / denominator
        let b1 = 2 * (k * k - highGain) / denominator
        let b2 = (highGain - transitionGain * k / q + k * k) / denominator
        let a1 = 2 * (k * k - 1) / denominator
        let a2 = (1 - k / q + k * k) / denominator
        return Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    private static func highPass(sampleRate: Double) -> Biquad {
        let frequency = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * frequency / sampleRate)
        let denominator = 1 + k / q + k * k
        let a1 = 2 * (k * k - 1) / denominator
        let a2 = (1 - k / q + k * k) / denominator
        return Biquad(b0: 1, b1: -2, b2: 1, a1: a1, a2: a2)
    }
}
