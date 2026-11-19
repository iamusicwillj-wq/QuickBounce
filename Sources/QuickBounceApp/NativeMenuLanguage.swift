import AppKit

/// SwiftUI owns menu construction; translate only standard system commands.
/// User presets, file names, recent items and window names are never looked up.
@MainActor
final class NativeMenuLanguage {
    static let shared = NativeMenuLanguage()
    private let originalTitles = NSMapTable<NSMenuItem, NSString>.weakToStrongObjects()
    private var observer: NSObjectProtocol?
    private let actions: Set<String> = [
        "orderFrontStandardAboutPanel:", "hide:", "hideOtherApplications:", "unhideAllApplications:",
        "terminate:", "performClose:", "performMiniaturize:", "performZoom:", "arrangeInFront:",
        "undo:", "redo:", "cut:", "copy:", "paste:", "delete:", "selectAll:",
        "toggleFullScreen:", "showSettingsWindow:", "showPreferencesWindow:"
    ]
    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }
    func apply() {
        guard let menu = NSApp.mainMenu else { return }
        translate(menu, topLevel: true)
        for window in NSApp.windows where window.title == "QuickBounce Settings" || window.title == "QuickBounce 设置" {
            window.title = "QuickBounce " + L("Settings")
        }
    }
    private func translate(_ menu: NSMenu, topLevel: Bool = false) {
        for item in menu.items {
            let knownHeading = topLevel && ["File", "Edit", "View", "Window", "Help"].contains(item.title)
            let systemAction = item.action.map { actions.contains(NSStringFromSelector($0)) } ?? false
            if let original = originalTitles.object(forKey: item) {
                item.title = L(original as String)
            } else if knownHeading || systemAction {
                originalTitles.setObject(item.title as NSString, forKey: item)
                item.title = L(item.title)
            }
            if let submenu = item.submenu {
                if topLevel, originalTitles.object(forKey: item) != nil { submenu.title = item.title }
                translate(submenu)
            }
        }
    }
}
