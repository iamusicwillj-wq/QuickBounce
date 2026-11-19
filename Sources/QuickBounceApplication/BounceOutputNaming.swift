import Foundation
import QuickBounceDomain

/// Works on copies for this export only; saved Mix names remain unchanged.
public enum BounceOutputNaming {
    public static func sanitized(_ name: String, planID: UUID) -> String {
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "-")
        return joined.isEmpty ? "QuickBounce-\(planID.uuidString)" : joined
    }

    public static func preparing(_ plans: [BouncePlan]) throws -> [BouncePlan] {
        let resolver = OutputDirectoryResolver()
        var occupiedByDirectory: [String: Set<String>] = [:]
        let supportedExtensions: Set<String> = ["wav", "mp3", "mov"]
        func key(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.lowercased()
        }
        return try plans.map { original in
            guard original.isEnabled else { return original }
            let destination = resolver.canonicalURL(for: original.settings.fileDestination)
            let defaultDestination = URL(fileURLWithPath: original.session.path)
                .deletingLastPathComponent().appendingPathComponent("Bounced Files")
                .standardizedFileURL.resolvingSymlinksInPath()
            // Custom destinations retain the existing explicit overwrite flow.
            guard destination == defaultDestination else { return original }
            let directoryKey = key(destination.path)
            if occupiedByDirectory[directoryKey] == nil {
                let files: [URL]
                if FileManager.default.fileExists(atPath: destination.path) {
                    files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                } else {
                    files = []
                }
                occupiedByDirectory[directoryKey] = Set(files.filter {
                    supportedExtensions.contains($0.pathExtension.lowercased())
                }.map { key($0.deletingPathExtension().lastPathComponent) })
            }
            let base = sanitized(original.name, planID: original.id)
            var candidate = base
            var number = 1
            while occupiedByDirectory[directoryKey, default: []].contains(key(candidate)) {
                candidate = "\(base)_\(number)"
                number += 1
            }
            occupiedByDirectory[directoryKey, default: []].insert(key(candidate))
            var prepared = original
            if candidate != base { prepared.name = candidate }
            return prepared
        }
    }
}
