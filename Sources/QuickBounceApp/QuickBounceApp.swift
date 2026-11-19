import SwiftUI

@main
struct QuickBounceDesktopApp: App {
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system.rawValue
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Quick Bounce") {
            QuickBounceWorkspace(model: model)
                .tint(.cyan)
                .onAppear {
                    (AppTheme(rawValue: theme) ?? .system).apply()
                    DispatchQueue.main.async { NativeMenuLanguage.shared.apply() }
                }
                .onChange(of: interfaceLanguage) { _, _ in
                    DispatchQueue.main.async { NativeMenuLanguage.shared.apply() }
                }
                .onChange(of: theme) { _, value in
                    (AppTheme(rawValue: value) ?? .system).apply()
                }
        }
        .defaultSize(width: 1_560, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("About QuickBounce"), action: AppAttribution.showAbout)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(L("Settings…")) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button(L("Export Diagnostic Log…")) {
                    model.exportDiagnosticLog()
                }
                .disabled(!model.canExportDiagnosticLog)
                .menuFunctionTip("Export Diagnostic Log…")
            }

            CommandMenu(L("Review")) {
                Button(L(reviewSpacebarTitle)) {
                    model.handleReviewSpacebar()
                }
                .disabled(!model.canHandleReviewSpacebar)
                .menuFunctionTip(reviewSpacebarTitle)

                Button(L("Close Quick Look")) {
                    model.quickLook.close()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            CommandMenu(L("Workspace")) {
                Button(L(model.isKeepOnTopMode ? "Exit Keep on Top" : "Keep on Top")) {
                    model.toggleKeepOnTopMode()
                }

                Button(L(model.isReviewExpanded ? "Collapse Review" : "Expand Review")) {
                    model.toggleReviewPane()
                }
                .disabled(model.isKeepOnTopMode)
            }
        }

        Settings {
            AppSettingsView()
        }
    }

    private var reviewSpacebarTitle: String {
        if !model.selectedAudioArtifacts.isEmpty {
            return model.isPlaying ? "Pause" : "Play"
        }
        return "Quick Look Selected Movie"
    }
}
