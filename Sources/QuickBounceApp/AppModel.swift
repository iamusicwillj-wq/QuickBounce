@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import QuickBounceApplication
import QuickBounceAudio
import QuickBounceDomain
import QuickBouncePersistence
import QuickBounceProTools
import UniformTypeIdentifiers

private final class ReviewKeyboardMonitorToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    deinit { NSEvent.removeMonitor(value) }
}

struct CompatibilityNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    typealias MixCapture = ProToolsMixCapture

    struct OverwriteConfirmation: Identifiable {
        let id = UUID()
        var plans: [BouncePlan]
        var crossSession: Bool
        var collisions: [ExistingOutputCollision]
    }

    struct RecoveryDiscardConfirmation: Identifiable {
        let id = UUID()
        var snapshotIDs: [UUID]
        var sessionNames: [String]
    }

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var connectionDetail = "Connecting to Pro Tools…"
    @Published private(set) var connectionCapabilities: PTSLCapabilities?
    @Published var sessionInfo: SessionInfo?
    @Published var mixNamePrefix = ""
    @Published var mixNameSuffix = ""
    @Published var presetLibrary = BouncePresetLibrary()
    @Published var capturePresetID: UUID?
    @Published var isPresentingPresets = false
    @Published var isPresentingNewPreset = false
    @Published var isPresentingSessionSettingsHistory = false
    @Published var sessionSettingsSaveDraft: SessionSettingsSaveDraft?
    @Published private(set) var sessionSettingsHistory: [SessionSettingsLibrary.Entry] = []
    let sessionSettingsLibrary: SessionSettingsLibrary
    @Published private(set) var sessionSettingsNames: [String: String] = [:]
    @Published private(set) var isManagingSettings = false
    @Published var plans: [BouncePlan] = []
    @Published var selectedPlanIDs: Set<UUID> = []
    @Published var artifacts: [AudioArtifact] = []
    @Published var selectedArtifactIDs: Set<UUID> = []
    @Published var waveforms: [UUID: WaveformPyramid] = [:]
    @Published private(set) var analysisErrors: [UUID: String] = [:]
    @Published var reviewDecisions: [UUID: ReviewDecision] = [:]
    @Published var reviewMode: ReviewMode = .mixCompare
    @Published var job: BounceJob?
    @Published var events: [JobEvent] = []
    @Published var batchDestinations: [URL] = []
    @Published var isPreparingMix = false
    @Published var isPresentingAddMix = false
    @Published var isLoadingWaveforms = false
    @Published var errorMessage: String? {
        didSet {
            guard let errorMessage, errorMessage != oldValue else { return }
            let diagnostics = diagnostics
            Task { await diagnostics?.record(category: "user_interface", action: "error_presented",
                fields: ["error": errorMessage]) }
        }
    }
    @Published var statusMessage = "Starting QuickBounce…"
    @Published var isPlaying = false
    let playbackClock = ReviewPlaybackClock()
    let reviewMeter = ReviewMeterState()
    var playbackPosition: Double { playbackClock.sample.position }
    @Published var playbackDuration: Double = 0
    @Published var monitorChannelCount = 2
    @Published var monitorDownmix = false
    @Published var monitorWarnings: [String] = []
    @Published var monitorTrimDB: Float = 0
    @Published var waveformZoom: Double = 1
    @Published var waveformScroll: Double = 0
    @Published var stemStates: [UUID: StemPlaybackState] = [:]
    @Published var activeMixID: UUID?
    @Published var pendingRecoverySnapshots: [SessionSnapshot] = []
    @Published var isRecoveringSessionState = false
    @Published var isDiscardingRecoveryRecord = false
    @Published var isPreparingBounce = false
    @Published var editingPlanID: UUID?
    @Published var overwriteConfirmation: OverwriteConfirmation?
    @Published var compatibilityNotice: CompatibilityNotice?
    @Published var recoveryDiscardConfirmation: RecoveryDiscardConfirmation?
    @Published private(set) var checkedMixID: UUID?
    @Published private(set) var isCheckingMix = false
    @Published private(set) var isExportingDiagnosticLog = false
    @Published private(set) var mixSourcesBySession: [String: [ProToolsMixSource]] = [:]
    @Published private(set) var isReviewExpanded = false
    @Published private(set) var isKeepOnTopMode = false
    @Published private(set) var addMixShortcut = AddMixShortcutStore.loadRespectingExplicitClear()
    @Published private(set) var isAddMixShortcutActive = false

    let moviePlayer = AVPlayer()
    private var moviePreviewID: UUID?

    private var store: SQLiteStore?
    private var diagnostics: DiagnosticLogger?
    private var proTools: RealProToolsAdapter?
    private var coordinator: BounceCoordinator?
    private var reviewEngine: AudioReviewEngine?
    private var waveformCache: WaveformCache?
    private var reviewAnalysis: ReviewAnalysisService?
    private var captureTask: Task<MixCapture, Error>?
    private var captureRunID: UUID?
    private var mixCheckSnapshot: MixCheckSessionState?
    private var mixCheckTask: Task<Void, Never>?
    private var didPresentCompatibilityNotice = false
    private var coordinatorObservation: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var analysisRunID: UUID?
    private var pendingAnalysisIDs: [UUID] = []
    private var scheduledAnalysisIDs: Set<UUID> = []
    private var reviewKeyboardMonitor: ReviewKeyboardMonitorToken?
    private let workspaceWindowController = WorkspaceWindowController()
    private var globalHotKeyController: GlobalHotKeyController?
    private var reviewAutoExpansionPolicy = ReviewPaneAutoExpansionPolicy()
    private var lastHandledTerminalJobID: UUID?
    private var selectionAnchor: UUID?
    private var artifactSelectionAnchor: UUID?
    private let demoMode: Bool
    private let demoStartsWithMOV: Bool
    private let demoStartsInStemsMode: Bool
    private let demoStartsZoomed: Bool

    private(set) var defaultSettings = BounceSettings(
        fileDestination: AppPaths.defaultBounceOutput.path
    )

    init(initializeServices: Bool = true, sessionSettingsDirectory: URL? = nil) {
        let arguments = ProcessInfo.processInfo.arguments
        demoMode = arguments.contains("--demo")
        demoStartsWithMOV = arguments.contains("--demo-mov")
        demoStartsInStemsMode = arguments.contains("--demo-stems")
        demoStartsZoomed = arguments.contains("--demo-zoomed")
        sessionSettingsLibrary = SessionSettingsLibrary(directory: sessionSettingsDirectory ?? (demoMode
            ? AppPaths.demo.appendingPathComponent("Session Settings", isDirectory: true) : AppPaths.sessionSettings))
        guard initializeServices else { return }
        refreshSessionSettingsHistory()
        do {
            let launchPreparation = try AppPaths.prepareForLaunch(demoMode: demoMode)
            let store = try SQLiteStore(url: demoMode ? AppPaths.demoDatabase : AppPaths.database)
            try AppPaths.finalizeLegacyData(launchPreparation)
            let bundle = Bundle.main
            let diagnosticConfiguration = DiagnosticLogConfiguration(
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development",
                appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "development"
            )
            let diagnostics = try? DiagnosticLogger(
                directory: AppPaths.diagnostics,
                configuration: diagnosticConfiguration
            )
            self.store = store
            self.diagnostics = diagnostics
            self.reviewEngine = AudioReviewEngine()
            do {
                self.waveformCache = try WaveformCache(directory: AppPaths.waveforms)
            } catch {
                // Cache availability must not prevent connecting or bouncing.
                let message = error.localizedDescription
                Task { await diagnostics?.record(category: "review_analysis",
                    action: "waveform_cache_unavailable", fields: ["error": message]) }
            }
            self.reviewAnalysis = ReviewAnalysisService(cache: self.waveformCache, diagnostics: diagnostics)
            if demoMode {
                self.proTools = nil
                self.coordinator = nil
            } else {
                let proTools = RealProToolsAdapter(diagnostics: diagnostics)
                let coordinator = try BounceCoordinator(
                    proTools: proTools,
                    store: store,
                    workDirectory: AppPaths.staging,
                    diagnostics: diagnostics
                )
                self.proTools = proTools
                self.coordinator = coordinator
                observe(coordinator)
            }
            startMeterUpdates()
            installReviewKeyboardMonitor()
            if let diagnostics {
                Task { await diagnostics.recordLaunch() }
            }
            Task { await bootstrap() }
        } catch {
            errorMessage = error.localizedDescription
            connectionDetail = "QuickBounce could not initialize"
            statusMessage = "Initialization failed"
        }
    }

    deinit {
        captureTask?.cancel()
        mixCheckTask?.cancel()
        coordinatorObservation?.cancel()
        meterTask?.cancel()
        analysisTask?.cancel()
    }

    var isCrossSessionQueue: Bool {
        Set(plans.map { canonicalSessionPath($0.session.path) }).count > 1
    }

    var isBusy: Bool {
        guard let job else { return false }
        return !job.state.isTerminal && job.state != .draft
    }

    var isMixCheckActive: Bool { checkedMixID != nil || isCheckingMix }

    var isReviewPaneVisible: Bool { isReviewExpanded && !isKeepOnTopMode }

    var canExportDiagnosticLog: Bool {
        diagnostics != nil && !isExportingDiagnosticLog && !isBusy
            && !isPreparingMix && !isPreparingBounce && !isCheckingMix
    }

    /// User-facing limitations for the currently queued work.  A missing
    /// capability object means that no Host has been negotiated yet, so the
    /// picker remains usable while the connection is being established.
    var unsupportedBounceFeatures: [String] {
        guard let capabilities = connectionCapabilities else { return [] }
        var features: [String] = []
        if isCrossSessionQueue && !capabilities.openSessionBehaviorOptions {
            features.append("Cross-Session Bounce")
        }
        if plans.contains(where: { $0.settings.exportType == .mp3 }) &&
           !capabilities.audioEncodingOptions {
            features.append("MP3-only export")
        }
        return features
    }

    func isExportTypeAvailable(_ type: ExportType) -> Bool {
        guard let capabilities = connectionCapabilities else { return true }
        // WAV + MP3 uses a single WAV Bounce followed by local MP3 encoding,
        // so it remains available on Hosts that predate direct MP3 options.
        if type == .mp3 && !capabilities.audioEncodingOptions { return false }
        return true
    }

    var canCancel: Bool {
        guard let job else { return false }
        return isBusy && job.state != .importing && !job.cancellationRequested
    }

    var canBounce: Bool {
        !demoMode && connectionStatus == .connected && !plans.isEmpty && !isBusy
            && !isCheckingMix
            && !queueHasPendingRecovery && !isRecoveringSessionState
            && !isDiscardingRecoveryRecord && !isManagingSettings && !isPresentingPresets && !isPresentingNewPreset && sessionSettingsSaveDraft == nil && !isPresentingSessionSettingsHistory
            && !isPreparingBounce && overwriteConfirmation == nil
            && unsupportedBounceFeatures.isEmpty
    }

    var canAddMix: Bool {
        !demoMode && connectionStatus == .connected && !isBusy
            && !isPreparingMix && !isPresentingAddMix
            && !isMixCheckActive
            && !currentSessionHasPendingRecovery && !isRecoveringSessionState
            && !isDiscardingRecoveryRecord && !isManagingSettings && !isPresentingPresets && !isPresentingNewPreset && sessionSettingsSaveDraft == nil && !isPresentingSessionSettingsHistory
            && !isPreparingBounce && overwriteConfirmation == nil
    }

    var hasPendingRecovery: Bool { !pendingRecoverySnapshots.isEmpty }

    var currentSessionHasPendingRecovery: Bool {
        guard let sessionInfo else { return false }
        let currentPath = canonicalSessionPath(sessionInfo.identity.path)
        return pendingRecoverySnapshots.contains {
            canonicalSessionPath($0.session.path) == currentPath
        }
    }

    var canRecoverCurrentSession: Bool {
        guard let sessionInfo else { return false }
        let currentPath = canonicalSessionPath(sessionInfo.identity.path)
        return pendingRecoverySnapshots.contains {
            canonicalSessionPath($0.session.path) == currentPath
                && $0.session.instanceID == sessionInfo.identity.instanceID
        }
    }

    private var queueHasPendingRecovery: Bool {
        let pendingPaths = Set(pendingRecoverySnapshots.map {
            canonicalSessionPath($0.session.path)
        })
        return plans.contains { pendingPaths.contains(canonicalSessionPath($0.session.path)) }
    }

    var recoveryDiscardMessage: String {
        guard let confirmation = recoveryDiscardConfirmation else { return "" }
        let names = confirmation.sessionNames.joined(separator: ", ")
        return "Discard the recovery record for \(names)?\n\nThis removes only QuickBounce's recovery metadata. It does not open, modify, save, or delete any Pro Tools Session. Any Solo/Mute state left in that old Session will not be restored automatically."
    }

    var isQueueLocked: Bool {
        isBusy || isManagingSettings || isPreparingBounce || overwriteConfirmation != nil
    }

    var canHandleReviewSpacebar: Bool {
        !isBusy && editingPlanID == nil && !isPresentingAddMix
            && (!selectedAudioArtifacts.isEmpty || reviewedMOV != nil)
    }

    var overwriteConfirmationMessage: String {
        guard let confirmation = overwriteConfirmation else { return "" }
        let paths = confirmation.collisions.map(\.fileURL.path)
        if paths.count == 1, let path = paths.first {
            return "A bounced file already exists:\n\(path)\n\nDo you want to overwrite it?"
        }
        let visible = paths.prefix(5).joined(separator: "\n")
        let remaining = max(0, paths.count - 5)
        let suffix = remaining > 0 ? "\n…and \(remaining) more" : ""
        return "\(paths.count) bounced files already exist:\n\(visible)\(suffix)\n\nDo you want to overwrite them?"
    }

    var selectedPlans: [BouncePlan] {
        plans.filter { selectedPlanIDs.contains($0.id) }
    }

    var selectedSettings: BounceSettings {
        selectedPlans.first?.settings ?? plans.first?.settings ?? defaultSettings
    }

    var selectedBouncePreset: BounceSettingsPreset? {
        guard let id = selectedPlans.first?.bouncePresetID,
              selectedPlans.allSatisfy({ $0.bouncePresetID == id }) else { return nil }
        return presetLibrary.presets.first { $0.id == id }
    }

    var bouncePresetTitle: String {
        selectedBouncePreset?.name ?? L("Bounce Settings Presets")
    }

    var sessionSettingsTitle: String {
        let paths = Set(selectedPlans.map { canonicalSessionPath($0.session.path) })
        if paths.count > 1 { return L("Session Settings") }
        guard let path = paths.first ?? sessionInfo.map({ canonicalSessionPath($0.identity.path) }) else {
            return L("Session Settings")
        }
        return sessionSettingsNames[path] ?? L("Session Settings")
    }

    private func rememberSessionSettings(_ entry: SessionSettingsLibrary.Entry, for session: SessionIdentity) {
        sessionSettingsNames[canonicalSessionPath(session.path)] = entry.name
    }

    var selectedArtifacts: [AudioArtifact] {
        artifacts.filter { selectedArtifactIDs.contains($0.id) }
    }

    var reviewedMOV: AudioArtifact? {
        guard isReviewPaneVisible, !isBusy, selectedAudioArtifacts.isEmpty else { return nil }
        let movies = selectedArtifacts.filter(\.canPreviewVideo)
        return movies.first { $0.id == artifactSelectionAnchor } ?? movies.first
    }

    var selectedAudioArtifacts: [AudioArtifact] {
        selectedArtifacts.filter(\.canReviewAudio)
    }

    var latestEventMessage: String? { events.last?.message }

    var progressLabel: String {
        guard let job else { return "Ready to bounce \(plans.count) mixes" }
        switch job.state {
        case .reviewReady:
            return "Bounced \(job.completedPlanCount) of \(job.totalPlanCount) mixes"
        case .cancelled:
            return "Cancelled — \(job.completedPlanCount) completed"
        case .failed:
            return "Stopped — \(job.completedPlanCount) completed"
        case .recoveryRequired:
            return "Recovery required — do not change Session state"
        default:
            return latestEventMessage ?? "Processing \(job.completedPlanCount + 1) of \(job.totalPlanCount)"
        }
    }

    var progress: Double { job?.progress ?? 0 }

    var waveformViewportDuration: Double {
        guard playbackDuration > 0 else { return 0 }
        return playbackDuration / max(1, waveformZoom)
    }

    var waveformViewportStart: Double {
        let available = max(0, playbackDuration - waveformViewportDuration)
        return available * min(1, max(0, waveformScroll))
    }

    func attachWorkspaceWindow(_ window: NSWindow) {
        workspaceWindowController.attach(
            window: window,
            reviewExpanded: isReviewExpanded,
            keepOnTop: isKeepOnTopMode
        )
        updateMoviePreview()
    }

    func detachWorkspaceWindow(_ window: NSWindow) {
        moviePlayer.pause()
        if isKeepOnTopMode {
            globalHotKeyController?.unregister()
            isAddMixShortcutActive = false
            isKeepOnTopMode = false
        }
        workspaceWindowController.detach(window: window)
    }

    func toggleReviewPane() {
        guard !isKeepOnTopMode else { return }
        setReviewExpanded(!isReviewExpanded)
    }

    func toggleKeepOnTopMode() {
        setKeepOnTopMode(!isKeepOnTopMode)
    }

    func setKeepOnTopMode(_ enabled: Bool) {
        guard enabled != isKeepOnTopMode else { return }
        isKeepOnTopMode = enabled
        updateMoviePreview()
        workspaceWindowController.apply(
            reviewExpanded: isReviewExpanded,
            keepOnTop: enabled
        )

        if enabled {
            do {
                try activateAddMixShortcut()
                if let addMixShortcut {
                    statusMessage = "Keep on Top enabled — Add Mix: \(addMixShortcut.displayName)"
                } else {
                    statusMessage = "Keep on Top enabled — set an Add Mix shortcut from the keyboard button"
                }
            } catch {
                isAddMixShortcutActive = false
                present(error)
            }
        } else {
            globalHotKeyController?.unregister()
            isAddMixShortcutActive = false
            statusMessage = "Keep on Top disabled"
        }
    }

    func updateAddMixShortcut(_ shortcut: AddMixShortcut?) {
        let previous = addMixShortcut
        if isKeepOnTopMode {
            do {
                try registerAddMixShortcut(shortcut)
            } catch {
                if let previous {
                    try? registerAddMixShortcut(previous)
                } else {
                    globalHotKeyController?.unregister()
                    isAddMixShortcutActive = false
                }
                present(error)
                return
            }
        }
        addMixShortcut = shortcut
        AddMixShortcutStore.save(shortcut)
        if let shortcut {
            statusMessage = isKeepOnTopMode
                ? "Add Mix shortcut active: \(shortcut.displayName)"
                : "Add Mix shortcut set to \(shortcut.displayName); it activates in Keep on Top mode"
        } else {
            statusMessage = "Add Mix shortcut cleared"
        }
    }

    func restoreDefaultAddMixShortcut() {
        updateAddMixShortcut(.defaultValue)
    }

    private func setReviewExpanded(_ expanded: Bool) {
        guard expanded != isReviewExpanded else { return }
        isReviewExpanded = expanded
        updateMoviePreview()
        workspaceWindowController.apply(
            reviewExpanded: expanded,
            keepOnTop: isKeepOnTopMode
        )
    }

    private func showCompletedBounceReview() {
        // Apply the final window state together to avoid two resize animations.
        globalHotKeyController?.unregister()
        isAddMixShortcutActive = false
        isKeepOnTopMode = false
        isReviewExpanded = true
        updateMoviePreview()
        workspaceWindowController.apply(reviewExpanded: true, keepOnTop: false)
        workspaceWindowController.activateAndFocus()
    }

    private func activateAddMixShortcut() throws {
        try registerAddMixShortcut(addMixShortcut)
    }

    private func registerAddMixShortcut(_ shortcut: AddMixShortcut?) throws {
        guard let shortcut else {
            globalHotKeyController?.unregister()
            isAddMixShortcutActive = false
            return
        }
        if globalHotKeyController == nil {
            globalHotKeyController = try GlobalHotKeyController()
        }
        try globalHotKeyController?.register(shortcut: shortcut) { [weak self] in
            self?.handleGlobalAddMixShortcut()
        }
        isAddMixShortcutActive = true
    }

    private func handleGlobalAddMixShortcut() {
        guard isKeepOnTopMode else { return }
        workspaceWindowController.activateAndFocus()
        guard canAddMix else {
            NSSound.beep()
            statusMessage = "Add Mix is not available right now"
            return
        }
        beginMixCapture()
    }

    func bootstrap() async {
        guard let store else { return }
        do {
            presetLibrary = try await store.loadPresetLibrary()
            if demoMode {
                let seeded = try await DemoContent.seedIfNeeded(store: store)
                plans = seeded.plans
                artifacts = seeded.artifacts
                reviewDecisions = Dictionary(
                    uniqueKeysWithValues: (try await store.loadReviewDecisions()).map { ($0.artifactID, $0) }
                )
                selectedPlanIDs = Set(plans.prefix(1).map(\.id))
                if let first = plans.first {
                    defaultSettings = first.settings
                    sessionInfo = SessionInfo(
                        identity: first.session,
                        name: "Demo Review",
                        sampleRate: first.settings.sampleRate,
                        bitDepth: first.settings.bitDepth,
                        fileFormat: "WAV",
                        trackCount: first.targetTrackStates.count,
                        lengthSamples: first.range.end
                    )
                }
                connectionStatus = .connected
                connectionDetail = "Demo Review Mode"
                statusMessage = "Review controls are live; Pro Tools writes are disabled"
                reviewMode = demoStartsInStemsMode ? .stemsCheck : .mixCompare
                if demoStartsWithMOV,
                   let movie = artifacts.first(where: \.canPreviewVideo) {
                    selectedArtifactIDs = [movie.id]
                    activeMixID = nil
                    setReviewExpanded(true)
                } else {
                    selectInitialArtifacts()
                }
                if demoStartsZoomed {
                    waveformZoom = 8
                    waveformScroll = 0.5
                }
                reloadReviewGraph()
                analyzeCompletedAudio()
                return
            }
            try await store.clearTransientWorkspace()
            try? await waveformCache?.removeAll()
            sessionInfo = nil
            connectionCapabilities = nil
            plans = []
            selectedPlanIDs = []
            artifacts = []
            reviewDecisions = [:]
            selectedArtifactIDs = []
            waveforms = [:]
            job = nil
            events = []
            batchDestinations = []
            mixSourcesBySession = [:]
            editingPlanID = nil
            overwriteConfirmation = nil
            compatibilityNotice = nil
            recoveryDiscardConfirmation = nil
            checkedMixID = nil
            mixCheckSnapshot = nil
            isCheckingMix = false
            isDiscardingRecoveryRecord = false
            artifactSelectionAnchor = nil
            defaultSettings = BounceSettings(
                fileDestination: AppPaths.defaultBounceOutput.path
            )
            pendingRecoverySnapshots = try await store.pendingSnapshots()
            await connect()
            reloadReviewGraph()
            analyzeCompletedAudio()
        } catch {
            present(error)
        }
    }

    func connect() async {
        if demoMode {
            connectionStatus = .connected
            connectionDetail = "Demo Review Mode"
            return
        }
        guard let proTools else { return }
        connectionDetail = "Connecting to Pro Tools…"
        do {
            let connection = try await proTools.connect()
            connectionCapabilities = connection.capabilities
            connectionStatus = connection.status
            // Show the one-time compatibility notice as soon as the Host is
            // negotiated, even when Pro Tools currently has no Session open.
            presentCompatibilityNoticeIfNeeded(for: connection)
            do {
                let info = try await proTools.currentSessionInfo()
                sessionInfo = info
                connectionStatus = .connected
                connectionDetail = "Connected to Pro Tools"
                statusMessage = "Connected to \(info.name)"
                do {
                    cacheMixSources(
                        try await proTools.exportMixSources(),
                        for: info.identity
                    )
                } catch {
                    mixSourcesBySession[canonicalSessionPath(info.identity.path)] = []
                    errorMessage = "Could not read Bounce Sources from \(info.name): \(error.localizedDescription)"
                }
                if plans.isEmpty {
                    defaultSettings.sampleRate = info.sampleRate
                    defaultSettings.bitDepth = info.bitDepth
                    defaultSettings.fileDestination = URL(fileURLWithPath: info.identity.path)
                        .deletingLastPathComponent()
                        .appendingPathComponent("Bounced Files", isDirectory: true)
                        .path
                }
                await refreshRecoveryStatus()
            } catch {
                sessionInfo = nil
                connectionStatus = .connectedWithoutSession
                connectionDetail = "Connected, but no Session is open"
                statusMessage = "Open a Pro Tools Session to add a Mix"
                await refreshRecoveryStatus()
            }
        } catch {
            connectionStatus = .disconnected
            sessionInfo = nil
            connectionCapabilities = nil
            connectionDetail = "Disconnected"
            statusMessage = "Launch Pro Tools and enable PTSL"
            if let transportError = error as? PTSLTransportError,
               transportError.indicatesProToolsIsNotAvailable {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportDiagnosticLog() {
        guard let diagnostics, !isExportingDiagnosticLog else { return }
        let panel = NSSavePanel()
        panel.title = L("Export Diagnostic Log")
        panel.prompt = L("Export")
        panel.message = L("The ZIP is anonymized and contains no audio, Session files, or QuickBounce database.")
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "QuickBounce Diagnostic Log \(formatter.string(from: Date())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExportingDiagnosticLog = true
        statusMessage = "Exporting anonymized diagnostic log…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isExportingDiagnosticLog = false }
            do {
                await diagnostics.record(
                    category: "diagnostics",
                    action: "export_requested"
                )
                let exported = try await diagnostics.export(to: destination)
                self.statusMessage = "Diagnostic log exported"
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } catch {
                self.present(error)
            }
        }
    }

    func beginMixCapture() {
        guard connectionStatus == .connected, !isMixCheckActive, let proTools else {
            errorMessage = "Open a Pro Tools Session before adding a Mix."
            return
        }
        capturePresetID = presetLibrary.defaultPresetID
        captureTask?.cancel()
        let runID = UUID()
        captureRunID = runID
        isPreparingMix = true
        let task = Task {
            try await proTools.captureMix()
        }
        captureTask = task
        Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await task.value
                guard self.captureRunID == runID else { return }
                self.refreshSessionContext(using: capture)
            } catch {
                // commitMix presents capture errors in the Add Mix workflow.
            }
        }
        isPresentingAddMix = true
    }

    func cancelMixCapture() {
        captureTask?.cancel()
        captureTask = nil
        captureRunID = nil
        isPreparingMix = false
        isPresentingAddMix = false
    }

    func commitMix(name: String, note: String) async -> Bool {
        guard let captureTask, let store else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Mix name cannot be empty."
            return false
        }
        do {
            let capture = try await captureTask.value
            refreshSessionContext(using: capture)
            guard capture.range.isValid else {
                throw QuickBounceError.invalidPlan("Choose a non-empty Pro Tools Timeline Selection")
            }
            let templatePlan = selectedPlans.first ?? plans.last
            let preset = presetLibrary.presets.first { $0.id == capturePresetID }
            var settings = templatePlan?.settings ?? defaultSettings
            if let preset {
                settings = preset.applying(to: settings)
                guard isExportTypeAvailable(settings.exportType) else {
                    throw QuickBounceError.invalidPlan("This preset's export format is unavailable in this Pro Tools version. Choose another preset.")
                }
            } else {
                settings.sampleRate = capture.session.sampleRate
                settings.bitDepth = capture.session.bitDepth
            }
            if settings.exportType == .mp3,
               settings.sampleRate != 44_100,
               settings.sampleRate != 48_000 {
                settings.sampleRate = settings.sampleRate.isMultiple(of: 44_100)
                    ? 44_100
                    : 48_000
            }
            useSupportedMOVSampleRate(&settings)
            if templatePlan.map({
                canonicalSessionPath($0.session.path)
                    != canonicalSessionPath(capture.session.identity.path)
            }) ?? true {
                settings.fileDestination = bouncedFilesDestination(for: capture.session.identity)
            }
            cacheMixSources(capture.mixSources, for: capture.session.identity)
            let requestedSource = ProToolsMixSource(
                type: settings.mixSourceType,
                name: settings.mixSource
            )
            if preset != nil, !capture.mixSources.contains(requestedSource) {
                throw QuickBounceError.invalidPlan("The preset's Mix Source is unavailable in this Session. Choose another preset or use Current Settings.")
            }
            if !capture.mixSources.contains(requestedSource),
               let source = capture.mixSources.first(where: { $0.type == settings.mixSourceType })
                    ?? capture.mixSources.first {
                settings.mixSourceType = source.type
                settings.mixSource = source.name
            }
            if isCrossSessionQueue { settings.importAfterBounce = false }
            let plan = BouncePlan(
                name: trimmedName,
                bouncePresetID: preset?.id,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                session: capture.session.identity,
                targetTrackStates: capture.trackStates,
                range: capture.range,
                sourceSampleRate: capture.session.sampleRate,
                sourceTimeCodeRate: capture.session.timeCodeRate,
                settings: settings
            )
            await diagnostics?.recordTrackStates(
                action: "mix_captured",
                states: capture.trackStates,
                correlationID: plan.id.uuidString,
                fields: [
                    "plan_id": plan.id.uuidString,
                    "plan_name": trimmedName,
                    "session_path": capture.session.identity.path,
                    "session_reported_track_count": String(capture.session.trackCount),
                    "mix_capture_track_count": String(capture.trackStates.count),
                    "range_start_samples": String(capture.range.start),
                    "range_end_samples": String(capture.range.end),
                    "timecode_fps": capture.session.timeCodeRate.map {
                        String(format: "%.3f", $0.framesPerSecond)
                    } ?? "unknown"
                ]
            )
            try await store.save(plan: plan)
            plans.append(plan)
            selectedPlanIDs = [plan.id]
            selectionAnchor = plan.id
            defaultSettings = settings
            normalizeCrossSessionImportRule()
            isPresentingAddMix = false
            isPreparingMix = false
            self.captureTask = nil
            captureRunID = nil
            statusMessage = "Captured \(trimmedName) at \(formatDuration(planDuration(plan)))"
            return true
        } catch {
            isPreparingMix = false
            present(error)
            return false
        }
    }

    var canManageSettings: Bool {
        !isQueueLocked && !isMixCheckActive && !isPresentingAddMix && !isPreparingMix
            && !isRecoveringSessionState && !isDiscardingRecoveryRecord
    }

    func savePreset(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedPlans.isEmpty, let store, canManageSettings else { return false }
        guard !presetLibrary.presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A preset with this name already exists. Choose a different name."
            return false
        }
        var next = presetLibrary
        let preset = BounceSettingsPreset(name: name, settings: selectedSettings)
        next.presets.append(preset)
        // Associate only Mixes whose settings match the newly saved preset.
        let changed = selectedPlans.filter {
            preset.applying(to: $0.settings) == $0.settings
        }.map { plan in
            var updated = plan
            updated.bouncePresetID = preset.id
            return updated
        }
        isManagingSettings = true
        defer { isManagingSettings = false }
        do {
            try await store.save(presetLibrary: next, associating: changed)
            presetLibrary = next
            for updated in changed {
                if let index = plans.firstIndex(where: { $0.id == updated.id }) { plans[index] = updated }
            }
            statusMessage = "Saved preset \(name)"
            return true
        } catch { present(error); return false }
    }

    func updateCurrentPreset() {
        guard canManageSettings, let preset = selectedBouncePreset, let store else { return }
        var next = presetLibrary
        do { try next.update(id: preset.id, settings: selectedSettings) }
        catch { present(error); return }
        isManagingSettings = true
        Task {
            defer { isManagingSettings = false }
            do {
                try await store.save(presetLibrary: next)
                presetLibrary = next
                statusMessage = "Updated preset \(preset.name)"
            } catch { present(error) }
        }
    }

    func changePresetLibrary(removing id: UUID? = nil, defaultID: UUID? = nil) {
        guard canManageSettings, let store else { return }
        var next = presetLibrary
        if let id {
            next.presets.removeAll { $0.id == id }
            if next.defaultPresetID == id { next.defaultPresetID = nil }
        } else {
            next.defaultPresetID = defaultID
        }
        isManagingSettings = true
        Task {
            defer { isManagingSettings = false }
            do {
                try await store.save(presetLibrary: next)
                presetLibrary = next
            } catch { present(error) }
        }
    }

    func applyPreset(_ preset: BounceSettingsPreset) {
        guard canManageSettings, !selectedPlans.isEmpty else { return }
        guard isExportTypeAvailable(preset.settings.exportType) else {
            errorMessage = "This preset's export format is unavailable in this Pro Tools version."
            return
        }
        let source = ProToolsMixSource(type: preset.settings.mixSourceType, name: preset.settings.mixSource)
        for plan in selectedPlans {
            if let available = mixSourcesBySession[canonicalSessionPath(plan.session.path)],
               !available.contains(source) {
                errorMessage = "The preset's Mix Source is unavailable in \(URL(fileURLWithPath: plan.session.path).deletingPathExtension().lastPathComponent)."
                return
            }
        }
        guard let store else { return }
        let changed = selectedPlans.map { plan in
            var updated = plan
            updated.bouncePresetID = preset.id
            updated.settings = preset.applying(to: plan.settings)
            if isCrossSessionQueue || updated.settings.exportType == .mov {
                updated.settings.importAfterBounce = false
            }
            return updated
        }
        isManagingSettings = true
        Task {
            defer { isManagingSettings = false }
            do {
                try await store.appendPlans(changed)
                for updated in changed {
                    if let index = plans.firstIndex(where: { $0.id == updated.id }) { plans[index] = updated }
                }
                if let first = changed.first { defaultSettings = first.settings }
                statusMessage = "Applied \(preset.name) to \(changed.count) mixes"
            } catch { present(error) }
        }
    }

    func refreshSessionSettingsHistory() {
        do { sessionSettingsHistory = try sessionSettingsLibrary.entries() }
        catch { present(error) }
    }

    func openSessionSettingsFolder() {
        do {
            try FileManager.default.createDirectory(at: sessionSettingsLibrary.directory, withIntermediateDirectories: true)
            WorkspaceNavigation.open(sessionSettingsLibrary.directory)
        } catch { present(error) }
    }

    var currentSessionSettingsEntry: SessionSettingsLibrary.Entry? {
        guard let selected = selectedPlans.first ?? plans.first else { return nil }
        let name = sessionSettingsNames[canonicalSessionPath(selected.session.path)]
            ?? URL(fileURLWithPath: selected.session.path).deletingPathExtension().lastPathComponent
        return sessionSettingsHistory.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func beginSavingSessionSettings(asNew: Bool = false) {
        guard canManageSettings, let selected = selectedPlans.first ?? plans.first else { return }
        do {
            let document = try SessionSettingsDocument(plans: plans.filter {
                canonicalSessionPath($0.session.path) == canonicalSessionPath(selected.session.path)
            })
            let sessionName = URL(fileURLWithPath: selected.session.path).deletingPathExtension().lastPathComponent
            let name = asNew ? sessionName : (currentSessionSettingsEntry?.name ?? sessionName)
            sessionSettingsSaveDraft = SessionSettingsSaveDraft(name: name, session: selected.session, document: document)
        } catch { present(error) }
    }

    func commitSessionSettingsSave(_ request: SessionSettingsLibrary.SaveRequest,
                                   session: SessionIdentity, replacing: Bool = false) -> Bool {
        guard canManageSettings else { return false }
        do {
            let entry = try sessionSettingsLibrary.save(request, replacing: replacing)
            rememberSessionSettings(entry, for: session)
            refreshSessionSettingsHistory()
            statusMessage = "Saved \(request.document.plans.count) mixes to Session Settings"
            return true
        } catch { present(error); return false }
    }

    func loadSessionSettings(_ entry: SessionSettingsLibrary.Entry) {
        guard canManageSettings, connectionStatus == .connected, let proTools, let store else { return }
        isManagingSettings = true
        statusMessage = "Loading Session Settings…"
        Task {
            defer { isManagingSettings = false }
            do {
                let document = try sessionSettingsLibrary.load(entry)
                let context = try await proTools.currentSessionContext()
                let info = context.info
                let tracks = context.trackStates
                let sources = try await proTools.exportMixSources()
                let verified = try await proTools.currentSessionIdentity()
                guard info.identity == verified else {
                    throw QuickBounceError.invalidPlan("The active Session changed while loading. Please try again.")
                }
                var restored = try document.restoredPlans(session: info, tracks: tracks)
                let existingNames = Set(plans.filter { canonicalSessionPath($0.session.path) == canonicalSessionPath(info.identity.path) }.map(\.name))
                guard !restored.contains(where: { existingNames.contains($0.name) }) else {
                    throw QuickBounceError.invalidPlan("Some Mix names already exist in this Session's queue. Remove or rename them before loading these settings.")
                }
                let crossSession = plans.contains { canonicalSessionPath($0.session.path) != canonicalSessionPath(info.identity.path) }
                if crossSession {
                    for index in restored.indices { restored[index].settings.importAfterBounce = false }
                }
                try await store.appendPlans(restored)
                plans.append(contentsOf: restored)
                selectedPlanIDs = Set(restored.map(\.id))
                sessionInfo = info
                rememberSessionSettings(entry, for: info.identity)
                cacheMixSources(sources, for: info.identity)
                normalizeCrossSessionImportRule()
                statusMessage = "Loaded \(restored.count) mixes. Use Check to verify them before Bounce."
            } catch { present(error) }
        }
    }

    func selectPlan(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.option) {
            selectedPlanIDs = selectedPlanIDs.count == plans.count ? [] : Set(plans.map(\.id))
            selectionAnchor = id
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = plans.firstIndex(where: { $0.id == anchor }),
           let end = plans.firstIndex(where: { $0.id == id }) {
            let range = min(start, end)...max(start, end)
            selectedPlanIDs.formUnion(plans[range].map(\.id))
            return
        }
        if modifiers.contains(.command) {
            if selectedPlanIDs.contains(id) { selectedPlanIDs.remove(id) }
            else { selectedPlanIDs.insert(id) }
            selectionAnchor = id
            return
        }
        selectedPlanIDs = [id]
        selectionAnchor = id
    }

    func clearPlanSelection() {
        selectedPlanIDs.removeAll()
        selectionAnchor = nil
    }

    func deletePlan(_ id: UUID) {
        guard !isQueueLocked, let store else { return }
        if editingPlanID == id { cancelPlanRename() }
        plans.removeAll { $0.id == id }
        selectedPlanIDs.remove(id)
        if selectedPlanIDs.isEmpty, let next = plans.first?.id { selectedPlanIDs = [next] }
        Task {
            do { try await store.deletePlan(id: id) }
            catch { present(error) }
        }
    }

    func toggleMixCheck(_ id: UUID) {
        guard !demoMode, connectionStatus == .connected,
              connectionCapabilities?.trackStateSetters == true,
              !isBusy,
              !isPreparingMix, !isPreparingBounce, !isCheckingMix, !isManagingSettings,
              overwriteConfirmation == nil else {
            return
        }
        guard let proTools, let plan = plans.first(where: { $0.id == id }) else { return }
        if checkedMixID == id {
            restoreMixCheck(using: proTools)
            return
        }

        // Switching directly to another Mix first restores the state captured
        // before the original Check, then applies the newly selected Mix. The
        // original snapshot remains the restore target for the next click.
        if let previousID = checkedMixID, let snapshot = mixCheckSnapshot {
            let previousPlan = plans.first(where: { $0.id == previousID })
            isCheckingMix = true
            statusMessage = "Switching Check to \(plan.name)…"
            mixCheckTask?.cancel()
            mixCheckTask = Task { [weak self] in
                do {
                    await self?.diagnostics?.recordTrackStates(
                        action: "mix_check_switch_requested",
                        states: plan.targetTrackStates,
                        correlationID: plan.id.uuidString,
                        fields: [
                            "plan_id": plan.id.uuidString,
                            "plan_name": plan.name
                        ]
                    )
                    try await MixCheckWorkflow.restore(snapshot, using: proTools)
                    try await MixCheckWorkflow.apply(plan, using: proTools)
                    guard let self else { return }
                    self.checkedMixID = id
                    self.mixCheckSnapshot = snapshot
                    self.isCheckingMix = false
                    self.statusMessage = "Showing \(plan.name) Solo/Mute and Timeline Selection in Pro Tools"
                    await self.diagnostics?.record(
                        category: "mix_check",
                        action: "switch_applied",
                        correlationID: plan.id.uuidString,
                        fields: [
                            "plan_id": plan.id.uuidString,
                            "plan_name": plan.name
                        ]
                    )
                } catch {
                    // Keep the previous Check active if the switch cannot be
                    // completed. Best-effort reapplication avoids leaving PT
                    // in the pre-check state while the old button is Checked.
                    if let previousPlan {
                        try? await MixCheckWorkflow.apply(previousPlan, using: proTools)
                    }
                    guard let self else { return }
                    self.isCheckingMix = false
                    self.present(error)
                }
            }
            return
        }

        isCheckingMix = true
        statusMessage = "Checking \(plan.name) Solo/Mute and Timeline Selection…"
        mixCheckTask?.cancel()
        mixCheckTask = Task { [weak self] in
            var original: MixCheckSessionState?
            do {
                original = try await MixCheckWorkflow.capture(using: proTools)
                await self?.diagnostics?.recordTrackStates(
                    action: "mix_check_requested",
                    states: plan.targetTrackStates,
                    correlationID: plan.id.uuidString,
                    fields: [
                        "plan_id": plan.id.uuidString,
                        "plan_name": plan.name,
                        "pre_check_track_count": String(original?.trackStates.count ?? 0),
                        "range_start_sample": String(plan.range.start),
                        "range_end_sample": String(plan.range.end)
                    ]
                )
                try await MixCheckWorkflow.apply(plan, using: proTools)
                guard let self else { return }
                self.mixCheckSnapshot = original
                self.checkedMixID = id
                self.isCheckingMix = false
                self.statusMessage = "Showing \(plan.name) Solo/Mute and Timeline Selection in Pro Tools"
                await self.diagnostics?.record(
                    category: "mix_check",
                    action: "check_applied",
                    correlationID: plan.id.uuidString,
                    fields: [
                        "plan_id": plan.id.uuidString,
                        "plan_name": plan.name,
                        "range_start_sample": String(plan.range.start),
                        "range_end_sample": String(plan.range.end)
                    ]
                )
            } catch {
                if let original {
                    try? await MixCheckWorkflow.restore(original, using: proTools)
                }
                guard let self else { return }
                self.isCheckingMix = false
                self.present(error)
            }
        }
    }

    private func restoreMixCheck(using proTools: RealProToolsAdapter) {
        guard let snapshot = mixCheckSnapshot, !isCheckingMix else { return }
        isCheckingMix = true
        statusMessage = "Restoring Pro Tools Solo/Mute and Timeline Selection…"
        mixCheckTask?.cancel()
        mixCheckTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.restoreMixCheckState(snapshot, using: proTools)
                self.isCheckingMix = false
                self.statusMessage = "Restored Pro Tools Solo/Mute and Timeline Selection"
            } catch {
                guard let self else { return }
                self.isCheckingMix = false
                self.present(error)
            }
        }
    }

    private func restoreMixCheckState(
        _ snapshot: MixCheckSessionState,
        using proTools: RealProToolsAdapter
    ) async throws {
        await diagnostics?.recordTrackStates(
            action: "mix_check_restore_requested",
            states: snapshot.trackStates,
            fields: [
                "range_start_sample": String(snapshot.timelineSelection.start),
                "range_end_sample": String(snapshot.timelineSelection.end)
            ]
        )
        try await MixCheckWorkflow.restore(snapshot, using: proTools)
        mixCheckSnapshot = nil
        checkedMixID = nil
        await diagnostics?.record(
            category: "mix_check",
            action: "check_restored"
        )
    }

    func beginPlanRename(_ id: UUID) {
        guard !isQueueLocked, !isMixCheckActive,
              plans.contains(where: { $0.id == id }) else { return }
        selectedPlanIDs = [id]
        selectionAnchor = id
        editingPlanID = id
    }

    func commitPlanRename(_ id: UUID, name draft: String) {
        guard let index = plans.firstIndex(where: { $0.id == id }),
              let store else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Mix name cannot be empty."
            return
        }
        plans[index].name = name
        let plan = plans[index]
        if editingPlanID == id { editingPlanID = nil }
        Task {
            do { try await store.save(plan: plan) }
            catch { present(error) }
        }
    }

    func cancelPlanRename(_ id: UUID? = nil) {
        guard id == nil || editingPlanID == id else { return }
        editingPlanID = nil
    }

    func updateSelectedSettings(_ mutation: (inout BounceSettings) -> Void) {
        guard !selectedPlanIDs.isEmpty, !isQueueLocked, let store else { return }
        for index in plans.indices where selectedPlanIDs.contains(plans[index].id) {
            mutation(&plans[index].settings)
            useSupportedMOVSampleRate(&plans[index].settings)
            if plans[index].settings.exportType == .mov || isCrossSessionQueue {
                plans[index].settings.importAfterBounce = false
            }
            defaultSettings = plans[index].settings
            let plan = plans[index]
            Task {
                do { try await store.save(plan: plan) }
                catch { present(error) }
            }
        }
    }

    func updateSelectedExportType(_ type: ExportType) {
        guard isExportTypeAvailable(type) else {
            errorMessage = "Direct MP3 export is unavailable in this Pro Tools version. Choose WAV or WAV + MP3."
            return
        }
        updateSelectedSettings { settings in
            settings.exportType = type
            if type == .mp3 {
                if settings.sampleRate != 44_100, settings.sampleRate != 48_000 {
                    settings.sampleRate = 48_000
                }
                if settings.mp3Quality == .standard {
                    settings.mp3Quality = .highest
                }
            }
        }
    }

    private func useSupportedMOVSampleRate(_ settings: inout BounceSettings) {
        if settings.exportType == .mov, settings.movAudioCodec == .aac,
           !MOVAudioCodec.aacSampleRates.contains(settings.sampleRate) {
            settings.sampleRate = 48_000
        }
    }

    func availableMixSources(for type: MixSourceType) -> [ProToolsMixSource] {
        var sessionKeys: [String] = []
        for plan in selectedPlans {
            let key = canonicalSessionPath(plan.session.path)
            if !sessionKeys.contains(key) { sessionKeys.append(key) }
        }
        if sessionKeys.isEmpty, let sessionInfo {
            sessionKeys = [canonicalSessionPath(sessionInfo.identity.path)]
        }
        guard let firstKey = sessionKeys.first,
              let firstSources = mixSourcesBySession[firstKey] else { return [] }

        var common = Set(firstSources.filter { $0.type == type })
        for key in sessionKeys.dropFirst() {
            guard let sources = mixSourcesBySession[key] else { return [] }
            common.formIntersection(sources.filter { $0.type == type })
        }
        return firstSources.filter { $0.type == type && common.contains($0) }
    }

    func updateSelectedMixSourceType(_ type: MixSourceType) {
        let sources = availableMixSources(for: type)
        updateSelectedSettings { settings in
            settings.mixSourceType = type
            if !sources.contains(where: { $0.name == settings.mixSource }) {
                settings.mixSource = sources.first?.name ?? ""
            }
        }
    }

    func updateSelectedMixSource(_ name: String) {
        let type = selectedSettings.mixSourceType
        guard availableMixSources(for: type).contains(where: { $0.name == name }) else { return }
        updateSelectedSettings { $0.mixSource = name }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = L("Choose Bounced Files Folder")
        panel.prompt = L("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: selectedSettings.fileDestination)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateSelectedSettings { $0.fileDestination = url.standardizedFileURL.path }
    }

    func startBounce() {
        guard canBounce, let coordinator, let proTools else { return }
        errorMessage = nil
        let queuedPlans = plans
        let crossSession = isCrossSessionQueue
        let checkSnapshot = mixCheckSnapshot
        isPreparingBounce = true
        Task {
            defer {
                isPreparingBounce = false
                isCheckingMix = false
            }
            do {
                if let checkSnapshot {
                    isCheckingMix = true
                    statusMessage = "Restoring checked Solo/Mute and Timeline Selection before Bounce…"
                    try await restoreMixCheckState(checkSnapshot, using: proTools)
                }
                let collisions = try await coordinator.existingOutputCollisions(
                    for: queuedPlans
                )
                guard collisions.isEmpty else {
                    overwriteConfirmation = OverwriteConfirmation(
                        plans: queuedPlans,
                        crossSession: crossSession,
                        collisions: collisions
                    )
                    return
                }
                await performBounce(
                    plans: queuedPlans,
                    crossSession: crossSession,
                    authorizedOverwritePaths: []
                )
            } catch {
                present(error)
            }
        }
    }

    func confirmOverwrite() {
        guard let confirmation = overwriteConfirmation,
              !isBusy else { return }
        overwriteConfirmation = nil
        isPreparingBounce = true
        Task {
            defer { isPreparingBounce = false }
            await performBounce(
                plans: confirmation.plans,
                crossSession: confirmation.crossSession,
                authorizedOverwritePaths: Set(confirmation.collisions.map(\.pathKey))
            )
        }
    }

    func declineOverwrite() {
        guard let confirmation = overwriteConfirmation else { return }
        overwriteConfirmation = nil
        if let planID = confirmation.collisions.first?.planID {
            beginPlanRename(planID)
            statusMessage = "Rename the highlighted Mix before bouncing again"
        }
    }

    private func performBounce(
        plans: [BouncePlan],
        crossSession: Bool,
        authorizedOverwritePaths: Set<String>
    ) async {
        guard let coordinator else { return }
        moviePlayer.pause()
        reviewEngine?.pause()
        isPlaying = false
        // End any work belonging to the previous batch. As soon as each new
        // file is committed, coordinator snapshots feed it into a single
        // utility-priority analysis queue while Pro Tools bounces the next Mix.
        resetAudioAnalysis(clearWaveforms: true)
        _ = await coordinator.run(
            plans: plans,
            crossSession: crossSession,
            authorizedOverwritePaths: authorizedOverwritePaths
        )
    }

    func cancelBounce() {
        guard canCancel, let coordinator else { return }
        Task { await coordinator.requestCancel() }
    }

    func recoverSessionState() {
        guard !demoMode, !isBusy, let coordinator else { return }
        isRecoveringSessionState = true
        errorMessage = nil
        statusMessage = "Restoring the pending Session snapshot…"
        Task {
            defer { isRecoveringSessionState = false }
            do {
                if connectionStatus != .connected { await connect() }
                guard connectionStatus == .connected else {
                    throw QuickBounceError.connection(
                        "Open the matching Session before recovery"
                    )
                }
                pendingRecoverySnapshots = try await coordinator.recoverPendingSnapshots()
                if pendingRecoverySnapshots.isEmpty {
                    statusMessage = "Pending Session state was restored and verified"
                } else {
                    let names = pendingRecoverySnapshots.map {
                        URL(fileURLWithPath: $0.session.path).lastPathComponent
                    }.joined(separator: ", ")
                    errorMessage = "Recovery is still pending for: \(names). Open the matching Session and try again."
                    statusMessage = "Recovery still requires the matching Session"
                }
            } catch {
                await refreshRecoveryStatus()
                present(error)
                statusMessage = "Session recovery could not be verified"
            }
        }
    }

    func requestDiscardRecoveryRecords() {
        guard !pendingRecoverySnapshots.isEmpty, !isBusy,
              !isRecoveringSessionState, !isDiscardingRecoveryRecord else { return }
        recoveryDiscardConfirmation = RecoveryDiscardConfirmation(
            snapshotIDs: pendingRecoverySnapshots.map(\.id),
            sessionNames: pendingRecoverySnapshots.map {
                URL(fileURLWithPath: $0.session.path).lastPathComponent
            }
        )
    }

    func cancelDiscardRecoveryRecords() {
        recoveryDiscardConfirmation = nil
    }

    func confirmDiscardRecoveryRecords() {
        guard let confirmation = recoveryDiscardConfirmation,
              let coordinator, !isDiscardingRecoveryRecord else { return }
        recoveryDiscardConfirmation = nil
        isDiscardingRecoveryRecord = true
        Task {
            defer { isDiscardingRecoveryRecord = false }
            do {
                pendingRecoverySnapshots = try await coordinator.discardPendingSnapshots(
                    ids: confirmation.snapshotIDs
                )
                statusMessage = pendingRecoverySnapshots.isEmpty
                    ? "Discarded the obsolete Session recovery record"
                    : "Some Session recovery records are still pending"
            } catch {
                present(error)
            }
        }
    }

    func openBouncedFiles() {
        let destinations = batchDestinations.isEmpty
            ? plans.map { URL(fileURLWithPath: $0.settings.fileDestination) }
            : batchDestinations
        let result = WorkspaceNavigation.openDirectories(destinations)
        if !result.failed.isEmpty {
            let paths = result.failed.map(\.path).joined(separator: "\n")
            errorMessage = "These Bounced Files folders could not be opened:\n\(paths)"
        } else if result.opened.isEmpty, !destinations.isEmpty {
            errorMessage = "None of the Bounced Files folders currently exists."
        }
    }

    func reveal(_ artifact: AudioArtifact) {
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            errorMessage = "The file has been moved or deleted: \(artifact.path)"
            return
        }
        WorkspaceNavigation.reveal(artifact.fileURL)
    }

    func removeArtifactFromList(_ id: UUID) {
        guard !isBusy, let store,
              let artifact = artifacts.first(where: { $0.id == id }) else { return }
        let wasSelected = selectedArtifactIDs.contains(id)
        resetAudioAnalysis(clearWaveforms: false)

        Task {
            do {
                if let coordinator {
                    try await coordinator.removeArtifactRecord(id: id)
                } else {
                    try await store.deleteArtifact(id: id)
                }
                try? await waveformCache?.invalidate(for: artifact)

                if wasSelected {
                    reviewEngine?.pause()
                    isPlaying = false
                }
                artifacts.removeAll { $0.id == id }
                selectedArtifactIDs.remove(id)
                waveforms.removeValue(forKey: id)
                stemStates.removeValue(forKey: id)
                reviewDecisions.removeValue(forKey: id)
                if activeMixID == id { activeMixID = nil }
                if artifactSelectionAnchor == id { artifactSelectionAnchor = nil }

                let remainingIDs = Set(artifacts.map(\.id))
                selectedArtifactIDs.formIntersection(remainingIDs)
                if selectedArtifactIDs.isEmpty {
                    selectInitialArtifacts()
                } else if activeMixID == nil {
                    activeMixID = selectedAudioArtifacts.first?.id
                }

                reloadReviewGraph()
                analyzeCompletedAudio()
                statusMessage = "Removed \(artifact.name) from the QuickBounce list; the file was kept on disk"
            } catch {
                present(error)
            }
        }
    }

    func openMOV(_ artifact: AudioArtifact, inBrowser: Bool = false) {
        guard artifact.canPreviewVideo else { return }
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            errorMessage = "The file has been moved or deleted: \(artifact.path)"
            return
        }
        moviePlayer.pause()
        if inBrowser {
            Task {
                do {
                    try await WorkspaceNavigation.openInDefaultBrowser(artifact.fileURL)
                } catch {
                    errorMessage = "This video could not be opened in the default browser."
                }
            }
        } else if !NSWorkspace.shared.open(artifact.fileURL) {
            errorMessage = "This video could not be opened in the default video player."
        }
    }

    func selectArtifact(_ id: UUID, modifiers: NSEvent.ModifierFlags = [], autoplayMovie: Bool = true) {
        guard artifacts.contains(where: { $0.id == id }) else { return }
        if modifiers.contains(.option) {
            let completed = artifacts.filter { $0.state == .completed }
            selectedArtifactIDs = Set(completed.map(\.id))
            artifactSelectionAnchor = id
        } else if modifiers.contains(.shift),
                  let anchor = artifactSelectionAnchor,
                  let start = artifacts.firstIndex(where: { $0.id == anchor }),
                  let end = artifacts.firstIndex(where: { $0.id == id }) {
            let range = min(start, end)...max(start, end)
            selectedArtifactIDs.formUnion(artifacts[range].map(\.id))
        } else if modifiers.contains(.command) {
            if selectedArtifactIDs.contains(id) { selectedArtifactIDs.remove(id) }
            else { selectedArtifactIDs.insert(id) }
            artifactSelectionAnchor = id
        } else {
            selectedArtifactIDs = [id]
            artifactSelectionAnchor = id
        }

        if selectedArtifactIDs.contains(id),
           let artifact = artifacts.first(where: { $0.id == id }),
           artifact.canReviewAudio {
            activeMixID = id
        } else if activeMixID.map({ !selectedArtifactIDs.contains($0) }) ?? true {
            activeMixID = selectedAudioArtifacts.first?.id
        }
        reloadReviewGraph()
        if autoplayMovie, reviewedMOV?.id == id {
            playMoviePreview()
        }
    }

    func setReviewMode(_ mode: ReviewMode) {
        reviewMode = mode
        reloadReviewGraph()
    }

    func setReviewDecision(_ status: ReviewDecisionStatus, for id: UUID) {
        guard artifacts.contains(where: { $0.id == id }), let store else { return }
        var decision = reviewDecisions[id] ?? ReviewDecision(artifactID: id)
        decision.status = status
        decision.reviewedAt = status == .unreviewed ? nil : Date()
        reviewDecisions[id] = decision
        Task {
            do {
                try await store.save(reviewDecision: decision)
            } catch {
                present(error)
            }
        }
    }

    func selectAudibleMix(_ id: UUID) {
        activeMixID = id
        reviewEngine?.selectMix(id)
        syncReviewState()
    }

    func toggleStemSolo(_ id: UUID) {
        var state = stemStates[id] ?? StemPlaybackState(artifactID: id)
        state.isSolo.toggle()
        stemStates[id] = state
        reviewEngine?.setStemState(state)
        syncReviewState()
    }

    func toggleStemMute(_ id: UUID) {
        var state = stemStates[id] ?? StemPlaybackState(artifactID: id)
        state.isMuted.toggle()
        stemStates[id] = state
        reviewEngine?.setStemState(state)
        syncReviewState()
    }

    func togglePlayback() {
        guard !isBusy, let reviewEngine else { return }
        do {
            if reviewEngine.isPlaying { reviewEngine.pause() }
            else { try reviewEngine.play() }
            syncReviewState()
        } catch { present(error) }
    }

    func handleReviewSpacebar() {
        if reviewedMOV != nil {
            if moviePlayer.timeControlStatus == .paused {
                playMoviePreview()
            } else {
                moviePlayer.pause()
            }
        } else {
            togglePlayback()
        }
    }

    private func playMoviePreview() {
        guard let item = moviePlayer.currentItem else { return }
        let end = item.duration
        if end.isNumeric, moviePlayer.currentTime() >= end {
            moviePlayer.seek(to: .zero)
        }
        moviePlayer.play()
    }

    func stopPlayback() {
        reviewEngine?.stop()
        syncReviewState()
    }

    func seek(to seconds: Double) {
        guard !isBusy else { return }
        do {
            try reviewEngine?.seek(to: seconds)
            syncReviewState()
        } catch { present(error) }
    }

    func setMonitorTrim(_ value: Float) {
        monitorTrimDB = min(6, max(-60, value))
        reviewEngine?.monitorTrimDB = monitorTrimDB
    }

    func setWaveformZoom(_ value: Double) {
        waveformZoom = min(32, max(1, value))
        if waveformZoom == 1 { waveformScroll = 0 }
    }

    func setWaveformScroll(_ value: Double) {
        waveformScroll = min(1, max(0, value))
    }

    func fitWaveforms() {
        waveformZoom = 1
        waveformScroll = 0
    }

    func dismissError() { errorMessage = nil }

    func showErrorDetails(_ raw: String) {
        dismissError()
        DispatchQueue.main.async { ErrorDetailsPanel.show(raw) }
    }

    func duration(for plan: BouncePlan) -> String { formatDuration(planDuration(plan)) }

    func duration(for artifact: AudioArtifact) -> String {
        if let duration = artifact.durationSeconds { return formatDuration(duration) }
        guard let frames = artifact.frameCount, let rate = artifact.sampleRate, rate > 0 else { return "—" }
        return formatDuration(Double(frames) / rate)
    }

    func dbString(_ value: Double?, suffix: String) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f %@", value, suffix)
    }

    private func observe(_ coordinator: BounceCoordinator) {
        coordinatorObservation = Task { [weak self] in
            let snapshots = await coordinator.snapshots()
            for await snapshot in snapshots {
                guard let self else { return }
                self.job = snapshot.job
                self.artifacts = self.mergingReviewData(into: snapshot.artifacts)
                if self.reviewAutoExpansionPolicy.shouldExpand(
                    completedPlanCount: snapshot.job?.completedPlanCount ?? 0
                ) {
                    self.setReviewExpanded(true)
                }
                self.selectFirstArtifactForLiveAnalysisIfNeeded()
                self.updateMoviePreview()
                self.events = snapshot.events
                self.batchDestinations = snapshot.batchDestinations
                let failureMessage = snapshot.job.flatMap { job in
                    job.failureMessage.map { failure in
                        job.state == .recoveryRequired && !failure.hasPrefix("Session save failed:")
                            ? "Session restoration failed: \(failure)" : failure
                    }
                }
                let lastMessage = snapshot.events.last?.message ?? self.statusMessage
                self.statusMessage = failureMessage.map { UserFacingError.message(for: $0) } ?? lastMessage
                // commit() publishes each completed artifact before the next
                // Bounce Plan begins, so Review work can overlap that next
                // export instead of waiting for the entire batch to finish.
                self.analyzeCompletedAudio()
                if let job = snapshot.job,
                   job.state.isTerminal,
                   self.lastHandledTerminalJobID != job.id {
                    self.lastHandledTerminalJobID = job.id
                    self.selectInitialArtifacts()
                    self.reloadReviewGraph()
                    if job.state == .reviewReady {
                        self.showCompletedBounceReview()
                    }
                    await self.removeCompletedPlans(snapshot.completedPlanIDsToRemove)
                    if let failureMessage { self.errorMessage = failureMessage }
                    await self.refreshRecoveryStatus()
                }
            }
        }
    }

    private func analyzeCompletedAudio() {
        let inputs = artifacts.filter(\.canReviewAudio)
        let availableIDs = Set(inputs.map(\.id))
        pendingAnalysisIDs.removeAll { !availableIDs.contains($0) }
        for artifact in inputs where !scheduledAnalysisIDs.contains(artifact.id) {
            scheduledAnalysisIDs.insert(artifact.id)
            pendingAnalysisIDs.append(artifact.id)
        }

        startAnalysisWorkerIfNeeded()
    }

    private func startAnalysisWorkerIfNeeded() {
        guard analysisTask == nil, !pendingAnalysisIDs.isEmpty else { return }
        let runID = UUID()
        analysisRunID = runID
        isLoadingWaveforms = true
        analysisTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runAudioAnalysisQueue(runID: runID)
        }
    }

    private func runAudioAnalysisQueue(runID: UUID) async {
        guard let reviewAnalysis else { return }
        defer {
            if analysisRunID == runID {
                analysisTask = nil
                analysisRunID = nil
                isLoadingWaveforms = false
                if !Task.isCancelled { startAnalysisWorkerIfNeeded() }
            }
        }
        while !Task.isCancelled, analysisRunID == runID,
              let artifactID = pendingAnalysisIDs.first {
            pendingAnalysisIDs.removeFirst()
            guard let artifact = artifacts.first(where: {
                $0.id == artifactID && $0.canReviewAudio
            }) else { continue }

            do {
                if waveforms[artifact.id] == nil {
                    let pyramid = try await reviewAnalysis.waveform(for: artifact)
                    guard !Task.isCancelled, analysisRunID == runID else { return }
                    waveforms[artifact.id] = pyramid
                }

                let currentIndex = artifacts.firstIndex { $0.id == artifact.id }
                let currentArtifact = currentIndex.map { artifacts[$0] } ?? artifact
                let analysis = try await reviewAnalysis.metrics(for: currentArtifact)
                guard !Task.isCancelled, analysisRunID == runID else { return }
                if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) {
                    artifacts[index].metrics = analysis.metrics
                    artifacts[index].analysis = analysis
                    try await store?.save(artifact: artifacts[index])
                }
                analysisErrors.removeValue(forKey: artifact.id)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || analysisRunID != runID { return }
                analysisErrors[artifact.id] = error.localizedDescription
                errorMessage = "Review analysis \(artifact.name): \(error.localizedDescription)"
                await diagnostics?.record(category: "review_analysis", action: "review_failed",
                    fields: ["artifact_id": artifact.id.uuidString, "error": error.localizedDescription])
            }
        }

    }

    func retryAnalysis(_ id: UUID) {
        guard analysisErrors[id] != nil, artifacts.contains(where: { $0.id == id && $0.canReviewAudio }) else { return }
        analysisErrors.removeValue(forKey: id)
        waveforms.removeValue(forKey: id)
        scheduledAnalysisIDs.remove(id)
        analyzeCompletedAudio()
    }

    private func resetAudioAnalysis(clearWaveforms: Bool) {
        analysisTask?.cancel()
        analysisTask = nil
        analysisRunID = nil
        pendingAnalysisIDs.removeAll(keepingCapacity: true)
        scheduledAnalysisIDs.removeAll(keepingCapacity: true)
        analysisErrors.removeAll()
        isLoadingWaveforms = false
        if clearWaveforms { waveforms = [:] }
    }

    private func mergingReviewData(into incoming: [AudioArtifact]) -> [AudioArtifact] {
        let existingByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        return incoming.map { incomingArtifact in
            guard let existing = existingByID[incomingArtifact.id],
                  existing.path == incomingArtifact.path else { return incomingArtifact }
            var merged = incomingArtifact
            if merged.metrics == nil { merged.metrics = existing.metrics }
            if merged.analysis == nil { merged.analysis = existing.analysis }
            return merged
        }
    }

    private func selectFirstArtifactForLiveAnalysisIfNeeded() {
        let availableIDs = Set(artifacts.map(\.id))
        selectedArtifactIDs.formIntersection(availableIDs)
        guard selectedArtifactIDs.isEmpty,
              let first = artifacts.first(where: \.canReviewAudio)
                ?? artifacts.first(where: \.canPreviewVideo) else { return }
        selectedArtifactIDs = [first.id]
        artifactSelectionAnchor = first.id
        activeMixID = first.canReviewAudio ? first.id : nil
    }

    private func updateMoviePreview() {
        let movie = reviewedMOV
        guard moviePreviewID != movie?.id else { return }
        moviePlayer.pause()
        moviePreviewID = movie?.id
        moviePlayer.replaceCurrentItem(with: movie.map { AVPlayerItem(url: $0.fileURL) })
    }

    private func reloadReviewGraph() {
        updateMoviePreview()
        guard let reviewEngine else { return }
        do {
            try reviewEngine.load(selectedAudioArtifacts, mode: reviewMode)
            if selectedAudioArtifacts.isEmpty { fitWaveforms() }
            if let activeMixID, selectedArtifactIDs.contains(activeMixID) {
                reviewEngine.selectMix(activeMixID)
            }
            for state in stemStates.values { reviewEngine.setStemState(state) }
            syncReviewState()
        } catch { present(error) }
    }

    private func syncReviewState() {
        guard let reviewEngine else { return }
        let nextIsPlaying = reviewEngine.isPlaying
        let nextPlaybackPosition = reviewEngine.currentPositionSeconds
        let nextPlaybackDuration = reviewEngine.durationSeconds
        let nextActiveMixID = reviewEngine.activeMixID
        let nextStemStates = reviewEngine.stemStates
        let nextMeter = reviewEngine.meterReading()

        // Frequent samples go only to the small views that use them. List,
        // waveform-envelope and settings layout no longer update each tick.
        if isPlaying != nextIsPlaying { isPlaying = nextIsPlaying }
        playbackClock.update(position: nextPlaybackPosition, isPlaying: nextIsPlaying)
        if playbackDuration != nextPlaybackDuration { playbackDuration = nextPlaybackDuration }
        if activeMixID != nextActiveMixID { activeMixID = nextActiveMixID }
        if stemStates != nextStemStates { stemStates = nextStemStates }
        if monitorChannelCount != reviewEngine.monitorChannelCount { monitorChannelCount = reviewEngine.monitorChannelCount }
        if monitorDownmix != reviewEngine.isDownmixing { monitorDownmix = reviewEngine.isDownmixing }
        if monitorWarnings != reviewEngine.warnings { monitorWarnings = reviewEngine.warnings }
        reviewMeter.update(nextMeter)
    }

    private func startMeterUpdates() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.syncReviewState()
                if self.isPlaying, self.playbackDuration > 0,
                   self.playbackPosition >= self.playbackDuration {
                    self.stopPlayback()
                }
            }
        }
    }

    private func installReviewKeyboardMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: {
            [weak self] event in
            guard event.keyCode == 49 else { return event }
            let blockedModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift
            ]
            guard event.modifierFlags.intersection(blockedModifiers).isEmpty else {
                return event
            }
            // Let TextField's field editor receive ordinary spaces.
            guard !(NSApp.keyWindow?.firstResponder is NSTextView),
                  let self,
                  self.canHandleReviewSpacebar else { return event }
            guard !event.isARepeat else { return nil }
            self.handleReviewSpacebar()
            return nil
        })
        guard let monitor else { return }
        reviewKeyboardMonitor = ReviewKeyboardMonitorToken(monitor)
    }

    private func selectInitialArtifacts() {
        let completed = artifacts.filter { $0.state == .completed }
        guard !completed.isEmpty else {
            selectedArtifactIDs = []
            artifactSelectionAnchor = nil
            activeMixID = nil
            return
        }
        selectedArtifactIDs = Set(completed.map(\.id))
        artifactSelectionAnchor = completed.first?.id
        activeMixID = completed.first(where: \.canReviewAudio)?.id
    }

    private func normalizeCrossSessionImportRule() {
        guard isCrossSessionQueue, let store else { return }
        for index in plans.indices where plans[index].settings.importAfterBounce {
            plans[index].settings.importAfterBounce = false
            let plan = plans[index]
            Task { try? await store.save(plan: plan) }
        }
    }

    private func removeCompletedPlans(_ completedPlanIDs: [UUID]) async {
        let completed = Set(completedPlanIDs)
        guard !completed.isEmpty else { return }

        var persistenceFailure: Error?
        if let store {
            for id in completed {
                do {
                    try await store.deletePlan(id: id)
                } catch {
                    persistenceFailure = error
                }
            }
        }

        plans.removeAll { completed.contains($0.id) }
        selectedPlanIDs.subtract(completed)
        if let editingPlanID, completed.contains(editingPlanID) {
            cancelPlanRename()
        }
        if let selectionAnchor, completed.contains(selectionAnchor) {
            self.selectionAnchor = nil
        }
        if selectedPlanIDs.isEmpty, let next = plans.first?.id {
            selectedPlanIDs = [next]
            selectionAnchor = next
        }
        if let persistenceFailure { present(persistenceFailure) }
    }

    private func refreshSessionContext(using capture: MixCapture) {
        let info = capture.session
        sessionInfo = info
        connectionStatus = .connected
        connectionDetail = "Connected to Pro Tools"
        statusMessage = "Captured current Session context from \(info.name)"
        cacheMixSources(capture.mixSources, for: info.identity)
        defaultSettings.sampleRate = info.sampleRate
        defaultSettings.bitDepth = info.bitDepth
        defaultSettings.fileDestination = bouncedFilesDestination(for: info.identity)
    }

    private func presentCompatibilityNoticeIfNeeded(for connection: ProToolsConnection) {
        guard !didPresentCompatibilityNotice,
              let release = PTSLHostRelease.fromDisplayString(connection.ptslVersion),
              release < .v2026_04 else { return }
        didPresentCompatibilityNotice = true
        let unavailable = release.unavailableUserFeatures
        let detail: String
        if unavailable.isEmpty {
            detail = "No user-facing QuickBounce features are disabled. Some Pro Tools operations use a compatibility path."
        } else {
            detail = "Unavailable in this Pro Tools version:\n"
                + unavailable.map { "• \($0)" }.joined(separator: "\n")
        }
        compatibilityNotice = CompatibilityNotice(
            title: "Pro Tools Compatibility Mode",
            message: "Pro Tools/PTSL \(connection.ptslVersion) is supported in compatibility mode.\n\n\(detail)"
        )
    }

    private func bouncedFilesDestination(for session: SessionIdentity) -> String {
        URL(fileURLWithPath: session.path)
            .deletingLastPathComponent()
            .appendingPathComponent("Bounced Files", isDirectory: true)
            .standardizedFileURL.path
    }

    private func refreshRecoveryStatus() async {
        guard !demoMode, let store else { return }
        do {
            pendingRecoverySnapshots = try await store.pendingSnapshots()
            if !pendingRecoverySnapshots.isEmpty, !isBusy {
                statusMessage = currentSessionHasPendingRecovery
                    ? "The current Session has a pending state recovery"
                    : "A recovery record is pending for another Session; the current Session remains available"
            }
        } catch {
            present(error)
        }
    }

    private func planDuration(_ plan: BouncePlan) -> Double {
        let rate = max(1, plan.sourceSampleRate ?? plan.settings.sampleRate)
        return Double(plan.range.length) / Double(rate)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func canonicalSessionPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func cacheMixSources(
        _ sources: [ProToolsMixSource],
        for session: SessionIdentity
    ) {
        var seen = Set<ProToolsMixSource>()
        mixSourcesBySession[canonicalSessionPath(session.path)] = sources.filter {
            !$0.name.isEmpty && seen.insert($0).inserted
        }
    }

    private func present(_ error: Error) {
        errorMessage = (QuickBounceError.diskSpaceFailure(for: error) ?? error).localizedDescription
    }
}
