import Foundation

/// Typed DRM playback errors. Names match Android `DrmPlaybackError` and app `drm-playback-messages.ts`.
public enum DrmPlaybackError: String, Error, Equatable, CaseIterable {
    case blockedByStreamLimit
    case notEntitled
    case expired
    case network
    case unknown

    /// Terminal errors fire once, then the session releases itself. Never auto-retry them.
    public var isTerminal: Bool {
        switch self {
        case .blockedByStreamLimit, .notEntitled, .expired:
            return true
        case .network, .unknown:
            return false
        }
    }
}
