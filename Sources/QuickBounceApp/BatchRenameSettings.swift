import AppKit
import SwiftUI

struct MixNameDraft: Equatable {
    var text: String
    var caretOffset: Int

    init(prefix: String, suffix: String) {
        text = prefix + suffix
        // NSTextView selection locations are UTF-16, including emoji prefixes.
        caretOffset = prefix.utf16.count
    }
}

struct BatchRenameSettings: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = "en"
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Batch Rename")).font(.headline)
            Text(L("New Mixes start with this prefix and suffix. Type the Mix name between them. Leave either field empty to skip it."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("Prefix"), text: $model.mixNamePrefix).functionTip("Prefix")
            TextField(L("Suffix"), text: $model.mixNameSuffix).functionTip("Suffix")
            Text(model.mixNamePrefix + L("Mix Name") + model.mixNameSuffix)
                .font(.callout.monospaced()).lineLimit(2)
            Text(L("Applies to future Add Mix entries only. Include any spaces or separators you want."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 310)
    }
}

/// Positions the insertion point once when the sheet opens. Later edits and
/// focus changes must never reset the user's selection.
struct MixNameTextField: NSViewRepresentable {
    @Binding var text: String
    let initialCaretOffset: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> InitialCaretTextField {
        let field = InitialCaretTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = L("Mix Name")
        field.setAccessibilityLabel(L("Mix Name"))
        field.stringValue = text
        field.initialCaretOffset = initialCaretOffset
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: InitialCaretTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = L("Mix Name")
        field.setAccessibilityLabel(L("Mix Name"))
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class InitialCaretTextField: NSTextField {
    var initialCaretOffset = 0
    private var didPositionCaret = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didPositionCaret else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.didPositionCaret else { return }
            window.makeFirstResponder(self)
            guard let editor = self.currentEditor() else { return }
            editor.selectedRange = NSRange(location: min(self.initialCaretOffset, self.stringValue.utf16.count), length: 0)
            self.didPositionCaret = true
        }
    }
}
