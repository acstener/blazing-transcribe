import Foundation
import FluidAudio

/// Turns speech-model download / load errors into plain copy for people,
/// and classifies them for retry and analytics. Never mentions vendor names.
enum ModelLoadErrorCopy {
    enum Kind: String, Equatable {
        case network
        case serverBusy
        case diskFull
        case load
    }

    static func kind(of error: Error) -> Kind {
        if let hfError = error as? DownloadUtils.HuggingFaceDownloadError {
            switch hfError {
            case .rateLimited:
                return .serverBusy
            case .downloadFailed(_, let underlying):
                return isDiskFull(underlying) ? .diskFull : .network
            case .invalidResponse:
                return .network
            case .modelNotFound:
                return .load
            }
        }
        if let asrError = error as? AsrModelsError, case .downloadFailed = asrError {
            return .network
        }
        if isDiskFull(error) {
            return .diskFull
        }
        if error is URLError {
            return .network
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingKind = kind(of: underlying)
            if underlyingKind != .load { return underlyingKind }
        }
        return .load
    }

    /// Network-shaped failures are worth one automatic retry: the partial cache is kept,
    /// so a retry resumes from the files already downloaded.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        switch kind(of: error) {
        case .network, .serverBusy: return true
        case .diskFull, .load: return false
        }
    }

    static func message(for error: Error) -> String {
        message(for: kind(of: error))
    }

    static func message(for kind: Kind) -> String {
        switch kind {
        case .network:
            return "Couldn't download the speech model. Check your internet connection and try again."
        case .serverBusy:
            return "The speech model download server is busy. Try again in a few minutes."
        case .diskFull:
            return "Not enough disk space for the speech model. Free up about 1 GB and try again."
        case .load:
            return "Couldn't load the speech model. Try again, or restart Blazing."
        }
    }

    static let retryingMessage = "Couldn't download the speech model. Retrying automatically…"

    private static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error, underlying as NSError !== nsError {
            return isDiskFull(underlying)
        }
        return false
    }
}
