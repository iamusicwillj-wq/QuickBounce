import AppKit
@testable import QuickBounceApp
import Testing

@MainActor
@Suite(.serialized)
struct InlineMixRenameTests {
    private func makeField() async throws -> (NSWindow, MixRenameTextField, NSTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = MixRenameTextField(frame: NSRect(x: 10, y: 50, width: 360, height: 24))
        field.stringValue = "Original Mix"
        field.isEditable = true
        field.isSelectable = true
        window.contentView?.addSubview(field)
        for _ in 0..<30 where field.currentEditor() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (window, field, try #require(field.currentEditor() as? NSTextView))
    }

    private func drainCallbacks() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    @Test func returnEndsNativeEditingBeforeRemovingViewAndCommitsOnce() async throws {
        let (window, field, editor) = try await makeField()
        defer { field.detachEditor(); window.close() }
        var names: [String] = []
        field.onCommit = { name in
            #expect(field.currentEditor() == nil)
            names.append(name)
            field.removeFromSuperview()
        }
        // Exercise AppKit replacement/undo with both shorter strings and UTF-16.
        editor.insertText("A long replacement name", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("歌曲🎵 MMM", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(names.isEmpty) // No SwiftUI removal from inside the Return callback.
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        try await drainCallbacks()
        #expect(names == ["歌曲🎵 MMM"])
    }

    @Test func escapeCancelsWithoutSavingEditedText() async throws {
        let (window, field, editor) = try await makeField()
        defer { field.detachEditor(); window.close() }
        var cancelled = 0
        var saved = 0
        field.onCommit = { _ in saved += 1 }
        field.onCancel = { cancelled += 1 }
        editor.insertText("Do not save", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        _ = field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try await drainCallbacks()
        #expect(cancelled == 1)
        #expect(saved == 0)
    }

    @Test func losingFocusSavesDraftWithoutReturn() async throws {
        let (window, field, editor) = try await makeField()
        defer { field.detachEditor(); window.close() }
        var result: String?
        field.onCommit = { result = $0 }
        editor.insertText("Click away", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        window.makeFirstResponder(nil)
        try await drainCallbacks()
        #expect(result == "Click away")
    }

    @Test func emptyNameRemainsEditableAndCanBeCorrected() async throws {
        let (window, field, editor) = try await makeField()
        defer { field.detachEditor(); window.close() }
        var invalid = 0
        var names: [String] = []
        field.onInvalid = { invalid += 1 }
        field.onCommit = { names.append($0) }
        editor.insertText("  ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        _ = field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try await drainCallbacks()
        #expect(invalid == 1 && names.isEmpty)
        let activeEditor = try #require(field.currentEditor() as? NSTextView)
        activeEditor.insertText("Corrected", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
        _ = field.control(field, textView: activeEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try await drainCallbacks()
        #expect(names == ["Corrected"])
    }

    @Test func dismantlingEditorDoesNotCommitDraft() async throws {
        let (window, field, _) = try await makeField()
        defer { window.close() }
        var count = 0
        field.onCommit = { _ in count += 1 }
        field.detachEditor()
        field.removeFromSuperview()
        try await drainCallbacks()
        #expect(count == 0)
    }
}
