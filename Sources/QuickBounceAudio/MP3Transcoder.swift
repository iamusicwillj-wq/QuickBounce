import AVFoundation
import Foundation
@preconcurrency import QuickBounceLAMEShim
import QuickBounceDomain

public actor MP3Transcoder {
    private var activeTask: Task<Void, Error>?

    public init() {}

    public static var encoderVersion: String {
        String(cString: qb_lame_version())
    }

    public func transcode(
        source: URL,
        destination: URL,
        bitRateKbps: Int,
        quality: MP3EncodingQuality
    ) async throws {
        guard activeTask == nil else {
            throw QuickBounceError.invalidPlan("The MP3 encoder is already busy")
        }
        guard (16...320).contains(bitRateKbps) else {
            throw QuickBounceError.invalidPlan("MP3 CBR must be between 16 and 320 kbps")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw QuickBounceError.exportFailed("Refusing to overwrite \(destination.path)")
        }

        let task = Task.detached(priority: .utility) {
            try Self.encode(
                source: source,
                destination: destination,
                bitRateKbps: bitRateKbps,
                qualityValue: quality.lameQuality
            )
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    public func cancel() {
        activeTask?.cancel()
    }

    private nonisolated static func encode(
        source: URL,
        destination: URL,
        bitRateKbps: Int,
        qualityValue: Int32
    ) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channelCount = Int(format.channelCount)
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              (1...2).contains(channelCount) else {
            throw QuickBounceError.artifactInvalid(
                "Local MP3 encoding requires mono or stereo Float32 PCM"
            )
        }

        var status: Int32 = 0
        guard let encoder = qb_lame_encoder_create(
            Int32(format.sampleRate.rounded()),
            Int32(channelCount),
            Int32(bitRateKbps),
            qualityValue,
            &status
        ) else {
            throw QuickBounceError.artifactInvalid("LAME initialization failed (\(status))")
        }
        defer { qb_lame_encoder_destroy(encoder) }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data().write(to: destination, options: .withoutOverwriting)
        let outputFile = try FileHandle(forWritingTo: destination)
        defer { try? outputFile.close() }

        let frameCapacity: AVAudioFrameCount = 8_192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw QuickBounceError.artifactInvalid("Unable to allocate MP3 input buffer")
        }
        let outputCapacity = Int(Double(frameCapacity) * 1.25) + 7_200
        var outputBytes = [UInt8](repeating: 0, count: outputCapacity)

        while input.framePosition < input.length {
            try Task.checkCancellation()
            inputBuffer.frameLength = 0
            let remaining = input.length - input.framePosition
            try input.read(
                into: inputBuffer,
                frameCount: AVAudioFrameCount(min(Int64(frameCapacity), remaining))
            )
            guard inputBuffer.frameLength > 0 else { break }
            guard let channels = inputBuffer.floatChannelData else {
                throw QuickBounceError.artifactInvalid("WAV decoding did not produce Float32 PCM")
            }

            let encodedByteCount = outputBytes.withUnsafeMutableBufferPointer { output in
                qb_lame_encoder_encode(
                    encoder,
                    channels[0],
                    channelCount > 1 ? channels[1] : nil,
                    Int32(inputBuffer.frameLength),
                    output.baseAddress,
                    Int32(output.count)
                )
            }
            guard encodedByteCount >= 0 else {
                throw QuickBounceError.artifactInvalid(
                    "LAME encoding failed (\(encodedByteCount))"
                )
            }
            if encodedByteCount > 0 {
                try outputFile.write(contentsOf: Data(outputBytes.prefix(Int(encodedByteCount))))
            }
        }

        try Task.checkCancellation()
        let flushedByteCount = outputBytes.withUnsafeMutableBufferPointer { output in
            qb_lame_encoder_flush(
                encoder,
                output.baseAddress,
                Int32(output.count)
            )
        }
        guard flushedByteCount >= 0 else {
            throw QuickBounceError.artifactInvalid("LAME flush failed (\(flushedByteCount))")
        }
        if flushedByteCount > 0 {
            try outputFile.write(contentsOf: Data(outputBytes.prefix(Int(flushedByteCount))))
        }
        try outputFile.synchronize()
    }
}

private extension MP3EncodingQuality {
    var lameQuality: Int32 {
        switch self {
        case .fastest: 7
        case .standard: 4
        case .highest: 0
        }
    }
}
