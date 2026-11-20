import AppKit
import Foundation

@MainActor
enum WorkspaceNavigation {
    struct DirectoryOpenResult {
        var opened: [URL] = []
        var failed: [URL] = []
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openInDefaultBrowser(_ url: URL) async throws {
        let workspace = NSWorkspace.shared
        let webURL = URL(string: "https://example.com")!
        guard let browser = workspace.urlForApplication(toOpen: webURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try await workspace.open([url], withApplicationAt: browser, configuration: .init())
    }

    static func openDirectories(_ urls: [URL]) -> DirectoryOpenResult {
        var result = DirectoryOpenResult()
        var seen = Set<String>()
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { continue }
            let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                result.failed.append(canonical)
                continue
            }
            if NSWorkspace.shared.open(canonical) {
                result.opened.append(canonical)
            } else {
                result.failed.append(canonical)
            }
        }
        return result
    }
}
