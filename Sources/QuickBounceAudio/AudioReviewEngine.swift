@preconcurrency import AVFoundation
import Darwin
import Foundation
import QuickBounceAudioRealtime
import QuickBounceDomain

private final class RealtimeMeterBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<QBRealtimeMeter>

    init?() {
        guard let pointer = qb_meter_create() else { return nil }
        self.pointer = pointer
    }

    deinit {
        qb_meter_destroy(pointer)
    }
}

@MainActor
public final class AudioReviewEngine {
    private struct LoadedAsset {
        var artifact: AudioArtifact
        var file: AVAudioFile
        var player: AVAudioPlayerNode
        var bus: AVAudioNodeBus
    }

    private let engine = AVAudioEngine()
    private let programMixer = AVAudioMixerNode()
    private let meterBox: RealtimeMeterBox
    private var loaded: [UUID: LoadedAsset] = [:]
    private var startPositionSeconds: Double = 0
    private var startHostTime: UInt64?
    private var configurationObserver: NSObjectProtocol?
    private var isRecoveringConfiguration = false
    private let outputFormatOverride: AVAudioFormat?
    public private(set) var monitorChannelCount: Int = 2
    public private(set) var isDownmixing = false

    public private(set) var mode: ReviewMode = .mixCompare
    public private(set) var activeMixID: UUID?
    public private(set) var stemStates: [UUID: StemPlaybackState] = [:]
    public private(set) var isPlaying = false
    public private(set) var warnings: [String] = []

    public var monitorTrimDB: Float = 0 {
        didSet {
            engine.mainMixerNode.outputVolume = powf(10, monitorTrimDB / 20)
        }
    }

    public convenience init() { self.init(outputFormat: nil) }

    init(outputFormat: AVAudioFormat?) {
        self.outputFormatOverride = outputFormat
        guard let meterBox = RealtimeMeterBox() else {
            preconditionFailure("Unable to create realtime meter")
        }
        self.meterBox = meterBox
        engine.attach(programMixer)
        configureMonitorOutput()
        installMeterTap()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverFromAudioDeviceChange()
            }
        }
    }

    public func shutdown() {
        stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        programMixer.removeTap(onBus: 0)
        engine.stop()
    }

    /// Rebuilds scheduling after the default output device or audio format
    /// changes. The shared playback position and audible Mix/Stem state are
    /// retained; a failed restart is surfaced as a Review warning.
    func recoverFromAudioDeviceChange() {
        guard !isRecoveringConfiguration, !loaded.isEmpty else { return }
        isRecoveringConfiguration = true
        defer { isRecoveringConfiguration = false }

        let position = min(currentPositionSeconds, durationSeconds)
        let shouldResume = isPlaying
        for asset in loaded.values { asset.player.stop() }
        engine.stop()
        configureMonitorOutput(reinstallTap: true)
        startPositionSeconds = position
        startHostTime = nil
        isPlaying = false
        scheduleAll(from: position)

        guard shouldResume else { return }
        do {
            try play()
        } catch {
            warnings.append("Audio device changed; playback is paused: \(error.localizedDescription)")
        }
    }

    public func load(_ artifacts: [AudioArtifact], mode: ReviewMode) throws {
        // Rebuild only while the engine is stopped. Detaching player nodes from
        // a still-running engine can surface Core Audio's opaque AVFAudio
        // 2003334207 error when a Review-list item is removed.
        for asset in loaded.values { asset.player.stop() }
        engine.stop()
        startPositionSeconds = 0
        startHostTime = nil
        isPlaying = false
        for asset in loaded.values {
            engine.detach(asset.player)
        }
        loaded.removeAll()
        stemStates.removeAll()
        warnings.removeAll()
        self.mode = mode

        let audioArtifacts = artifacts.filter(\.canReviewAudio)
        var referenceRate: Double?
        for artifact in audioArtifacts {
            let file = try AVAudioFile(forReading: artifact.fileURL)
            if file.processingFormat.channelCount > 2, !AudioChannelLayoutInfo.hasKnownSpeakerPositions(file.processingFormat.channelLayout, count: Int(file.processingFormat.channelCount)) {
                let warning = "Unknown channel layout: playback unavailable. Waveform and peak analysis remain available."
                if !warnings.contains(warning) { warnings.append(warning) }
                continue
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let bus = programMixer.nextAvailableInputBus
            engine.connect(player, to: programMixer, fromBus: 0, toBus: bus, format: file.processingFormat)
            loaded[artifact.id] = LoadedAsset(artifact: artifact, file: file, player: player, bus: bus)
            stemStates[artifact.id] = StemPlaybackState(artifactID: artifact.id)
            if let referenceRate, abs(referenceRate - file.processingFormat.sampleRate) > 0.5 {
                warnings.append("Sample-rate mismatch: \(artifact.name)")
            } else if referenceRate == nil {
                referenceRate = file.processingFormat.sampleRate
            }
        }

        configureMonitorOutput(reinstallTap: true)
        activeMixID = audioArtifacts.first(where: { loaded[$0.id] != nil })?.id
        updateGains()
        scheduleAll(from: 0)
    }

    private func configureMonitorOutput(reinstallTap: Bool = false) {
        var format = outputFormatOverride ?? MonitorOutputFormat.current(output: engine.outputNode)
        if let current = format, current.channelCount > 2, loaded.values.contains(where: { MonitorChannelRouting.coefficients(input: $0.file.processingFormat, output: current) == nil }) {
            format = AVAudioFormat(standardFormatWithSampleRate: current.sampleRate, channels: 2)
        }
        monitorChannelCount = Int(format?.channelCount ?? 2)
        isDownmixing = loaded.values.contains { Int($0.file.processingFormat.channelCount) > monitorChannelCount }
        if reinstallTap, let format, programMixer.outputFormat(forBus: 0).isEqual(format) { return }
        if reinstallTap { programMixer.removeTap(onBus: 0) }
        engine.connect(programMixer, to: engine.mainMixerNode, format: format)
        if let format { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format) }
        if reinstallTap { installMeterTap() }
    }

    // Exercise exactly the playback graph without depending on a physical
    // surround interface or sending test tones to the user's speakers.
    func renderOffline(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard outputFormatOverride != nil else { throw QuickBounceError.invalidPlan("Offline output format missing") }
        let format = programMixer.outputFormat(forBus: 0)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCount)
        scheduleAll(from: 0)
        try engine.start()
        try configureChannelRouting()
        for asset in loaded.values { asset.player.play() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        let status = try engine.renderOffline(frameCount, to: output)
        guard status == .success else { throw QuickBounceError.artifactInvalid("Offline render failed: \(status)") }
        return output
    }

    private func configureChannelRouting() throws {
        let output = programMixer.outputFormat(forBus: 0)
        for asset in loaded.values {
            if monitorChannelCount == 2, asset.file.processingFormat.channelCount > 2 {
                try StereoDownmix.apply(to: programMixer, bus: asset.bus, input: asset.file.processingFormat)
            } else if monitorChannelCount > 2,
                      let matrix = MonitorChannelRouting.coefficients(input: asset.file.processingFormat, output: output) {
                try StereoDownmix.apply(matrix: matrix, to: programMixer, bus: asset.bus)
            }
        }
    }

    public func selectMix(_ id: UUID) {
        guard loaded[id] != nil else { return }
        activeMixID = id
        if mode == .mixCompare, currentPositionSeconds >= durationSeconds { stop() }
        updateGains()
    }

    public func setStemState(_ state: StemPlaybackState) {
        guard loaded[state.artifactID] != nil else { return }
        stemStates[state.artifactID] = state
        updateGains()
    }

    public func play() throws {
        guard !loaded.isEmpty else { return }
        if !engine.isRunning {
            try engine.start()
            do { try configureChannelRouting() }
            catch { engine.stop(); throw error }
        }
        let commonStart = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.04))
        for asset in loaded.values {
            asset.player.play(at: commonStart)
        }
        startHostTime = commonStart.hostTime
        isPlaying = true
    }

    public func pause() {
        let position = currentPositionSeconds
        for asset in loaded.values { asset.player.pause() }
        startPositionSeconds = position
        startHostTime = nil
        isPlaying = false
    }

    public func stop() {
        for asset in loaded.values { asset.player.stop() }
        startPositionSeconds = 0
        startHostTime = nil
        isPlaying = false
        scheduleAll(from: 0)
    }

    public func seek(to seconds: Double) throws {
        let wasPlaying = isPlaying
        for asset in loaded.values { asset.player.stop() }
        startPositionSeconds = min(durationSeconds, max(0, seconds))
        startHostTime = nil
        scheduleAll(from: startPositionSeconds)
        if wasPlaying { try play() }
    }

    public var currentPositionSeconds: Double {
        guard isPlaying, let startHostTime else { return startPositionSeconds }
        let now = mach_absolute_time()
        // Players share a host time slightly in the future so every Mix/Stem
        // starts sample-aligned. UI polling can occur before that time arrives;
        // avoid an unsigned subtraction trap during that short lead-in.
        guard now >= startHostTime else { return startPositionSeconds }
        let elapsed = AVAudioTime.seconds(forHostTime: now - startHostTime)
        return startPositionSeconds + elapsed
    }

    public var durationSeconds: Double {
        if mode == .mixCompare, let id = activeMixID, let asset = loaded[id] {
            return Double(asset.file.length) / asset.file.processingFormat.sampleRate
        }
        return loaded.values.map { Double($0.file.length) / $0.file.processingFormat.sampleRate }.max() ?? 0
    }

    public func meterReading() -> ProgramMeterReading {
        var peakLeft: Float = 0
        var peakRight: Float = 0
        var rmsLeft: Float = 0
        var rmsRight: Float = 0
        qb_meter_load(meterBox.pointer, &peakLeft, &peakRight, &rmsLeft, &rmsRight)
        return ProgramMeterReading(
            peakLeft: peakLeft,
            peakRight: peakRight,
            rmsLeft: rmsLeft,
            rmsRight: rmsRight
        )
    }

    public var audibleArtifactIDs: Set<UUID> {
        switch mode {
        case .mixCompare:
            return activeMixID.map { [$0] } ?? []
        case .stemsCheck:
            let hasSolo = stemStates.values.contains(where: \.isSolo)
            return Set(loaded.keys.filter { id in
                let state = stemStates[id] ?? StemPlaybackState(artifactID: id)
                return !state.isMuted && (!hasSolo || state.isSolo)
            })
        }
    }

    private func scheduleAll(from seconds: Double) {
        for asset in loaded.values {
            let sampleRate = asset.file.processingFormat.sampleRate
            let startFrame = max(0, min(asset.file.length, AVAudioFramePosition(seconds * sampleRate)))
            let remaining = max(0, asset.file.length - startFrame)
            guard remaining > 0 else { continue }
            asset.player.scheduleSegment(
                asset.file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(min(Int64(UInt32.max), remaining)),
                at: nil
            )
        }
    }

    private func updateGains() {
        switch mode {
        case .mixCompare:
            for (id, asset) in loaded {
                asset.player.volume = id == activeMixID ? 1 : 0
            }
        case .stemsCheck:
            let hasSolo = stemStates.values.contains(where: \.isSolo)
            for (id, asset) in loaded {
                let state = stemStates[id] ?? StemPlaybackState(artifactID: id)
                asset.player.volume = (!state.isMuted && (!hasSolo || state.isSolo)) ? 1 : 0
            }
        }
    }

    private func installMeterTap() {
        let meterBox = meterBox
        // AVAudioEngine invokes tap blocks on its realtime queue. Without an
        // explicit @Sendable context Swift 6 inherits this @MainActor method's
        // isolation for the closure and traps as soon as playback begins.
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)

            func measure(_ channel: Int) -> (peak: Float, rms: Float) {
                guard channel < channelCount else { return (0, 0) }
                var peak: Float = 0
                var squares: Float = 0
                let samples = channelData[channel]
                for frame in 0..<frameCount {
                    let value = samples[frame]
                    peak = max(peak, abs(value))
                    squares += value * value
                }
                return (peak, sqrtf(squares / Float(frameCount)))
            }

            var left = measure(0)
            var right = measure(channelCount > 1 ? 1 : 0)
            if channelCount > 2 {
                for channel in 1..<channelCount {
                    let value = measure(channel)
                    left = (max(left.peak, value.peak), max(left.rms, value.rms))
                }
                right = left
            }
            qb_meter_store(meterBox.pointer, left.peak, right.peak, left.rms, right.rms)
        }
        programMixer.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: tapBlock)
    }
}
