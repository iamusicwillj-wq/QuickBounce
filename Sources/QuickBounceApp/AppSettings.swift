import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "quickbounce.appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow macOS"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    func apply() {
        // nil removes the override so macOS changes continue to propagate.
        // App-wide appearance includes sheets, menus and native file panels.
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettingsView: View {
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system.rawValue
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage(FunctionTipsPreference.key) private var functionTips = true

    private var currentLanguage: AppLanguage { AppLanguage(rawValue: language) ?? .english }
    private func copy(_ value: String) -> String { Copy.text(value, language: currentLanguage) }

    var body: some View {
        Form {
            Section(copy("Appearance")) {
                Picker(copy("Theme"), selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(copy(theme.title)).tag(theme.rawValue)
                    }
                }.id("picker1-\(language)").functionTip("Theme")
                .pickerStyle(.segmented)
                Picker(copy("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }.id("picker2-\(language)").functionTip("Language")
                Toggle(copy("Show Function Tips"), isOn: $functionTips).functionTip("Show Function Tips")
                Text(copy("Choose Light, Dark, or follow your Mac’s appearance. Changes apply immediately."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 240)
        .onAppear {
            (AppTheme(rawValue: theme) ?? .system).apply()
            DispatchQueue.main.async { NativeMenuLanguage.shared.apply() }
        }
        .onChange(of: language) { _, _ in
            DispatchQueue.main.async { NativeMenuLanguage.shared.apply() }
        }
        .onChange(of: theme) { _, value in
            (AppTheme(rawValue: value) ?? .system).apply()
        }
    }
}
