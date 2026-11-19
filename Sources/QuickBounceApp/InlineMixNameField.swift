import AppKit
import SwiftUI

/// Keep the draft in AppKit's field editor. Publishing or clearing a SwiftUI
/// text binding while Return tears down that editor can invalidate its undo
/// ranges on macOS 14.0. Only publish a snapshot after editing has ended.
struct InlineMixNameField: NSViewRepresentable {
    let name: String
    let commit: (String) -> Void
    let cancel: () -> Void
    let invalid: () -> Void

    func makeNSView(context: Context) -> MixRenameTextField {
        let field = MixRenameTextField()
        field.stringValue = name
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.setAccessibilityLabel(L("Mix name"))
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: MixRenameTextField, context: Context) {
        // Never replace active text or its undo history during a SwiftUI refresh.
        field.onCommit = commit
        field.onCancel = cancel
        field.onInvalid = invalid
        field.setAccessibilityLabel(L("Mix name"))
    }

    static func dismantleNSView(_ field: MixRenameTextField, coordinator: ()) {
        field.detachEditor()
    }
}

final class MixRenameTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onInvalid: () -> Void = {}
    private var completed = false
    private var didFocus = false
    private var isReportingInvalid = false
    private var mouseMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if didFocus { detachEditor() }
            return
        }
        guard !didFocus else { return }
        didFocus = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let passThrough = MainActor.assumeIsolated {
                guard let self, !self.completed, event.window === self.window,
                      self.currentEditor() != nil,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return true }
                // Empty drafts keep editing; do not also activate the clicked control.
                return self.finish(cancelled: false)
            }
            return passThrough ? event : nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.completed, let window = self.window else { return }
            window.makeFirstResponder(self)
            if let editor = self.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: editor.string.utf16.count)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            _ = finish(cancelled: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            _ = finish(cancelled: true)
            return true
        default:
            return false // Includes input-method composition and ordinary editing.
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        isReportingInvalid = false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        _ = finish(cancelled: false)
    }

    @discardableResult
    func finish(cancelled: Bool) -> Bool {
        guard !completed else { return true }
        let draft = (currentEditor()?.string ?? stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        if !cancelled && draft.isEmpty {
            guard !isReportingInvalid else { return false }
            isReportingInvalid = true
            let invalid = onInvalid
            DispatchQueue.main.async { [weak self] in
                invalid()
                guard let self, !self.completed else { return }
                if self.currentEditor() == nil { self.window?.makeFirstResponder(self) }
            }
            return false
        }
        completed = true // End-editing notifications must not submit twice.
        let commit = onCommit
        let cancel = onCancel
        endNativeEditing()
        // AppKit must finish the current key/mouse event before SwiftUI removes us.
        DispatchQueue.main.async {
            if cancelled { cancel() } else { commit(draft) }
        }
        return true
    }

    func detachEditor() {
        completed = true
        endNativeEditing()
    }

    private func endNativeEditing() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if currentEditor() != nil {
            abortEditing()
            window?.makeFirstResponder(nil)
        }
    }
}
