import AppKit
import Foundation
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURL: URL?

    func toggle(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            previewURL = nil
            return
        }
        previewURL = url
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
        previewURL = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

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
