import AppKit
import QuickBounceDomain
import SwiftUI

struct QuickBounceWorkspace: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let minimum = model.isReviewPaneVisible ? WorkspaceGeometry.minimumExpandedWidth : 570
            let width = max(minimum, proxy.size.width)
            let height = max(700, proxy.size.height)
            let columns = WorkspaceGeometry.columns(width: width, expanded: model.isReviewPaneVisible)
            // Tiny displays still get scrollable access to every control.
            // Normal displays allocate exact column widths, preventing the
            // HStack's ideal size from extending beyond the native window.
            ScrollView(scrollAxes(size: proxy.size, minimumWidth: minimum)) {
                HStack(spacing: 0) {
                    SessionSidebar(model: model).frame(width: columns.sidebar)
                    Divider().frame(width: 1)
                    BounceSettingsPanel(model: model).frame(width: columns.settings)
                    if model.isReviewPaneVisible {
                        Divider().frame(width: 1)
                        ReviewPanel(model: model).frame(width: columns.review)
                        Divider().frame(width: 1)
                        MasterStrip(model: model, meter: model.reviewMeter).frame(width: columns.master)
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
        }
        .frame(minWidth: 570, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            WorkspaceWindowReader(
                onWindowAvailable: { window in
                    model.attachWorkspaceWindow(window)
                },
                onWindowUnavailable: { window in
                    model.detachWorkspaceWindow(window)
                }
            )
            .frame(width: 0, height: 0)
        }
        .friendlyErrorAlert(model: model)
        .alert(item: $model.compatibilityNotice) { notice in
            Alert(
                title: Text(L(notice.title)),
                message: Text(L(notice.message)),
                dismissButton: .default(Text(L("OK")))
            )
        }
        .alert(
            L("Files Already Exist"),
            isPresented: Binding(
                get: { model.overwriteConfirmation != nil },
                set: { _ in }
            )
        ) {
            Button(L("Don't Overwrite"), role: .cancel) { model.declineOverwrite() }.functionTip("Don't Overwrite")
            Button(L("Overwrite"), role: .destructive) { model.confirmOverwrite() }.functionTip("Overwrite")
        } message: {
            Text(L(model.overwriteConfirmationMessage))
        }
        .alert(item: $model.recoveryDiscardConfirmation) { _ in
            Alert(
                title: Text(L("Discard Recovery Record?")),
                message: Text(L(model.recoveryDiscardMessage)),
                primaryButton: .destructive(Text(L("Discard Record"))) {
                    model.confirmDiscardRecoveryRecords()
                },
                secondaryButton: .cancel {
                    model.cancelDiscardRecoveryRecords()
                }
            )
        }
        .sheet(isPresented: $model.isPresentingAddMix) {
            AddMixSheet(model: model)
        }
        .sheet(isPresented: $model.isPresentingPresets) {
            BouncePresetManager(model: model)
        }
        .sheet(isPresented: $model.isPresentingSessionSettingsHistory) {
            SessionSettingsHistorySheet(model: model)
        }
        .sheet(item: $model.sessionSettingsSaveDraft) { draft in
            NewSessionSettingsSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $model.isPresentingNewPreset) {
            NewBouncePresetSheet(model: model)
        }
    }

    private func scrollAxes(size: CGSize, minimumWidth: CGFloat) -> Axis.Set {
        var axes: Axis.Set = []
        if size.width < minimumWidth { axes.insert(.horizontal) }
        if size.height < 700 { axes.insert(.vertical) }
        return axes
    }
}

/// Preserve readable labels when the window is constrained by a small screen.
private struct AdaptiveControlRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
    }
}

private struct SessionSidebar: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @State private var isBatchRenamePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConnectionCard(model: model)
            SessionInfoCard(info: model.sessionInfo)
            AdaptiveControlRow {
                SessionSettingsControl(model: model)
                Button(L("Batch Rename")) { isBatchRenamePresented.toggle() }.functionTip("Batch Rename")
                    .fixedSize()
                    .disabled(!model.canManageSettings)
                    .popover(isPresented: $isBatchRenamePresented) {
                        BatchRenameSettings(model: model)
                    }
            }
            if model.hasPendingRecovery {
                RecoveryCard(model: model)
            }

            Button {
                model.beginMixCapture()
            } label: {
                LocalizedLabel(english: "Add Mix", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!model.canAddMix)
            .functionTip("Add Mix")

            HStack {
                LocalizedText(english: "MIXES TO BOUNCE (\(model.plans.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isCrossSessionQueue {
                    Label(L("Cross-Session"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if model.unsupportedBounceFeatures.contains("Cross-Session Bounce") {
                Label(L("Cross-Session Bounce is unavailable in this Pro Tools version. You can still Bounce mixes from one Session at a time."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(Array(model.plans.enumerated()), id: \.element.id) { index, plan in
                        MixPlanRow(
                            index: index + 1,
                            plan: plan,
                            selected: model.selectedPlanIDs.contains(plan.id),
                            isEditing: model.editingPlanID == plan.id,
                            duration: model.duration(for: plan),
                            beginRename: { model.beginPlanRename(plan.id) },
                            commitRename: { model.commitPlanRename(plan.id, name: $0) },
                            cancelRename: { model.cancelPlanRename(plan.id) },
                            invalidRename: { model.errorMessage = "Mix name cannot be empty." },
                            delete: { model.deletePlan(plan.id) },
                            check: { model.toggleMixCheck(plan.id) },
                            isChecked: model.checkedMixID == plan.id,
                            isCheckBusy: model.isCheckingMix,
                            checkDisabled: false,
                            deleteDisabled: model.isMixCheckActive
                        )
                        .onTapGesture {
                            model.selectPlan(plan.id, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                        }
                    }

                    if model.plans.isEmpty {
                        EmptySidebarState()
                    } else {
                        Color.clear
                            .frame(height: 80)
                            .contentShape(Rectangle())
                            .onTapGesture { model.clearPlanSelection() }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)

            AuthorSignature()
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct RecoveryCard: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L("SESSION RECOVERY REQUIRED"), systemImage: "exclamationmark.shield.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
            Text(L("Restore the matching Session when available. Other Sessions remain usable, or you can discard this record if the original Session no longer exists."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(recoveryNames)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(action: model.recoverSessionState) {
                if model.isRecoveringSessionState {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 22)
                } else {
                    LocalizedLabel(english: "Recover Session State", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .functionTip("Recover Session State")
            .disabled(
                !model.canRecoverCurrentSession || model.isBusy
                    || model.isRecoveringSessionState
                    || model.isDiscardingRecoveryRecord
            )
            Button(role: .destructive, action: model.requestDiscardRecoveryRecords) {
                if model.isDiscardingRecoveryRecord {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 22)
                } else {
                    LocalizedLabel(english: "Discard Recovery Record…", systemImage: "trash")
                        .functionTip("Discard Recovery Record")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                model.isBusy || model.isRecoveringSessionState
                    || model.isDiscardingRecoveryRecord
            )
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        }
    }

    private var recoveryNames: String {
        model.pendingRecoverySnapshots.map {
            URL(fileURLWithPath: $0.session.path).lastPathComponent
        }.joined(separator: ", ")
    }
}

private struct ConnectionCard: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    private var color: Color {
        switch model.connectionStatus {
        case .connected: .green
        case .connectedWithoutSession: .orange
        case .disconnected: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.55), radius: 4)
            Text(L(model.connectionDetail))
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                Task { await model.connect() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .functionTip("Reconnect")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct SessionInfoCard: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let info: SessionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                LocalizedText(english: "SESSION INFO")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .functionTip("SESSION INFO")
            }
            Divider()
            InfoPair(label: L("Session Name"), value: info?.name ?? L("No Session"), accent: info != nil)
            InfoPair(label: L("Sample Rate"), value: info.map { "\($0.sampleRate) Hz" } ?? "—")
            InfoPair(label: L("Bit Depth"), value: info.map { L("\($0.bitDepth)-bit") } ?? "—")
            InfoPair(label: L("Session File Format"), value: info?.fileFormat ?? "—")
            InfoPair(label: L("Track Count"), value: info.map { "\($0.trackCount)" } ?? "—")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct InfoPair: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let label: String
    let value: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(label)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(accent ? .semibold : .regular))
                .foregroundStyle(accent ? Color.cyan : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

private struct MixPlanRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let index: Int
    let plan: BouncePlan
    let selected: Bool
    let isEditing: Bool
    let duration: String
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let cancelRename: () -> Void
    let invalidRename: () -> Void
    let delete: () -> Void
    let check: () -> Void
    let isChecked: Bool
    let isCheckBusy: Bool
    let checkDisabled: Bool
    let deleteDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(L("\(index)"))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    InlineMixNameField(name: plan.name, commit: commitRename, cancel: cancelRename, invalid: invalidRename)
                        .frame(height: 20)
                } else {
                    Text(plan.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRename)
                        .functionTip("Double-click to rename")
                }
                Text("\(plan.settings.exportType.displayName)  ·  \(duration)  ·  \(sampleRateLabel)  ·  \(L(bitDepthLabel))")
                    .functionTip("Mix Row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !plan.note.isEmpty {
                    Text(plan.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Button(action: check) {
                if isCheckBusy && isChecked {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L(isChecked ? "Checked" : "Check"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isChecked ? Color.orange : Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(checkDisabled || isEditing || isCheckBusy)
            .functionTip(
                isChecked
                    ? "Checked"
                    : "Check"
            )
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isEditing || isCheckBusy || deleteDisabled || isChecked)
            .functionTip("混音清单垃圾桶")
        }
        .padding(10)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var sampleRateLabel: String {
        let rate = plan.settings.sampleRate
        return rate.isMultiple(of: 1_000)
            ? "\(rate / 1_000) kHz"
            : String(format: "%.1f kHz", Double(rate) / 1_000)
    }

    private var bitDepthLabel: String {
        if plan.settings.exportType == .mp3 { return "16-bit" }
        return plan.settings.bitDepth == 32
            ? "32-bit Float"
            : "\(plan.settings.bitDepth)-bit"
    }

}

private struct EmptySidebarState: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(L("No Mix snapshots yet"))
                .font(.callout.weight(.medium))
            Text(L("Set Solo/Mute and a Timeline Selection in Pro Tools, then click Add Mix."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

private struct BounceSettingsPanel: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @State private var isShortcutPopoverPresented = false

    private var settings: BounceSettings { model.selectedSettings }
    private var settingsDisabled: Bool {
        model.selectedPlanIDs.isEmpty || model.isQueueLocked || model.isMixCheckActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                LocalizedText(english: "BOUNCE SETTINGS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .functionTip("Settings")
                Button {
                    isShortcutPopoverPresented.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.borderless)
                .functionTip("Set the Add Mix shortcut")
                .popover(isPresented: $isShortcutPopoverPresented, arrowEdge: .top) {
                    AddMixShortcutSettings(model: model)
                }

                Button(action: model.toggleKeepOnTopMode) {
                    Image(systemName: model.isKeepOnTopMode ? "pin.fill" : "pin")
                        .foregroundStyle(model.isKeepOnTopMode ? Color.cyan : Color.secondary)
                }
                .buttonStyle(.borderless)
                .functionTip("Keep on Top")

                Button(action: model.toggleReviewPane) {
                    Image(systemName: model.isReviewExpanded ? "chevron.right" : "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(model.isKeepOnTopMode)
                .functionTip(reviewToggleHelp)
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(model.presetLibrary.presets) { preset in
                        Button(preset.name + (preset.id == model.presetLibrary.defaultPresetID ? " (" + L("Default") + ")" : "")) {
                            model.applyPreset(preset)
                        }
                        .disabled(model.selectedPlanIDs.isEmpty)
                    }
                    Divider()
                    Button(L("Manage Presets…")) { model.isPresentingPresets = true }.menuFunctionTip("Manage Presets…")
                } label: {
                    Label(model.bouncePresetTitle, systemImage: "slider.horizontal.3")
                        .lineLimit(1).truncationMode(.middle)
                }
                .functionTip("Bounce Settings Presets")

                if let preset = model.selectedBouncePreset {
                    Menu {
                        Button(L("Add Current Settings as New Preset…")) { model.isPresentingNewPreset = true }.menuFunctionTip("Add Current Settings as New Preset…")
                        Button(L("Update “\(preset.name)”")) { model.updateCurrentPreset() }
                            .menuFunctionTip("Update Preset")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .functionTip("Add a new preset or update the selected preset")
                } else {
                    Button { model.isPresentingNewPreset = true } label: {
                        Image(systemName: "plus")
                    }
                    .functionTip("Add current settings as a new preset")
                    .disabled(model.selectedPlans.isEmpty)
                }
            }
            .disabled(!model.canManageSettings)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingField("EXPORT TYPE") {
                        Picker(L("Export Type"), selection: Binding(
                            get: { settings.exportType },
                            set: { value in model.updateSelectedExportType(value) }
                        )) {
                            ForEach(ExportType.allCases) { type in
                                Text(L(type.displayName)).tag(type)
                                    .disabled(!model.isExportTypeAvailable(type))
                            }
                        }.id("picker1-\(interfaceLanguage)").functionTip("Export Type")
                        .labelsHidden()
                    }

                    if !model.isExportTypeAvailable(.mp3) {
                        Label(L("Direct MP3 export is unavailable in this Pro Tools version. WAV + MP3 remains available."), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.exportType == .mov {
                        SettingField("MOV AUDIO CODEC") {
                            Picker(L("MOV Audio Codec"), selection: Binding(
                                get: { settings.movAudioCodec },
                                set: { codec in
                                    model.updateSelectedSettings { settings in
                                        if settings.exportType == .mov { settings.movAudioCodec = codec }
                                    }
                                }
                            )) {
                                ForEach(MOVAudioCodec.allCases) { codec in
                                    Text(codec.displayName).tag(codec)
                                }
                            }
                            .labelsHidden()
                            .functionTip("MOV Audio Codec")
                        }
                    }

                    SettingField("SAMPLE RATE") {
                        Picker(L("Sample Rate"), selection: Binding(
                            get: { settings.sampleRate },
                            set: { value in model.updateSelectedSettings { $0.sampleRate = value } }
                        )) {
                            ForEach(sampleRates, id: \.self) { rate in
                                Text(L("\(rate) Hz")).tag(rate)
                            }
                        }.id("picker2-\(interfaceLanguage)").functionTip("Sample Rate")
                        .labelsHidden()
                    }

                    if settings.exportType != .mov || settings.movAudioCodec == .pcm {
                        SettingField("BIT DEPTH") {
                            if settings.exportType == .mp3 {
                                Text(L("16-bit (fixed by Pro Tools)"))
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker(L("Bit Depth"), selection: Binding(
                                    get: { settings.bitDepth },
                                    set: { value in model.updateSelectedSettings { $0.bitDepth = value } }
                                )) {
                                    Text(L("16-bit")).tag(16)
                                    Text(L("24-bit")).tag(24)
                                    Text(L("32-bit Float")).tag(32)
                                }.id("picker3-\(interfaceLanguage)").functionTip("Bit Depth")
                                .labelsHidden()
                            }
                        }
                    }

                    SettingField("FILE FORMAT") {
                        Picker(L("File Format"), selection: Binding(
                            get: { settings.fileLayout },
                            set: { value in model.updateSelectedSettings { $0.fileLayout = value } }
                        )) {
                            ForEach(AudioFileLayout.allCases) { layout in
                                Text(L(layout.displayName)).tag(layout)
                            }
                        }.id("picker4-\(interfaceLanguage)")
                        .functionTip("FILE FORMAT")
                        .labelsHidden()
                    }

                    SettingField("BOUNCE SOURCE") {
                        VStack(spacing: 7) {
                            Picker(L("Source Type"), selection: Binding(
                                get: { settings.mixSourceType },
                                set: { value in model.updateSelectedMixSourceType(value) }
                            )) {
                                ForEach([
                                    MixSourceType.bus,
                                    .trackOutput,
                                    .physicalOutput
                                ]) { type in
                                    Text(L(type.displayName)).tag(type)
                                }
                            }.id("picker5-\(interfaceLanguage)").functionTip("Source Type")
                            .labelsHidden()

                            let sources = model.availableMixSources(for: settings.mixSourceType)
                            Picker(L("Source"), selection: Binding(
                                get: { settings.mixSource },
                                set: { value in model.updateSelectedMixSource(value) }
                            )) {
                                if sources.isEmpty {
                                    Text(L("No \(settings.mixSourceType.displayName) sources available"))
                                        .tag("")
                                } else {
                                    if !settings.mixSource.isEmpty,
                                       !sources.contains(where: { $0.name == settings.mixSource }) {
                                        Text(L("Unavailable — \(settings.mixSource)"))
                                            .tag(settings.mixSource)
                                    }
                                    ForEach(sources) { source in
                                        Text(source.name).tag(source.name)
                                    }
                                }
                            }.id("picker6-\(interfaceLanguage)").functionTip("Source")
                            .labelsHidden()
                            .disabled(sources.isEmpty)
                        }
                    }

                    if settings.exportType == .mp3 || settings.exportType == .wavAndMP3 {
                        Divider()
                        SettingField("ENCODING QUALITY") {
                            Picker(L("Encoding Quality"), selection: Binding(
                                get: { settings.mp3Quality },
                                set: { value in model.updateSelectedSettings { $0.mp3Quality = value } }
                            )) {
                                ForEach(mp3Qualities) { quality in
                                    Text(L(quality.displayName)).tag(quality)
                                }
                            }.id("picker7-\(interfaceLanguage)").functionTip("Encoding Quality")
                            .labelsHidden()
                        }
                        SettingField("CONSTANT BIT RATE") {
                            Picker(L("Constant Bit Rate"), selection: Binding(
                                get: { settings.mp3ConstantBitRateKbps },
                                set: { value in model.updateSelectedSettings { $0.mp3ConstantBitRateKbps = value } }
                            )) {
                                ForEach([128, 160, 192, 256, 320], id: \.self) { rate in
                                    Text(L("\(rate) kbps")).tag(rate)
                                }
                            }.id("picker8-\(interfaceLanguage)").functionTip("Constant Bit Rate")
                            .labelsHidden()
                        }
                        if settings.exportType == .wavAndMP3 {
                            Label(L("One WAV Bounce; MP3 is encoded locally. Import uses WAV only."), systemImage: "bolt.horizontal.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(L("MP3 is exported directly by Pro Tools."), systemImage: "waveform.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { settings.offlineBounce },
                        set: { value in model.updateSelectedSettings { $0.offlineBounce = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Offline Bounce"))
                            Text(L(settings.offlineBounce ? "Exports faster than real time" : "Real-time Bounce"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .functionTip("Offline Bounce")

                    Toggle(isOn: Binding(
                        get: { settings.padToFrameBoundary },
                        set: { value in model.updateSelectedSettings { $0.padToFrameBoundary = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Pad To Frame Boundary"))
                            Text(L(settings.padToFrameBoundary
                                ? "Extends both ends to complete video frames"
                                : "Keeps the exact Timeline Selection"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .functionTip("Pad To Frame Boundary")

                    SettingField("FILE DESTINATION") {
                        HStack(spacing: 7) {
                            TextField(L("Bounced Files Folder"), text: Binding(
                                get: { settings.fileDestination },
                                set: { value in model.updateSelectedSettings { $0.fileDestination = value } }
                            ))
                            .lineLimit(1)
                            Button(action: model.chooseDestination) {
                                Image(systemName: "folder")
                            }
                            .functionTip("Choose Bounced Files Folder")
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { settings.importAfterBounce },
                        set: { value in model.updateSelectedSettings { $0.importAfterBounce = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Import After Bounce"))
                            Text(L(importExplanation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .functionTip(model.isCrossSessionQueue ? "Unavailable for cross-Session Bounce" : settings.exportType == .mov ? "MOV cannot be imported after Bounce" : "Import After Bounce")
                    .disabled(settings.exportType == .mov || model.isCrossSessionQueue)

                    if model.isCrossSessionQueue {
                        Label(L("Import is disabled for cross-Session queues. Every Session is restored, verified, saved, and closed before the next opens."), systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(settingsDisabled)
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L(model.progressLabel))
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Text(model.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: model.progress)
                    .tint(model.job?.state == .recoveryRequired ? .red : .cyan)
            }

            if model.isBusy {
                Button(role: .destructive, action: model.cancelBounce) {
                    Label(L(model.job?.cancellationRequested == true ? "Cancelling…" : "Cancel Bounce"), systemImage: "xmark.octagon.fill")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCancel)
                .functionTip("Cancel Bounce")
            } else {
                AdaptiveControlRow {
                    Button(action: model.startBounce) {
                        LocalizedLabel(english: "Bounce Mixes", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(!model.canBounce)
                    .functionTip("Bounce Mixes")

                    Button(action: model.openBouncedFiles) {
                        LocalizedLabel(english: "Open Bounced Files", systemImage: "folder.badge.plus")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .functionTip("Open Bounced Files")
                    .disabled(model.plans.isEmpty && model.batchDestinations.isEmpty)
                }
            }
        }
        .padding(20)
    }

    private var importExplanation: String {
        if model.isCrossSessionQueue { return "Unavailable for cross-Session Bounce" }
        if settings.exportType == .mov { return "MOV cannot be imported after Bounce" }
        if settings.exportType == .wavAndMP3 { return "Imports WAV only after the whole round" }
        return "Imports after all Mixes finish and Session state is restored"
    }

    private var sampleRates: [Int] {
        if settings.exportType == .mp3 { return [44_100, 48_000] }
        if settings.exportType == .mov, settings.movAudioCodec == .aac {
            // A copied or older preset can still show its saved value so the
            // user can choose a supported rate before export.
            let rates = MOVAudioCodec.aacSampleRates
            return rates.contains(settings.sampleRate) ? rates : (rates + [settings.sampleRate]).sorted()
        }
        return [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    }

    private var mp3Qualities: [MP3EncodingQuality] {
        settings.exportType == .mp3
            ? [.fastest, .highest]
            : MP3EncodingQuality.allCases
    }

    private var reviewToggleHelp: String {
        if model.isKeepOnTopMode { return "Review stays hidden in Keep on Top mode" }
        return model.isReviewExpanded
            ? "Collapse Bounced Files and waveform review"
            : "Expand Bounced Files and waveform review"
    }
}

private struct AddMixShortcutSettings: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Add Mix Shortcut"), systemImage: "keyboard")
                .font(.headline)

            AddMixShortcutRecorder(shortcut: Binding(
                get: { model.addMixShortcut },
                set: { model.updateAddMixShortcut($0) }
            ))
            .frame(width: 180, height: 28)
            .functionTip("Record Add Mix shortcut")

            Text(L("Click the shortcut, then press a key with Command, Option, or Control. Press Delete to clear it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Label(
                L(model.isAddMixShortcutActive ? "Active in Keep on Top mode" : "Activates only in Keep on Top mode"),
                systemImage: model.isAddMixShortcutActive ? "checkmark.circle.fill" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(model.isAddMixShortcutActive ? Color.green : Color.secondary)

            Text(L("While active, QuickBounce receives this shortcut before Pro Tools, brings its window forward, and opens Add Mix."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(L("Use Default")) { model.restoreDefaultAddMixShortcut() }.functionTip("Use Default")
                Spacer()
                Button(L("Clear")) { model.updateAddMixShortcut(nil) }.functionTip("Clear")
                    .disabled(model.addMixShortcut == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct SettingField<Content: View>: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(title))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .functionTip(title)
            content
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ReviewPanel: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @AppStorage("review.visibleAudioMetrics.v1") private var visibleMetricPreference =
        DisplayedAudioMetric.defaultPreference
    @State private var isMetricsPopoverPresented = false

    private var visibleMetrics: Set<DisplayedAudioMetric> {
        DisplayedAudioMetric.decodePreference(visibleMetricPreference)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("BOUNCED FILES & INTEGRITY VERIFICATION"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingWaveforms {
                    ProgressView().controlSize(.small)
                    Text(L("Analyzing audio"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ArtifactList(model: model)
                .frame(minHeight: 112, idealHeight: 160, maxHeight: 220)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    modePicker
                    Spacer(minLength: 8)
                    reviewActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    modePicker
                    HStack {
                        Spacer(minLength: 0)
                        reviewActions
                    }
                }
            }

            if model.reviewMode == .stemsCheck {
                WaveformViewportControls(model: model)
            }

            ReviewContent(model: model, visibleMetrics: visibleMetrics)

            TransportBar(model: model, clock: model.playbackClock)
        }
        .padding(20)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            Text(L("Review Mode")).fixedSize()
            ReviewModePicker(selection: Binding(
                get: { model.reviewMode },
                set: { model.setReviewMode($0) }
            ))
            .frame(height: 24)
        }
        .frame(maxWidth: 330)
    }

    private var reviewActions: some View {
        HStack(spacing: 8) {
            Button {
                isMetricsPopoverPresented.toggle()
            } label: {
                LocalizedLabel(english: "Metrics", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .functionTip("Metrics")
            .popover(isPresented: $isMetricsPopoverPresented, arrowEdge: .top) {
                VStack(spacing: 2) {
                    ForEach(DisplayedAudioMetric.allCases) { metric in
                        MetricSelectionRow(
                            metric: metric,
                            isSelected: visibleMetrics.contains(metric),
                            action: { toggleMetric(metric) }
                        )
                    }
                }
                .padding(8)
                .frame(width: 310)
            }

            if model.selectedMOV != nil {
                Button {
                    model.toggleQuickLook()
                } label: {
                    LocalizedLabel(english: "Quick Look", systemImage: "eye")
                }
                .functionTip("Quick Look")
            }
        }
        .fixedSize()
    }

    private func toggleMetric(_ metric: DisplayedAudioMetric) {
        var next = visibleMetrics
        if next.contains(metric) {
            next.remove(metric)
        } else {
            next.insert(metric)
        }
        visibleMetricPreference = DisplayedAudioMetric.encodePreference(next)
    }
}

private struct MetricSelectionRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let metric: DisplayedAudioMetric
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(L(metric.title))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 16, alignment: .trailing)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(L(metric.title))
        .accessibilityValue(L(isSelected ? "Shown" : "Hidden"))
    }
}

private struct WaveformViewportControls: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Label(L("Waveform Zoom"), systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.setWaveformZoom(model.waveformZoom / 2)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(model.waveformZoom <= 1)
            .functionTip("Zoom Out")

            Slider(
                value: Binding(
                    get: { model.waveformZoom },
                    set: { value in model.setWaveformZoom(value) }
                ),
                in: 1...32
            )
            .frame(maxWidth: 150)
            .functionTip("Waveform Zoom")
            .disabled(model.selectedAudioArtifacts.isEmpty)

            Button {
                model.setWaveformZoom(model.waveformZoom * 2)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.waveformZoom >= 32 || model.selectedAudioArtifacts.isEmpty)
            .functionTip("Zoom In")

            Text(zoomLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Slider(
                value: Binding(
                    get: { model.waveformScroll },
                    set: { value in model.setWaveformScroll(value) }
                ),
                in: 0...1
            )
            .functionTip("Scroll the shared time window")
            .disabled(model.waveformZoom <= 1 || model.selectedAudioArtifacts.isEmpty)

            Button(L("Fit"), action: model.fitWaveforms).functionTip("Fit")
                .buttonStyle(.borderless)
                .disabled(model.waveformZoom == 1)
        }
        .controlSize(.small)
    }

    private var zoomLabel: String {
        model.waveformZoom == 1
            ? "×1"
            : String(format: "×%.1f", model.waveformZoom)
    }
}

private struct ArtifactList: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(model.artifacts) { artifact in
                    ArtifactRow(
                        artifact: artifact,
                        selected: model.selectedArtifactIDs.contains(artifact.id),
                        waveform: model.waveforms[artifact.id],
                        canRemove: !model.isQueueLocked,
                        remove: { model.removeArtifactFromList(artifact.id) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.selectArtifact(artifact.id)
                        if artifact.kind == .mov { model.openMOV(artifact) }
                    }
                    .onTapGesture {
                        model.selectArtifact(
                            artifact.id,
                            modifiers: NSApp.currentEvent?.modifierFlags ?? []
                        )
                    }
                    .contextMenu {
                        Button {
                            model.reveal(artifact)
                        } label: {
                            Label(L("Reveal in Finder"), systemImage: "folder")
                        }
                        .disabled(!FileManager.default.fileExists(atPath: artifact.path))
                        .menuFunctionTip("Reveal in Finder")

                        if artifact.kind == .mov {
                            Button {
                                model.openMOV(artifact)
                            } label: {
                                Label(L("Open in Default Player"), systemImage: "play.rectangle")
                            }
                        }
                    }
                }

                if model.artifacts.isEmpty {
                    ContentUnavailableView(
                        L("No Bounced Files"),
                        systemImage: "waveform.path.ecg.rectangle",
                        description: Text(L("Completed files from the current batch appear here."))
                    )
                    .frame(minHeight: 100)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary)
        }
    }
}

private struct ArtifactRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let artifact: AudioArtifact
    let selected: Bool
    let waveform: WaveformPyramid?
    let canRemove: Bool
    let remove: () -> Void

    private var stateColor: Color {
        switch artifact.state {
        case .completed: .green
        case .candidate: .cyan
        case .partial: .orange
        case .invalid: .red
        }
    }

    private var stateIcon: String {
        switch artifact.state {
        case .completed: "checkmark.circle.fill"
        case .candidate: "arrow.down.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .invalid: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L(metadataSummary))
                    .functionTip("Artifact Row")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if artifact.kind == .mov {
                Label(L("Quick Look"), systemImage: "play.rectangle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 86)
            } else {
                MiniWaveform(pyramid: waveform, color: selected ? .cyan : .secondary)
                    .frame(width: 86, height: 26)
            }
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!canRemove)
            .functionTip("Remove from QuickBounce list (keeps the bounced file on disk)")
            .accessibilityLabel(L("Remove \(artifact.name) from QuickBounce list"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var metadataSummary: String {
        let state = L(artifact.state.rawValue.capitalized)
        let format = artifact.kind.rawValue.uppercased()
        let length: String
        if let seconds = artifact.durationSeconds ?? artifactDuration {
            let total = Int(max(0, seconds).rounded(.down))
            length = String(format: "%d:%02d", total / 60, total % 60)
        } else {
            length = "—"
        }
        let sampleRate = artifact.sampleRate.map {
            $0.truncatingRemainder(dividingBy: 1_000) == 0
                ? String(format: "%.0f kHz", $0 / 1_000)
                : String(format: "%.1f kHz", $0 / 1_000)
        } ?? "— kHz"
        let bitDepth = artifact.bitDepth.map { "\($0)-bit" } ?? "— bit"
        return "\(state)  ·  \(format)  ·  \(length)  ·  \(sampleRate)  ·  \(bitDepth)"
    }

    private var artifactDuration: Double? {
        guard let frames = artifact.frameCount,
              let sampleRate = artifact.sampleRate,
              sampleRate > 0 else { return nil }
        return Double(frames) / sampleRate
    }

}

private struct ReviewContent: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    let visibleMetrics: Set<DisplayedAudioMetric>

    var body: some View {
        Group {
            if !model.selectedAudioArtifacts.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.selectedAudioArtifacts) { artifact in
                            ReviewWaveformRow(
                                artifact: artifact,
                                pyramid: model.waveforms[artifact.id],
                                playbackClock: model.playbackClock,
                                viewportStart: model.waveformViewportStart,
                                viewportDuration: model.waveformViewportDuration,
                                mode: model.reviewMode,
                                audible: model.activeMixID == artifact.id,
                                stemState: model.stemStates[artifact.id] ?? StemPlaybackState(artifactID: artifact.id),
                                visibleMetrics: visibleMetrics,
                                selectMix: { model.selectAudibleMix(artifact.id) },
                                solo: { model.toggleStemSolo(artifact.id) },
                                mute: { model.toggleStemMute(artifact.id) },
                                seek: { position in
                                    if model.reviewMode == .mixCompare {
                                        model.selectAudibleMix(artifact.id)
                                    }
                                    model.seek(to: position)
                                },
                                analysisError: model.analysisErrors[artifact.id],
                                retryAnalysis: { model.retryAnalysis(artifact.id) }
                            )
                        }
                    }
                }
            } else if let movie = model.selectedMOV {
                MOVReviewPlaceholder(
                    artifact: movie,
                    quickLook: model.toggleQuickLook,
                    open: { model.openMOV(movie) }
                )
            } else {
                ContentUnavailableView(
                    L("Select WAV or MP3 Files"),
                    systemImage: "waveform",
                    description: Text(L("Click one file, Shift-click to add a range, or Option-click to select all."))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct MOVReviewPlaceholder: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let artifact: AudioArtifact
    let quickLook: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 52))
                .foregroundStyle(.cyan)
            Text(artifact.name)
                .font(.title3.weight(.semibold))
            Text(L("MOV uses macOS system preview and never enters the waveform or audio Review graph."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(L("Quick Look (Space)"), action: quickLook).functionTip("Quick Look (Space)")
                    .buttonStyle(.borderedProminent)
                Button(L("Open in Default Player"), action: open).functionTip("Open in Default Player")
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TransportBar: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @ObservedObject var clock: ReviewPlaybackClock

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { min(clock.sample.position, max(model.playbackDuration, 0)) },
                    set: { value in model.seek(to: value) }
                ),
                in: 0...max(0.001, model.playbackDuration)
            )
            .tint(.cyan)
            .disabled(model.isBusy || model.playbackDuration <= 0)
            .functionTip("Seek")

            HStack {
                Text(time(clock.sample.position))
                    .font(.system(.headline, design: .monospaced))
                Text(L("/ \(time(model.playbackDuration))"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.stopPlayback) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .functionTip("Stop")
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(model.isBusy || model.selectedAudioArtifacts.isEmpty)
                .functionTip(model.isPlaying ? "Pause" : "Play")
                Spacer()
                Text(L(model.reviewMode == .mixCompare ? "Full song · one audible Mix" : "Does not change file volume"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.quaternary) }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}

private struct MasterStrip: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @ObservedObject var meter: ReviewMeterState

    var body: some View {
        VStack(spacing: 12) {
            Text(L("MASTER"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    Text(L("TRIM"))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    VerticalTrimSlider(value: Binding(
                        get: { model.monitorTrimDB },
                        set: { value in model.setMonitorTrim(value) }
                    ))
                    Text(String(format: "%.1f", model.monitorTrimDB))
                        .font(.caption2.monospacedDigit())
                }
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        MeterBar(level: meter.reading.peakLeft)
                        if model.monitorChannelCount <= 2 { MeterBar(level: meter.reading.peakRight) }
                    }
                    HStack(spacing: 12) {
                        if model.monitorChannelCount > 2 {
                            Text(L("ALL"))
                        } else {
                            Text(L("L"))
                            Text(L("R"))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                }
            }
            if model.monitorDownmix {
                Text(L("Downmix preview")).font(.caption2).foregroundStyle(.secondary)
            } else if model.monitorChannelCount > 2 {
                Text("\(model.monitorChannelCount) ch").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(model.monitorWarnings, id: \.self) { warning in
                Text(L(warning)).font(.caption2).foregroundStyle(.orange)
            }
            if meter.reading.hasOver {
                Text(L("OVER"))
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            } else {
                Text(L("PROGRAM"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct VerticalTrimSlider: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @Binding var value: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.cyan.opacity(0.8))
                    .frame(height: proxy.size.height * CGFloat((value + 60) / 66))
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay { Circle().stroke(Color.secondary.opacity(0.6)) }
                    .shadow(radius: 1)
                    .frame(width: 18, height: 18)
                    .offset(y: -max(0, proxy.size.height * CGFloat((value + 60) / 66) - 9))
            }
            .frame(width: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let fraction = 1 - min(1, max(0, gesture.location.y / proxy.size.height))
                    value = Float(fraction) * 66 - 60
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        }
        .frame(width: 26, height: 360)
        .functionTip("Monitor Trim")
        .accessibilityLabel(L("Monitor Trim"))
        .accessibilityValue("\(value) dB")
    }
}

private struct MeterBar: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    let level: Float

    private var normalized: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db + 60) / 66)))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.22))
                VStack(spacing: 0) {
                    Color.red.frame(height: proxy.size.height * 0.09)
                    Color.yellow.frame(height: proxy.size.height * 0.18)
                    Color.green.frame(maxHeight: .infinity)
                }
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: proxy.size.height * normalized)
                }
            }
        }
        .frame(width: 14, height: 390)
        .functionTip("Program Meter")
    }
}

private struct AddMixSheet: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @State private var name: String
    @State private var note = ""
    @State private var isSaving = false
    private let initialCaretOffset: Int

    init(model: AppModel) {
        self.model = model
        let draft = MixNameDraft(prefix: model.mixNamePrefix, suffix: model.mixNameSuffix)
        _name = State(initialValue: draft.text)
        initialCaretOffset = draft.caretOffset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading) {
                    Text(L("Add Mix Snapshot"))
                        .font(.title3.weight(.semibold))
                    Text(L("QuickBounce is capturing the current Solo/Mute state and Timeline Selection."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker(L("Bounce Preset"), selection: $model.capturePresetID) {
                    Text(L("Current Settings")).tag(nil as UUID?)
                    ForEach(model.presetLibrary.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }.id("picker10-\(interfaceLanguage)").functionTip("Bounce Preset")
                LabeledContent(L("Mix Name")) {
                    MixNameTextField(text: $name, initialCaretOffset: initialCaretOffset)
                        .functionTip("Mix Name")
                        .frame(minWidth: 220, minHeight: 22)
                }
                TextField(L("Note"), text: $note, axis: .vertical).functionTip("Note")
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            if model.isPreparingMix {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Reading Pro Tools…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { model.cancelMixCapture() }.functionTip("Cancel（Add Mix）")
                    .keyboardShortcut(.cancelAction)
                Button(L("Add Mix")) {
                    isSaving = true
                    Task {
                        _ = await model.commitMix(name: name, note: note)
                        isSaving = false
                    }
                }.functionTip("Add Mix（确认按钮）")
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 470)
        .interactiveDismissDisabled()
        .friendlyErrorAlert(model: model)
    }
}
