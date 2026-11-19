import QuickBounceDomain

/// Mute changes can be sparse. Enabling Solo must send the complete target
/// set in one request because X-OR resets Solo on unlisted tracks.
struct TrackStateMutations {
    var mutes: [TrackState]
    var soloOff: [TrackState]
    var soloOn: [TrackState]

    static func make(target: [TrackState], current: [TrackState], full: Bool) -> Self {
        let currentByID = Dictionary(grouping: current, by: { $0.track.id })
        let supported = target.filter { PTSLRequestBodyFactory.supportsMuteAndSoloState($0.track) }
        func muteChanged(_ state: TrackState) -> Bool {
            currentByID[state.track.id]?.first?.isMuted != state.isMuted
        }
        func soloChanged(_ state: TrackState) -> Bool {
            currentByID[state.track.id]?.first?.isSolo != state.isSolo
        }
        let changeSolo = full || supported.contains(where: soloChanged)
        return Self(
            mutes: supported.filter { muteChanged($0) || (full && $0.isInactive != true) },
            soloOff: changeSolo ? supported.filter {
                !$0.isSolo && (soloChanged($0) || $0.isInactive != true)
            } : [],
            soloOn: changeSolo ? supported.filter {
                $0.isSolo && (soloChanged($0) || $0.isInactive != true)
            } : []
        )
    }
}
