import AppKit
import SwiftUI

/// The author's name remains the same in both interface languages.
struct AuthorSignature: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("by")
                .font(.system(size: 10))
            Text("Huang Wenjie")
                .font(.system(size: 15, weight: .medium, design: .serif).italic())
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("by Huang Wenjie")
    }
}

@MainActor
enum AppAttribution {
    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "QuickBounce",
            .credits: NSAttributedString(string: ""),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Huang Wenjie"
        ])
    }
}
