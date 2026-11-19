import AVFoundation
import Accelerate
import Foundation
import QuickBounceDomain

public actor WaveformAnalyzer {
    public init() {}

    public func analyze(
        artifact: AudioArtifact,
        blockSizes: [Int]? = nil
    ) async throws -> WaveformPyramid {
        guard artifact.kind.hasWaveform else {
            throw QuickBounceError.artifactInvalid("MOV files do not enter the waveform pipeline")
        }
        if let blockSizes, blockSizes.allSatisfy({ $0 <= 0 }) {
            throw QuickBounceError.artifactInvalid("At least one waveform block size is required")
        }
        let url = artifact.fileURL

        let worker = Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let channelCount = Int(format.channelCount)
            guard channelCount > 0, file.length > 0, format.sampleRate > 0 else {
                throw QuickBounceError.artifactInvalid("Waveform analysis requires a non-empty decodable file")
            }
            let sizes = blockSizes.map {
                Array(Set($0.filter { $0 > 0 })).sorted()
            } ?? Self.adaptiveBlockSizes(
                frameCount: file.length,
                channelCount: channelCount
            )
            guard let baseSize = sizes.first else {
                throw QuickBounceError.artifactInvalid("At least one waveform block size is required")
            }

            var baseChannels = Array(repeating: [WaveformLevel](), count: channelCount)
            let expectedBaseCount = Int(ceil(Double(file.length) / Double(baseSize)))
            for channel in baseChannels.indices {
                baseChannels[channel].reserveCapacity(expectedBaseCount)
            }
            var pendingMinimum = Array(repeating: Float.greatestFiniteMagnitude, count: channelCount)
            var pendingMaximum = Array(repeating: -Float.greatestFiniteMagnitude, count: channelCount)
            var pendingFrames = 0
            // Larger sequential reads reduce decoder overhead. Extrema are
            // reduced a whole span at a time with Accelerate instead of
            // crossing the Swift/array bounds machinery for every sample.
            let readSize: AVAudioFrameCount = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readSize) else {
                throw QuickBounceError.artifactInvalid("Unable to allocate waveform read buffer")
            }

            while file.framePosition < file.length {
                try Task.checkCancellation()
                let remaining = file.length - file.framePosition
                let previousPosition = file.framePosition
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(readSize), remaining)))
                guard buffer.frameLength > 0, file.framePosition > previousPosition else {
                    throw QuickBounceError.artifactInvalid("Audio decoding stopped before the end of the file")
                }
                guard let samples = buffer.floatChannelData else {
                    throw QuickBounceError.artifactInvalid("Waveform decoding did not produce Float32 PCM")
                }

                let frameCount = Int(buffer.frameLength)
                var frameOffset = 0
                while frameOffset < frameCount {
                    let spanCount = min(baseSize - pendingFrames, frameCount - frameOffset)
                    for channel in 0..<channelCount {
                        var spanMinimum: Float = 0
                        var spanMaximum: Float = 0
                        vDSP_minv(
                            samples[channel].advanced(by: frameOffset),
                            1,
                            &spanMinimum,
                            vDSP_Length(spanCount)
                        )
                        vDSP_maxv(
                            samples[channel].advanced(by: frameOffset),
                            1,
                            &spanMaximum,
                            vDSP_Length(spanCount)
                        )
                        pendingMinimum[channel] = min(pendingMinimum[channel], spanMinimum)
                        pendingMaximum[channel] = max(pendingMaximum[channel], spanMaximum)
                    }
                    pendingFrames += spanCount
                    frameOffset += spanCount
                    if pendingFrames == baseSize {
                        for channel in 0..<channelCount {
                            baseChannels[channel].append(
                                WaveformLevel(minimum: pendingMinimum[channel], maximum: pendingMaximum[channel])
                            )
                            pendingMinimum[channel] = .greatestFiniteMagnitude
                            pendingMaximum[channel] = -.greatestFiniteMagnitude
                        }
                        pendingFrames = 0
                    }
                }
            }

            if pendingFrames > 0 {
                for channel in 0..<channelCount {
                    baseChannels[channel].append(
                        WaveformLevel(minimum: pendingMinimum[channel], maximum: pendingMaximum[channel])
                    )
                }
            }

            var levels = [WaveformEnvelope(
                artifactID: artifact.id,
                sampleRate: format.sampleRate,
                frameCount: file.length,
                channels: baseChannels,
                blockSize: baseSize
            )]

            var previousChannels = baseChannels
            var previousBlockSize = baseSize
            for size in sizes.dropFirst() {
                // Each coarser level is reduced from the preceding level,
                // avoiding repeated full scans of the finest (largest) array.
                let groupSize = max(1, Int(ceil(Double(size) / Double(previousBlockSize))))
                guard groupSize > 1 else { continue }
                let channels = previousChannels.map { source -> [WaveformLevel] in
                    stride(from: 0, to: source.count, by: groupSize).map { start -> WaveformLevel in
                        let end = min(source.count, start + groupSize)
                        var minimum = Float.greatestFiniteMagnitude
                        var maximum = -Float.greatestFiniteMagnitude
                        for index in start..<end {
                            minimum = min(minimum, source[index].minimum)
                            maximum = max(maximum, source[index].maximum)
                        }
                        return WaveformLevel(
                            minimum: minimum.isFinite ? minimum : 0,
                            maximum: maximum.isFinite ? maximum : 0
                        )
                    }
                }
                levels.append(WaveformEnvelope(
                    artifactID: artifact.id,
                    sampleRate: format.sampleRate,
                    frameCount: file.length,
                    channels: channels,
                    blockSize: previousBlockSize * groupSize
                ))
                previousChannels = channels
                previousBlockSize *= groupSize
            }

            let pyramid = WaveformPyramid(artifactID: artifact.id, levels: levels)
            guard pyramid.isValid else {
                throw QuickBounceError.artifactInvalid("Waveform contains invalid or incomplete sample data")
            }
            return pyramid
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Keeps the finest cached layer within a bounded total bin budget while
    /// retaining enough resolution for the product's 32× zoom. Short files can
    /// therefore reach sample or near-sample detail without making long,
    /// multichannel files consume unbounded memory and disk space.
    public nonisolated static func adaptiveBlockSizes(
        frameCount: Int64,
        channelCount: Int,
        finestBinBudget: Int = 262_144,
        overviewBinTarget: Int = 2_048
    ) -> [Int] {
        let safeFrames = max(1, frameCount)
        let safeChannels = max(1, channelCount)
        let safeBudget = max(1, finestBinBudget)
        let requiredBase = max(
            1,
            Int(ceil(Double(safeFrames) * Double(safeChannels) / Double(safeBudget)))
        )
        let baseSize = powerOfTwo(atLeast: requiredBase)
        let overviewBlockSize = max(
            baseSize,
            Int(ceil(Double(safeFrames) / Double(max(1, overviewBinTarget))))
        )

        var sizes = [baseSize]
        while let last = sizes.last, last < overviewBlockSize {
            guard last <= Int.max / 4 else { break }
            sizes.append(last * 4)
        }
        return sizes
    }

    private nonisolated static func powerOfTwo(atLeast value: Int) -> Int {
        var result = 1
        while result < value, result <= Int.max / 2 {
            result *= 2
        }
        return result
    }
}

public actor WaveformCache {
    private struct CachedWaveform: Codable {
        var cacheVersion: Int
        var fileFingerprint: String
        var pyramid: WaveformPyramid
    }

    public static let cacheVersion = 3
    public let directory: URL
    private let encoder: PropertyListEncoder
    private let decoder = PropertyListDecoder()

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func load(for artifact: AudioArtifact) throws -> WaveformPyramid? {
        guard artifact.kind.hasWaveform else { return nil }
        let url = cacheURL(for: artifact)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: legacyCacheURL(for: artifact))
            return nil
        }
        let cached: CachedWaveform
        do {
            cached = try decoder.decode(CachedWaveform.self, from: Data(contentsOf: url))
        } catch {
            // Pre-V0.2 caches had no version or file fingerprint. They are
            // disposable derived data, so remove and regenerate them.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let fingerprint = try AudioQCAnalyzer.fileFingerprint(for: artifact.fileURL)
        guard cached.cacheVersion == Self.cacheVersion,
              cached.fileFingerprint == fingerprint,
              cached.pyramid.artifactID == artifact.id,
              cached.pyramid.isValid else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached.pyramid
    }

    public func save(_ pyramid: WaveformPyramid, for artifact: AudioArtifact,
                     expectedFingerprint: String? = nil) throws {
        guard artifact.kind.hasWaveform else { return }
        let fingerprint = try AudioQCAnalyzer.fileFingerprint(for: artifact.fileURL)
        guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
            throw QuickBounceError.artifactInvalid("The audio file changed before its waveform could be cached")
        }
        let cached = CachedWaveform(
            cacheVersion: Self.cacheVersion,
            fileFingerprint: fingerprint,
            pyramid: pyramid
        )
        try encoder.encode(cached).write(to: cacheURL(for: artifact), options: [.atomic])
    }

    public func invalidate(for artifact: AudioArtifact) throws {
        for url in [cacheURL(for: artifact), legacyCacheURL(for: artifact)] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func removeAll() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private func cacheURL(for artifact: AudioArtifact) -> URL {
        directory.appendingPathComponent("\(artifact.id.uuidString).waveform")
    }

    private func legacyCacheURL(for artifact: AudioArtifact) -> URL {
        directory.appendingPathComponent("\(artifact.id.uuidString).waveform.json")
    }
}
