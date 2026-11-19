import Foundation
import QuickBounceDomain
import Testing

@Test func stateMachineAcceptsSuccessfulWAVMP3Flow() throws {
    var machine = BounceJobStateMachine()
    for state: BounceJobState in [
        .validating, .connecting, .snapshotting, .applyingTrackState,
        .verifyingTrackState, .exporting, .waitingForArtifact, .transcoding,
        .validatingArtifact, .restoring, .verifyingRestore, .importing,
        .analyzing, .reviewReady
    ] {
        try machine.transition(to: state)
    }
    #expect(machine.state == .reviewReady)
}

@Test func stateMachineAcceptsCrossSessionSaveCloseFlow() throws {
    var machine = BounceJobStateMachine(state: .validatingArtifact)
    for state: BounceJobState in [
        .restoring, .verifyingRestore, .savingSession, .closingSession,
        .snapshotting
    ] {
        try machine.transition(to: state)
    }
    #expect(machine.state == .snapshotting)
}

@Test func stateMachineRejectsUnsafeJump() {
    var machine = BounceJobStateMachine(state: .exporting)
    #expect(throws: QuickBounceError.self) {
        try machine.transition(to: .reviewReady)
    }
}

@Test func movNeverEntersAudioReview() {
    let artifact = AudioArtifact(
        jobID: UUID(),
        planID: UUID(),
        name: "review.mov",
        path: "/tmp/review.mov",
        kind: .mov,
        state: .completed
    )
    #expect(!artifact.canReviewAudio)
    #expect(artifact.canQuickLook)
    #expect(!artifact.kind.hasWaveform)
}

@Test func waveformPixelColumnsPreserveTransientExtrema() throws {
    let artifactID = UUID()
    let left = [
        WaveformLevel(minimum: -0.1, maximum: 0.1),
        WaveformLevel(minimum: -0.2, maximum: 0.2),
        WaveformLevel(minimum: -0.1, maximum: 0.95),
        WaveformLevel(minimum: -0.3, maximum: 0.1),
        WaveformLevel(minimum: -0.1, maximum: 0.1),
        WaveformLevel(minimum: -0.8, maximum: 0.2),
        WaveformLevel(minimum: -0.1, maximum: 0.1),
        WaveformLevel(minimum: -0.1, maximum: 0.1)
    ]
    let right = left.enumerated().map { index, level in
        index == 7
            ? WaveformLevel(minimum: level.minimum, maximum: 1)
            : level
    }
    let envelope = WaveformEnvelope(
        artifactID: artifactID,
        sampleRate: 32,
        frameCount: 32,
        channels: [left, right],
        blockSize: 4
    )

    let columns = envelope.pixelColumns(
        channel: 0,
        viewportStart: 0,
        viewportDuration: 1,
        pixelWidth: 4
    )
    let combined = envelope.combinedPixelColumns(
        viewportStart: 0,
        viewportDuration: 1,
        pixelWidth: 4
    )

    #expect(columns.count == 4)
    #expect(columns[1].maximum == 0.95)
    #expect(columns[2].minimum == -0.8)
    #expect(combined[3].maximum == 1)
}

@Test func waveformLevelSelectionNeverUndersamplesBackingPixels() throws {
    let artifactID = UUID()
    func envelope(_ blockSize: Int) -> WaveformEnvelope {
        WaveformEnvelope(
            artifactID: artifactID,
            sampleRate: 48_000,
            frameCount: 1_440_000,
            channels: [[WaveformLevel(minimum: -0.5, maximum: 0.5)]],
            blockSize: blockSize
        )
    }
    let pyramid = WaveformPyramid(
        artifactID: artifactID,
        levels: [envelope(256), envelope(2_048), envelope(16_384)]
    )

    let selected = try #require(
        pyramid.bestLevel(forVisibleFrames: 1_440_000, pixelWidth: 900)
    )

    #expect(selected.blockSize == 256)
    #expect(selected.blockSize <= 1_600)
}

@Test func wavAndMP3SupportsImportButMOVDoesNot() {
    #expect(ExportType.wavAndMP3.supportsImportAfterBounce)
    #expect(!ExportType.mov.supportsImportAfterBounce)
    let settings = BounceSettings(
        exportType: .mov,
        importAfterBounce: true,
        fileDestination: "/tmp"
    )
    #expect(!settings.importAfterBounce)
}

@Test func bounceSettingsDefaultsPreserveProToolsBounceBehaviorForLegacyPayloads() throws {
    let defaults = BounceSettings(fileDestination: "/tmp")
    #expect(defaults.offlineBounce)
    #expect(defaults.padToFrameBoundary)

    let legacyPayload = Data(
        """
        {
          "exportType": "wav",
          "sampleRate": 48000,
          "bitDepth": 24,
          "fileLayout": "interleaved",
          "mp3Quality": "highest",
          "mp3ConstantBitRateKbps": 320,
          "importAfterBounce": false,
          "fileDestination": "/tmp",
          "mixSourceType": "physicalOutput",
          "mixSource": "Output 1–2"
        }
        """.utf8
    )
    let decoded = try JSONDecoder().decode(BounceSettings.self, from: legacyPayload)

    #expect(decoded.offlineBounce)
    #expect(decoded.padToFrameBoundary)
}

@Test func padToFrameBoundaryRoundsEachSelectionEdgeIndependently() {
    let range = SampleRange(start: 13_969_615, end: 19_085_558)
    let rawDuration = Double(range.length) / 48_000
    let paddedDuration = SessionTimeCodeRate.fps25.paddedDuration(
        for: range,
        sampleRate: 48_000
    )

    #expect(abs(paddedDuration - 106.64) < 0.000_001)
    #expect(paddedDuration - rawDuration > SessionTimeCodeRate.fps25.frameDurationSeconds)
    #expect(paddedDuration - rawDuration < 2 * SessionTimeCodeRate.fps25.frameDurationSeconds)
}

@Test func folderSoloReadbackAllowsOnlyDerivedDescendantSolo() {
    let folder = TrackState(
        track: TrackReference(id: "folder", name: "Music", index: 0, kind: "RoutingFolder"),
        isSolo: true,
        isMuted: false
    )
    let nestedFolder = TrackState(
        track: TrackReference(
            id: "nested",
            name: "Keys",
            index: 1,
            kind: "BasicFolder",
            parentFolderID: folder.track.id
        ),
        isSolo: false,
        isMuted: false
    )
    let child = TrackState(
        track: TrackReference(
            id: "child",
            name: "Piano",
            index: 2,
            kind: "Audio",
            parentFolderID: nestedFolder.track.id
        ),
        isSolo: false,
        isMuted: false
    )
    let unrelated = TrackState(
        track: TrackReference(id: "other", name: "VO", index: 3, kind: "Audio"),
        isSolo: false,
        isMuted: false
    )
    let expected = [folder, nestedFolder, child, unrelated]
    var derivedReadback = expected
    derivedReadback[1].isSolo = true
    derivedReadback[2].isSolo = true

    #expect(TrackStateVerification.firstIssue(expected: expected, actual: derivedReadback) == nil)

    var unrelatedSolo = derivedReadback
    unrelatedSolo[3].isSolo = true
    #expect(
        TrackStateVerification.firstIssue(expected: expected, actual: unrelatedSolo)
            == .stateMismatch("VO")
    )

    var changedMute = derivedReadback
    changedMute[2].isMuted = true
    #expect(
        TrackStateVerification.firstIssue(expected: expected, actual: changedMute)
            == .stateMismatch("Piano")
    )
}

@Test func staleTrackIDsRebindByNameAndTypeWithoutGuessing() throws {
    let captured = [
        TrackState(
            track: TrackReference(id: "old-audio", name: "VO", index: 0, kind: "TType_Audio"),
            isSolo: true,
            isMuted: false
        ),
        TrackState(
            track: TrackReference(id: "old-folder", name: "Music", index: 1, kind: "TType_RoutingFolder"),
            isSolo: false,
            isMuted: true
        )
    ]
    let current = [
        TrackState(
            track: TrackReference(id: "new-audio", name: "VO", index: 0, kind: "TType_Audio"),
            isSolo: false,
            isMuted: false
        ),
        TrackState(
            track: TrackReference(id: "new-folder", name: "Music", index: 1, kind: "TType_RoutingFolder"),
            isSolo: false,
            isMuted: false
        )
    ]

    let resolved = try TrackStateResolver.resolve(expected: captured, against: current)

    #expect(resolved.map(\.track.id) == ["new-audio", "new-folder"])
    #expect(resolved.map(\.isSolo) == [true, false])
    #expect(resolved.map(\.isMuted) == [false, true])

    var readback = current
    readback[0].isSolo = true
    readback[1].isMuted = true
    #expect(TrackStateVerification.firstIssue(expected: captured, actual: readback) == nil)
}

@Test func staleTrackIDRebindingRejectsAmbiguousNames() {
    let captured = TrackState(
        track: TrackReference(id: "old", name: "Duplicate", index: 99, kind: "TType_Audio"),
        isSolo: false,
        isMuted: false
    )
    let current = [
        TrackState(
            track: TrackReference(id: "new-1", name: "Duplicate", index: 0, kind: "TType_Audio"),
            isSolo: false,
            isMuted: false
        ),
        TrackState(
            track: TrackReference(id: "new-2", name: "Duplicate", index: 1, kind: "TType_Audio"),
            isSolo: false,
            isMuted: false
        )
    ]

    #expect(throws: QuickBounceError.ambiguousTrackName("Duplicate")) {
        _ = try TrackStateResolver.resolve(expected: [captured], against: current)
    }
}
