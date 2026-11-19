import AppKit
import QuickBounceDomain
import SwiftUI

/// Segment labels in a SwiftUI Picker are not independent hoverable views.
/// Use the native segmented control and track each segment's actual region.
struct ReviewModePicker: NSViewRepresentable {
    @Binding var selection: ReviewMode
    @AppStorage(AppLanguage.preferenceKey) private var language = "en"
    @AppStorage(FunctionTipsPreference.key) private var tipsEnabled = true

    func makeNSView(context: Context) -> ReviewModeSegmentedControl {
        let control = ReviewModeSegmentedControl()
        control.segmentCount = ReviewMode.allCases.count
        control.segmentDistribution = .fillEqually
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.target = control
        control.action = #selector(ReviewModeSegmentedControl.changed)
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: ReviewModeSegmentedControl, context: Context) {
        control.configure(selection: selection, language: AppLanguage(rawValue: language) ?? .english, tipsEnabled: tipsEnabled)
        control.selectionChanged = { selection = $0 }
    }

    static func dismantleNSView(_ control: ReviewModeSegmentedControl, coordinator: ()) {
        control.dismissTip()
    }
}

final class ReviewModeSegmentedControl: NSSegmentedControl {
    var selectionChanged: ((ReviewMode) -> Void)?
    private let tipOwner = UUID()
    private var hoveredSegment: Int?
    private var language: AppLanguage = .english
    private var tipsEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(selection: ReviewMode, language: AppLanguage, tipsEnabled: Bool) {
        if self.language != language || self.tipsEnabled != tipsEnabled { dismissTip() }
        self.language = language
        self.tipsEnabled = tipsEnabled
        for (index, mode) in ReviewMode.allCases.enumerated() {
            setLabel(Copy.text(mode.rawValue, language: language), forSegment: index)
        }
        selectedSegment = ReviewMode.allCases.firstIndex(of: selection) ?? 0
        setAccessibilityLabel(Copy.text("Review Mode", language: language))
    }

    @objc func changed() {
        guard ReviewMode.allCases.indices.contains(selectedSegment) else { return }
        selectionChanged?(ReviewMode.allCases[selectedSegment])
    }

    func tipKey(at point: NSPoint) -> String? {
        guard bounds.contains(point), bounds.width > 0, segmentCount > 0 else { return nil }
        let index = min(segmentCount - 1, Int((point.x - bounds.minX) / bounds.width * Double(segmentCount)))
        return ReviewMode.allCases[index].rawValue
    }

    private func updateTip(at point: NSPoint) {
        let key = tipKey(at: point)
        let index = ReviewMode.allCases.firstIndex { $0.rawValue == key }
        guard index != hoveredSegment else { return }
        dismissTip()
        hoveredSegment = index
        guard let key, let text = Copy.tip(key, language: language, enabled: tipsEnabled) else { return }
        FunctionTipWindow.shared.schedule(owner: tipOwner, text: text)
    }

    override func mouseEntered(with event: NSEvent) { updateTip(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateTip(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { dismissTip() }
    override func mouseDown(with event: NSEvent) {
        dismissTip()
        super.mouseDown(with: event)
    }
    func dismissTip() {
        hoveredSegment = nil
        FunctionTipWindow.shared.dismiss(owner: tipOwner)
    }
}
