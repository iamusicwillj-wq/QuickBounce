@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import QuickBounceDomain

public actor MOVAACTranscoder {
    private var activeTask: Task<Void, Error>?

    public init() {}

    public func transcode(source: URL, destination: URL, bitRateMode: AACBitRateMode = .cbr) async throws {
        guard activeTask == nil else {
            throw QuickBounceError.invalidPlan("The MOV audio encoder is already busy")
        }
        let task = Task.detached(priority: .utility) {
            try await Self.encode(source: source, destination: destination, bitRateMode: bitRateMode)
        }
        activeTask = task
        defer { activeTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancel() {
        activeTask?.cancel()
    }

    private struct TrackIO {
        let source: AVAssetTrack
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false
    }

    private static func encode(source: URL, destination: URL, bitRateMode: AACBitRateMode) async throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw QuickBounceError.exportFailed("Refusing to overwrite \(destination.path)")
        }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero,
              tracks.contains(where: { $0.mediaType == .video }),
              tracks.contains(where: { $0.mediaType == .audio }) else {
            throw QuickBounceError.artifactInvalid("MOV requires a video track and PCM audio")
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)
        writer.movieTimeScale = max(60_000, duration.timescale)
        var completed = false
        defer {
            if !completed {
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var pairs: [TrackIO] = []
        for track in tracks {
            let mediaType = track.mediaType
            guard mediaType == .video || mediaType == .audio || mediaType == .timecode else {
                throw QuickBounceError.artifactInvalid("AAC conversion cannot preserve this MOV track type")
            }
            let descriptions = try await track.load(.formatDescriptions)
            guard descriptions.count == 1, let description = descriptions.first else {
                throw QuickBounceError.artifactInvalid("MOV track uses an unsupported format description")
            }
            let settings = mediaType == .audio ? try aacSettings(from: description, bitRateMode: bitRateMode) : nil
            if let settings, !writer.canApply(outputSettings: settings, forMediaType: .audio) {
                throw QuickBounceError.artifactInvalid("The AAC encoder does not support this MOV audio format")
            }

            // Original compressed video/timecode samples pass through. All tracks
            // stay on the same movie timeline, including any leading track offset.
            // Request PCM decoding for audio so the reader applies the source
            // edit list, including silence before the first audible sample.
            let readSettings: [String: Any]? = mediaType == .audio ? [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ] : nil
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: mediaType,
                outputSettings: settings,
                sourceFormatHint: mediaType == .audio ? nil : description
            )
            input.metadata = try await track.load(.metadata)
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            if mediaType != .audio {
                input.mediaTimeScale = try await track.load(.naturalTimeScale)
            }
            if mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
            }
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw QuickBounceError.artifactInvalid("Unable to preserve a MOV track during AAC conversion")
            }
            reader.add(output)
            writer.add(input)
            pairs.append(TrackIO(source: track, output: output, input: input))
        }

        for pair in pairs {
            for type in try await pair.source.load(.availableTrackAssociationTypes) {
                for associated in try await pair.source.loadAssociatedTracks(ofType: type) {
                    guard let target = pairs.first(where: { $0.source.trackID == associated.trackID }),
                          pair.input.canAddTrackAssociation(withTrackOf: target.input, type: type.rawValue) else {
                        throw QuickBounceError.artifactInvalid("Unable to preserve a MOV track association")
                    }
                    pair.input.addTrackAssociation(withTrackOf: target.input, type: type.rawValue)
                }
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? QuickBounceError.exportFailed("Unable to start MOV AAC conversion")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw reader.error ?? QuickBounceError.exportFailed("Unable to read the source MOV")
        }
        try await copySamples(&pairs, reader: reader, writer: writer)
        writer.endSession(atSourceTime: duration)
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? QuickBounceError.exportFailed("MOV AAC conversion did not finish")
        }
        try await verifyTimeline(sourceTracks: tracks, duration: duration, destination: destination)
        completed = true
    }

    static func aacSettings(from description: CMFormatDescription, bitRateMode: AACBitRateMode) throws -> [String: Any] {
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else {
            throw QuickBounceError.artifactInvalid("MOV audio must be PCM before AAC conversion")
        }
        let channels = Int(stream.mChannelsPerFrame)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: stream.mSampleRate,
            AVNumberOfChannelsKey: channels
        ]
        switch bitRateMode {
        case .cbr:
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
            settings[AVEncoderBitRateKey] = channels > 2 ? 64_000 * channels : 128_000 * channels
        case .vbr:
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Variable
            settings[AVEncoderAudioQualityForVBRKey] = AVAudioQuality.max.rawValue
        }
        if channels > 2 {
            let labels = channelLabels(for: description, channels: channels)
            var specifier = AudioStreamBasicDescription()
            specifier.mFormatID = kAudioFormatMPEG4AAC
            specifier.mChannelsPerFrame = stream.mChannelsPerFrame
            let property = kAudioFormatProperty_AvailableEncodeChannelLayoutTags
            let specifierSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var size: UInt32 = 0
            guard Set(labels).count == channels,
                  !labels.contains(kAudioChannelLabel_Unknown),
                  AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr,
                  size >= MemoryLayout<AudioChannelLayoutTag>.size else {
                throw QuickBounceError.artifactInvalid("Multichannel AAC requires a known audio channel layout")
            }
            var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
            let status = tags.withUnsafeMutableBytes {
                AudioFormatGetProperty(property, specifierSize, &specifier, &size, $0.baseAddress)
            }
            guard status == noErr,
                  let tag = tags.first(where: {
                      Set(AudioChannelLayoutInfo.labels(AVAudioChannelLayout(layoutTag: $0), count: channels)) == Set(labels)
                  }) else {
                throw QuickBounceError.artifactInvalid("The AAC encoder does not support this MOV channel layout")
            }
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = tag
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }

    private static func channelLabels(for description: CMFormatDescription, channels: Int) -> [AudioChannelLabel] {
        var size = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size)
            .map { AVAudioChannelLayout(layout: $0) }
        return AudioChannelLayoutInfo.labels(layout, count: channels)
    }

    private static func copySamples(
        _ pairs: inout [TrackIO], reader: AVAssetReader, writer: AVAssetWriter
    ) async throws {
        let clock = ContinuousClock()
        var lastProgress = clock.now
        while pairs.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            guard reader.status != .failed, writer.status == .writing else {
                throw writer.error ?? reader.error ?? QuickBounceError.exportFailed("MOV AAC conversion stopped")
            }
            var progressed = false
            for index in pairs.indices where !pairs[index].finished && pairs[index].input.isReadyForMoreMediaData {
                let pair = pairs[index]
                if let sample = pair.output.copyNextSampleBuffer() {
                    guard pair.input.append(sample) else {
                        throw writer.error ?? QuickBounceError.exportFailed("Unable to write a MOV media sample")
                    }
                } else {
                    if let error = reader.error { throw error }
                    pair.input.markAsFinished()
                    pairs[index].finished = true
                }
                progressed = true
            }
            if progressed {
                lastProgress = clock.now
            } else {
                guard clock.now - lastProgress < .seconds(30) else {
                    throw QuickBounceError.exportFailed("MOV AAC conversion stopped making progress")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private static func verifyTimeline(
        sourceTracks: [AVAssetTrack], duration: CMTime, destination: URL
    ) async throws {
        let movie = AVURLAsset(url: destination)
        let outputTracks = try await movie.load(.tracks)
        let outputDuration = try await movie.load(.duration)
        // Allow a millisecond for container time-scale rounding, well below one frame.
        let tolerance = 0.001
        guard outputTracks.count == sourceTracks.count,
              abs((outputDuration - duration).seconds) <= tolerance else {
            throw QuickBounceError.artifactInvalid("AAC conversion changed the MOV track count or duration")
        }
        for mediaType in Set(sourceTracks.map(\.mediaType)) {
            let originals = sourceTracks.filter { $0.mediaType == mediaType }
            let converted = outputTracks.filter { $0.mediaType == mediaType }
            guard originals.count == converted.count else {
                throw QuickBounceError.artifactInvalid("AAC conversion changed the MOV track layout")
            }
            for (original, output) in zip(originals, converted) {
                let before = try await original.load(.timeRange)
                let after = try await output.load(.timeRange)
                guard abs((after.start - before.start).seconds) <= tolerance,
                      abs((after.end - before.end).seconds) <= tolerance else {
                    throw QuickBounceError.artifactInvalid("AAC conversion changed MOV \(mediaType.rawValue) timing from \(before.start.seconds)–\(before.end.seconds) s to \(after.start.seconds)–\(after.end.seconds) s")
                }
                let beforeFormats = try await original.load(.formatDescriptions)
                let afterFormats = try await output.load(.formatDescriptions)
                if mediaType == .audio {
                    guard let sourceFormat = beforeFormats.first.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee,
                          let outputFormat = afterFormats.first.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee,
                          outputFormat.mFormatID == kAudioFormatMPEG4AAC,
                          outputFormat.mChannelsPerFrame == sourceFormat.mChannelsPerFrame,
                          outputFormat.mSampleRate == sourceFormat.mSampleRate else {
                        throw QuickBounceError.artifactInvalid("AAC conversion changed the MOV audio sample rate or channel count")
                    }
                    let channels = Int(outputFormat.mChannelsPerFrame)
                    if channels > 2,
                       Set(channelLabels(for: beforeFormats[0], channels: channels)) != Set(channelLabels(for: afterFormats[0], channels: channels)) {
                        throw QuickBounceError.artifactInvalid("AAC conversion changed the MOV audio channel layout")
                    }
                } else if beforeFormats.map(\.mediaSubType) != afterFormats.map(\.mediaSubType) {
                    throw QuickBounceError.artifactInvalid("AAC conversion changed a MOV picture or timecode format")
                }
            }
        }
    }
}
