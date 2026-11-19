import AppKit
import SwiftUI

extension Copy {
    static func tip(_ key: String, language: AppLanguage, enabled: Bool = true) -> String? {
        guard enabled, let entry = InterfaceCopy.tips[key], entry.count == 2 else { return nil }
        return entry[language == .english ? 0 : 1]
    }
}

extension View {
    func functionTip(_ key: String) -> some View { modifier(FunctionTipModifier(key: key)) }
}

private struct FunctionTipModifier: ViewModifier {
    let key: String
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @AppStorage(FunctionTipsPreference.key) private var enabled = true
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            // A tracking view keeps tips available for disabled controls too.
            .background {
                FunctionTipTrackingView(
                    owner: owner,
                    key: key,
                    language: AppLanguage(rawValue: language) ?? .english,
                    enabled: enabled
                )
            }
            .onChange(of: enabled) { _, _ in FunctionTipWindow.shared.dismiss(owner: owner) }
            .onChange(of: language) { _, _ in FunctionTipWindow.shared.dismiss(owner: owner) }
            .onChange(of: key) { _, _ in FunctionTipWindow.shared.dismiss(owner: owner) }
            .onDisappear { FunctionTipWindow.shared.dismiss(owner: owner) }
    }
}

struct FunctionTipTrackingView: NSViewRepresentable {
    let owner: UUID
    let key: String
    let language: AppLanguage
    let enabled: Bool

    func makeNSView(context: Context) -> TipTrackingNSView {
        let view = TipTrackingNSView()
        view.configure(owner: owner, key: key, language: language, enabled: enabled)
        return view
    }

    func updateNSView(_ view: TipTrackingNSView, context: Context) {
        view.configure(owner: owner, key: key, language: language, enabled: enabled)
    }

    static func dismantleNSView(_ view: TipTrackingNSView, coordinator: ()) {
        view.dismissTip()
    }
}

final class TipTrackingNSView: NSView {
    private var owner = UUID()
    private var key = ""
    private var language: AppLanguage = .english
    private var enabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(owner: UUID, key: String, language: AppLanguage, enabled: Bool) {
        if self.owner != owner || self.key != key || self.language != language || self.enabled != enabled {
            FunctionTipWindow.shared.dismiss(owner: self.owner)
        }
        self.owner = owner
        self.key = key
        self.language = language
        self.enabled = enabled
    }

    func dismissTip() { FunctionTipWindow.shared.dismiss(owner: owner) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        guard enabled, let text = Copy.tip(key, language: language) else { return }
        FunctionTipWindow.shared.schedule(owner: owner, text: text)
    }

    override func mouseExited(with event: NSEvent) {
        FunctionTipWindow.shared.dismiss(owner: owner)
    }
}

/// One nonactivating panel for the entire app. No audio or Pro Tools work runs here.
@MainActor
final class FunctionTipWindow {
    static let shared = FunctionTipWindow()
    private var owner: UUID?
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func schedule(owner: UUID, text: String) {
        dismiss()
        self.owner = owner
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, self.owner == owner, NSApp.isActive else { return }
            self.show(text)
        }
    }

    func dismiss(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
        panel = nil
        self.owner = nil
    }

    private func show(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 290
        let width = min(290, max(80, label.intrinsicContentSize.width))
        let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 40
        let size = NSSize(width: width + 22, height: ceil(height) + 16)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSApp.effectiveAppearance
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 11, y: 8, width: width, height: size.height - 16)
        background.addSubview(label)
        panel.contentView = background
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y + 20)
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        if origin.y + size.height > bounds.maxY - 6 { origin.y = point.y - size.height - 20 }
        origin.y = max(bounds.minY + 6, origin.y)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        self.panel = panel
    }
}

// Native menus render their items outside the SwiftUI view hierarchy. Let AppKit
// present these explanations, using the same language and preference as panels.
extension View {
    func menuFunctionTip(_ key: String) -> some View { modifier(MenuFunctionTipModifier(key: key)) }
}

private struct MenuFunctionTipModifier: ViewModifier {
    let key: String
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @AppStorage(FunctionTipsPreference.key) private var enabled = true
    func body(content: Content) -> some View {
        content.help(Copy.tip(key, language: AppLanguage(rawValue: language) ?? .english, enabled: enabled) ?? "")
    }
}
