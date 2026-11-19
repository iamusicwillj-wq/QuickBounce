@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import QuickBounceAudio
import QuickBounceDomain
import QuickBouncePersistence

enum DemoContent {
    static func seedIfNeeded(store: SQLiteStore) async throws -> (
        plans: [BouncePlan],
        artifacts: [AudioArtifact]
    ) {
        let existingPlans = try await store.loadPlans()
        let existingArtifacts = try await store.loadArtifacts()
        if !existingPlans.isEmpty {
            return (existingPlans, existingArtifacts.filter { FileManager.default.fileExists(atPath: $0.path) })
        }

        try FileManager.default.createDirectory(at: AppPaths.demoOutput, withIntermediateDirectories: true)
        let session = SessionIdentity(
            path: AppPaths.demo.appendingPathComponent("My Song Mix v3.ptx").path,
            originID: "quickbounce-demo-origin",
            instanceID: "quickbounce-demo-instance",
            proToolsVersion: "2026.04",
            ptslVersion: "2026.4.0"
        )
        let names = [
            ("Mix v1 — Vocal Up +2dB", "Vocal stem snapshot"),
            ("Mix v2 — Bass Heavy", "Instrument sub focus"),
            ("Mix v3 — Radio Edit", "Clean lyrics edit"),
            ("Mix v4 — Instrumental", "Main backing track"),
            ("Mix v5 — TV Mix", "No vocal stem edit")
        ]
        let plans = names.enumerated().map { index, item in
            var states = demoTracks
            if index < states.count { states[index].isSolo = true }
            return BouncePlan(
                name: item.0,
                note: item.1,
                session: session,
                targetTrackStates: states,
                range: SampleRange(start: 0, end: Int64(48_000 * (50 + index * 8))),
                settings: BounceSettings(fileDestination: AppPaths.demoOutput.path),
                isEnabled: true
            )
        }
        for plan in plans { try await store.save(plan: plan) }

        let inspector = ArtifactInspector()
        let jobID = UUID()
        var artifacts: [AudioArtifact] = []
        for index in 0..<3 {
            let url = AppPaths.demoOutput.appendingPathComponent("Demo Review \(index + 1).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try makeWAV(
                    at: url,
                    frequency: 220 * Double(index + 1),
                    duration: 3 + Double(index)
                )
            }
            var artifact = AudioArtifact(
                jobID: jobID,
                planID: plans[index].id,
                name: url.lastPathComponent,
                path: url.path,
                kind: .wav,
                state: .candidate,
                metrics: AudioMetrics(
                    samplePeakDBFS: -3.4 - Double(index),
                    truePeakDBTP: -3.1 - Double(index),
                    integratedLUFS: -14.0 - Double(index),
                    maxMomentaryLUFS: -11.2 - Double(index)
                )
            )
            artifact = try await inspector.inspect(artifact)
            try await store.save(artifact: artifact)
            artifacts.append(artifact)
        }

        let movURL = AppPaths.demoOutput.appendingPathComponent("Demo Picture Review.mov")
        if !FileManager.default.fileExists(atPath: movURL.path) {
            try await makeMOV(at: movURL)
        }
        var mov = AudioArtifact(
            jobID: jobID,
            planID: plans[3].id,
            name: movURL.lastPathComponent,
            path: movURL.path,
            kind: .mov,
            state: .candidate
        )
        mov = try await inspector.inspect(mov)
        try await store.save(artifact: mov)
        artifacts.append(mov)
        return (plans, artifacts)
    }

    static let demoTracks: [TrackState] = [
        TrackState(track: TrackReference(id: "01", name: "Lead Vocal", index: 0, kind: "Audio"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "02", name: "Bass", index: 1, kind: "Audio"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "03", name: "Drums", index: 2, kind: "RoutingFolder"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "04", name: "Music", index: 3, kind: "Aux"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "05", name: "FX", index: 4, kind: "Aux"), isSolo: false, isMuted: false)
    ]

    private static func makeWAV(at url: URL, frequency: Double, duration: Double) throws {
        let sampleRate = 48_000
        let channelCount = 2
        let frameCount = Int(Double(sampleRate) * duration)
        let dataByteCount = frameCount * channelCount * 2
        var data = Data(capacity: 44 + dataByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * channelCount * 2))
        data.appendLittleEndian(UInt16(channelCount * 2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataByteCount))
        for frame in 0..<frameCount {
            let envelope = min(1, Double(frame) / 4_000) * min(1, Double(frameCount - frame) / 4_000)
            for channel in 0..<channelCount {
                let value = sin(2 * .pi * frequency * Double(channel + 1) * Double(frame) / Double(sampleRate))
                data.appendLittleEndian(Int16((value * envelope * 0.28 * Double(Int16.max)).rounded()))
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func makeMOV(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 960
        let height = 540
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw QuickBounceError.artifactInvalid("Unable to create demo MOV video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? QuickBounceError.artifactInvalid("Unable to start demo MOV writer")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<72 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw QuickBounceError.artifactInvalid("Unable to allocate demo MOV pixel pool")
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw QuickBounceError.artifactInvalid("Unable to allocate demo MOV frame")
            }
            fill(buffer: buffer, frame: frame)
            let time = CMTime(value: CMTimeValue(frame), timescale: 24)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? QuickBounceError.artifactInvalid("Unable to append demo MOV frame")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? QuickBounceError.artifactInvalid("Demo MOV writer did not complete")
        }
    }

    private static func fill(buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pulse = UInt8(60 + (frame * 3) % 150)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8(28 + (x * 80 / width))
                row[offset + 1] = UInt8(34 + (y * 80 / height))
                row[offset + 2] = pulse
                row[offset + 3] = 255
            }
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(contentsOf: value.utf8) }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
