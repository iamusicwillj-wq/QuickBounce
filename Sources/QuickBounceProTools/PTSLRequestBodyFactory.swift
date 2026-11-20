import Foundation
import QuickBounceDomain

/// JSON request bodies pinned to the vendored PTSL 2026.04 contract.
/// Keeping construction separate from transport makes enum and field changes
/// reviewable without issuing a command to Pro Tools.
enum PTSLRequestBodyFactory {
    /// SetTimelineSelection's two roll boundary strings are present in the
    /// 2025.10, 2025.12 and 2026.04 contracts. Pro Tools 2025.10 rejects the
    /// request when either is omitted, even when the corresponding roll is
    /// disabled. Pin them to the selected range boundaries so every supported
    /// Host receives a complete, zero-roll request without changing playback
    /// or Bounce limits on newer releases.
    static func setTimelineSelection(_ range: SampleRange) throws -> [String: Any] {
        try setTimelineState(.forBounce(range))
    }

    static func setTimelineState(_ state: TimelineState) throws -> [String: Any] {
        let range = state.selection
        // Pro Tools represents an insertion point as equal In/Out samples.
        // Accept that form so Check can restore the exact pre-check Timeline
        // state; BouncePlan validation still requires a non-empty range.
        guard range.start >= 0, range.end >= range.start else {
            throw QuickBounceError.invalidPlan("Timeline Selection has invalid sample positions")
        }
        return [
            "location_type": "TLType_Samples",
            "in_time": String(range.start),
            "out_time": String(range.end),
            "play_start_marker_time": String(state.playStartMarker),
            "pre_roll_start_time": String(state.preRollStart),
            "post_roll_stop_time": String(state.postRollStop),
            "pre_roll_enabled": state.preRollEnabled ? "TB_True" : "TB_False",
            "post_roll_enabled": state.postRollEnabled ? "TB_True" : "TB_False"
        ]
    }

    static func setTrackMuteState(
        trackIDs: [String],
        trackNames: [String] = [],
        enabled: Bool,
        useTrackIDs: Bool = true
    ) -> [String: Any] {
        var body: [String: Any] = ["enabled": enabled]
        if useTrackIDs { body["track_ids"] = trackIDs }
        else { body["track_names"] = trackNames }
        return body
    }

    /// Pro Tools 26.4.0.175 reports `SetTrackSoloState(track_ids:)` as
    /// completed without changing the requested Solo state. The same command
    /// is reliable when addressed by track name. Mute-by-ID does not share
    /// this runtime defect, so only Solo uses the name-based compatibility
    /// path.
    static func setTrackSoloState(trackNames: [String], enabled: Bool) -> [String: Any] {
        ["track_names": trackNames, "enabled": enabled]
    }

    /// PTSL excludes only Video and Master Fader tracks from both
    /// SetTrackMuteState and SetTrackSoloState. Audio, Aux, VCA, Instrument,
    /// Basic Folder and Routing Folder tracks must remain controllable.
    /// Every BouncePlan captures the whole Session, so filtering is required
    /// even when the user never touched the unsupported track.
    static func supportsMuteAndSoloState(_ track: TrackReference) -> Bool {
        let kind = track.kind.lowercased()
        return !kind.contains("video") && !kind.contains("master")
    }

    static func exportMix(
        _ request: ProToolsExportRequest,
        capabilities: PTSLCapabilities = .ptsl2026_04
    ) throws -> [String: Any] {
        let stagingDirectory = try ptslDirectoryPath(request.stagingDirectory)
        let modernEnums = capabilities.audioEncodingOptions

        let fileType: String
        switch request.kind {
        case .wav:
            fileType = modernEnums ? "EMFType_WAV" : "EM_WAV"
        case .mov:
            fileType = modernEnums ? "EMFType_MOV" : "EM_MOV"
        case .mp3:
            fileType = modernEnums ? "EMFType_MP3" : "EM_MP3"
        }

        let exportFormat: String = switch request.plan.settings.fileLayout {
        case .mono: modernEnums ? "EFormat_Mono" : "EF_Mono"
        case .multipleMono: modernEnums ? "EFormat_MultipleMono" : "EF_MultipleMono"
        case .interleaved: modernEnums ? "EFormat_Interleaved" : "EF_Interleaved"
        }

        let bitDepth: String = switch request.plan.settings.bitDepth {
        case 16: modernEnums ? "BDepth_16" : "Bit16"
        case 24: modernEnums ? "BDepth_24" : "Bit24"
        case 32: modernEnums ? "BDepth_32Float" : "Bit32Float"
        default:
            throw QuickBounceError.invalidPlan(
                "Unsupported bit depth: \(request.plan.settings.bitDepth)"
            )
        }

        if request.kind == .mp3,
           request.plan.settings.sampleRate != 44_100,
           request.plan.settings.sampleRate != 48_000 {
            throw QuickBounceError.invalidPlan(
                "Pro Tools MP3 Bounce supports only 44.1 kHz or 48 kHz"
            )
        }

        var audioInfo: [String: Any] = [
            "compression_type": "CType_PCM",
            "export_format": exportFormat,
            "pad_to_frame_boundary": request.plan.settings.padToFrameBoundary
                ? (modernEnums ? "TBool_True" : "TB_True")
                : (modernEnums ? "TBool_False" : "TB_False"),
            "delivery_format": modernEnums ? "EMDFormat_SingleFile" : "EM_DF_SingleFile"
        ]
        if capabilities.exportTimeRange {
            audioInfo["sample_rate_custom"] = request.plan.settings.sampleRate
        } else {
            audioInfo["sample_rate"] = sampleRateName(request.plan.settings.sampleRate)
        }
        if request.kind != .mp3 {
            audioInfo["bit_depth"] = bitDepth
        }

        var locationInfo: [String: Any] = [
            "file_destination": modernEnums ? "EMFDestination_Directory" : "EM_FD_Directory",
            "directory": stagingDirectory
        ]
        if request.kind != .mp3 {
            locationInfo["import_after_bounce"] = modernEnums ? "TBool_False" : "TB_False"
        }

        let encodingOptions: [String: Any]
        if request.kind == .mp3 {
            let supportedRates = [128, 160, 192, 256, 320]
            guard supportedRates.contains(request.plan.settings.mp3ConstantBitRateKbps) else {
                throw QuickBounceError.invalidPlan(
                    "Unsupported Pro Tools MP3 CBR: \(request.plan.settings.mp3ConstantBitRateKbps) kbps"
                )
            }
            let quality = switch request.plan.settings.mp3Quality {
            case .fastest: "MP3EOQuality_Low"
            case .standard, .highest: "MP3EOQuality_Highest"
            }
            encodingOptions = [
                "encoding_options_mp3": [
                    "bit_rate": "MP3EOCBRate_\(request.plan.settings.mp3ConstantBitRateKbps)kbps",
                    "quality": quality
                ]
            ]
        } else {
            encodingOptions = [:]
        }

        var body: [String: Any] = [
            "file_name": request.baseFileName,
            "file_type": fileType,
            "audio_info": audioInfo,
            "location_info": locationInfo,
            "offline_bounce": request.plan.settings.offlineBounce
                ? (modernEnums ? "TBool_True" : "TB_True")
                : (modernEnums ? "TBool_False" : "TB_False"),
            "mix_source_list": [[
                "source_type": mixSourceName(
                    request.plan.settings.mixSourceType,
                    modern: modernEnums
                ),
                "name": request.plan.settings.mixSource
            ]],
        ]

        if capabilities.audioEncodingOptions {
            body["audio_encoding_options"] = encodingOptions
        }
        if capabilities.exportTimeRange {
            body["start_time"] = [
                "location": String(request.plan.range.start),
                "time_type": "TLType_Samples"
            ]
            body["end_time"] = [
                "location": String(request.plan.range.end),
                "time_type": "TLType_Samples"
            ]
        }

        if request.kind == .mov {
            let exportOption: String
            let codecName: String
            switch request.videoMode {
            case .sameAsSource:
                exportOption = modernEnums ? "EMVEOptions_SameAsSource" : "VE_SameAsSource"
                codecName = ""
            case .transcodeH264:
                exportOption = modernEnums ? "EMVEOptions_Transcode" : "VE_Transcode"
                codecName = "H264"
            }
            body["video_info"] = [
                "include_video": modernEnums ? "TBool_True" : "TB_True",
                "export_option": exportOption,
                "replace_timecode_track": modernEnums ? "TBool_False" : "TB_False",
                // Let Pro Tools choose encoding properties for H.264.
                "codec_info": [
                    "codec_name": codecName,
                    "property_list": []
                ]
            ]
        }
        return body
    }

    /// PTSL 2026.04 expects directory destinations to be absolute file-system
    /// paths terminated by exactly one slash. Without the trailing slash,
    /// Pro Tools can interpret the value as a file location and assert while
    /// constructing its macOS file-location object.
    private static func ptslDirectoryPath(_ directory: URL) throws -> String {
        guard directory.isFileURL else {
            throw QuickBounceError.invalidPlan(
                "Pro Tools export directory must be a local file URL"
            )
        }

        var path = directory.standardizedFileURL.path
        guard path.hasPrefix("/") else {
            throw QuickBounceError.invalidPlan(
                "Pro Tools export directory must be an absolute path"
            )
        }

        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path != "/" {
            path.append("/")
        }
        return path
    }

    static func importAudio(_ request: ImportAudioRequest) -> [String: Any] {
        [
            "import_type": "IType_Audio",
            "audio_data": [
                "file_list": [request.fileURL.path],
                "audio_operations": "AOperations_CopyAudio",
                "audio_destination": "MDestination_NewTrack",
                "audio_location": "MLocation_Spot",
                "location_data": [
                    "location_type": "SLType_Start",
                    "location": [
                        "location": String(request.spotSamples),
                        "time_type": "TLType_Samples"
                    ]
                ]
            ]
        ]
    }

    static func mixSourceName(_ type: MixSourceType, modern: Bool = true) -> String {
        switch type {
        case .physicalOutput: modern ? "EMSType_PhysicalOut" : "PhysicalOut"
        case .bus: modern ? "EMSType_Bus" : "Bus"
        case .trackOutput: modern ? "EMSType_Output" : "Output"
        }
    }

    private static func sampleRateName(_ rate: Int) -> String {
        switch rate {
        case 44_100: return "SR_44100"
        case 48_000: return "SR_48000"
        case 88_200: return "SR_88200"
        case 96_000: return "SR_96000"
        case 176_400: return "SR_176400"
        case 192_000: return "SR_192000"
        default: return "SR_None"
        }
    }
}
