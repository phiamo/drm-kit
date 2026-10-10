import Foundation

/// Host-supplied identity for offline licences.
///
/// `deviceId` is the stable per-install UUID (sent as `session=download:{deviceId}`).
/// `authorization` returns the current SSO access token and is read on every request.
public struct OfflineLicenseConfig {
    public let deviceId: String
    public let authorization: () -> String
    /// How the key identifier becomes the SPC content identifier (same meaning as for streaming).
    public let contentIdentifierForm: FairPlaySession.ContentIdentifierForm

    public init(
        deviceId: String,
        authorization: @escaping () -> String,
        contentIdentifierForm: FairPlaySession.ContentIdentifierForm = .keyUri
    ) {
        self.deviceId = deviceId
        self.authorization = authorization
        self.contentIdentifierForm = contentIdentifierForm
    }
}

/// Absolute per-download endpoints; `tokenUrl` is the asset's `/drm-token`. Persisted with the
/// download so one manager can renew downloads of different assets after a restart.
public struct OfflineEndpoints: Equatable, Codable {
    public let tokenUrl: String
    public let licenseUrl: String
    public let certificateUrl: String

    public init(tokenUrl: String, licenseUrl: String, certificateUrl: String) {
        self.tokenUrl = tokenUrl
        self.licenseUrl = licenseUrl
        self.certificateUrl = certificateUrl
    }
}

/// Offline `/drm-token` answer: the entitlement token and the server-side licence expiry.
struct OfflineToken {
    let token: String
    let licenseExpiresAt: Date
}

/// HTTP client for the offline wire format: `/drm-token?purpose=offline`, the FairPlay
/// certificate and Axinom AcquireLicense. No renewal credential is ever sent.
/// Never logs tokens, SPCs or licence bodies.
final class FairPlayOfflineLicenseClient {
    static let purposeOffline = "offline"
    static let sessionPrefix = "download:"
    static let reasonOfflineDeviceLimit = "offline_device_limit"

    private enum CallKind { case certificate, token, license }

    private let config: OfflineLicenseConfig
    private let urlSession: URLSession

    init(config: OfflineLicenseConfig, urlSession: URLSession = FairPlayLicenseClient.defaultURLSession()) {
        self.config = config
        self.urlSession = urlSession
    }

    func fetchCertificate(url: String) async throws -> Data {
        var request = URLRequest(url: try Self.parse(url))
        request.httpMethod = "GET"
        let body = try await execute(request, kind: .certificate)
        guard !body.isEmpty else { throw DrmPlaybackError.unknown }
        return body
    }

    /// Fresh offline token for `kidHex`; the bearer is read on every call. A response without a
    /// parseable `licenseExpiresAt` is `unknown`: the expiry cannot be read from the key.
    func fetchToken(tokenUrl: String, kidHex: String) async throws -> OfflineToken {
        guard var components = URLComponents(url: try Self.parse(tokenUrl), resolvingAgainstBaseURL: false) else {
            throw DrmPlaybackError.unknown
        }
        let replaced: Set<String> = ["kid", "session", "purpose"]
        var items = (components.queryItems ?? []).filter { !replaced.contains($0.name) }
        items.append(URLQueryItem(name: "kid", value: kidHex))
        items.append(URLQueryItem(name: "session", value: Self.sessionPrefix + config.deviceId))
        items.append(URLQueryItem(name: "purpose", value: Self.purposeOffline))
        components.queryItems = items
        guard let url = components.url else { throw DrmPlaybackError.unknown }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            FairPlayLicenseClient.bearer(config.authorization()),
            forHTTPHeaderField: FairPlayLicenseClient.headerAuthorization
        )
        let body = try await execute(request, kind: .token)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty,
              let expiry = json["licenseExpiresAt"] as? String,
              let expiresAt = Self.parseDate(expiry) else {
            throw DrmPlaybackError.unknown
        }
        return OfflineToken(token: token, licenseExpiresAt: expiresAt)
    }

    func acquireLicense(url: String, spc: Data, token: String) async throws -> Data {
        var request = URLRequest(url: try Self.parse(url))
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: FairPlayLicenseClient.headerAxinomMessage)
        let body = try await execute(request, kind: .license)
        guard let ckc = FairPlayLicenseClient.ckc(from: body) else { throw DrmPlaybackError.unknown }
        return ckc
    }

    static func parseDate(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private static func parse(_ value: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw DrmPlaybackError.unknown
        }
        return url
    }

    private func execute(_ request: URLRequest, kind: CallKind) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw DrmPlaybackError.network
        }
        guard let http = response as? HTTPURLResponse else { throw DrmPlaybackError.unknown }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHttpError(kind, status: http.statusCode, body: data)
        }
        return data
    }

    private static func mapHttpError(_ kind: CallKind, status: Int, body: Data) -> DrmPlaybackError {
        switch kind {
        case .token:
            switch status {
            case 403: return isDeviceLimit(body) ? .offlineDeviceLimit : .notEntitled
            case 401: return .expired
            case 429: return .rateLimited
            default: return .unknown
            }
        case .license:
            if status == 429 { return .rateLimited }
            guard status == 403 else { return .unknown }
            return isDeviceLimit(body) ? .offlineDeviceLimit : .notEntitled
        case .certificate:
            return .unknown
        }
    }

    private static func isDeviceLimit(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["error"] as? String == reasonOfflineDeviceLimit
    }
}
