import Foundation
import QuickBounceApplication
import QuickBounceAudio
import QuickBounceDomain
import QuickBounceProTools
import QuickBounceTestSupport
import Testing

@Test func waveformIsReturnedWhenItsCacheCannotBeWritten() async throws {
    let directory = try TestWorkspace.freshDirectory("review-cache-failure")
    let cacheDirectory = directory.appendingPathComponent("Cache")
    let cache = try WaveformCache(directory: cacheDirectory)
    // A file in place of the owned cache directory deterministically fails
    // writes, including when tests run with elevated filesystem permissions.
    try FileManager.default.removeItem(at: cacheDirectory)
    try Data("blocked cache".utf8).write(to: cacheDirectory)
    let logs = directory.appendingPathComponent("Logs")
    let logger = try DiagnosticLogger(directory: logs,
        configuration: .init(appVersion: "0.6.0", appBuild: "35"))
    let service = ReviewAnalysisService(cache: cache, diagnostics: logger)
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Audio.wav"), durationSeconds: 0.2)
    let artifact = TestWorkspace.artifact(for: url)
    let pyramid = try await service.waveform(for: artifact)
    #expect(pyramid.isValid)
    let metrics = try await service.metrics(for: artifact)
    #expect(metrics.metrics.samplePeakDBFS != nil)
    let actions = try analysisLogActions(in: logs)
    #expect(actions.contains("waveform_cache_write_failed"))
    #expect(actions.contains("waveform_completed"))
    #expect(actions.contains("metrics_completed"))
}

@Test func missingAudioIsDiagnosedAndCanBeAnalyzedAgainAfterItReturns() async throws {
    let directory = try TestWorkspace.freshDirectory("review-retry")
    let logs = directory.appendingPathComponent("Logs")
    let logger = try DiagnosticLogger(directory: logs,
        configuration: .init(appVersion: "0.6.0", appBuild: "35"))
    let cache = try WaveformCache(directory: directory.appendingPathComponent("Cache"))
    let service = ReviewAnalysisService(cache: cache, diagnostics: logger)
    let url = directory.appendingPathComponent("Returned.wav")
    let artifact = TestWorkspace.artifact(for: url)
    await #expect(throws: (any Error).self) { try await service.waveform(for: artifact) }
    await #expect(throws: (any Error).self) { try await service.metrics(for: artifact) }
    try TestWorkspace.makeWAV(at: url, durationSeconds: 0.2)
    let waveform = try await service.waveform(for: artifact)
    #expect(waveform.isValid)
    _ = try await service.metrics(for: artifact)
    _ = try await service.waveform(for: artifact)
    let actions = try analysisLogActions(in: logs)
    #expect(actions.contains("waveform_failed"))
    #expect(actions.contains("metrics_failed"))
    #expect(actions.contains("waveform_cache_hit"))
}

@Test func inconsistentWaveformCacheIsRegeneratedAndChangedFileCannotBeCachedAsOldData() async throws {
    let directory = try TestWorkspace.freshDirectory("review-invalid-cache")
    let url = try TestWorkspace.makeWAV(at: directory.appendingPathComponent("Audio.wav"), durationSeconds: 0.2)
    let artifact = TestWorkspace.artifact(for: url)
    let cache = try WaveformCache(directory: directory.appendingPathComponent("Cache"))
    let service = ReviewAnalysisService(cache: cache, diagnostics: nil)
    var invalid = try await service.waveform(for: artifact)
    invalid.levels[0].channels[0].removeLast()
    #expect(!invalid.isValid)
    try await cache.save(invalid, for: artifact)
    let regenerated = try await service.waveform(for: artifact)
    #expect(regenerated.isValid)
    let fingerprint = try AudioQCAnalyzer.fileFingerprint(for: url)
    try TestWorkspace.makeWAV(at: url, durationSeconds: 0.3)
    await #expect(throws: QuickBounceError.self) {
        try await cache.save(regenerated, for: artifact, expectedFingerprint: fingerprint)
    }
    #expect(try await cache.load(for: artifact) == nil)
}

private func analysisLogActions(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
        .flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
                (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["action"] as? String
            }
        }
}
