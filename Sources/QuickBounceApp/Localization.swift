import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    static let preferenceKey = "quickbounce.language"
    var id: String { rawValue }
    var title: String { self == .english ? "English" : "简体中文" }
}

enum FunctionTipsPreference {
    static let key = "quickbounce.functionTips"
}

enum Copy {
    static func text(_ english: String, language: AppLanguage) -> String {
        guard language == .simplifiedChinese else { return english }
        return UserFacingError.chinese[english] ?? InterfaceCopy.chinese[english] ?? english
    }
}

struct LocalizedText: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.english.rawValue
    let english: String
    var body: some View { Text(Copy.render(english, language: AppLanguage(rawValue: language) ?? .english)) }
}

struct LocalizedLabel: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.english.rawValue
    let english: String
    let systemImage: String
    var body: some View {
        Label(Copy.render(english, language: AppLanguage(rawValue: language) ?? .english), systemImage: systemImage)
    }
}

/// UI-only lookup. Persisted model values and user-entered names remain untouched.
func L(_ english: String) -> String {
    Copy.render(english, language: AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "en") ?? .english)
}

extension Copy {
    struct Template {
        let expression: NSRegularExpression
        let translated: String
        let placeholders: [String]
        let specificity: Int
    }

    static let templates: [Template] = InterfaceCopy.chinese.compactMap { source, translated in
        let marker = try! NSRegularExpression(pattern: "\\{[^}]+\\}")
        let ns = source as NSString
        let matches = marker.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var pattern = "^"
        var offset = 0
        var placeholders: [String] = []
        for match in matches {
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            pattern += "([\\s\\S]*?)"
            placeholders.append(ns.substring(with: match.range))
            offset = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: offset)) + "$"
        return Template(expression: try! NSRegularExpression(pattern: pattern), translated: translated,
                        placeholders: placeholders, specificity: source.count - placeholders.joined().count)
    }.sorted { $0.specificity > $1.specificity }

    static func render(_ english: String, language: AppLanguage) -> String {
        guard language == .simplifiedChinese else { return english }
        if let errorCopy = UserFacingError.chinese[english] { return errorCopy }
        if let exact = InterfaceCopy.chinese[english] { return exact }
        for template in templates {
            let ns = english as NSString
            guard let match = template.expression.firstMatch(in: english, range: NSRange(location: 0, length: ns.length)) else { continue }
            // Substitute in a single pass so user content containing braces stays intact.
            let captures = Dictionary(template.placeholders.enumerated().map { index, key in
                (key, ns.substring(with: match.range(at: index + 1)))
            }, uniquingKeysWith: { first, _ in first })
            let marker = try! NSRegularExpression(pattern: "\\{[^}]+\\}")
            var output = template.translated
            let outputNS = output as NSString
            for token in marker.matches(in: output, range: NSRange(location: 0, length: outputNS.length)).reversed() {
                let key = outputNS.substring(with: token.range)
                if let value = captures[key], let range = Range(token.range, in: output) {
                    output.replaceSubrange(range, with: value)
                }
            }
            return output
        }
        return english
    }
}
