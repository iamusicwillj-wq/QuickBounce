import AppKit
@testable import QuickBounceApp
import Testing

@Test func batchNameDraftPreservesSeparatorsAndPositionsCaretBetweenAffixes() {
    for (prefix, suffix) in [("", ""), ("Album_", ""), ("", "_Mix"), ("歌曲🎵_", "_24bit"), ("Song - ", " - Final")] {
        let draft = MixNameDraft(prefix: prefix, suffix: suffix)
        #expect(draft.text == prefix + suffix)
        let name = NSMutableString(string: draft.text)
        name.insert("MMM", at: draft.caretOffset)
        #expect(name as String == prefix + "MMM" + suffix)
    }
}

@MainActor
@Test func mixNameFieldPlacesRealCaretWithoutSelectingAffixes() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = InitialCaretTextField(frame: NSRect(x: 10, y: 10, width: 360, height: 24))
    field.stringValue = "歌曲🎵__Final"
    field.initialCaretOffset = "歌曲🎵_".utf16.count
    window.contentView?.addSubview(field)
    for _ in 0..<20 where field.currentEditor() == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let editor = try #require(field.currentEditor())
    #expect(editor.selectedRange == NSRange(location: "歌曲🎵_".utf16.count, length: 0))
    editor.selectedRange = NSRange(location: 0, length: 1)
    field.viewDidMoveToWindow()
    #expect(editor.selectedRange == NSRange(location: 0, length: 1))
}
