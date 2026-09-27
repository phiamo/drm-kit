import Foundation

/// Client stream-limit policy from the playback descriptor / client-config (mirrors Android `StreamLimit`).
/// Cadence comes from the interval fields; callers must not hardcode 300.
public struct StreamLimit: Equatable {
    public static let modeNone = "none"
    public static let modeAxinomCsl = "axinom_csl"
    public static let modeLongLicense = "long_license"
    public static let modeAppHeartbeat = "app_heartbeat"

    public let mode: String
    public let renewalIntervalSeconds: Int
    public let heartbeatIntervalSeconds: Int

    public init(mode: String, renewalIntervalSeconds: Int, heartbeatIntervalSeconds: Int) {
        self.mode = mode
        self.renewalIntervalSeconds = renewalIntervalSeconds
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
    }
}
