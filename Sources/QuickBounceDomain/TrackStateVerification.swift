import Foundation

public enum TrackStateVerificationIssue: Equatable, Sendable {
    case missingTrack(String)
    case ambiguousTrack(String)
    case stateMismatch(String)
}

/// Rebinds captured Track state to the identifiers returned by the currently
/// open Session. PTSL Track IDs can change after Pro Tools or a Session is
/// reopened, so an exact name/type match is used as a guarded fallback.
public enum TrackStateResolver {
    public static func resolve(
        expected: [TrackState],
        against current: [TrackState]
    ) throws -> [TrackState] {
        let currentByID = Dictionary(grouping: current, by: { $0.track.id })
        var claimedIDs = Set<String>()
        var resolved: [TrackState] = []
        resolved.reserveCapacity(expected.count)

        for expectedState in expected {
            let liveState: TrackState
            if let exact = currentByID[expectedState.track.id], exact.count == 1,
               let match = exact.first, !claimedIDs.contains(match.track.id) {
                liveState = match
            } else {
                let sameName = current.filter {
                    !claimedIDs.contains($0.track.id)
                        && $0.track.name == expectedState.track.name
                }
                let sameNameAndKind = sameName.filter {
                    normalizedKind($0.track.kind) == normalizedKind(expectedState.track.kind)
                }
                let candidates = sameNameAndKind.isEmpty ? sameName : sameNameAndKind

                if candidates.count == 1, let match = candidates.first {
                    liveState = match
                } else if candidates.count > 1 {
                    let sameIndex = candidates.filter {
                        $0.track.index == expectedState.track.index
                    }
                    guard sameIndex.count == 1, let match = sameIndex.first else {
                        throw QuickBounceError.ambiguousTrackName(expectedState.track.name)
                    }
                    liveState = match
                } else {
                    throw QuickBounceError.trackMissing(expectedState.track.name)
                }
            }

            claimedIDs.insert(liveState.track.id)
            resolved.append(
                TrackState(
                    track: liveState.track,
                    isSolo: expectedState.isSolo,
                    isMuted: expectedState.isMuted,
                    isInactive: liveState.isInactive
                )
            )
        }
        return resolved
    }

    private static func normalizedKind(_ value: String) -> String {
        let lowercased = value.lowercased()
        return lowercased.split(separator: "_").last.map(String.init) ?? lowercased
    }
}

/// Compares requested Solo/Mute state with Pro Tools readback while preserving
/// Pro Tools' Folder Solo semantics. Pro Tools can report descendants of an
/// explicitly soloed Folder as soloed even when their own captured Solo flags
/// are off. That one derived state is accepted; Mute and unrelated Solo state
/// remain exact comparisons.
public enum TrackStateVerification {
    public static func firstIssue(
        expected: [TrackState],
        actual: [TrackState]
    ) -> TrackStateVerificationIssue? {
        let resolvedExpected: [TrackState]
        do {
            resolvedExpected = try TrackStateResolver.resolve(
                expected: expected,
                against: actual
            )
        } catch let error as QuickBounceError {
            switch error {
            case let .trackMissing(name): return .missingTrack(name)
            case let .ambiguousTrackName(name): return .ambiguousTrack(name)
            default: return .missingTrack("Unknown Track")
            }
        } catch {
            return .missingTrack("Unknown Track")
        }

        var expectedByID: [String: TrackState] = [:]
        for state in resolvedExpected { expectedByID[state.track.id] = state }
        let actualByID = Dictionary(grouping: actual, by: { $0.track.id })

        for expectedState in resolvedExpected {
            guard let matches = actualByID[expectedState.track.id],
                  matches.count == 1,
                  let actualState = matches.first else {
                return .missingTrack(expectedState.track.name)
            }

            guard expectedState.isMuted == actualState.isMuted else {
                return .stateMismatch(expectedState.track.name)
            }

            if expectedState.isSolo == actualState.isSolo { continue }
            let isDerivedFolderSolo = !expectedState.isSolo
                && actualState.isSolo
                && hasExplicitlySoloedFolderAncestor(
                    expectedState,
                    expectedByID: expectedByID
                )
            if !isDerivedFolderSolo {
                return .stateMismatch(expectedState.track.name)
            }
        }
        return nil
    }

    private static func hasExplicitlySoloedFolderAncestor(
        _ state: TrackState,
        expectedByID: [String: TrackState]
    ) -> Bool {
        var parentID = state.track.parentFolderID
        var visited = Set<String>()
        while let id = parentID, visited.insert(id).inserted,
              let parent = expectedByID[id] {
            if parent.isSolo && parent.track.kind.localizedCaseInsensitiveContains("folder") {
                return true
            }
            parentID = parent.track.parentFolderID
        }
        return false
    }
}
