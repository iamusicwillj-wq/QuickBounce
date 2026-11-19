import Foundation

public enum LegacyInternalDataMigration {
    @discardableResult
    public static func installDatabaseIfNeeded(
        from legacyDatabase: URL,
        to destinationDatabase: URL
    ) throws -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationDatabase.path),
              fileManager.fileExists(atPath: legacyDatabase.path) else { return false }

        let destinationDirectory = destinationDatabase.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let temporary = destinationDirectory
            .appendingPathComponent(".quickbounce-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let temporaryDatabase = temporary.appendingPathComponent(destinationDatabase.lastPathComponent)
        let legacyWAL = URL(fileURLWithPath: legacyDatabase.path + "-wal")
        let destinationWAL = URL(fileURLWithPath: destinationDatabase.path + "-wal")
        let destinationSHM = URL(fileURLWithPath: destinationDatabase.path + "-shm")
        let temporaryWAL = temporary.appendingPathComponent(destinationWAL.lastPathComponent)

        // Copy the complete closed legacy database set before publishing any
        // destination file. Install WAL first and the main database last so
        // main-database existence is the migration commit marker on restart.
        try fileManager.copyItem(at: legacyDatabase, to: temporaryDatabase)
        if fileManager.fileExists(atPath: legacyWAL.path) {
            try fileManager.copyItem(at: legacyWAL, to: temporaryWAL)
        }
        for orphan in [destinationWAL, destinationSHM]
        where fileManager.fileExists(atPath: orphan.path) {
            try fileManager.removeItem(at: orphan)
        }
        if fileManager.fileExists(atPath: temporaryWAL.path) {
            try fileManager.moveItem(at: temporaryWAL, to: destinationWAL)
        }
        try fileManager.moveItem(at: temporaryDatabase, to: destinationDatabase)
        return true
    }
}
