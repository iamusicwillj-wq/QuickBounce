import AppKit
import SwiftUI

struct SessionSettingsControl: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @ObservedObject var model: AppModel
    @State private var searchPresented = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if model.sessionSettingsHistory.isEmpty {
                    Button(L("No saved Session Settings yet.")) {}.disabled(true)
                }
                historyItems(Array(model.sessionSettingsHistory.prefix(5)))
                if model.sessionSettingsHistory.count > 5 {
                    Divider()
                    Menu(L("Show More")) {
                        historyItems(Array(model.sessionSettingsHistory.prefix(10)))
                        if model.sessionSettingsHistory.count > 10 {
                            Divider()
                            Button(L("Show More"), action: showAll).menuFunctionTip("Show More Session Settings")
                        }
                    }
                }
            } label: {
                Label(model.sessionSettingsTitle, systemImage: "doc.badge.gearshape")
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 100, maxWidth: .infinity)
            .functionTip("Session Settings")
            HStack(spacing: 4) {
                Button { save(asNew: false) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 20, height: 20)
                }
                .accessibilityLabel(L("Update Session Settings"))
                .functionTip("Update Session Settings")
                .disabled(model.currentSessionSettingsEntry == nil || model.plans.isEmpty)
                Button { save(asNew: true) } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .accessibilityLabel(L("New Session Settings…"))
                .functionTip("New Session Settings…")
                .disabled(model.plans.isEmpty)
                Button(action: model.openSessionSettingsFolder) {
                    Image(systemName: "folder").frame(width: 20, height: 20)
                }
                .accessibilityLabel(L("Open Settings Folder"))
                .functionTip("Open Settings Folder")
                Button { searchPresented.toggle() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 20, height: 20)
                }
                .accessibilityLabel(L("Search Session Settings"))
                .functionTip("Search Session Settings")
                .popover(isPresented: $searchPresented, arrowEdge: .bottom) {
                    SessionSettingsSearchView(model: model, load: load)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .disabled(!model.canManageSettings || model.sessionSettingsSaveDraft != nil)
        .onAppear { model.refreshSessionSettingsHistory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSessionSettingsHistory()
        }
    }

    private func historyItems(_ entries: [SessionSettingsLibrary.Entry]) -> some View {
        ForEach(entries) { entry in
            Button(entry.name) { load(entry) }
                .disabled(!model.canManageSettings || model.connectionStatus != .connected)
                .menuFunctionTip("Load Session Settings")
        }
    }

    private func save(asNew: Bool) {
        searchPresented = false
        DispatchQueue.main.async { model.beginSavingSessionSettings(asNew: asNew) }
    }

    private func showAll() {
        searchPresented = false
        DispatchQueue.main.async { model.isPresentingSessionSettingsHistory = true }
    }

    private func load(_ entry: SessionSettingsLibrary.Entry) {
        searchPresented = false
        model.loadSessionSettings(entry)
    }
}

struct SessionSettingsSearchView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @ObservedObject var model: AppModel
    let load: (SessionSettingsLibrary.Entry) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var entries: [SessionSettingsLibrary.Entry] {
        SessionSettingsLibrary.visibleEntries(model.sessionSettingsHistory, query: query, searching: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Search all saved settings"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty {
                        Text(L(model.sessionSettingsHistory.isEmpty ? "No saved Session Settings yet." : "No matching settings."))
                            .foregroundStyle(.secondary).font(.callout).padding(.vertical, 8)
                    }
                    ForEach(entries) { entry in
                        Button { load(entry) } label: {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .functionTip("Load Session Settings")
                        .disabled(!model.canManageSettings || model.connectionStatus != .connected)
                    }
                }
            }
            .frame(height: CGFloat(min(5, max(1, entries.count))) * 30)
        }
        .padding(12).frame(width: 350)
        .onAppear { model.refreshSessionSettingsHistory(); searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSessionSettingsHistory()
        }
    }
}

struct SessionSettingsHistorySheet: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [SessionSettingsLibrary.Entry] {
        SessionSettingsLibrary.visibleEntries(model.sessionSettingsHistory, query: query, searching: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Session Settings History")).font(.title3.bold())
            TextField(L("Search all saved settings"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty {
                        Text(L(model.sessionSettingsHistory.isEmpty ? "No saved Session Settings yet." : "No matching settings."))
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(entries) { entry in
                        Button {
                            dismiss()
                            model.loadSessionSettings(entry)
                        } label: {
                            HStack {
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .functionTip("Load Session Settings")
                        .disabled(!model.canManageSettings || model.connectionStatus != .connected)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 560, height: 460)
        .onAppear { model.refreshSessionSettingsHistory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSessionSettingsHistory()
        }
    }
}

struct NewSessionSettingsSheet: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @ObservedObject var model: AppModel
    let draft: SessionSettingsSaveDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var replacement: SessionSettingsLibrary.SaveRequest?
    @State private var confirmingReplacement = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Save Session Settings")).font(.title3.bold())
            Text(L("Save all queued Mixes for the selected Session in QuickBounce’s settings folder. Use an existing name to update its settings."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L("Settings Name"), text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save"), action: prepareSave).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canManageSettings)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { name = draft.name; nameFocused = true }
        .alert(L("Replace Session Settings?"), isPresented: $confirmingReplacement) {
            Button(L("Cancel"), role: .cancel) { replacement = nil }
            Button(L("Replace"), role: .destructive) {
                if let request = replacement,
                   model.commitSessionSettingsSave(request, session: draft.session, replacing: true) { dismiss() }
                replacement = nil
            }
        } message: {
            Text(L("Settings named “\(replacement?.entry.name ?? name)” already exist. Replace them with the current Mixes?"))
        }
        .friendlyErrorAlert(model: model)
    }

    private func prepareSave() {
        do {
            let request = try model.sessionSettingsLibrary.prepareSave(name: name, document: draft.document)
            if request.requiresReplacement {
                replacement = request
                confirmingReplacement = true
            } else if model.commitSessionSettingsSave(request, session: draft.session) {
                dismiss()
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
}
