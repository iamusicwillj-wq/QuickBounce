import Foundation
import QuickBounceDomain
@testable import QuickBounceProTools
import QuickBounceTestSupport
import Testing

@Test func proToolsUnavailableTransportErrorIsClassifiedWithoutHidingOtherFailures() {
    let unavailable = PTSLTransportError.command(
        status: 4,
        message: """
        {"errors":[{"command_error_type":"OS_ProToolsIsNotAvailable","command_error_message":"[Error]: Pro Tools is not available yet.","is_warning":false}]}
        """
    )
    let unrelated = PTSLTransportError.command(
        status: 4,
        message: """
        {"errors":[{"command_error_type":"CEType_PT_UnknownError","command_error_message":"Unexpected failure","is_warning":false}]}
        """
    )

    #expect(unavailable.indicatesProToolsIsNotAvailable)
    #expect(!unrelated.indicatesProToolsIsNotAvailable)
}

@Test func sessionAudioFormatUsesProductFacingNames() {
    #expect(RealProToolsAdapter.sessionAudioFormatDisplayName("SAFormat_WAVE") == "WAV")
    #expect(RealProToolsAdapter.sessionAudioFormatDisplayName("SAF_WAVE") == "WAV")
    #expect(RealProToolsAdapter.sessionAudioFormatDisplayName("SAFormat_AIFF") == "AIFF")
    #expect(RealProToolsAdapter.sessionAudioFormatDisplayName(nil) == "WAV")
}

@Test func sessionTimeCodeRateNormalizesLegacyModernAndDropFrameEnums() {
    #expect(RealProToolsAdapter.sessionTimeCodeRate("STCR_Fps25") == .fps25)
    #expect(RealProToolsAdapter.sessionTimeCodeRate("STCRate_Fps23976") == .fps23_976)
    #expect(RealProToolsAdapter.sessionTimeCodeRate("SSTCRate_Fps2997Drop") == .fps29_97)
    #expect(RealProToolsAdapter.sessionTimeCodeRate("STCRate_Fps60Drop") == .fps60)
    #expect(RealProToolsAdapter.sessionTimeCodeRate("STCRate_Unknown") == nil)
}

@Test func hostReleaseMapsLegacyPTSLGenerationsAndCapabilities() {
    #expect(PTSLHostRelease.fromHostResponse(major: 3, minor: 0, revision: 0) == .v2024_03)
    #expect(PTSLHostRelease.fromHostResponse(major: 4, minor: 0, revision: 0) == .v2024_06)
    #expect(PTSLHostRelease.fromHostResponse(major: 2025, minor: 6, revision: 0) == .v2025_06)

    let legacy = PTSLCapabilities.forHostRelease(.v2024_03)
    #expect(!legacy.trackIDSetters)
    #expect(legacy.trackStateSetters)
    #expect(!legacy.audioEncodingOptions)
    #expect(!legacy.openSessionBehaviorOptions)
}

@Test func timelineSelectionBodyIsCompleteAcrossPTSL2025_10Through2026_04() throws {
    let range = SampleRange(start: 48_000, end: 144_000)
    let body = try PTSLRequestBodyFactory.setTimelineSelection(range)

    #expect(body["location_type"] as? String == "TLType_Samples")
    #expect(body["in_time"] as? String == "48000")
    #expect(body["out_time"] as? String == "144000")
    #expect(body["play_start_marker_time"] as? String == "48000")
    #expect(body["pre_roll_start_time"] as? String == "48000")
    #expect(body["post_roll_stop_time"] as? String == "144000")
    #expect(body["pre_roll_enabled"] as? String == "TB_False")
    #expect(body["post_roll_enabled"] as? String == "TB_False")
}

@Test func timelineSelectionBodySupportsInsertionPointForExactStateRestoration() throws {
    let body = try PTSLRequestBodyFactory.setTimelineSelection(
        SampleRange(start: 48_000, end: 48_000)
    )

    #expect(body["in_time"] as? String == "48000")
    #expect(body["out_time"] as? String == "48000")
    #expect(body["play_start_marker_time"] as? String == "48000")
}

@Test func timelineSelectionBodyRejectsReversedRangeBeforeContactingProTools() {
    #expect(throws: QuickBounceError.self) {
        _ = try PTSLRequestBodyFactory.setTimelineSelection(
            SampleRange(start: 48_001, end: 48_000)
        )
    }
}

@Test func legacyExportBodyOmitsModernFields() throws {
    let capabilities = PTSLCapabilities.forHostRelease(.v2024_03)
    let body = try PTSLRequestBodyFactory.exportMix(
        makeExportRequest(kind: .wav),
        capabilities: capabilities
    )
    let audio = try #require(body["audio_info"] as? [String: Any])
    let location = try #require(body["location_info"] as? [String: Any])

    #expect(body["file_type"] as? String == "EM_WAV")
    #expect(body["start_time"] == nil)
    #expect(body["end_time"] == nil)
    #expect(body["audio_encoding_options"] == nil)
    #expect(audio["sample_rate"] as? String == "SR_48000")
    #expect(audio["sample_rate_custom"] == nil)
    #expect(audio["pad_to_frame_boundary"] as? String == "TB_True")
    #expect(audio["delivery_format"] as? String == "EM_DF_SingleFile")
    #expect(location["file_destination"] as? String == "EM_FD_Directory")
}

@Test func wavExportBodyMatchesPTSL2026_04Contract() throws {
    let request = makeExportRequest(kind: .wav, sourceType: .bus, sourceName: "Print Bus")
    let body = try PTSLRequestBodyFactory.exportMix(request)
    let audio = try #require(body["audio_info"] as? [String: Any])
    let location = try #require(body["location_info"] as? [String: Any])
    let sourceList = try #require(body["mix_source_list"] as? [[String: Any]])
    let start = try #require(body["start_time"] as? [String: Any])
    let end = try #require(body["end_time"] as? [String: Any])

    #expect(body["file_type"] as? String == "EMFType_WAV")
    #expect(body["offline_bounce"] as? String == "TBool_True")
    #expect(body["video_info"] == nil)
    #expect(audio["compression_type"] as? String == "CType_PCM")
    #expect(audio["export_format"] as? String == "EFormat_Interleaved")
    #expect(audio["bit_depth"] as? String == "BDepth_24")
    #expect(audio["sample_rate_custom"] as? Int == 48_000)
    #expect(audio["pad_to_frame_boundary"] as? String == "TBool_True")
    #expect(audio["delivery_format"] as? String == "EMDFormat_SingleFile")
    #expect(location["import_after_bounce"] as? String == "TBool_False")
    #expect(location["file_destination"] as? String == "EMFDestination_Directory")
    #expect(location["directory"] as? String == "/Staging/")
    #expect(sourceList.first?["source_type"] as? String == "EMSType_Bus")
    #expect(sourceList.first?["name"] as? String == "Print Bus")
    #expect(start["location"] as? String == "48000")
    #expect(start["time_type"] as? String == "TLType_Samples")
    #expect(end["location"] as? String == "96000")
}

@Test func exportDirectoryIsStandardizedWithExactlyOneTrailingSlash() throws {
    let request = makeExportRequest(
        kind: .wav,
        stagingDirectory: URL(fileURLWithPath: "/Staging/Jobs/../Current///")
    )
    let body = try PTSLRequestBodyFactory.exportMix(request)
    let location = try #require(body["location_info"] as? [String: Any])

    #expect(location["directory"] as? String == "/Staging/Current/")
}

@Test func realTimeExportUsesPTSLOfflineFalse() throws {
    let body = try PTSLRequestBodyFactory.exportMix(
        makeExportRequest(kind: .wav, offlineBounce: false)
    )

    #expect(body["offline_bounce"] as? String == "TBool_False")
}

@Test func exportExplicitlyDisablesFramePaddingWhenMixSettingIsOff() throws {
    let modern = try PTSLRequestBodyFactory.exportMix(
        makeExportRequest(kind: .wav, padToFrameBoundary: false)
    )
    let legacy = try PTSLRequestBodyFactory.exportMix(
        makeExportRequest(kind: .wav, padToFrameBoundary: false),
        capabilities: .forHostRelease(.v2024_03)
    )

    #expect((modern["audio_info"] as? [String: Any])?["pad_to_frame_boundary"] as? String == "TBool_False")
    #expect((legacy["audio_info"] as? [String: Any])?["pad_to_frame_boundary"] as? String == "TB_False")
}

@Test func nonFileExportDirectoryIsRejected() throws {
    let request = makeExportRequest(
        kind: .wav,
        stagingDirectory: try #require(URL(string: "https://example.com/Staging"))
    )

    #expect(throws: QuickBounceError.self) {
        _ = try PTSLRequestBodyFactory.exportMix(request)
    }
}

@Test(arguments: [MOVAudioCodec.pcm, .aac])
func movExportBodyUsesSameAsSourceVideoAndPCM(codec: MOVAudioCodec) throws {
    var request = makeExportRequest(kind: .mov, sourceType: .physicalOutput, sourceName: "Playback 1-2")
    request.plan.settings.movAudioCodec = codec
    let body = try PTSLRequestBodyFactory.exportMix(request)
    let video = try #require(body["video_info"] as? [String: Any])
    let audio = try #require(body["audio_info"] as? [String: Any])

    #expect(body["file_type"] as? String == "EMFType_MOV")
    #expect(video["include_video"] as? String == "TBool_True")
    #expect(video["export_option"] as? String == "EMVEOptions_SameAsSource")
    #expect(video["replace_timecode_track"] as? String == "TBool_False")
    let codec = try #require(video["codec_info"] as? [String: Any])
    #expect(codec["codec_name"] as? String == "")
    #expect((codec["property_list"] as? [Any])?.isEmpty == true)
    #expect(audio["compression_type"] as? String == "CType_PCM")
}

@Test func importBodySpotsNewTrackAtExactSamples() throws {
    let request = ImportAudioRequest(
        fileURL: URL(fileURLWithPath: "/Bounced Files/Main Mix.wav"),
        spotSamples: 123_456,
        trackName: "Main Mix"
    )
    let body = PTSLRequestBodyFactory.importAudio(request)
    let audio = try #require(body["audio_data"] as? [String: Any])
    let locationData = try #require(audio["location_data"] as? [String: Any])
    let location = try #require(locationData["location"] as? [String: Any])

    #expect(body["session_path"] == nil)
    #expect(body["import_type"] as? String == "IType_Audio")
    #expect(audio["audio_operations"] as? String == "AOperations_CopyAudio")
    #expect(audio["audio_destination"] as? String == "MDestination_NewTrack")
    #expect(audio["audio_location"] as? String == "MLocation_Spot")
    #expect(locationData["location_type"] as? String == "SLType_Start")
    #expect(location["location"] as? String == "123456")
    #expect(location["time_type"] as? String == "TLType_Samples")
}

@Test func directProToolsMP3RequestCarriesEncodingOptionsWithoutBitDepthOrImport() throws {
    let body = try PTSLRequestBodyFactory.exportMix(makeExportRequest(kind: .mp3))
    let audio = try #require(body["audio_info"] as? [String: Any])
    let location = try #require(body["location_info"] as? [String: Any])
    let options = try #require(body["audio_encoding_options"] as? [String: Any])
    let mp3 = try #require(options["encoding_options_mp3"] as? [String: Any])

    #expect(body["file_type"] as? String == "EMFType_MP3")
    #expect(audio["bit_depth"] == nil)
    #expect(audio["sample_rate_custom"] as? Int == 48_000)
    #expect(location["import_after_bounce"] == nil)
    #expect(mp3["bit_rate"] as? String == "MP3EOCBRate_320kbps")
    #expect(mp3["quality"] as? String == "MP3EOQuality_Highest")
}

@Test func directProToolsMP3RejectsUnsupportedSampleRate() throws {
    #expect(throws: QuickBounceError.self) {
        _ = try PTSLRequestBodyFactory.exportMix(
            makeExportRequest(kind: .mp3, sampleRate: 96_000)
        )
    }
}

@Test func trackStateRequestsUseRuntimeVerifiedAddressing() throws {
    let muteBody = PTSLRequestBodyFactory.setTrackMuteState(
        trackIDs: ["{track-id}"],
        enabled: true
    )
    let soloBody = PTSLRequestBodyFactory.setTrackSoloState(
        trackNames: ["Music Folder"],
        enabled: true
    )

    #expect(muteBody["track_ids"] as? [String] == ["{track-id}"])
    #expect(muteBody["track_names"] == nil)
    #expect(muteBody["enabled"] as? Bool == true)
    #expect(soloBody["track_names"] as? [String] == ["Music Folder"])
    #expect(soloBody["track_ids"] == nil)
    #expect(soloBody["enabled"] as? Bool == true)
}

@Test func muteAndSoloSupportExcludesOnlyVideoAndMasterTracks() {
    let audio = TrackReference(id: "audio", name: "Audio", index: 0, kind: "TType_Audio")
    let aux = TrackReference(id: "aux", name: "FX", index: 1, kind: "TType_Aux")
    let basicFolder = TrackReference(id: "basic-folder", name: "Edits", index: 2, kind: "TType_BasicFolder")
    let routingFolder = TrackReference(id: "routing-folder", name: "Music", index: 3, kind: "TType_RoutingFolder")
    let video = TrackReference(id: "video", name: "Picture", index: 4, kind: "TType_Video")
    let master = TrackReference(id: "master", name: "Master 1", index: 5, kind: "TType_Master")

    #expect(PTSLRequestBodyFactory.supportsMuteAndSoloState(audio))
    #expect(PTSLRequestBodyFactory.supportsMuteAndSoloState(aux))
    #expect(PTSLRequestBodyFactory.supportsMuteAndSoloState(basicFolder))
    #expect(PTSLRequestBodyFactory.supportsMuteAndSoloState(routingFolder))
    #expect(!PTSLRequestBodyFactory.supportsMuteAndSoloState(video))
    #expect(!PTSLRequestBodyFactory.supportsMuteAndSoloState(master))
}

private func makeExportRequest(
    kind: ArtifactKind,
    sourceType: MixSourceType = .physicalOutput,
    sourceName: String = "Output 1–2",
    stagingDirectory: URL = URL(fileURLWithPath: "/Staging"),
    offlineBounce: Bool = true,
    padToFrameBoundary: Bool = true,
    sampleRate: Int = 48_000
) -> ProToolsExportRequest {
    let session = SessionIdentity(
        path: "/Sessions/Contract.ptx",
        originID: "origin",
        instanceID: "instance",
        proToolsVersion: "2026.04",
        ptslVersion: "2026.4.0"
    )
    let plan = BouncePlan(
        name: "Main Mix",
        session: session,
        targetTrackStates: [],
        range: SampleRange(start: 48_000, end: 96_000),
        settings: BounceSettings(
            sampleRate: sampleRate,
            bitDepth: 24,
            fileLayout: .interleaved,
            offlineBounce: offlineBounce,
            padToFrameBoundary: padToFrameBoundary,
            fileDestination: "/Bounced Files",
            mixSourceType: sourceType,
            mixSource: sourceName
        )
    )
    return ProToolsExportRequest(
        plan: plan,
        stagingDirectory: stagingDirectory,
        baseFileName: "Main Mix",
        kind: kind
    )
}
