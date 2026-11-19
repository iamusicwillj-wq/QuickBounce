@preconcurrency import AVFoundation
import Foundation
import QuickBounceDomain

public struct ArtifactExpectation: Hashable, Sendable {
    public var kind: ArtifactKind
    public var baseFileName: String
    public var allowsMultipleMonoSuffixes: Bool
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var channelCount: Int?
    public var durationSeconds: Double?
    public var durationToleranceSeconds: Double
    public var requiresVideoTrack: Bool
    public var requiresAudioTrack: Bool
    public var movAudioCodec: MOVAudioCodec?

    public init(
        kind: ArtifactKind,
        baseFileName: String,
        allowsMultipleMonoSuffixes: Bool = false,
        sampleRate: Double? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil,
        durationSeconds: Double? = nil,
        durationToleranceSeconds: Double = 0.01,
        requiresVideoTrack: Bool = false,
        requiresAudioTrack: Bool = false,
        movAudioCodec: MOVAudioCodec? = nil
    ) {
        self.kind = kind
        self.baseFileName = baseFileName
        self.allowsMultipleMonoSuffixes = allowsMultipleMonoSuffixes
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.durationToleranceSeconds = max(0, durationToleranceSeconds)
        self.requiresVideoTrack = requiresVideoTrack
        self.requiresAudioTrack = requiresAudioTrack
        self.movAudioCodec = movAudioCodec
    }
}

public actor ArtifactInspector {
    public init() {}

    public func waitUntilStable(
        url: URL,
        requiredStableObservations: Int = 3,
        interval: Duration = .milliseconds(250),
        timeout: Duration = .seconds(30)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var stableCount = 0
        var previous: (size: Int64, modified: Date)?

        while clock.now < deadline {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                try await Task.sleep(for: interval)
                continue
            }
            let current = (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            if current.0 > 0, let previous, previous.size == current.0, previous.modified == current.1 {
                stableCount += 1
                if stableCount >= requiredStableObservations { return }
            } else {
                stableCount = 0
            }
            previous = current
            try await Task.sleep(for: interval)
        }
        throw QuickBounceError.artifactMissing(url.path)
    }

    public func inspect(
        _ artifact: AudioArtifact,
        expectation: ArtifactExpectation? = nil
    ) async throws -> AudioArtifact {
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            throw QuickBounceError.artifactMissing(artifact.path)
        }
        if let expectation {
            try validateIdentity(of: artifact, against: expectation)
        }
        var result = artifact
        if artifact.kind == .mov {
            let asset = AVURLAsset(url: artifact.fileURL)
            let playable = try await asset.load(.isPlayable)
            guard playable else { throw QuickBounceError.artifactInvalid("MOV is not playable") }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else {
                throw QuickBounceError.artifactInvalid("MOV has no valid duration")
            }
            result.durationSeconds = duration.seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if expectation?.requiresVideoTrack == true, videoTracks.isEmpty {
                throw QuickBounceError.artifactInvalid("MOV contains no video track")
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if expectation?.requiresAudioTrack == true, audioTracks.isEmpty {
                throw QuickBounceError.artifactInvalid("MOV contains no audio track")
            }
            if let codec = expectation?.movAudioCodec {
                let expected: AudioFormatID = codec == .aac ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM
                for track in audioTracks {
                    let descriptions = try await track.load(.formatDescriptions)
                    guard !descriptions.isEmpty,
                          descriptions.allSatisfy({
                              CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mFormatID == expected
                          }) else {
                        throw QuickBounceError.artifactInvalid("MOV audio is not \(codec.displayName)")
                    }
                }
            }
            if let audioTrack = audioTracks.first,
               let description = try await audioTrack.load(.formatDescriptions).first,
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if stream.mSampleRate > 0 {
                    result.sampleRate = stream.mSampleRate
                    result.frameCount = Int64((duration.seconds * stream.mSampleRate).rounded())
                }
                if stream.mChannelsPerFrame > 0 {
                    result.channelCount = Int(stream.mChannelsPerFrame)
                }
                if stream.mBitsPerChannel > 0 {
                    result.bitDepth = Int(stream.mBitsPerChannel)
                }
            }
            result.state = .completed
            if let expectation {
                try validateMetadata(of: result, against: expectation)
            }
            return result
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: artifact.fileURL)
        } catch {
            throw QuickBounceError.artifactInvalid(
                "Unable to decode \(artifact.kind.rawValue.uppercased()) audio"
            )
        }
        guard file.length > 0, file.processingFormat.channelCount > 0 else {
            throw QuickBounceError.artifactInvalid("Audio file contains no decodable frames")
        }
        result.sampleRate = file.processingFormat.sampleRate
        result.channelCount = Int(file.processingFormat.channelCount)
        result.channelNames = AudioChannelLayoutInfo.names(file.fileFormat.channelLayout, count: Int(file.processingFormat.channelCount))
        result.frameCount = file.length
        result.durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        let encodedBits = file.fileFormat.streamDescription.pointee.mBitsPerChannel
        if encodedBits > 0 {
            result.bitDepth = Int(encodedBits)
        } else if artifact.kind == .mp3 {
            // MP3 has no PCM word length in its bitstream. Pro Tools exposes
            // MP3 Bounce as a fixed 16-bit source format, so report that
            // product-facing value instead of AVFoundation's 0-bit sentinel.
            result.bitDepth = 16
        }
        if let expectation {
            let formatID = file.fileFormat.streamDescription.pointee.mFormatID
            switch expectation.kind {
            case .wav:
                guard formatID == kAudioFormatLinearPCM else {
                    throw QuickBounceError.artifactInvalid(
                        "WAV audio codec is \(Self.fourCC(formatID)); expected PCM"
                    )
                }
            case .mp3:
                guard formatID == kAudioFormatMPEGLayer3 else {
                    throw QuickBounceError.artifactInvalid(
                        "MP3 container contains \(Self.fourCC(formatID)) audio"
                    )
                }
            case .mov:
                break
            }
            try validateMetadata(of: result, against: expectation)
        }
        result.state = .completed
        return result
    }

    private func validateIdentity(
        of artifact: AudioArtifact,
        against expectation: ArtifactExpectation
    ) throws {
        guard artifact.kind == expectation.kind else {
            throw QuickBounceError.artifactInvalid(
                "Artifact type is \(artifact.kind.rawValue.uppercased()); expected \(expectation.kind.rawValue.uppercased())"
            )
        }
        let url = artifact.fileURL
        guard url.pathExtension.lowercased() == expectation.kind.rawValue else {
            throw QuickBounceError.artifactInvalid(
                "File extension is .\(url.pathExtension); expected .\(expectation.kind.rawValue)"
            )
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let exact = stem == expectation.baseFileName
        let multipleMono = expectation.allowsMultipleMonoSuffixes
            && stem.hasPrefix(expectation.baseFileName + ".")
            && stem.count > expectation.baseFileName.count + 1
        guard exact || multipleMono else {
            throw QuickBounceError.artifactInvalid(
                "File name “\(url.lastPathComponent)” does not match expected Bounce name “\(expectation.baseFileName)”"
            )
        }
    }

    private func validateMetadata(
        of artifact: AudioArtifact,
        against expectation: ArtifactExpectation
    ) throws {
        if let expected = expectation.sampleRate {
            guard let actual = artifact.sampleRate, abs(actual - expected) <= 0.5 else {
                throw QuickBounceError.artifactInvalid(
                    "Sample rate is \(Self.number(artifact.sampleRate)) Hz; expected \(Self.number(expected)) Hz"
                )
            }
        }
        if let expected = expectation.bitDepth {
            guard artifact.bitDepth == expected else {
                let actual = artifact.bitDepth.map(String.init) ?? "unknown"
                throw QuickBounceError.artifactInvalid(
                    "Bit depth is \(actual)-bit; expected \(expected)-bit"
                )
            }
        }
        if let expected = expectation.channelCount {
            guard artifact.channelCount == expected else {
                let actual = artifact.channelCount.map(String.init) ?? "unknown"
                throw QuickBounceError.artifactInvalid(
                    "Channel count is \(actual); expected \(expected)"
                )
            }
        }
        if let expected = expectation.durationSeconds {
            guard let actual = artifact.durationSeconds,
                  abs(actual - expected) <= expectation.durationToleranceSeconds else {
                let actualText = artifact.durationSeconds.map { String(format: "%.6f", $0) } ?? "unknown"
                throw QuickBounceError.artifactInvalid(
                    "Duration is \(actualText) s; expected \(String(format: "%.6f", expected)) s ± \(String(format: "%.3f", expectation.durationToleranceSeconds)) s"
                )
            }
        }
    }

    private nonisolated static func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "unknown"
    }

    private nonisolated static func fourCC(_ value: AudioFormatID) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

public actor ArtifactLocator {
    public init() {}

    public func expectedCandidates(
        in directory: URL,
        baseName: String,
        kind: ArtifactKind,
        allowsMultipleMonoSuffixes: Bool = false
    ) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let expectedExtension = kind.rawValue.lowercased()
        return entries.filter { url in
            guard url.pathExtension.lowercased() == expectedExtension else { return false }
            let stem = url.deletingPathExtension().lastPathComponent
            return stem == baseName || (
                allowsMultipleMonoSuffixes
                    && stem.hasPrefix(baseName + ".")
                    && stem.count > baseName.count + 1
            )
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
