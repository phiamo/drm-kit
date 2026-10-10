import Foundation

/// Typed DRM playback errors. Names match Android `DrmPlaybackError` and app `drm-playback-messages.ts`.
public enum DrmPlaybackError: String, Error, Equatable, CaseIterable {
    case blockedByStreamLimit
    case notEntitled
    /// Offline licences only: the user already holds offline licences on the maximum number of devices.
    case offlineDeviceLimit
    case expired
    case network
    case rateLimited
    case unknown

    /// Terminal errors fire once, then the session releases itself. Never auto-retry them.
    public var isTerminal: Bool {
        switch self {
        case .blockedByStreamLimit, .notEntitled, .offlineDeviceLimit, .expired, .rateLimited:
            return true
        case .network, .unknown:
            return false
        }
    }
}
