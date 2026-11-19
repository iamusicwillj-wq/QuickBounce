import SwiftUI

struct BouncePresetManager: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Bounce Settings Presets")).font(.title3.bold())
            Text(L("Choose a default preset or delete presets you no longer need."))
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.presetLibrary.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name)
                            Text(L("\(preset.settings.exportType.displayName) · \(preset.settings.sampleRate) Hz · \(preset.settings.bitDepth)-bit"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.presetLibrary.defaultPresetID == preset.id {
                            Label(L("Default"), systemImage: "checkmark").foregroundStyle(.cyan)
                        } else {
                            Button(L("Make Default")) { model.changePresetLibrary(defaultID: preset.id) }.functionTip("Make Default")
                        }
                        Button(role: .destructive) { model.changePresetLibrary(removing: preset.id) } label: {
                            Image(systemName: "trash")
                        }
                        .functionTip("Delete preset")
                    }
                }
            }
            .frame(height: 220)
            .disabled(model.isManagingSettings)
            Text(L("The default preset is selected automatically each time you Add Mix."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Clear Default")) { model.changePresetLibrary() }.functionTip("Clear Default")
                    .disabled(model.presetLibrary.defaultPresetID == nil || model.isManagingSettings)
                Spacer()
                Button(L("Done")) { dismiss() }.functionTip("Done").keyboardShortcut(.defaultAction)
                    .disabled(model.isManagingSettings)
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled(model.isManagingSettings)
        .friendlyErrorAlert(model: model)
    }
}

struct NewBouncePresetSheet: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("New Bounce Settings Preset")).font(.title3.bold())
            Text(L("Save the current settings of the first selected Mix."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L("Preset Name"), text: $name).functionTip("Preset Name")
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.functionTip("Cancel")
                    .keyboardShortcut(.cancelAction)
                Button(L("Confirm")) {
                    Task { if await model.savePreset(name: name) { dismiss() } }
                }.functionTip("Confirm")
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .disabled(model.isManagingSettings)
        .interactiveDismissDisabled(model.isManagingSettings)
        .onAppear { nameFocused = true }
        .friendlyErrorAlert(model: model)
    }
}
