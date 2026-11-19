import Foundation
import QuickBounceDomain

public typealias FakeExportWriter = @Sendable (
    _ request: ProToolsExportRequest,
    _ outputURL: URL
) async throws -> Void

public struct FakeProToolsTrace: Sendable {
    public var operations: [String] = []
    public var appliedStates: [[TrackState]] = []
    public var exportRequests: [ProToolsExportRequest] = []
    public var importRequests: [ImportAudioRequest] = []
    public var openedSessionURLs: [URL] = []
    public var saveCount = 0
    public var closeCount = 0
    public var cancelCount = 0
    public var trackReadCount = 0

    public init() {}
}

public actor FakeProToolsAdapter: ProToolsControlling {
    public enum InjectedFailure: Sendable, Equatable {
        case connect
        case apply
        case applyReadbackMismatch
        case export
        case restore
        case save
        case open
        case close
        case importAudio
        case hostReady
        case hostExitDuringExport
        case timelineRead
        case timelineWrite
        case timelineReadbackMismatch
        case timelineRollReadbackMismatch
    }

    private var sessionInfo: SessionInfo
    private var states: [TrackState]
    private var connected = false
    private var hasOpenSession = true
    private var activeExportCancelled = false
    private var failure: InjectedFailure?
    private var operationDelay: Duration
    private let initialStates: [TrackState]
    private var timelineState: TimelineState
    private let capabilities: PTSLCapabilities
    private let mixSources: [ProToolsMixSource]
    private let exportWriter: FakeExportWriter?
    private var callTrace = FakeProToolsTrace()

    public init(
        sessionInfo: SessionInfo = FakeProToolsAdapter.demoSession,
        trackStates: [TrackState] = FakeProToolsAdapter.demoTracks,
        operationDelay: Duration = .milliseconds(40),
        capabilities: PTSLCapabilities = .ptsl2026_04,
        mixSources: [ProToolsMixSource] = [
            ProToolsMixSource(type: .physicalOutput, name: "Output 1–2"),
            ProToolsMixSource(type: .bus, name: "Bus 1–2")
        ],
        exportWriter: FakeExportWriter? = nil
    ) {
        self.sessionInfo = sessionInfo
        self.states = trackStates
        self.initialStates = trackStates
        self.timelineState = .forBounce(SampleRange(start: 0, end: sessionInfo.lengthSamples))
        self.operationDelay = operationDelay
        self.capabilities = capabilities
        self.mixSources = mixSources
        self.exportWriter = exportWriter
    }

    public func injectFailure(_ failure: InjectedFailure?) {
        self.failure = failure
    }

    public func trace() -> FakeProToolsTrace { callTrace }

    public func resetTrace() { callTrace = FakeProToolsTrace() }

    public func connect() async throws -> ProToolsConnection {
        try failIfNeeded(.connect)
        connected = true
        return ProToolsConnection(
            status: hasOpenSession ? .connected : .connectedWithoutSession,
            connectionID: "fake-control",
            ptslVersion: "2026.4.0",
            capabilities: capabilities
        )
    }

    public func disconnect() async { connected = false }

    public func currentSessionInfo() async throws -> SessionInfo {
        guard connected, hasOpenSession else {
            throw QuickBounceError.connection("Fake adapter has no open Session")
        }
        return sessionInfo
    }

    public func trackStates() async throws -> [TrackState] {
        guard connected, hasOpenSession else {
            throw QuickBounceError.connection("Fake adapter has no open Session")
        }
        callTrace.trackReadCount += 1
        return states
    }

    public func currentTimelineSelection() async throws -> SampleRange {
        try failIfNeeded(.timelineRead)
        return timelineState.selection
    }

    public func setTimelineSelection(_ range: SampleRange) async throws {
        try await setTimelineState(.forBounce(range))
    }

    public func currentTimelineState() async throws -> TimelineState {
        try failIfNeeded(.timelineRead)
        return timelineState
    }

    public func setTimelineState(_ state: TimelineState) async throws {
        let range = state.selection
        try failIfNeeded(.timelineWrite)
        guard range.start >= 0, range.end >= range.start else {
            throw QuickBounceError.invalidPlan("Timeline Selection has invalid sample positions")
        }
        if failure == .timelineReadbackMismatch { return }
        timelineState = state
        if failure == .timelineRollReadbackMismatch {
            timelineState.preRollEnabled.toggle()
        }
    }

    public func exportMixSources() async throws -> [ProToolsMixSource] {
        mixSources
    }

    @discardableResult
    public func apply(trackStates: [TrackState]) async throws -> [TrackState] {
        if failure == .restore, trackStates == initialStates {
            throw QuickBounceError.restoreFailed("Injected restore failure")
        }
        if failure == .apply, trackStates != initialStates {
            throw QuickBounceError.exportFailed("Injected apply failure")
        }
        if failure == .applyReadbackMismatch, trackStates != initialStates {
            return states
        }
        try await Task.sleep(for: operationDelay)
        let resolved = try TrackStateResolver.resolve(expected: trackStates, against: states)
        states = resolved
        callTrace.appliedStates.append(resolved)
        callTrace.operations.append("apply")
        return states
    }

    public func exportMix(_ request: ProToolsExportRequest) async throws -> ProToolsExportResult {
        try failIfNeeded(.export)
        activeExportCancelled = false
        try await Task.sleep(for: operationDelay)
        if activeExportCancelled { throw QuickBounceError.exportCancelled }
        if failure == .hostExitDuringExport {
            connected = false
            hasOpenSession = false
            callTrace.exportRequests.append(request)
            callTrace.operations.append("host-exit-during-export")
            throw QuickBounceError.connection("Pro Tools exited during Export Mix")
        }
        callTrace.exportRequests.append(request)
        callTrace.operations.append("export:\(request.baseFileName)")
        let extensionName = request.kind.rawValue
        try FileManager.default.createDirectory(
            at: request.stagingDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = request.stagingDirectory
            .appendingPathComponent("\(request.baseFileName).\(extensionName)")
        if let exportWriter {
            try await exportWriter(request, outputURL)
        } else {
            switch request.kind {
            case .wav:
                try Self.makeTestWAV(for: request).write(to: outputURL, options: .atomic)
            case .mp3:
                // Direct-MP3 workflow tests provide an injected writer so the
                // production inspector receives a real MPEG Layer III file.
                try Self.makeTestWAV(for: request).write(to: outputURL, options: .atomic)
            case .mov:
                // MOV fixtures are provided by media tests.
                break
            }
        }
        return ProToolsExportResult(
            taskID: "fake-\(UUID().uuidString)",
            candidateURLs: [outputURL]
        )
    }

    public func cancelActiveExport() async {
        callTrace.cancelCount += 1
        callTrace.operations.append("cancel")
        activeExportCancelled = true
    }

    public func waitUntilReady() async throws {
        try failIfNeeded(.hostReady)
        try await Task.sleep(for: operationDelay)
        callTrace.operations.append("host-ready")
    }

    public func importAudio(_ request: ImportAudioRequest) async throws {
        try failIfNeeded(.importAudio)
        try await Task.sleep(for: operationDelay)
        callTrace.importRequests.append(request)
        callTrace.operations.append("import:\(request.fileURL.lastPathComponent)")
    }

    public func saveSession() async throws {
        try failIfNeeded(.save)
        try await Task.sleep(for: operationDelay)
        callTrace.saveCount += 1
        callTrace.operations.append("save")
    }

    public func closeSession() async throws {
        try failIfNeeded(.close)
        try await Task.sleep(for: operationDelay)
        callTrace.closeCount += 1
        callTrace.operations.append("close")
        hasOpenSession = false
    }

    public func openSession(at url: URL) async throws {
        try failIfNeeded(.open)
        try await Task.sleep(for: operationDelay)
        callTrace.openedSessionURLs.append(url.standardizedFileURL)
        callTrace.operations.append("open:\(url.standardizedFileURL.path)")
        sessionInfo.identity.path = url.path
        sessionInfo.identity.originID = "fake-origin:\(url.standardizedFileURL.path)"
        sessionInfo.identity.instanceID = UUID().uuidString
        sessionInfo.name = url.deletingPathExtension().lastPathComponent
        hasOpenSession = true
    }

    private func failIfNeeded(_ expected: InjectedFailure) throws {
        guard failure == expected else { return }
        if expected == .restore { throw QuickBounceError.restoreFailed("Injected restore failure") }
        if expected == .save { throw QuickBounceError.saveFailed("Injected save failure") }
        throw QuickBounceError.exportFailed("Injected \(String(describing: expected)) failure")
    }

    private static func makeTestWAV(for request: ProToolsExportRequest) -> Data {
        let outputRate = max(1, request.plan.settings.sampleRate)
        let sourceRate = max(1, request.plan.sourceSampleRate ?? outputRate)
        let sampleRate = UInt32(outputRate)
        let channelCount: UInt16 = request.plan.settings.fileLayout == .interleaved ? 2 : 1
        let requestedBits = request.plan.settings.bitDepth
        let bitsPerSample = UInt16([16, 24, 32].contains(requestedBits) ? requestedBits : 24)
        let duration: Double
        if request.plan.settings.padToFrameBoundary,
           let frameRate = request.plan.sourceTimeCodeRate {
            duration = frameRate.paddedDuration(
                for: request.plan.range,
                sampleRate: sourceRate
            )
        } else {
            duration = Double(request.plan.range.length) / Double(sourceRate)
        }
        let frameCount = max(1, Int((duration * Double(sampleRate)).rounded()))
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = frameCount * Int(channelCount) * bytesPerSample
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)

        var data = Data(capacity: 44 + dataByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataByteCount))

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
            let normalized = sin(phase) * 0.2
            for _ in 0..<channelCount {
                switch bitsPerSample {
                case 16:
                    data.appendLittleEndian(Int16((normalized * Double(Int16.max)).rounded()))
                case 24:
                    data.appendSignedInt24(Int32((normalized * 8_388_607).rounded()))
                default:
                    data.appendLittleEndian(Int32((normalized * Double(Int32.max)).rounded()))
                }
            }
        }
        return data
    }

    public static let demoTracks: [TrackState] = [
        TrackState(track: TrackReference(id: "01", name: "Lead Vocal", index: 0, kind: "Audio"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "02", name: "Bass", index: 1, kind: "Audio"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "03", name: "Drums", index: 2, kind: "RoutingFolder"), isSolo: false, isMuted: false),
        TrackState(track: TrackReference(id: "04", name: "Music", index: 3, kind: "Aux"), isSolo: false, isMuted: false)
    ]

    public static let demoSession: SessionInfo = {
        let identity = SessionIdentity(
            path: "/Demo/My Song Mix v3.ptx",
            originID: "demo-origin",
            instanceID: "demo-instance",
            proToolsVersion: "2026.04",
            ptslVersion: "2026.4.0"
        )
        return SessionInfo(
            identity: identity,
            name: "My Song Mix v3",
            sampleRate: 48_000,
            bitDepth: 24,
            fileFormat: "WAV",
            trackCount: demoTracks.count,
            lengthSamples: 48_000 * 272,
            timeCodeRate: .fps25
        )
    }()
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendSignedInt24(_ value: Int32) {
        let littleEndian = UInt32(bitPattern: value).littleEndian
        append(UInt8(littleEndian & 0xff))
        append(UInt8((littleEndian >> 8) & 0xff))
        append(UInt8((littleEndian >> 16) & 0xff))
    }
}
