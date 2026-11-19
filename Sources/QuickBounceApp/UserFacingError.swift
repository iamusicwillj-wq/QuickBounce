import AppKit
import Foundation
import SwiftUI

/// Presentation only: keep the original error in the model/log, and select a
/// short explanation using PTSL's documented error type. Never guess that an
/// unknown Host error was caused by the user's settings.
enum UserFacingError {
    private static let connection = "QuickBounce could not connect to Pro Tools. Open Pro Tools, wait until it is ready, then reconnect."
    private static let selection = "Select a time range in Pro Tools, then add the Mix again."
    private static let noSession = "Open the Session you want to export in Pro Tools, then try again."
    private static let tracks = "The saved tracks no longer match the open Session. Check the Session and add this Mix again."
    private static let forbiddenTrack = "Pro Tools could not change a track’s Solo/Mute state. Check the track type and whether it is active, then try again."
    private static let busy = "Pro Tools is busy. Close any open dialog and wait for the current operation to finish, then try again."
    private static let timeout = "Pro Tools did not respond in time. Check its current state before trying again."
    private static let settings = "Pro Tools did not accept this request. Check the relevant settings; if it repeats, export a diagnostic log."
    private static let permission = "QuickBounce cannot write to the selected folder. Choose a folder you can save files in."
    private static let space = "Not enough disk space. Free space on the export or system disk, then try again."
    private static let spaceRecovery = "Not enough disk space. Free space, recover the Pro Tools Session, then try again."
    private static let location = "The selected file or folder could not be found. Reconnect the disk or choose the location again."
    private static let duplicate = "A file with this name already exists. Choose another name or confirm that it can be overwritten."
    private static let name = "This file name is not accepted by Pro Tools. Use a shorter name without special characters."
    private static let video = "Pro Tools cannot find a video track to export. Check the Session’s video track, or choose WAV or MP3."
    private static let videoEngine = "The Pro Tools video engine is unavailable. Enable it and wait for the video to load, then try again."
    private static let sampleRate = "The sample rates do not match. Check the Session and export sample-rate settings."
    private static let readOnly = "This Session is read-only. Save a writable copy in Pro Tools, then try again."
    private static let version = "This feature is unavailable in your Pro Tools version. Choose another option or update Pro Tools."
    private static let state = "The Mix’s Solo/Mute state could not be confirmed. Check the tracks in Pro Tools before trying again."
    private static let restore = "The Session state could not be restored. Check Solo/Mute and the time selection in Pro Tools before continuing."
    private static let save = "The restored Session could not be saved. Save it in Pro Tools before continuing."
    private static let analysis = "This file could not be analyzed. Check that it is accessible, then click Retry Analysis."
    private static let playback = "This audio file could not be played. Check the file and your audio output device, then try again."
    private static let integrity = "The exported file did not pass the integrity check. Check the export settings and file before using it."
    private static let database = "QuickBounce could not save its local data. Check disk space and folder access, then try again."
    private static let unknownPT = "Pro Tools could not complete this operation. Try again; if it repeats, export a diagnostic log for troubleshooting."
    private static let unknown = "This operation could not be completed. Try again; if it repeats, export a diagnostic log for troubleshooting."

    static let chinese: [String: String] = [
        connection: "未能连接 Pro Tools。请打开 Pro Tools，等待就绪后重新连接。",
        selection: "请先在 Pro Tools 中选择一段时间范围，再重新添加混音版本。",
        noSession: "请在 Pro Tools 中打开需要导出的工程，然后重试。",
        tracks: "保存的轨道与当前工程不一致。请确认工程，并重新添加这个混音版本。",
        forbiddenTrack: "Pro Tools 未能更改某条轨道的独奏或静音状态。请检查轨道类型及是否已激活，然后重试。",
        busy: "Pro Tools 正忙。请关闭其中的弹窗，等待当前操作结束后重试。",
        timeout: "Pro Tools 响应超时。请先确认它当前的状态，再重试。",
        settings: "Pro Tools 未接受这次操作请求。请核对相关设置；如果再次出现，请导出诊断日志。",
        permission: "无法写入所选文件夹。请改选一个可以保存文件的文件夹。",
        space: "磁盘空间不足。请在导出磁盘或系统磁盘上腾出空间后重试。",
        spaceRecovery: "磁盘空间不足。请腾出空间，恢复 Pro Tools 工程状态后再重试。",
        location: "找不到所选文件或文件夹。请重新连接磁盘，或重新选择位置。",
        duplicate: "已有同名文件。请修改名称，或确认是否覆盖。",
        name: "Pro Tools 不接受这个文件名。请缩短名称，并避免使用特殊字符。",
        video: "Pro Tools 未找到可导出的视频轨道。请检查工程的视频轨道，或改选 WAV、MP3。",
        videoEngine: "Pro Tools 视频引擎不可用。请启用视频引擎，等待视频加载后重试。",
        sampleRate: "采样率不一致。请检查工程与导出的采样率设置。",
        readOnly: "这个工程是只读的。请先在 Pro Tools 中另存为可写入的副本，再重试。",
        version: "当前 Pro Tools 版本不支持这项功能。请改选其他选项，或更新 Pro Tools。",
        state: "未能确认这个混音版本的独奏和静音状态。请先在 Pro Tools 中核查轨道，再重试。",
        restore: "工程状态未能恢复。继续操作前，请在 Pro Tools 中核查独奏、静音和时间选区。",
        save: "恢复后的工程未能保存。继续操作前，请先在 Pro Tools 中保存工程。",
        analysis: "这个文件未能完成分析。请确认文件可以访问，再点击“重新分析”。",
        playback: "未能播放这个音频文件。请检查文件和音频输出设备，然后重试。",
        integrity: "导出文件未通过完整性检查。使用前请检查导出设置和文件。",
        database: "QuickBounce 未能保存本地数据。请检查磁盘空间和文件夹访问权限，然后重试。",
        unknownPT: "Pro Tools 未能完成这次操作。请重试；如果再次出现，请导出诊断日志以便排查。",
        unknown: "这次操作未能完成。请重试；如果再次出现，请导出诊断日志以便排查。",
        "Technical Details…": "技术详情…",
        "Technical Details": "技术详情",
        "Copy Details": "复制详情",
    ]

    static func message(for raw: String) -> String {
        // Recovery/save failures take precedence over an embedded PTSL error:
        // the user must know that the original Session still needs attention.
        if raw.hasPrefix("Session save failed:") { return save }
        if raw.hasPrefix("Session restoration failed:") || raw.hasPrefix("Manual recovery required:") {
            return raw.contains("Not enough disk space:") ? spaceRecovery : restore
        }
        if raw.hasPrefix("Not enough disk space:") { return space }
        if raw.hasPrefix("Review analysis ") { return analysis }

        if let code = ptslErrorCode(in: raw) {
            switch code {
            case "OS_ProToolsIsNotAvailable", "SDK_GrpcGeneric": return connection
            case "PT_NoOpenedSession", "OS_NoSessionFound": return noSession
            case "PT_NoSelection", "PT_InvalidSelection": return selection
            case "PT_NoTrackFound", "PT_NoTracksFound": return tracks
            case "PT_ForbiddenTrackType": return forbiddenTrack
            case "PT_HostNotReady", "PT_HostIsBusy": return busy
            case "PT_CommandTimeout": return timeout
            case "PT_InvalidParameter", "PT_ArgumentOutOfRange": return settings
            case "OS_WritePermissions": return permission
            case "OS_DiskSpace": return space
            case "OS_NoLocationFound", "OS_FilePathLocation", "OS_NoFilePathFound", "PT_FileNotFound", "OS_ReadError": return location
            case "OS_DuplicateName": return duplicate
            case "OS_IllegalCharacters", "OS_CharactersLimit", "PT_IllegalCharactersSequenceName", "PT_MaxCharactersSequenceName": return name
            case "PT_NoVideoTrackFound": return video
            case "PT_NoVideoEngineFound": return videoEngine
            case "PT_SampleRateMismatch": return sampleRate
            case "PT_ReadOnlySession": return readOnly
            case "PT_UnsupportedCommand", "SDK_VersionMismatch", "SDK_NotImplemented": return version
            default: return unknownPT
            }
        }
        if raw.contains("PTSL status") || raw.contains("CEType_") || raw.contains("Assertion in") { return unknownPT }
        if raw.hasPrefix("Connection failed:") { return connection }
        if raw.hasPrefix("Track is missing:") || raw.contains("Session no longer matches") { return tracks }
        if raw.hasPrefix("Track state verification failed:") { return state }
        if raw.hasPrefix("Expected bounced file was not found:") { return location }
        if raw.hasPrefix("Bounced file is invalid:") { return integrity }
        if raw.hasPrefix("Permission is required:") { return permission }
        if raw.hasPrefix("Persistence failed:") { return database }
        if raw.contains("non-empty") && raw.contains("Timeline Selection") { return selection }
        if raw.contains("com.apple.coreaudio") || raw.contains("AVFAudio") { return playback }
        if raw.contains("NSCocoaErrorDomain") || raw.contains("NSOSStatusErrorDomain") || raw.contains("error ") && raw.contains("(") {
            return unknown
        }
        // Existing plain-language validation (e.g. an empty Mix name) stays
        // specific and continues to use the app's established translations.
        return raw
    }

    private static func ptslErrorCode(in raw: String) -> String? {
        let source = raw.range(of: "PTSL status").map { String(raw[$0.lowerBound...]) } ?? raw
        guard let start = source.firstIndex(of: "{"), let end = source.lastIndex(of: "}"),
              start <= end,
              let json = try? JSONSerialization.jsonObject(with: Data(source[start...end].utf8)) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let error = errors.first(where: { ($0["is_warning"] as? Bool) != true }) else { return nil }
        if let text = error["command_error_type"] as? String {
            return text.hasPrefix("CEType_") ? String(text.dropFirst(7)) : text
        }
        // Hosts normally return enum names, but proto JSON may use integers.
        let codes: [Int: String] = [0: "OS_WritePermissions", 2: "OS_NoLocationFound", 3: "OS_NoSessionFound",
            5: "OS_ReadError", 6: "OS_DiskSpace", 7: "OS_DuplicateName", 8: "OS_IllegalCharacters",
            9: "OS_CharactersLimit", 10: "OS_ProToolsIsNotAvailable", 11: "OS_NoFilePathFound",
            103: "PT_SampleRateMismatch", 104: "PT_NoVideoTrackFound", 105: "PT_NoTracksFound",
            106: "PT_NoOpenedSession", 107: "PT_NoTrackFound", 109: "PT_NoSelection", 123: "PT_FileNotFound",
            124: "PT_InvalidSelection", 125: "PT_ReadOnlySession", 126: "PT_InvalidParameter",
            129: "PT_ArgumentOutOfRange", 130: "PT_ForbiddenTrackType", 131: "PT_NoVideoEngineFound",
            133: "PT_UnsupportedCommand", 134: "PT_HostNotReady", 137: "PT_CommandTimeout",
            138: "PT_HostIsBusy", 401: "SDK_VersionMismatch", 402: "SDK_NotImplemented", 501: "SDK_GrpcGeneric"]
        return (error["command_error_type"] as? Int).flatMap { codes[$0] } ?? "PT_UnknownError"
    }
}

struct FriendlyErrorAlert: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert(L("QuickBounce"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } }
        )) {
            Button(L("OK"), action: model.dismissError)
            if let raw = model.errorMessage, UserFacingError.message(for: raw) != raw {
                Button(L("Technical Details…")) { model.showErrorDetails(raw) }
            }
        } message: {
            Text(L(UserFacingError.message(for: model.errorMessage ?? "Unknown error")))
        }
    }
}

extension View {
    func friendlyErrorAlert(model: AppModel) -> some View { modifier(FriendlyErrorAlert(model: model)) }
}

@MainActor
enum ErrorDetailsPanel {
    static func show(_ raw: String) {
        let alert = NSAlert()
        alert.messageText = L("Technical Details")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Copy Details"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 240))
        let text = NSTextView(frame: scroll.bounds)
        text.string = raw
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isVerticallyResizable = true
        text.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(raw, forType: .string)
        }
    }
}
