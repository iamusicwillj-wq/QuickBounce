import AppKit
@preconcurrency import Carbon
@testable import QuickBounceApp
import Foundation
import Testing

@Test
func addMixShortcutDisplaysAndRegistersExpectedModifiers() throws {
    let shortcut = AddMixShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: [.control, .option, .shift],
        keyLabel: "M"
    )

    #expect(shortcut.displayName == "⌃⌥⇧M")
    #expect(shortcut.carbonModifiers & UInt32(controlKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(optionKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(shiftKey) != 0)
    #expect(shortcut.carbonModifiers & UInt32(cmdKey) == 0)

    let encoded = try JSONEncoder().encode(shortcut)
    #expect(try JSONDecoder().decode(AddMixShortcut.self, from: encoded) == shortcut)
}

@Test
func defaultAddMixShortcutIsSafeAndReadable() {
    let shortcut = AddMixShortcut.defaultValue

    #expect(shortcut.keyCode == UInt32(kVK_ANSI_A))
    #expect(shortcut.modifiers == [.control, .option])
    #expect(shortcut.displayName == "⌃⌥A")
}

@Test
func reviewAutoExpansionRunsOnceAfterFirstCompletedMix() {
    var policy = ReviewPaneAutoExpansionPolicy()

    let beforeCompletion = policy.shouldExpand(completedPlanCount: 0)
    let firstCompletion = policy.shouldExpand(completedPlanCount: 1)
    let repeatedSnapshot = policy.shouldExpand(completedPlanCount: 1)
    let laterCompletion = policy.shouldExpand(completedPlanCount: 2)

    #expect(!beforeCompletion)
    #expect(firstCompletion)
    #expect(!repeatedSnapshot)
    #expect(!laterCompletion)
}

@MainActor
@Test func completedBounceWindowReturnsFromFloatingToExpandedNormalMode() {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let originalBehavior = window.collectionBehavior
    let controller = WorkspaceWindowController()
    controller.attach(window: window, reviewExpanded: false, keepOnTop: false)
    // Exercise two batches: the second must expand even after manual collapse.
    for _ in 0..<2 {
        controller.apply(reviewExpanded: false, keepOnTop: true, animated: false)
        #expect(window.level == .floating)
        controller.apply(reviewExpanded: true, keepOnTop: false, animated: false)
        #expect(window.level == .normal)
        #expect(window.collectionBehavior == originalBehavior)
        #expect(window.contentRect(forFrameRect: window.frame).width >= min(1280, window.screen?.visibleFrame.width ?? 1280))
    }
    controller.detach(window: window)
}

@Test func expandedWindowFitsSmallAndOffsetScreensAndAllColumnsStayInside() {
    for visible in [NSRect(x: 0, y: 30, width: 1280, height: 770),
                    NSRect(x: -1920, y: 80, width: 1440, height: 810),
                    NSRect(x: 1920, y: 24, width: 1024, height: 640)] {
        let proposed = NSRect(x: visible.maxX - 730, y: visible.minY - 100, width: 1560, height: 950)
        let fitted = WorkspaceGeometry.fittedFrame(proposed, in: visible)
        #expect(visible.contains(fitted))
        let columns = WorkspaceGeometry.columns(width: fitted.width, expanded: true)
        #expect(abs(columns.sidebar + columns.settings + columns.review + columns.master + 3 - fitted.width) < 0.001)
        #expect(columns.review > 400)
    }
}

@MainActor
@Test func repeatedWindowReaderUpdatesDoNotResetExpansionAnimationOrMinimumSize() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let controller = WorkspaceWindowController()
    controller.attach(window: window, reviewExpanded: false, keepOnTop: false)
    controller.apply(reviewExpanded: true, keepOnTop: false, animated: false)
    let frame = window.frame
    let minimum = window.contentMinSize
    for _ in 0..<20 { controller.attach(window: window, reviewExpanded: true, keepOnTop: false) }
    #expect(window.frame == frame && window.contentMinSize == minimum)
    if let visible = window.screen?.visibleFrame { #expect(visible.contains(window.frame)) }
    controller.detach(window: window)
}

@MainActor
@Test func screenChangeRestoresExpandedWorkspaceFromCompactWidth() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1400, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let controller = WorkspaceWindowController()
    defer {
        controller.detach(window: window)
        window.close()
    }
    controller.attach(window: window, reviewExpanded: false, keepOnTop: false)
    controller.apply(reviewExpanded: true, keepOnTop: false, animated: false)

    var compactFrame = window.frame
    compactFrame.size.width = 725
    let previousScreen = window.screen
    let destination = NSScreen.screens.first { $0.frame != previousScreen?.frame } ?? previousScreen
    if let destination {
        let visible = destination.visibleFrame
        compactFrame.origin = NSPoint(x: visible.maxX - compactFrame.width, y: visible.minY)
    }
    window.setFrame(compactFrame, display: false)
    try #require(window.contentRect(forFrameRect: window.frame).width < window.contentMinSize.width)
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

    // The notification handler schedules the window update on the main actor.
    for _ in 0..<20 {
        if window.contentRect(forFrameRect: window.frame).width >= window.contentMinSize.width { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.contentRect(forFrameRect: window.frame).width >= window.contentMinSize.width)
    if let destination {
        #expect(destination.visibleFrame.contains(window.frame))
    }
}

@MainActor
@Test func screenChangeFinishesCollapseWhenWindowIsStillWide() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1400, height: 750),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let controller = WorkspaceWindowController()
    defer {
        controller.detach(window: window)
        window.close()
    }
    controller.attach(window: window, reviewExpanded: true, keepOnTop: false)
    let expandedWidth = window.contentRect(forFrameRect: window.frame).width
    controller.apply(reviewExpanded: false, keepOnTop: false, animated: false)
    let compactWidth = window.contentRect(forFrameRect: window.frame).width

    // Reproduce a screen change reported while the window still has an
    // intermediate width from the collapse animation.
    var frame = window.frame
    frame.size.width = 1003
    window.setFrame(frame, display: false)
    try #require(window.contentRect(forFrameRect: window.frame).width > compactWidth)
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

    for _ in 0..<20 {
        if window.contentRect(forFrameRect: window.frame).width <= compactWidth { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.contentRect(forFrameRect: window.frame).width == compactWidth)
    controller.apply(reviewExpanded: true, keepOnTop: false, animated: false)
    #expect(window.contentRect(forFrameRect: window.frame).width == expandedWidth)
}
