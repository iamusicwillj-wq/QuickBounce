@preconcurrency import Carbon
import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct ReviewPaneAutoExpansionPolicy: Sendable {
    private(set) var hasExpandedForFirstCompletedMix = false

    mutating func shouldExpand(completedPlanCount: Int) -> Bool {
        guard !hasExpandedForFirstCompletedMix, completedPlanCount > 0 else {
            return false
        }
        hasExpandedForFirstCompletedMix = true
        return true
    }
}

struct AddMixShortcut: Codable, Equatable, Sendable {
    struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        let rawValue: UInt8

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    var keyCode: UInt32
    var modifiers: Modifiers
    var keyLabel: String

    static let defaultValue = AddMixShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: [.control, .option],
        keyLabel: "A"
    )

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    @MainActor
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        // Requiring Command, Option, or Control prevents an ordinary typing
        // key (or Shift plus a key) from being captured system-wide.
        guard !modifiers.intersection([.command, .option, .control]).isEmpty,
              !Self.modifierKeyCodes.contains(event.keyCode),
              let keyLabel = Self.keyLabel(for: event) else {
            return nil
        }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: keyLabel
        )
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock), UInt16(kVK_Function)
    ]

    @MainActor
    private static func keyLabel(for event: NSEvent) -> String? {
        if let functionKey = functionKeyLabel(keyCode: Int(event.keyCode)) {
            return functionKey
        }
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else {
                return nil
            }
            return String(characters.prefix(1)).uppercased()
        }
    }

    private static func functionKeyLabel(keyCode: Int) -> String? {
        let keys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
        ]
        return keys[keyCode]
    }
}

enum AddMixShortcutStore {
    private static let key = "addMix.globalShortcut.v1"

    static func load() -> AddMixShortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .defaultValue
        }
        return try? JSONDecoder().decode(AddMixShortcut.self, from: data)
    }

    static func save(_ shortcut: AddMixShortcut?) {
        guard let shortcut else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(true, forKey: key + ".cleared")
            return
        }
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".cleared")
        }
    }

    static func loadRespectingExplicitClear() -> AddMixShortcut? {
        if UserDefaults.standard.bool(forKey: key + ".cleared") {
            return nil
        }
        return load()
    }
}

enum GlobalHotKeyError: LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .eventHandler(status):
            return "QuickBounce could not start the shortcut listener (macOS status \(status))."
        case let .registration(status):
            if status == eventHotKeyExistsErr {
                return "That shortcut is already used by another app or by macOS. Choose a different shortcut."
            }
            return "macOS could not register that shortcut (status \(status)). Choose a different shortcut."
        }
    }
}

@MainActor
final class GlobalHotKeyController {
    private static let signature: OSType = 0x51424D58 // "QBMX"
    private static let identifier: UInt32 = 1

    // Carbon owns these opaque handles. They are installed and mutated only
    // from the main actor; marking the storage unsafe allows deinit to release
    // them synchronously under Swift 6's nonisolated-deinit rules.
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?

    init() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            quickBounceGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else { throw GlobalHotKeyError.eventHandler(status) }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    func register(shortcut: AddMixShortcut, action: @escaping () -> Void) throws {
        unregister()
        self.action = action
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            self.action = nil
            throw GlobalHotKeyError.registration(status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        action = nil
    }

    fileprivate func handle(identifier: EventHotKeyID) {
        guard identifier.signature == Self.signature,
              identifier.id == Self.identifier else { return }
        action?()
    }
}

private func quickBounceGlobalHotKeyHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }
    let controller = Unmanaged<GlobalHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        controller.handle(identifier: identifier)
    }
    return noErr
}

@MainActor
final class WorkspaceWindowController {
    private weak var window: NSWindow?
    private var regularContentWidth: CGFloat = 1_560
    private var compact = false
    private var animationGeneration = 0
    private var baseLevel: NSWindow.Level = .normal
    private var baseCollectionBehavior: NSWindow.CollectionBehavior = []
    private var reviewExpanded = false
    private var keepOnTop = false
    private var screenObservers: [NSObjectProtocol] = []

    func attach(
        window: NSWindow,
        reviewExpanded: Bool,
        keepOnTop: Bool
    ) {
        // NSViewRepresentable is updated during layout too. Reapplying here
        // interrupted the resize animation and raised its minimum too early.
        guard self.window !== window else { return }
        removeScreenObservers()
        self.window = window
        regularContentWidth = max(1_280, window.contentLayoutRect.width)
        baseLevel = window.level
        baseCollectionBehavior = window.collectionBehavior
        compact = false
        for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            screenObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: name == NSWindow.didChangeScreenNotification ? window : nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.apply(reviewExpanded: self.reviewExpanded, keepOnTop: self.keepOnTop, animated: false)
                }
            })
        }
        apply(reviewExpanded: reviewExpanded, keepOnTop: keepOnTop, animated: false)
    }

    func apply(reviewExpanded: Bool, keepOnTop: Bool, animated: Bool = true) {
        guard let window else { return }
        self.reviewExpanded = reviewExpanded
        self.keepOnTop = keepOnTop
        let shouldCompact = keepOnTop || !reviewExpanded
        animationGeneration += 1
        let generation = animationGeneration

        // Lower the minimum before collapsing. When expanding, retain the
        // compact minimum until the animation finishes; raising it first makes
        // AppKit snap the window to full width before it can animate.
        let visibleContent = window.screen.map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        let minimum = NSSize(
            width: min(shouldCompact ? 570 : WorkspaceGeometry.minimumExpandedWidth, visibleContent?.width ?? 1_280),
            height: min(700, visibleContent?.height ?? 760)
        )
        window.contentMinSize = NSSize(width: min(570, minimum.width), height: minimum.height)

        if shouldCompact != compact {
            compact = shouldCompact
            if shouldCompact {
                regularContentWidth = max(1_280, window.contentLayoutRect.width)
                window.contentMinSize = minimum
                resize(
                    window: window,
                    contentWidth: 730,
                    animated: animated
                )
            } else {
                resize(
                    window: window,
                    contentWidth: max(1_280, regularContentWidth),
                    animated: animated
                ) { [weak self, weak window] in
                    guard let self, let window,
                          self.animationGeneration == generation,
                          !self.compact else { return }
                    window.contentMinSize = minimum
                    window.contentView?.layoutSubtreeIfNeeded()
                }
            }
        } else {
            window.contentMinSize = minimum
            // Also fit an already-expanded window after a screen change or
            // when a batch completes; don't require the user to resize it.
            resize(window: window, contentWidth: window.contentLayoutRect.width, animated: false)
        }
        window.level = keepOnTop ? .floating : baseLevel
        if keepOnTop {
            var behavior = baseCollectionBehavior
            behavior.remove(.moveToActiveSpace)
            behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.collectionBehavior = behavior
        } else {
            window.collectionBehavior = baseCollectionBehavior
        }
    }

    func detach(window: NSWindow) {
        guard self.window === window else { return }
        window.level = baseLevel
        window.collectionBehavior = baseCollectionBehavior
        removeScreenObservers()
        self.window = nil
    }

    private func removeScreenObservers() {
        screenObservers.forEach(NotificationCenter.default.removeObserver)
        screenObservers.removeAll()
    }

    func activateAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func resize(
        window: NSWindow,
        contentWidth: CGFloat,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        let oldFrame = window.frame
        var contentRect = window.contentRect(forFrameRect: oldFrame)
        contentRect.size.width = contentWidth
        var newFrame = window.frameRect(forContentRect: contentRect)
        newFrame.origin.x = oldFrame.minX
        newFrame.origin.y = oldFrame.maxY - newFrame.height

        if let visible = window.screen?.visibleFrame {
            newFrame = WorkspaceGeometry.fittedFrame(newFrame, in: visible)
        }
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            window.setFrame(newFrame, display: true)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(newFrame, display: true)
        } completionHandler: {
            completion?()
        }
    }
}

enum WorkspaceGeometry {
    static let minimumExpandedWidth: CGFloat = 1_020

    struct Columns {
        var sidebar: CGFloat
        var settings: CGFloat
        var review: CGFloat
        var master: CGFloat
    }

    static func columns(width: CGFloat, expanded: Bool) -> Columns {
        if !expanded {
            let sidebar = min(340, max(270, (width - 1) * 0.46))
            return Columns(sidebar: sidebar, settings: width - 1 - sidebar, review: 0, master: 0)
        }
        let scale = min(1, max(0, (width - minimumExpandedWidth) / 420))
        let sidebar = 230 + scale * 75
        let settings = 260 + scale * 80
        let master = 86 + scale * 32
        return Columns(sidebar: sidebar, settings: settings,
            review: width - sidebar - settings - master - 3, master: master)
    }

    static func fittedFrame(_ proposed: NSRect, in visible: NSRect) -> NSRect {
        let width = min(proposed.width, visible.width)
        let height = min(proposed.height, visible.height)
        return NSRect(x: min(max(proposed.minX, visible.minX), visible.maxX - width),
            y: min(max(proposed.maxY - height, visible.minY), visible.maxY - height),
            width: width, height: height)
    }
}

struct WorkspaceWindowReader: NSViewRepresentable {
    let onWindowAvailable: @MainActor (NSWindow) -> Void
    let onWindowUnavailable: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowAvailable = onWindowAvailable
        view.onWindowUnavailable = onWindowUnavailable
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindowAvailable = onWindowAvailable
        nsView.onWindowUnavailable = onWindowUnavailable
        nsView.reportWindowIfAvailable()
    }
}

@MainActor
final class WindowProbeView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?
    var onWindowUnavailable: ((NSWindow) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window {
            onWindowUnavailable?(window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowIfAvailable()
    }

    func reportWindowIfAvailable() {
        if let window { onWindowAvailable?(window) }
    }
}

struct AddMixShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: AddMixShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onChange = { proposed in
            shortcut = proposed
            button.setShortcut(shortcut)
        }
        button.setShortcut(shortcut)
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.onChange = { proposed in
            shortcut = proposed
            nsView.setShortcut(shortcut)
        }
        nsView.setShortcut(shortcut)
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onChange: ((AddMixShortcut?) -> Void)?
    private var shortcut: AddMixShortcut?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel(L("Record Add Mix shortcut"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setShortcut(_ shortcut: AddMixShortcut?) {
        self.shortcut = shortcut
        if !isRecording { updateTitle() }
    }

    @objc private func beginRecording() {
        isRecording = true
        title = L("Type Shortcut…")
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        if (event.keyCode == UInt16(kVK_Delete)
            || event.keyCode == UInt16(kVK_ForwardDelete)),
           event.modifierFlags.intersection([
               .command, .option, .control, .shift
           ]).isEmpty {
            shortcut = nil
            onChange?(nil)
            finishRecording()
            return
        }
        guard let shortcut = AddMixShortcut(event: event) else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        onChange?(shortcut)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { finishRecording() }
        return result
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = shortcut?.displayName ?? L("Not Set")
        setAccessibilityValue(shortcut?.displayName ?? L("Not set"))
    }
}
