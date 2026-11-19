import Foundation
import QuickBounceDomain

/// A folder-backed library, independent of transient queues and the SQLite cleanup at launch.
struct SessionSettingsLibrary {
    struct Entry: Identifiable, Equatable {
        let url: URL
        let name: String
        let addedAt: Date
        var id: URL { url }
    }

    struct SaveRequest {
        let entry: Entry
        let document: SessionSettingsDocument
        let previousData: Data?
        var requiresReplacement: Bool { previousData != nil }
    }

    private struct Record: Codable {
        let libraryVersion: Int
        let addedAt: Date
        let document: SessionSettingsDocument
    }

    let directory: URL

    func entries() throws -> [Entry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey],
            options: [.skipsHiddenFiles]).compactMap { url in
                guard url.pathExtension.lowercased() == "json" else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                let record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
                // Keep unreadable JSON visible so users can find/remove it in Finder.
                return Entry(url: url, name: Self.name(for: url), addedAt: record?.addedAt ?? values.creationDate ?? .distantPast)
            }.sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
    }

    static func visibleEntries(_ entries: [Entry], query: String, searching: Bool) -> [Entry] {
        guard searching else { return Array(entries.prefix(5)) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(query) }
    }

    func prepareSave(name: String, document: SessionSettingsDocument, now: Date = Date()) throws -> SaveRequest {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              name.utf8.count <= 200,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil else {
            throw QuickBounceError.invalidPlan("Enter a settings name without slashes, colons or control characters (up to 200 UTF-8 bytes).")
        }
        let matches = try entries().filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard matches.count <= 1 else {
            throw QuickBounceError.invalidPlan("Multiple settings files have this name. Rename them in the settings folder first.")
        }
        let entry = matches.first ?? Entry(url: directory.appendingPathComponent(name + ".quickbounce.json"), name: name, addedAt: now)
        let previous = try matches.first.map { try Data(contentsOf: $0.url) }
        // Do not follow an existing symlink or overwrite a hidden/nonregular file.
        guard previous != nil || !FileManager.default.fileExists(atPath: entry.url.path) else {
            throw QuickBounceError.invalidPlan("A file already occupies this settings name. Check the settings folder.")
        }
        return SaveRequest(entry: entry, document: document, previousData: previous)
    }

    /// Only an explicitly confirmed request may replace a file. Detect Finder changes since the prompt.
    @discardableResult
    func save(_ request: SaveRequest, replacing: Bool = false) throws -> Entry {
        let existing = FileManager.default.fileExists(atPath: request.entry.url.path)
        let values = try? request.entry.url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true,
              (!request.requiresReplacement || replacing),
              (existing ? try Data(contentsOf: request.entry.url) : nil) == request.previousData else {
            throw QuickBounceError.invalidPlan("The settings file changed. Refresh the list and save again.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = Record(libraryVersion: 1, addedAt: request.entry.addedAt, document: request.document)
        try encoder.encode(record).write(to: request.entry.url, options: .atomic)
        return request.entry
    }

    func load(_ entry: Entry) throws -> SessionSettingsDocument {
        guard entry.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              try entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw QuickBounceError.invalidPlan("The settings file changed. Refresh the list and save again.")
        }
        let data = try Data(contentsOf: entry.url)
        let decoder = JSONDecoder()
        let document: SessionSettingsDocument
        if let record = try? decoder.decode(Record.self, from: data) {
            guard record.libraryVersion == 1 else {
                throw QuickBounceError.invalidPlan("This Session Settings file is empty or uses an unsupported version.")
            }
            document = record.document
        } else {
            // Existing user documents can be copied into this folder; never move/delete their originals.
            document = try decoder.decode(SessionSettingsDocument.self, from: data)
        }
        guard document.formatVersion == 1, !document.plans.isEmpty else {
            throw QuickBounceError.invalidPlan("This Session Settings file is empty or uses an unsupported version.")
        }
        return document
    }

    private static func name(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.hasSuffix(".quickbounce") ? String(stem.dropLast(".quickbounce".count)) : stem
    }
}

struct SessionSettingsSaveDraft: Identifiable {
    let id = UUID()
    let name: String
    let session: SessionIdentity
    let document: SessionSettingsDocument
}
