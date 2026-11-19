import Foundation

public enum ConnectionStatus: String, Codable, Sendable {
    case disconnected
    case connectedWithoutSession
    case connected
}

/// The physical frame cadence used by a Pro Tools Session. Drop-frame and
/// non-drop timecode with the same cadence intentionally share this value:
/// Pad to Frame Boundary is governed by frame duration, not frame numbering.
public struct SessionTimeCodeRate: Codable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int = 1) {
        precondition(numerator > 0 && denominator > 0)
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let fps23_976 = SessionTimeCodeRate(numerator: 24_000, denominator: 1_001)
    public static let fps24 = SessionTimeCodeRate(numerator: 24)
    public static let fps25 = SessionTimeCodeRate(numerator: 25)
    public static let fps29_97 = SessionTimeCodeRate(numerator: 30_000, denominator: 1_001)
    public static let fps30 = SessionTimeCodeRate(numerator: 30)
    public static let fps47_952 = SessionTimeCodeRate(numerator: 48_000, denominator: 1_001)
    public static let fps48 = SessionTimeCodeRate(numerator: 48)
    public static let fps50 = SessionTimeCodeRate(numerator: 50)
    public static let fps59_94 = SessionTimeCodeRate(numerator: 60_000, denominator: 1_001)
    public static let fps60 = SessionTimeCodeRate(numerator: 60)
    public static let fps100 = SessionTimeCodeRate(numerator: 100)
    public static let fps119_88 = SessionTimeCodeRate(numerator: 120_000, denominator: 1_001)
    public static let fps120 = SessionTimeCodeRate(numerator: 120)

    public var framesPerSecond: Double {
        guard numerator > 0, denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    public var frameDurationSeconds: Double {
        guard numerator > 0, denominator > 0 else { return 0 }
        return Double(denominator) / Double(numerator)
    }

    /// Pro Tools pads the In point down and the Out point up independently.
    /// Consequently the total duration can grow by almost two frames; using
    /// the exact padded frame count is stricter than treating that growth as a
    /// broad duration tolerance.
    public func paddedDuration(for range: SampleRange, sampleRate: Int) -> Double {
        guard numerator > 0, denominator > 0,
              sampleRate > 0, range.start >= 0, range.end >= range.start else {
            return 0
        }
        let samplesPerFrame = Double(sampleRate) * Double(denominator) / Double(numerator)
        let paddedInFrame = floor(Double(range.start) / samplesPerFrame)
        let paddedOutFrame = ceil(Double(range.end) / samplesPerFrame)
        return max(0, paddedOutFrame - paddedInFrame) * frameDurationSeconds
    }
}

public struct SessionInfo: Codable, Hashable, Sendable {
    public var identity: SessionIdentity
    public var name: String
    public var sampleRate: Int
    public var bitDepth: Int
    public var fileFormat: String
    public var trackCount: Int
    public var lengthSamples: Int64
    public var timeCodeRate: SessionTimeCodeRate?

    public init(
        identity: SessionIdentity,
        name: String,
        sampleRate: Int,
        bitDepth: Int,
        fileFormat: String,
        trackCount: Int,
        lengthSamples: Int64,
        timeCodeRate: SessionTimeCodeRate? = nil
    ) {
        self.identity = identity
        self.name = name
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileFormat = fileFormat
        self.trackCount = trackCount
        self.lengthSamples = lengthSamples
        self.timeCodeRate = timeCodeRate
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(lengthSamples) / Double(sampleRate) : 0
    }
}

public enum ReviewMode: String, CaseIterable, Identifiable, Sendable {
    case mixCompare = "Mix Compare"
    case stemsCheck = "Stems Check"

    public var id: String { rawValue }
}

public struct WaveformLevel: Codable, Hashable, Sendable {
    public var minimum: Float
    public var maximum: Float

    public init(minimum: Float, maximum: Float) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct WaveformEnvelope: Codable, Hashable, Sendable {
    public var artifactID: UUID
    public var sampleRate: Double
    public var frameCount: Int64
    public var channels: [[WaveformLevel]]
    public var blockSize: Int

    public init(
        artifactID: UUID,
        sampleRate: Double,
        frameCount: Int64,
        channels: [[WaveformLevel]],
        blockSize: Int
    ) {
        self.artifactID = artifactID
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channels = channels
        self.blockSize = blockSize
    }

    /// Reduces one channel to exact display columns without discarding extrema.
    /// A source block contributes to every pixel it overlaps, so narrow peaks
    /// remain visible when the viewport is fitted or zoomed.
    public func pixelColumns(
        channel: Int,
        viewportStart: Double,
        viewportDuration: Double,
        pixelWidth: Int
    ) -> [WaveformLevel] {
        guard pixelWidth > 0,
              viewportDuration > 0,
              sampleRate > 0,
              blockSize > 0,
              channels.indices.contains(channel),
              !channels[channel].isEmpty else { return [] }

        let windowStartFrame = Swift.max(0, viewportStart * sampleRate)
        let windowFrameCount = viewportDuration * sampleRate
        guard windowFrameCount > 0 else { return [] }
        let windowEndFrame = windowStartFrame + windowFrameCount
        let framesPerPixel = windowFrameCount / Double(pixelWidth)
        guard framesPerPixel > 0 else { return [] }

        var minimums = Array(repeating: Float.greatestFiniteMagnitude, count: pixelWidth)
        var maximums = Array(repeating: -Float.greatestFiniteMagnitude, count: pixelWidth)
        var populated = Array(repeating: false, count: pixelWidth)
        let source = channels[channel]
        let firstBlock = Swift.max(0, Int(floor(windowStartFrame / Double(blockSize))))
        let endBlock = Swift.min(
            source.count,
            Int(ceil(Swift.min(windowEndFrame, Double(frameCount)) / Double(blockSize)))
        )

        if firstBlock < endBlock {
            for sourceIndex in firstBlock..<endBlock {
                let blockStart = Double(sourceIndex * blockSize)
                let blockEnd = Swift.min(Double(frameCount), blockStart + Double(blockSize))
                let overlapStart = Swift.max(windowStartFrame, blockStart)
                let overlapEnd = Swift.min(windowEndFrame, blockEnd)
                guard overlapStart < overlapEnd else { continue }

                let firstPixel = Swift.max(
                    0,
                    Swift.min(pixelWidth - 1, Int(floor((overlapStart - windowStartFrame) / framesPerPixel)))
                )
                let endPixel = Swift.max(
                    firstPixel + 1,
                    Swift.min(pixelWidth, Int(ceil((overlapEnd - windowStartFrame) / framesPerPixel)))
                )
                let level = source[sourceIndex]
                for pixel in firstPixel..<endPixel {
                    minimums[pixel] = Swift.min(minimums[pixel], level.minimum)
                    maximums[pixel] = Swift.max(maximums[pixel], level.maximum)
                    populated[pixel] = true
                }
            }
        }

        return minimums.indices.map { index in
            populated[index]
                ? WaveformLevel(minimum: minimums[index], maximum: maximums[index])
                : WaveformLevel(minimum: 0, maximum: 0)
        }
    }

    /// Produces a compact overview that preserves a peak found in any channel.
    public func combinedPixelColumns(
        viewportStart: Double,
        viewportDuration: Double,
        pixelWidth: Int
    ) -> [WaveformLevel] {
        guard pixelWidth > 0, !channels.isEmpty else { return [] }
        var minimums = Array(repeating: Float.greatestFiniteMagnitude, count: pixelWidth)
        var maximums = Array(repeating: -Float.greatestFiniteMagnitude, count: pixelWidth)
        var populated = Array(repeating: false, count: pixelWidth)

        for channel in channels.indices {
            let columns = pixelColumns(
                channel: channel,
                viewportStart: viewportStart,
                viewportDuration: viewportDuration,
                pixelWidth: pixelWidth
            )
            for index in columns.indices {
                minimums[index] = Swift.min(minimums[index], columns[index].minimum)
                maximums[index] = Swift.max(maximums[index], columns[index].maximum)
                populated[index] = true
            }
        }

        return minimums.indices.map { index in
            populated[index]
                ? WaveformLevel(minimum: minimums[index], maximum: maximums[index])
                : WaveformLevel(minimum: 0, maximum: 0)
        }
    }
}

public struct WaveformPyramid: Codable, Hashable, Sendable {
    public var artifactID: UUID
    public var renderRevision: UUID
    public var levels: [WaveformEnvelope]

    public init(
        artifactID: UUID,
        renderRevision: UUID = UUID(),
        levels: [WaveformEnvelope]
    ) {
        self.artifactID = artifactID
        self.renderRevision = renderRevision
        self.levels = levels.sorted { $0.blockSize < $1.blockSize }
    }

    public var isValid: Bool {
        guard let base = levels.first, base.frameCount > 0,
              base.sampleRate.isFinite, base.sampleRate > 0, !base.channels.isEmpty else { return false }
        var previousSize = 0
        for level in levels {
            guard level.artifactID == artifactID, level.frameCount == base.frameCount,
                  level.sampleRate == base.sampleRate, level.blockSize > previousSize,
                  level.channels.count == base.channels.count else { return false }
            let bins = (level.frameCount - 1) / Int64(level.blockSize) + 1
            guard level.channels.allSatisfy({ channel in
                Int64(channel.count) == bins && channel.allSatisfy {
                    $0.minimum.isFinite && $0.maximum.isFinite && $0.minimum <= $0.maximum
                }
            }) else { return false }
            previousSize = level.blockSize
        }
        return true
    }

    public func bestLevel(forVisibleFrames visibleFrames: Int64, pixelWidth: Int) -> WaveformEnvelope? {
        guard pixelWidth > 0 else { return levels.last }
        let targetBlockSize = Swift.max(
            1,
            Int(ceil(Double(Swift.max(1, visibleFrames)) / Double(pixelWidth)))
        )
        // Never choose a source coarser than one block per backing pixel when
        // a finer level exists. The renderer can safely merge fine blocks, but
        // it cannot recover timing detail from an overly coarse level.
        return levels.last(where: { $0.blockSize <= targetBlockSize }) ?? levels.first
    }
}

public struct ProgramMeterReading: Hashable, Sendable {
    public var peakLeft: Float
    public var peakRight: Float
    public var rmsLeft: Float
    public var rmsRight: Float

    public init(peakLeft: Float = 0, peakRight: Float = 0, rmsLeft: Float = 0, rmsRight: Float = 0) {
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.rmsLeft = rmsLeft
        self.rmsRight = rmsRight
    }

    public var hasOver: Bool { peakLeft >= 1 || peakRight >= 1 }
}

public struct StemPlaybackState: Codable, Hashable, Sendable {
    public var artifactID: UUID
    public var isSolo: Bool
    public var isMuted: Bool

    public init(artifactID: UUID, isSolo: Bool = false, isMuted: Bool = false) {
        self.artifactID = artifactID
        self.isSolo = isSolo
        self.isMuted = isMuted
    }
}
