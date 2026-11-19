@testable import QuickBounceApp
import Testing

@Test func languageCopyUsesApprovedChineseAndKeepsTechnicalFormats() {
    #expect(AppLanguage.allCases.map(\.rawValue) == ["en", "zh-Hans"])
    #expect(Copy.text("Add Mix", language: .simplifiedChinese) == "添加混音版本")
    #expect(Copy.text("Stems Check", language: .simplifiedChinese) == "分层检查")
    #expect(Copy.text("WAV", language: .simplifiedChinese) == "WAV")
    #expect(Copy.text("User supplied name", language: .simplifiedChinese) == "User supplied name")
}

@Test func functionTipsPreferenceIsSeparateFromMetricDetailPopover() {
    #expect(FunctionTipsPreference.key != AppLanguage.preferenceKey)
    #expect(AppTheme.allCases.map(\.rawValue) == ["system", "light", "dark"])
}

@Test func dynamicCopyPreservesUserNamesAndPaths() {
    #expect(Copy.render("Bouncing My Mix {名称} 🎹", language: .simplifiedChinese) == "正在导出 My Mix {名称} 🎹")
    #expect(Copy.render("Bounced 2 of 8 mixes", language: .simplifiedChinese) == "已导出 2/8 个混音版本")
    #expect(Copy.render("Update “现场/Default”", language: .simplifiedChinese) == "更新“现场/Default”")
    #expect(Copy.render("Bouncing My Mix", language: .english) == "Bouncing My Mix")
    #expect(Copy.render("A bounced file already exists:\n/Volumes/T9/现场 {路径}.wav\n\nDo you want to overwrite it?", language: .simplifiedChinese) == "导出文件已存在：\n/Volumes/T9/现场 {路径}.wav\n\n是否覆盖？")
}

@Test func functionTipsUseSelectedLanguageAndRespectDisable() {
    #expect(Copy.tip("Offline Bounce", language: .english)?.contains("real time") == true)
    #expect(Copy.tip("Offline Bounce", language: .simplifiedChinese)?.contains("离线导出") == true)
    #expect(Copy.tip("Offline Bounce", language: .english, enabled: false) == nil)
    #expect(Copy.tip("Unknown user name", language: .simplifiedChinese) == nil)
    #expect(Copy.text("Max. Momentary Loudness", language: .simplifiedChinese) == "最大瞬时响度")
    for (_, pair) in InterfaceCopy.tips {
        #expect(pair.count == 2)
        #expect(pair.allSatisfy { !$0.isEmpty })
    }
}
