import AVFoundation
import Foundation

/// One FairPlay key request, abstracted from `AVContentKeyRequest` so tests can drive the flow.
protocol FairPlayKeyRequest: AnyObject {
    /// The `EXT-X-KEY` URI (`skd://…`) of the request.
    var keyIdentifier: String? { get }
    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data
    func processContentKeyResponse(ckc: Data)
    func processContentKeyResponseError(_ error: Error)
}

/// FairPlay streaming session for `AVPlayer` (mirrors Android `WidevineSession`).
///
/// On every `AVContentKeySession` key request (initial or renewing) it fetches the application
/// certificate once per session, builds the SPC, fetches a fresh token from `/drm-token`
/// (KID from the request's `skd://` identifier), POSTs the SPC to the FairPlay license URL with
/// `X-AxDRM-Message` and hands the CKC back to AVFoundation. `start()` runs the stream-limit timers:
/// `axinom_csl` / `long_license` renew via `renewExpiringResponseData` (first at 70% of the
/// interval), `app_heartbeat` POSTs the heartbeat, `none` schedules nothing.
///
/// Terminal errors (`blockedByStreamLimit`, `notEntitled`, `expired`) reach `onError` once, then the
/// session releases itself. `onError` is called on an arbitrary queue.
public final class FairPlaySession: NSObject {
    /// How the key request identifier becomes the SPC content identifier (Axinom reads the key URI
    /// from it). The Story 58.2 pilot decides which one ferrix needs.
    public enum ContentIdentifierForm: String, CaseIterable {
        /// The manifest's `EXT-X-KEY` URI unchanged (e.g. `skd://<kid hex>:<iv hex>`).
        case keyUri
        /// `skd://<KID as GUID>:<IV as 32 hex>`, Axinom's documented form.
        case axinomGuid
    }

    /// Host-built playback endpoints and credentials (as Android `WidevineSession.Config`, plus the
    /// certificate URL). All URLs must be absolute; drm-kit does not invent `/api/v2`.
    /// `authorization` returns the current SSO access token and is read on every request.
    public struct Config {
        public let tokenUrl: String
        public let licenseUrl: String
        public let certificateUrl: String
        public let heartbeatUrl: String
        public let playbackSessionId: String
        public let renewalCredential: String
        public let authorization: () -> String
        public let streamLimit: StreamLimit
        public let contentIdentifierForm: ContentIdentifierForm

        public init(
            tokenUrl: String,
            licenseUrl: String,
            certificateUrl: String,
            heartbeatUrl: String,
            playbackSessionId: String,
            renewalCredential: String,
            authorization: @escaping () -> String,
            streamLimit: StreamLimit,
            contentIdentifierForm: ContentIdentifierForm = .keyUri
        ) {
            self.tokenUrl = tokenUrl
            self.licenseUrl = licenseUrl
            self.certificateUrl = certificateUrl
            self.heartbeatUrl = heartbeatUrl
            self.playbackSessionId = playbackSessionId
            self.renewalCredential = renewalCredential
            self.authorization = authorization
            self.streamLimit = streamLimit
            self.contentIdentifierForm = contentIdentifierForm
        }
    }

    public let config: Config
    public let client: FairPlayLicenseClient
    private let scheduler: DrmTaskScheduler
    private let onError: (DrmPlaybackError) -> Void
    private let delegateQueue = DispatchQueue(label: "org.dwbn.drmkit.fairplay.keys")

    private let lock = NSLock()
    private var released = false
    private var terminalError: DrmPlaybackError?
    private var certificateTask: Task<Data, Error>?
    private var scheduled: [DrmScheduledTask] = []
    /// Last answered request per key identifier; renewals renew these.
    private var answered: [String: FairPlayKeyRequest] = [:]
    private var inFlight: Set<String> = []
    private var identifiers: [String] = []
    private var keySession: AVContentKeySession?

    /// Test seam: how a renewal is triggered. Default: `renewExpiringResponseData(for:)`.
    var renewer: ((FairPlayKeyRequest) -> Void)?

    public init(
        config: Config,
        client: FairPlayLicenseClient? = nil,
        scheduler: DrmTaskScheduler = DispatchTaskScheduler(),
        onError: @escaping (DrmPlaybackError) -> Void
    ) {
        self.config = config
        self.client = client ?? FairPlayLicenseClient(config: config)
        self.scheduler = scheduler
        self.onError = onError
        super.init()
    }

    /// Distinct key identifiers (`EXT-X-KEY` URIs) seen so far. Not secret: KID and IV are in the playlist.
    public var keyIdentifiers: [String] {
        withLock { identifiers }
    }

    public var isReleased: Bool {
        withLock { released }
    }

    /// The FairPlay `AVContentKeySession`, created on first use with this object as delegate.
    public var contentKeySession: AVContentKeySession {
        withLock {
            if let keySession { return keySession }
            let session = AVContentKeySession(keySystem: .fairPlayStreaming)
            session.setDelegate(self, queue: delegateQueue)
            keySession = session
            return session
        }
    }

    /// Routes the asset's FairPlay key requests through this session. Call before playback.
    public func addContentKeyRecipient(_ asset: AVURLAsset) {
        contentKeySession.addContentKeyRecipient(asset)
    }

    /// Starts the stream-limit timers. The host calls this when playback starts.
    /// `none` schedules nothing; key requests still fetch a token.
    public func start() {
        lock.lock()
        guard !released, scheduled.isEmpty else {
            lock.unlock()
            return
        }
        let limit = config.streamLimit
        var unknownMode = false
        switch limit.mode {
        case StreamLimit.modeNone:
            break
        case StreamLimit.modeAxinomCsl, StreamLimit.modeLongLicense:
            let period = limit.renewalIntervalSeconds
            if period > 0 {
                scheduled.append(scheduler.scheduleAtFixedRate(
                    initialDelaySeconds: Self.firstRenewalDelaySeconds(period),
                    periodSeconds: period
                ) { [weak self] in
                    self?.renewOnTimer()
                })
            }
        case StreamLimit.modeAppHeartbeat:
            let period = limit.heartbeatIntervalSeconds
            if period > 0 {
                scheduled.append(scheduler.scheduleAtFixedRate(
                    initialDelaySeconds: period,
                    periodSeconds: period
                ) { [weak self] in
                    await self?.heartbeatOnTimer()
                })
            }
        default:
            unknownMode = true
        }
        lock.unlock()
        if unknownMode {
            report(.unknown)
        }
    }

    /// Stops timers and refuses further key requests. Idempotent. Does not touch the player.
    public func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        let tasks = scheduled
        scheduled.removeAll()
        answered.removeAll()
        certificateTask?.cancel()
        certificateTask = nil
        lock.unlock()
        tasks.forEach { $0.cancel() }
        scheduler.shutdown()
    }

    // MARK: - Key requests

    func handle(_ request: FairPlayKeyRequest) async {
        let blocked: (terminal: DrmPlaybackError?, released: Bool) = withLock { (terminalError, released) }
        if let terminal = blocked.terminal {
            request.processContentKeyResponseError(terminal)
            return
        }
        if blocked.released {
            onError(.unknown)
            request.processContentKeyResponseError(DrmPlaybackError.unknown)
            return
        }
        guard let identifier = request.keyIdentifier,
              let keyUri = FairPlayKeyIds.parse(identifier),
              let contentIdentifier = FairPlayKeyIds.contentIdentifier(identifier, form: config.contentIdentifierForm) else {
            fail(request, .unknown)
            return
        }
        withLock {
            inFlight.insert(identifier)
            if !identifiers.contains(identifier) {
                identifiers.append(identifier)
            }
        }
        defer {
            withLock { _ = inFlight.remove(identifier) }
        }
        do {
            let certificate = try await self.certificate()
            let spc: Data
            do {
                spc = try await request.makeStreamingContentKeyRequestData(
                    certificate: certificate,
                    contentIdentifier: contentIdentifier
                )
            } catch {
                throw DrmPlaybackError.unknown
            }
            let token = try await client.fetchToken(kidHex: keyUri.kidHex)
            let ckc = try await client.acquireLicense(spc: spc, token: token)
            let accepted: Bool = withLock {
                guard !released else { return false }
                answered[identifier] = request
                return true
            }
            guard accepted else {
                request.processContentKeyResponseError(DrmPlaybackError.unknown)
                return
            }
            request.processContentKeyResponse(ckc: ckc)
        } catch {
            fail(request, (error as? DrmPlaybackError) ?? .unknown)
        }
    }

    private func fail(_ request: FairPlayKeyRequest, _ error: DrmPlaybackError) {
        request.processContentKeyResponseError(error)
        report(error)
    }

    private func certificate() async throws -> Data {
        let task: Task<Data, Error> = withLock {
            if let certificateTask { return certificateTask }
            let client = self.client
            let task = Task { try await client.fetchCertificate() }
            certificateTask = task
            return task
        }
        do {
            return try await task.value
        } catch {
            withLock {
                if certificateTask == task {
                    certificateTask = nil
                }
            }
            throw (error as? DrmPlaybackError) ?? DrmPlaybackError.network
        }
    }

    // MARK: - Timers

    func renewOnTimer() {
        let requests: [FairPlayKeyRequest] = withLock {
            guard !released else { return [] }
            return answered.filter { !inFlight.contains($0.key) }.map(\.value)
        }
        for request in requests {
            if let renewer {
                renewer(request)
            } else if let adapter = request as? AVKeyRequestAdapter {
                contentKeySession.renewExpiringResponseData(for: adapter.request)
            }
        }
    }

    func heartbeatOnTimer() async {
        guard !isReleased else { return }
        do {
            try await client.heartbeat()
        } catch {
            report((error as? DrmPlaybackError) ?? .unknown)
        }
    }

    func report(_ error: DrmPlaybackError) {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        if error.isTerminal {
            guard terminalError == nil else {
                lock.unlock()
                return
            }
            terminalError = error
            lock.unlock()
            onError(error)
            release()
            return
        }
        lock.unlock()
        onError(error)
    }

    /// First CSL / long-license renewal before the Axinom TTL (as Android): 300 s → 210 s,
    /// never later than the period, never below 1 s.
    static func firstRenewalDelaySeconds(_ periodSeconds: Int) -> Int {
        if periodSeconds <= 1 {
            return max(periodSeconds, 1)
        }
        return max(periodSeconds * 7 / 10, 1)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

extension FairPlaySession: AVContentKeySessionDelegate {
    public func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        let adapter = AVKeyRequestAdapter(keyRequest)
        Task { await self.handle(adapter) }
    }

    public func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        let adapter = AVKeyRequestAdapter(keyRequest)
        Task { await self.handle(adapter) }
    }

    public func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        false
    }
}

final class AVKeyRequestAdapter: FairPlayKeyRequest {
    let request: AVContentKeyRequest

    init(_ request: AVContentKeyRequest) {
        self.request = request
    }

    var keyIdentifier: String? {
        if let string = request.identifier as? String {
            return string
        }
        if let url = request.identifier as? URL {
            return url.absoluteString
        }
        return nil
    }

    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            request.makeStreamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: contentIdentifier,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? DrmPlaybackError.unknown)
                }
            }
        }
    }

    func processContentKeyResponse(ckc: Data) {
        request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
    }

    func processContentKeyResponseError(_ error: Error) {
        request.processContentKeyResponseError(error)
    }
}
