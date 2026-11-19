import Foundation

public struct BounceSettingsPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: BounceSettings

    public init(id: UUID = UUID(), name: String, settings: BounceSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// A reusable preset must never redirect another Session's output folder.
    public func applying(to current: BounceSettings) -> BounceSettings {
        var result = settings
        result.fileDestination = current.fileDestination
        return result
    }
}

public struct BouncePresetLibrary: Codable, Sendable {
    public var presets: [BounceSettingsPreset] = []
    public var defaultPresetID: UUID?
    public init() {}
    /// Updating preserves the preset identity and its default designation.
    public mutating func update(id: UUID, settings: BounceSettings) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw QuickBounceError.invalidPlan("This preset no longer exists. Save a new preset instead.")
        }
        presets[index].settings = settings
    }

    public var defaultPreset: BounceSettingsPreset? {
        presets.first { $0.id == defaultPresetID }
    }
}

/// An explicit user document. Contains no jobs, artifacts, or audio data.
public struct SessionSettingsDocument: Codable, Sendable {
    public var formatVersion: Int = 1
    public var plans: [BouncePlan]

    public init(plans: [BouncePlan]) throws {
        guard let first = plans.first,
              plans.allSatisfy({ $0.session.path == first.session.path }) else {
            throw QuickBounceError.invalidPlan("Select mixes from one Session to save Session Settings.")
        }
        self.plans = plans
    }

    public func restoredPlans(session: SessionInfo, tracks: [TrackState]) throws -> [BouncePlan] {
        guard formatVersion == 1, !plans.isEmpty else {
            throw QuickBounceError.invalidPlan("This Session Settings file is empty or uses an unsupported version.")
        }
        // Unique names and matching types are required when recalling a revision.
        // Never guess between duplicate names or trust recycled PTSL IDs.
        let live = Dictionary(grouping: tracks, by: { $0.track.name })
        return try plans.enumerated().map { offset, saved in
            guard saved.range.isValid, saved.sourceSampleRate == session.sampleRate,
                  saved.targetTrackStates.count == tracks.count else {
                throw QuickBounceError.invalidPlan("Session Settings require the same tracks and Session sample rate. Capture new mixes for this Session.")
            }
            let old = Dictionary(grouping: saved.targetTrackStates, by: { $0.track.name })
            let oldByID = Dictionary(grouping: saved.targetTrackStates, by: { $0.track.id })
            let liveByID = Dictionary(grouping: tracks, by: { $0.track.id })
            func kind(_ value: String) -> String {
                String(value.lowercased().split(separator: "_").last ?? "")
            }
            let rebound = try saved.targetTrackStates.map { state -> TrackState in
                guard old[state.track.name]?.count == 1,
                      let candidates = live[state.track.name], candidates.count == 1,
                      let match = candidates.first,
                      kind(match.track.kind) == kind(state.track.kind) else {
                    throw QuickBounceError.invalidPlan("Track ‘\(state.track.name)’ is missing, renamed, ambiguous, or has changed type. Capture new mixes for this Session.")
                }
                let oldParent = state.track.parentFolderID.flatMap { oldByID[$0]?.first?.track.name }
                let newParent = match.track.parentFolderID.flatMap { liveByID[$0]?.first?.track.name }
                guard oldParent == newParent else {
                    throw QuickBounceError.invalidPlan("The folder structure has changed for ‘\(state.track.name)’. Capture new mixes for this Session.")
                }
                return TrackState(track: match.track, isSolo: state.isSolo, isMuted: state.isMuted)
            }
            var settings = saved.settings
            let previousDefault = URL(fileURLWithPath: saved.session.path).deletingLastPathComponent()
                .appendingPathComponent("Bounced Files").path
            if settings.fileDestination == previousDefault {
                settings.fileDestination = URL(fileURLWithPath: session.identity.path).deletingLastPathComponent()
                    .appendingPathComponent("Bounced Files").path
            }
            return BouncePlan(name: saved.name, bouncePresetID: saved.bouncePresetID, note: saved.note, session: session.identity,
                              targetTrackStates: rebound, range: saved.range,
                              sourceSampleRate: session.sampleRate, sourceTimeCodeRate: session.timeCodeRate,
                              settings: settings, isEnabled: saved.isEnabled,
                              createdAt: Date().addingTimeInterval(Double(offset) * 0.001))
        }
    }
}
