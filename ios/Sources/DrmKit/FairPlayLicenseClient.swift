import Foundation

/// HTTP client for the FairPlay application certificate, `/drm-token`, Axinom FairPlay
/// AcquireLicense and the playback-session heartbeat (mirrors Android `WidevineLicenseClient`).
/// Never logs tokens, JWTs, entitlement messages, SPCs or license bodies.
public final class FairPlayLicenseClient {
    public static let purposeStream = "stream"
    public static let headerAuthorization = "Authorization"
    public static let headerRenewalCredential = "X-Renewal-Credential"
    public static let headerAxinomMessage = "X-AxDRM-Message"
    public static let headerAxinomErrorCode = "X-AxDrm-ErrorCode"

    /// Requests sent so far, per kind (pilot: license requests per playback). Contains no secrets.
    public struct RequestCounts: Equatable {
        public var certificate = 0
        public var token = 0
        public var license = 0
        public var heartbeat = 0

        public init(certificate: Int = 0, token: Int = 0, license: Int = 0, heartbeat: Int = 0) {
            self.certificate = certificate
            self.token = token
            self.license = license
            self.heartbeat = heartbeat
        }
    }

    private enum CallKind { case certificate, token, license, heartbeat }

    private let config: FairPlaySession.Config
    private let urlSession: URLSession
    private let lock = NSLock()
    private var counts = RequestCounts()

    public init(config: FairPlaySession.Config, urlSession: URLSession = FairPlayLicenseClient.defaultURLSession()) {
        self.config = config
        self.urlSession = urlSession
    }

    public var requestCounts: RequestCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    public static func defaultURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    /// DER application certificate from the descriptor's `fairplayCertificateUrl` (public, no auth).
    public func fetchCertificate() async throws -> Data {
        NSLog("[DrmKit][diag] config.certificateUrl = '%@' (isEmpty: %@), config.licenseUrl = '%@', config.tokenUrl = '%@'",
              config.certificateUrl, config.certificateUrl.isEmpty ? "true" : "false",
              config.licenseUrl, config.tokenUrl)
        var request = URLRequest(url: try url(config.certificateUrl))
        request.httpMethod = "GET"
        let body = try await execute(request, kind: .certificate)
        guard !body.isEmpty else { throw DrmPlaybackError.unknown }
        return body
    }

    /// Fresh Axinom entitlement token for [kidHex]; the bearer is read on every call.
    public func fetchToken(kidHex: String) async throws -> String {
        guard var components = URLComponents(url: try url(config.tokenUrl), resolvingAgainstBaseURL: false) else {
            throw DrmPlaybackError.unknown
        }
        let replaced: Set<String> = ["kid", "session", "purpose"]
        var items = (components.queryItems ?? []).filter { !replaced.contains($0.name) }
        items.append(URLQueryItem(name: "kid", value: kidHex))
        items.append(URLQueryItem(name: "session", value: config.playbackSessionId))
        items.append(URLQueryItem(name: "purpose", value: Self.purposeStream))
        components.queryItems = items
        guard let tokenUrl = components.url else { throw DrmPlaybackError.unknown }
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "GET"
        request.setValue(Self.bearer(config.authorization()), forHTTPHeaderField: Self.headerAuthorization)
        request.setValue(config.renewalCredential, forHTTPHeaderField: Self.headerRenewalCredential)
        let body = try await execute(request, kind: .token)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw DrmPlaybackError.unknown
        }
        return token
    }

    /// POSTs the SPC with the token as `X-AxDRM-Message`; returns the CKC.
    public func acquireLicense(spc: Data, token: String) async throws -> Data {
        var request = URLRequest(url: try url(config.licenseUrl))
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: Self.headerAxinomMessage)
        let body = try await execute(request, kind: .license)
        guard let ckc = Self.ckc(from: body) else { throw DrmPlaybackError.unknown }
        return ckc
    }

    public func heartbeat() async throws {
        var request = URLRequest(url: try url(config.heartbeatUrl))
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue(Self.bearer(config.authorization()), forHTTPHeaderField: Self.headerAuthorization)
        request.setValue(config.renewalCredential, forHTTPHeaderField: Self.headerRenewalCredential)
        _ = try await execute(request, kind: .heartbeat)
    }

    static func bearer(_ accessToken: String) -> String {
        accessToken.hasPrefix("Bearer ") ? accessToken : "Bearer \(accessToken)"
    }

    /// Raw CKC; tolerates the legacy `<ckc>base64</ckc>` wrapping some FairPlay servers use.
    static func ckc(from body: Data) -> Data? {
        guard !body.isEmpty else { return nil }
        if let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("<ckc>"), text.hasSuffix("</ckc>") {
            let inner = text.dropFirst("<ckc>".count).dropLast("</ckc>".count)
            guard let decoded = Data(base64Encoded: String(inner)), !decoded.isEmpty else { return nil }
            return decoded
        }
        return body
    }

    private func url(_ value: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw DrmPlaybackError.unknown
        }
        return url
    }

    private func execute(_ request: URLRequest, kind: CallKind) async throws -> Data {
        count(kind)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw DrmPlaybackError.network
        }
        guard let http = response as? HTTPURLResponse else { throw DrmPlaybackError.unknown }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHttpError(
                kind,
                status: http.statusCode,
                axinomErrorCode: http.value(forHTTPHeaderField: Self.headerAxinomErrorCode)
            )
        }
        return data
    }

    private func count(_ kind: CallKind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .certificate: counts.certificate += 1
        case .token: counts.token += 1
        case .license: counts.license += 1
        case .heartbeat: counts.heartbeat += 1
        }
    }

    private static func mapHttpError(_ kind: CallKind, status: Int, axinomErrorCode: String?) -> DrmPlaybackError {
        switch kind {
        case .token, .heartbeat:
            switch status {
            case 409: return .blockedByStreamLimit
            case 403: return .notEntitled
            case 401: return .expired
            default: return .unknown
            }
        case .license:
            if status == 403, axinomErrorCode?.trimmingCharacters(in: .whitespaces) == "1" {
                return .blockedByStreamLimit
            }
            return .unknown
        case .certificate:
            return .unknown
        }
    }
}
