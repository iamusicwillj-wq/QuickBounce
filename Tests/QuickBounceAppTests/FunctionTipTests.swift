import AppKit
import QuickBounceDomain
import SwiftUI
@testable import QuickBounceApp
import Testing

@MainActor
@Test func reviewSegmentsHaveIndependentTipsIncludingTheUnselectedSegment() {
    let control = ReviewModeSegmentedControl(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    control.segmentCount = 2
    control.segmentDistribution = .fillEqually
    control.configure(selection: .mixCompare, language: .simplifiedChinese, tipsEnabled: true)
    #expect(control.label(forSegment: 0) == "混音对比")
    #expect(control.label(forSegment: 1) == "分层检查")
    #expect(control.tipKey(at: NSPoint(x: 20, y: 12)) == "Mix Compare")
    #expect(control.tipKey(at: NSPoint(x: 280, y: 12)) == "Stems Check")
    #expect(control.tipKey(at: NSPoint(x: -1, y: 12)) == nil)
    var selected: ReviewMode?
    control.selectionChanged = { selected = $0 }
    control.selectedSegment = 1
    control.changed()
    #expect(selected == .stemsCheck)
    control.configure(selection: .stemsCheck, language: .english, tipsEnabled: false)
    #expect(control.label(forSegment: 1) == "Stems Check")
    #expect(control.selectedSegment == 1)
}

@MainActor
@Test func disabledAddMixKeepsATrackingAreaWithoutInterceptingClicks() throws {
    let view = NSHostingView(rootView:
        Button("Add Mix") {}.disabled(true).functionTip("Add Mix")
    )
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
    view.layoutSubtreeIfNeeded()
    func tracker(in view: NSView) -> TipTrackingNSView? {
        if let view = view as? TipTrackingNSView { return view }
        return view.subviews.lazy.compactMap { tracker(in: $0) }.first
    }
    let trackingView = try #require(tracker(in: view))
    #expect(trackingView.trackingAreas.count == 1)
    #expect(trackingView.trackingAreas[0].options.contains(.mouseEnteredAndExited))
    #expect(trackingView.trackingAreas[0].options.contains(.inVisibleRect))
    #expect(trackingView.hitTest(NSPoint(x: 10, y: 10)) == nil)
    #expect(Copy.tip("Add Mix", language: .english) != nil)
    #expect(Copy.tip("Add Mix", language: .simplifiedChinese) != nil)
}
