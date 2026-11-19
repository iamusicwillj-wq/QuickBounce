import Foundation
import QuickBounceAudio
import QuickBounceDomain
import QuickBounceProTools

/// Analysis is derived data. A cache write failure must never hide a waveform
/// that was decoded successfully, or stop QC for the delivered audio file.
public actor ReviewAnalysisService {
    private let cache: WaveformCache?
    private let waveforms = WaveformAnalyzer()
    private let qc = AudioQCAnalyzer()
    private let diagnostics: DiagnosticLogger?

    public init(cache: WaveformCache?, diagnostics: DiagnosticLogger?) {
        self.cache = cache
        self.diagnostics = diagnostics
    }

    public func waveform(for artifact: AudioArtifact) async throws -> WaveformPyramid {
        let timer = DiagnosticTimer()
        await record("waveform_started", artifact: artifact, fields: [
            "format": artifact.kind.rawValue,
            "sample_rate": artifact.sampleRate.map(String.init(describing:)) ?? "unknown",
            "frame_count": artifact.frameCount.map(String.init) ?? "unknown"
        ])
        do {
            do {
                if let cached = try await cache?.load(for: artifact) {
                    await record("waveform_cache_hit", artifact: artifact, fields: ["elapsed_ms": timer.field])
                    return cached
                }
            } catch {
                await record("waveform_cache_read_failed", artifact: artifact, fields: ["error": error.localizedDescription])
            }
            await record("waveform_cache_miss", artifact: artifact)
            let fingerprint = try AudioQCAnalyzer.fileFingerprint(for: artifact.fileURL)
            let pyramid = try await waveforms.analyze(artifact: artifact)
            try Task.checkCancellation()
            guard fingerprint == (try AudioQCAnalyzer.fileFingerprint(for: artifact.fileURL)) else {
                throw QuickBounceError.artifactInvalid("The audio file changed during waveform analysis. Retry analysis.")
            }
            do { try await cache?.save(pyramid, for: artifact, expectedFingerprint: fingerprint) }
            catch {
                await record("waveform_cache_write_failed", artifact: artifact, fields: ["error": error.localizedDescription])
            }
            await record("waveform_completed", artifact: artifact, fields: [
                "elapsed_ms": timer.field,
                "channel_count": String(pyramid.levels.first?.channels.count ?? 0),
                "decoded_frames": String(pyramid.levels.first?.frameCount ?? 0),
                "block_sizes": pyramid.levels.map { String($0.blockSize) }.joined(separator: ","),
                "level_bins": pyramid.levels.map { String($0.channels.first?.count ?? 0) }.joined(separator: ",")
            ])
            return pyramid
        } catch {
            await record(error is CancellationError ? "waveform_cancelled" : "waveform_failed",
                artifact: artifact, fields: ["elapsed_ms": timer.field, "error": error.localizedDescription])
            throw error
        }
    }

    public func metrics(for artifact: AudioArtifact) async throws -> AudioAnalysisResult {
        let timer = DiagnosticTimer()
        await record("metrics_started", artifact: artifact)
        do {
            if let cached = artifact.analysis, try await qc.cachedResultIsCurrent(cached, for: artifact) {
                await record("metrics_cache_hit", artifact: artifact, fields: ["elapsed_ms": timer.field])
                return cached
            }
            let result = try await qc.analyze(artifact: artifact)
            try Task.checkCancellation()
            guard try await qc.cachedResultIsCurrent(result, for: artifact) else {
                throw QuickBounceError.artifactInvalid("The audio file changed during loudness analysis. Retry analysis.")
            }
            await record("metrics_completed", artifact: artifact, fields: ["elapsed_ms": timer.field])
            return result
        } catch {
            await record(error is CancellationError ? "metrics_cancelled" : "metrics_failed",
                artifact: artifact, fields: ["elapsed_ms": timer.field, "error": error.localizedDescription])
            throw error
        }
    }

    private func record(_ action: String, artifact: AudioArtifact, fields: [String: String] = [:]) async {
        var details = fields
        details["artifact_id"] = artifact.id.uuidString
        details["file_name"] = artifact.name
        await diagnostics?.record(category: "review_analysis", action: action, fields: details)
    }
}
