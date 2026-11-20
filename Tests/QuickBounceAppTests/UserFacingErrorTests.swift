import Foundation
@testable import QuickBounceApp
import Testing

private func ptslError(_ code: Any, warning: Bool = false) throws -> String {
    let object: [String: Any] = ["errors": [
        ["command_error_type": "CEType_PT_Info", "command_error_message": "warning", "is_warning": true],
        ["command_error_type": code, "command_error_message": "private technical detail {track-id}", "is_warning": warning]
    ]]
    return "PTSL status 4: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test(arguments: ["CEType_PT_NoSelection", "PT_InvalidSelection", "CEType_PT_NoOpenedSession",
    "CEType_PT_NoTrackFound", "CEType_PT_ForbiddenTrackType", "CEType_OS_WritePermissions",
    "CEType_OS_DiskSpace", "CEType_PT_CommandTimeout", "CEType_PT_HostIsBusy",
    "CEType_PT_SampleRateMismatch", "CEType_PT_NoVideoTrackFound", "CEType_PT_ReadOnlySession",
    "CEType_PT_UnsupportedCommand", "CEType_PT_InvalidParameter", "CEType_OS_NoLocationFound"])
func commonPTSLErrorsHaveShortBilingualGuidance(code: String) throws {
    let raw = try ptslError(code)
    let english = UserFacingError.message(for: raw)
    let chinese = Copy.render(english, language: .simplifiedChinese)
    #expect(english != raw && chinese != english)
    #expect(!english.contains("CEType") && !english.contains("track-id"))
    #expect(english.count < 200 && chinese.count < 100)
    #expect(Copy.render(english, language: .english) == english)
}

@Test func numericErrorCodesAndWrappedFailuresUseTheSameGuidance() throws {
    let named = UserFacingError.message(for: try ptslError("CEType_PT_ForbiddenTrackType"))
    #expect(UserFacingError.message(for: try ptslError(130)) == named)
    #expect(UserFacingError.message(for: "Bounce failed: " + (try ptslError(130))) == named)
    let saved = UserFacingError.message(for: "Session save failed: " + (try ptslError(130)))
    #expect(saved.contains("could not be saved"))
    let restore = UserFacingError.message(for: "Session restoration failed: " + (try ptslError(130)))
    #expect(restore.contains("could not be restored"))
}

@Test func unknownHostErrorsDoNotClaimTheUserSettingsAreWrong() throws {
    for raw in [try ptslError("CEType_PT_UnknownError"), try ptslError("FutureUnknownError"),
                "PTSL status 4: malformed {", "Assertion in /Users/autobld/File.cpp, line 129"] {
        let message = UserFacingError.message(for: raw)
        #expect(message.contains("diagnostic log"))
        #expect(!message.contains("settings") && !message.contains("autobld"))
        #expect(Copy.render(message, language: .simplifiedChinese).contains("诊断日志"))
    }
    let validation = "Mix name cannot be empty."
    #expect(UserFacingError.message(for: validation) == validation)
    #expect(UserFacingError.message(for: "Bounce Plan is invalid: Choose a non-empty Pro Tools Timeline Selection").contains("Select a time range"))
}

@Test func bounceVolumeFailureTakesPrecedenceOverLongGOPWarning() throws {
    let warning: [String: Any] = [
        "command_error_type": "CEType_PT_UnknownError",
        "command_error_message": "Video within the current timeline selection is not supported for Same as Source export.\n\nLong GOP video requires the first frame of the file to be included in the bounce range.",
        "is_warning": true
    ]
    let failure: [String: Any] = [
        "command_error_type": "CEType_PT_UnknownError",
        "command_error_message": "Can't create bounce files because \"Macintosh HD\" is not an audio playback volume..",
        "is_warning": false
    ]
    func message(_ errors: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["errors": errors])
        return UserFacingError.message(for: "PTSL status 4: " + String(decoding: data, as: UTF8.self))
    }

    let combined = try message([warning, failure])
    let volumeOnly = try message([failure])
    #expect(combined.hasPrefix(volumeOnly + "\n\n"))
    #expect(volumeOnly.contains("Workspace"))
    #expect(combined.contains("first frame"))
    let chinese = Copy.render(combined, language: .simplifiedChinese)
    #expect(chinese.contains("磁盘卷") && chinese.contains("第一帧"))
    #expect(try message([warning]).contains("diagnostic log"))
}
