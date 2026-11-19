import Darwin
import Foundation

public enum StagingDirectoryLifecycle {
    public static let ownerFileName = ".quickbounce-owner-pid"

    public static func prepareRoot(
        _ root: URL,
        processIsAlive: ((Int32) -> Bool)? = nil
    ) throws {
        let fileManager = FileManager.default
        let processIsAlive = processIsAlive ?? Self.processIsAlive
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                try fileManager.removeItem(at: entry)
                continue
            }

            let ownerFile = entry.appendingPathComponent(ownerFileName)
            let ownerPID = try? String(contentsOf: ownerFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let ownerPID,
               let pid = Int32(ownerPID),
               pid > 0,
               processIsAlive(pid) {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    @discardableResult
    public static func prepareJob(
        in root: URL,
        jobID: UUID,
        ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> URL {
        let fileManager = FileManager.default
        let jobDirectory = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: jobDirectory.path) {
            try fileManager.removeItem(at: jobDirectory)
        }
        try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        let ownerFile = jobDirectory.appendingPathComponent(ownerFileName)
        try Data("\(ownerPID)\n".utf8).write(to: ownerFile, options: .atomic)
        return jobDirectory
    }

    public static func removePlanDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public static func removeJob(in root: URL, jobID: UUID) throws {
        let directory = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
