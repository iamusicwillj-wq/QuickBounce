import Darwin
import Foundation
import QuickBounceDomain

public enum TestWorkspace {
    public static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL

    public static let root = projectRoot
        .appendingPathComponent(".quickbounce-test-data", isDirectory: true)

    public static func freshDirectory(_ label: String = "test") throws -> URL {
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        let directory = root
            .appendingPathComponent(safeLabel, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    public static func makeWAV(
        at url: URL,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        durationSeconds: Double = 0.5,
        frequency: Double = 440,
        amplitude: Double = 0.25,
        channelAmplitudes: [Double]? = nil,
        phaseOffset: Double = 0,
        audibleRangeSeconds: Range<Double>? = nil
    ) throws -> URL {
        precondition((1...32).contains(channelCount))
        precondition(channelAmplitudes == nil || channelAmplitudes?.count == channelCount)
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = frameCount * channelCount * bytesPerSample
        let blockAlign = UInt16(channelCount * bytesPerSample)

        var data = Data(capacity: 44 + dataByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate) * UInt32(blockAlign))
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataByteCount))

        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let isAudible = audibleRangeSeconds?.contains(time) != false
            for channel in 0..<channelCount {
                let channelAmplitude = channelAmplitudes?[channel] ?? amplitude
                let frameAmplitude = isAudible ? channelAmplitude : 0
                let channelFrequency = frequency * Double(channel + 1)
                let phase = 2 * Double.pi * channelFrequency * Double(frame) / Double(sampleRate)
                    + phaseOffset
                let sample = Int16((sin(phase) * frameAmplitude * Double(Int16.max)).rounded())
                data.appendLittleEndian(sample)
            }
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func makeConstantWAV(
        at url: URL,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        durationSeconds: Double = 1,
        amplitude: Double
    ) throws -> URL {
        precondition((1...32).contains(channelCount))
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let bytesPerSample = 2
        let dataByteCount = frameCount * channelCount * bytesPerSample
        let blockAlign = UInt16(channelCount * bytesPerSample)
        var data = Data(capacity: 44 + dataByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate) * UInt32(blockAlign))
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataByteCount))
        let clamped = max(-1, min(1, amplitude))
        let sample = Int16((clamped * Double(Int16.max)).rounded())
        for _ in 0..<(frameCount * channelCount) { data.appendLittleEndian(sample) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Creates a PCM WAV whose audio payload is sparse zero-filled data. This
    /// keeps long-form waveform tests fast to set up without weakening the
    /// decoder's obligation to scan the declared frame range.
    @discardableResult
    public static func makeSparseSilentWAV(
        at url: URL,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        durationSeconds: Double
    ) throws -> URL {
        precondition((1...32).contains(channelCount))
        let frameCount = max(1, Int64(Double(sampleRate) * durationSeconds))
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = frameCount * Int64(channelCount * bytesPerSample)
        precondition(dataByteCount <= Int64(UInt32.max - 36))
        let blockAlign = UInt16(channelCount * bytesPerSample)

        var header = Data(capacity: 44)
        header.appendASCII("RIFF")
        header.appendLittleEndian(UInt32(36 + dataByteCount))
        header.appendASCII("WAVE")
        header.appendASCII("fmt ")
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(UInt16(channelCount))
        header.appendLittleEndian(UInt32(sampleRate))
        header.appendLittleEndian(UInt32(sampleRate) * UInt32(blockAlign))
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(UInt16(bitsPerSample))
        header.appendASCII("data")
        header.appendLittleEndian(UInt32(dataByteCount))

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try header.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(44 + dataByteCount))
        return url
    }

    public static func artifact(
        for url: URL,
        kind: ArtifactKind = .wav,
        state: ArtifactState = .completed,
        jobID: UUID = UUID(),
        planID: UUID = UUID()
    ) -> AudioArtifact {
        AudioArtifact(
            jobID: jobID,
            planID: planID,
            name: url.lastPathComponent,
            path: url.path,
            kind: kind,
            state: state
        )
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
