import Darwin
import Foundation

public enum QuickBounceError: Error, LocalizedError, Equatable, Sendable {
    case connection(String)
    case unsupportedVersion(String)
    case capabilityMissing(String)
    case sessionIdentityMismatch
    case trackMissing(String)
    case ambiguousTrackName(String)
    case stateVerificationFailed(String)
    case exportFailed(String)
    case exportCancelled
    case artifactMissing(String)
    case artifactInvalid(String)
    case restoreFailed(String)
    case saveFailed(String)
    case importFailed(String)
    case persistence(String)
    case invalidPlan(String)
    case permissionDenied(String)
    case insufficientDiskSpace(String)

    public static func diskSpaceFailure(for error: Error) -> QuickBounceError? {
        if let bounceError = error as? QuickBounceError, case .insufficientDiskSpace = bounceError {
            return bounceError
        }
        let original = error as NSError
        var causes = [original]
        while let cause = causes.popLast() {
            if (cause.domain == NSCocoaErrorDomain && cause.code == CocoaError.fileWriteOutOfSpace.rawValue)
                || (cause.domain == NSPOSIXErrorDomain && cause.code == Int(ENOSPC)) {
                let path = (original.userInfo[NSFilePathErrorKey] as? String)
                    ?? (cause.userInfo[NSFilePathErrorKey] as? String)
                let detail = path.map { "\($0): \(original.localizedDescription)" } ?? original.localizedDescription
                return .insufficientDiskSpace(detail)
            }
            causes.append(contentsOf: cause.underlyingErrors.map { $0 as NSError })
        }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .connection(let message): "Connection failed: \(message)"
        case .unsupportedVersion(let message): "Unsupported Pro Tools/PTSL version: \(message)"
        case .capabilityMissing(let message): "Required capability is unavailable: \(message)"
        case .sessionIdentityMismatch: "The active Pro Tools Session no longer matches this Bounce Plan."
        case .trackMissing(let name): "Track is missing: \(name)"
        case .ambiguousTrackName(let name): "Track name is ambiguous: \(name)"
        case .stateVerificationFailed(let message): "Track state verification failed: \(message)"
        case .exportFailed(let message): "Bounce failed: \(message)"
        case .exportCancelled: "Bounce was cancelled."
        case .artifactMissing(let path): "Expected bounced file was not found: \(path)"
        case .artifactInvalid(let message): "Bounced file is invalid: \(message)"
        case .restoreFailed(let message): "Session restoration failed: \(message)"
        case .saveFailed(let message): "Session save failed: \(message)"
        case .importFailed(let message): "Import After Bounce failed: \(message)"
        case .persistence(let message): "Persistence failed: \(message)"
        case .invalidPlan(let message): "Bounce Plan is invalid: \(message)"
        case .permissionDenied(let message): "Permission is required: \(message)"
        case .insufficientDiskSpace(let message): "Not enough disk space: \(message)"
        }
    }
}
