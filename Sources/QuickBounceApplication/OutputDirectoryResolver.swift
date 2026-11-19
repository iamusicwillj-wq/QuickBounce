import Foundation
import QuickBounceDomain

public struct OutputDirectoryResolver: Sendable {
    public init() {}

    public func uniqueDestinations(for plans: [BouncePlan]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for plan in plans {
            let url = URL(fileURLWithPath: plan.settings.fileDestination)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { continue }
            result.append(url)
        }
        return result
    }

    public func validate(_ plans: [BouncePlan], crossSession: Bool) throws {
        guard !plans.isEmpty else { throw QuickBounceError.invalidPlan("No enabled Mixes are available") }
        let sessionPaths = Set(plans.map { canonicalURL(for: $0.session.path).path })
        if !crossSession, sessionPaths.count > 1 {
            throw QuickBounceError.invalidPlan("Multiple Sessions require cross-Session mode")
        }
        for plan in plans {
            guard plan.range.isValid else {
                throw QuickBounceError.invalidPlan("\(plan.name) has an invalid time range")
            }
            guard !plan.settings.fileDestination.isEmpty else {
                throw QuickBounceError.invalidPlan("\(plan.name) has no File Destination")
            }
            if crossSession && plan.settings.importAfterBounce {
                throw QuickBounceError.invalidPlan("Import After Bounce is disabled for cross-Session jobs")
            }
            if plan.settings.exportType == .mov && plan.settings.importAfterBounce {
                throw QuickBounceError.invalidPlan("MOV does not support Import After Bounce")
            }
            if plan.settings.exportType == .mov, plan.settings.movAudioCodec == .aac,
               !MOVAudioCodec.aacSampleRates.contains(plan.settings.sampleRate) {
                throw QuickBounceError.invalidPlan("For MOV AAC, choose 44.1 or 48 kHz.")
            }
        }
    }

    public func canonicalURL(for path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
