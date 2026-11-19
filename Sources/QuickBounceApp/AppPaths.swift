import AppKit
import Foundation
import QuickBounceApplication
import QuickBounceDomain

enum AppPaths {
    private static let bundleIdentifier = "com.quickbounce.desktop"

    static let applicationSupport = userDirectory(.applicationSupportDirectory)
        .appendingPathComponent("QuickBounce", isDirectory: true)
    static let caches = userDirectory(.cachesDirectory)
        .appendingPathComponent(bundleIdentifier, isDirectory: true)

    static let database = applicationSupport.appendingPathComponent("QuickBounce.sqlite")
    static let sessionSettings = applicationSupport.appendingPathComponent("Session Settings", isDirectory: true)
    static let diagnostics = applicationSupport.appendingPathComponent("Diagnostics", isDirectory: true)
    static let staging = caches.appendingPathComponent("Staging", isDirectory: true)
    static let waveforms = caches.appendingPathComponent("Waveforms", isDirectory: true)
    static let demo = caches.appendingPathComponent("Demo", isDirectory: true)
    static let demoDatabase = demo.appendingPathComponent("QuickBounce-Demo.sqlite")
    static let demoOutput = demo.appendingPathComponent("Bounced Files", isDirectory: true)
    static let defaultBounceOutput = userDirectory(.musicDirectory)
        .appendingPathComponent("QuickBounce", isDirectory: true)
        .appendingPathComponent("Bounced Files", isDirectory: true)

    // V0.2.5 and earlier derived internal storage from the compile-time source
    // path. Keep this only as a one-release migration source; no new data is
    // ever written here.
    private static let legacyProjectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL
    private static let legacyData = legacyProjectRoot
        .appendingPathComponent(".quickbounce-data", isDirectory: true)
    private static let legacyDemo = legacyProjectRoot
        .appendingPathComponent(".quickbounce-demo", isDirectory: true)
    private static let legacyDatabase = legacyData.appendingPathComponent("QuickBounce.sqlite")

    struct LaunchPreparation {
        let shouldFinalizeLegacyData: Bool
    }

    static func prepareForLaunch(demoMode: Bool) throws -> LaunchPreparation {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        if demoMode {
            try fileManager.createDirectory(at: demo, withIntermediateDirectories: true)
            return LaunchPreparation(shouldFinalizeLegacyData: false)
        }

        guard containsKnownLegacyData else {
            return LaunchPreparation(shouldFinalizeLegacyData: false)
        }
        guard !hasAnotherRunningQuickBounce else {
            throw QuickBounceError.persistence(
                "Close the other running QuickBounce instance so QuickBounce can safely migrate and clean its legacy internal data"
            )
        }

        if !fileManager.fileExists(atPath: database.path),
           fileManager.fileExists(atPath: legacyDatabase.path) {
            try LegacyInternalDataMigration.installDatabaseIfNeeded(
                from: legacyDatabase,
                to: database
            )
        }
        return LaunchPreparation(shouldFinalizeLegacyData: true)
    }

    static func finalizeLegacyData(_ preparation: LaunchPreparation) throws {
        guard preparation.shouldFinalizeLegacyData else { return }
        let fileManager = FileManager.default
        let knownEntries = [
            legacyData.appendingPathComponent("Staging", isDirectory: true),
            legacyData.appendingPathComponent("Waveforms", isDirectory: true),
            legacyData.appendingPathComponent("QuickBounce.sqlite"),
            legacyData.appendingPathComponent("QuickBounce.sqlite-wal"),
            legacyData.appendingPathComponent("QuickBounce.sqlite-shm"),
            legacyData.appendingPathComponent("QuickBounce-Demo.sqlite"),
            legacyData.appendingPathComponent("QuickBounce-Demo.sqlite-wal"),
            legacyData.appendingPathComponent("QuickBounce-Demo.sqlite-shm")
        ]
        for entry in knownEntries where fileManager.fileExists(atPath: entry.path) {
            try fileManager.removeItem(at: entry)
        }
        if fileManager.fileExists(atPath: legacyDemo.path) {
            try fileManager.removeItem(at: legacyDemo)
        }
        if fileManager.fileExists(atPath: legacyData.path),
           try fileManager.contentsOfDirectory(atPath: legacyData.path).isEmpty {
            try fileManager.removeItem(at: legacyData)
        }
    }

    private static var containsKnownLegacyData: Bool {
        let fileManager = FileManager.default
        let knownNames = [
            "Staging", "Waveforms", "QuickBounce.sqlite", "QuickBounce.sqlite-wal",
            "QuickBounce.sqlite-shm", "QuickBounce-Demo.sqlite", "QuickBounce-Demo.sqlite-wal",
            "QuickBounce-Demo.sqlite-shm"
        ]
        return fileManager.fileExists(atPath: legacyDemo.path) || knownNames.contains {
            fileManager.fileExists(atPath: legacyData.appendingPathComponent($0).path)
        }
    }

    private static var hasAnotherRunningQuickBounce: Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID && !$0.isTerminated }
    }

    private static func userDirectory(_ directory: FileManager.SearchPathDirectory) -> URL {
        let fileManager = FileManager.default
        if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
            return url.standardizedFileURL
        }
        preconditionFailure("macOS did not provide the requested user directory: \(directory.rawValue)")
    }
}
