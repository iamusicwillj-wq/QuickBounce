import QuickBounceApplication
import QuickBounceDomain
import QuickBounceProTools
import Testing

@Test func mixCheckRestoresIndependentMarkerAndRolls() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let original = TimelineState(selection: SampleRange(start: 96_123, end: 240_456),
        playStartMarker: 72_321, preRollStart: 48_111, postRollStop: 288_999,
        preRollEnabled: true, postRollEnabled: true)
    try await adapter.setTimelineState(original)
    let saved = try await MixCheckWorkflow.capture(using: adapter)
    try await MixCheckWorkflow.apply(checkPlan(name: "Check", states: FakeProToolsAdapter.demoTracks,
        range: SampleRange(start: 300_000, end: 400_000)), using: adapter)
    try await MixCheckWorkflow.restore(saved, using: adapter)
    #expect(try await adapter.currentTimelineState() == original)
}

@Test func mixCheckRejectsSuccessfulSetterWithWrongRollReadback() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let saved = try await MixCheckWorkflow.capture(using: adapter)
    await adapter.injectFailure(.timelineRollReadbackMismatch)
    await #expect(throws: QuickBounceError.self) { try await MixCheckWorkflow.restore(saved, using: adapter) }
}

@Test func mixCheckShowsPlanTrackStateAndTimelineThenRestoresBoth() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let original = try await MixCheckWorkflow.capture(using: adapter)
    var targetStates = FakeProToolsAdapter.demoTracks
    targetStates[0].isSolo = true
    targetStates[1].isMuted = true
    let plan = checkPlan(
        name: "Vocal Up",
        states: targetStates,
        range: SampleRange(start: 96_000, end: 240_000)
    )

    try await MixCheckWorkflow.apply(plan, using: adapter)

    #expect(try await adapter.trackStates() == targetStates)
    #expect(try await adapter.currentTimelineSelection() == plan.range)

    try await MixCheckWorkflow.restore(original, using: adapter)

    #expect(try await adapter.trackStates() == original.trackStates)
    #expect(try await adapter.currentTimelineSelection() == original.timelineSelection)
}

@Test func mixCheckCanRestoreOriginalInsertionPoint() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let insertionPoint = SampleRange(start: 72_000, end: 72_000)
    try await adapter.setTimelineSelection(insertionPoint)
    let original = try await MixCheckWorkflow.capture(using: adapter)
    let plan = checkPlan(
        name: "Selection Check",
        states: FakeProToolsAdapter.demoTracks,
        range: SampleRange(start: 144_000, end: 288_000)
    )

    try await MixCheckWorkflow.apply(plan, using: adapter)
    #expect(try await adapter.currentTimelineSelection() == plan.range)

    try await MixCheckWorkflow.restore(original, using: adapter)
    #expect(try await adapter.currentTimelineSelection() == insertionPoint)
}

@Test func switchingMixCheckUpdatesTheVisibleTimelineRange() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let original = try await MixCheckWorkflow.capture(using: adapter)
    let first = checkPlan(
        name: "First",
        states: FakeProToolsAdapter.demoTracks,
        range: SampleRange(start: 48_000, end: 144_000)
    )
    let second = checkPlan(
        name: "Second",
        states: FakeProToolsAdapter.demoTracks,
        range: SampleRange(start: 192_000, end: 336_000)
    )

    try await MixCheckWorkflow.apply(first, using: adapter)
    try await MixCheckWorkflow.restore(original, using: adapter)
    try await MixCheckWorkflow.apply(second, using: adapter)

    #expect(try await adapter.currentTimelineSelection() == second.range)
}

@Test func mixCheckRejectsEmptySavedRangeBeforeChangingProTools() async throws {
    let adapter = FakeProToolsAdapter(operationDelay: .zero)
    _ = try await adapter.connect()
    let original = try await MixCheckWorkflow.capture(using: adapter)
    var targetStates = FakeProToolsAdapter.demoTracks
    targetStates[0].isMuted = true
    let invalidPlan = checkPlan(
        name: "Invalid",
        states: targetStates,
        range: SampleRange(start: 48_000, end: 48_000)
    )

    await #expect(throws: QuickBounceError.self) {
        try await MixCheckWorkflow.apply(invalidPlan, using: adapter)
    }

    #expect(try await adapter.trackStates() == original.trackStates)
    #expect(try await adapter.currentTimelineSelection() == original.timelineSelection)
}

private func checkPlan(
    name: String,
    states: [TrackState],
    range: SampleRange
) -> BouncePlan {
    BouncePlan(
        name: name,
        session: FakeProToolsAdapter.demoSession.identity,
        targetTrackStates: states,
        range: range,
        sourceSampleRate: FakeProToolsAdapter.demoSession.sampleRate,
        settings: BounceSettings(fileDestination: "/tmp/QuickBounce Check Tests")
    )
}
