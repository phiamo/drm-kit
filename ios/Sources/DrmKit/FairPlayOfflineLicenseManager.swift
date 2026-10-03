import AVFoundation
import Foundation

/// Outcome of an offline licence operation: success, or the typed `error`.
public struct OfflineLicenseResult: Equatable {
    public let error: DrmPlaybackError?

    public var isSuccess: Bool { error == nil }

    public static let success = OfflineLicenseResult(error: nil)

    public static func failure(_ error: DrmPlaybackError) -> OfflineLicenseResult {
        OfflineLicenseResult(error: error)
    }
}

/// Offline FairPlay licences (one persistable key per download) for the host's download manager
/// (mirrors Android `OfflineLicenseManager`).
///
/// One instance serves all downloads; the token, licence and certificate URLs are given per
/// download in `acquire` and persisted. Operations are serialised. Never logs tokens, SPCs, CKCs,
/// keys or subtitle contents. FairPlay does not run on the simulator.
public final class FairPlayOfflineLicenseManager {
    /// Renewal is due when a day or less of the licence remains.
    public static let renewalThreshold: TimeInterval = 24 * 60 * 60

    /// Encrypted subtitles of the downloads; deleted together with their licence.
    public let subtitles: EncryptedSubtitleStore

    private struct Failure: Error {
        let error: DrmPlaybackError
        var tokenRefused = false
    }

    private let config: OfflineLicenseConfig
    private let store: OfflineLicenseStore
    private let client: FairPlayOfflineLicenseClient
    private let driverFactory: () -> FairPlayOfflineKeyDriver
    private let clock: () -> Date
    private let mutex = AsyncMutex()
    private let playbackLock = NSLock()
    private var playbackSession: AVOfflinePlaybackSession?

    /// Production manager. State lives in Application Support `drm-kit/` (excluded from backup,
    /// protected until first unlock); the subtitle key lives in the Keychain.
    public convenience init(config: OfflineLicenseConfig) throws {
        let root = try DrmKitFiles.defaultRoot()
        self.init(
            config: config,
            store: FileOfflineLicenseStore(dir: root.appendingPathComponent("offline-licenses", isDirectory: true)),
            subtitles: EncryptedSubtitleStore(root: root.appendingPathComponent("subtitles", isDirectory: true)),
            client: FairPlayOfflineLicenseClient(config: config),
            driverFactory: { AVOfflineKeyDriver() },
            clock: Date.init
        )
    }

    init(
        config: OfflineLicenseConfig,
        store: OfflineLicenseStore,
        subtitles: EncryptedSubtitleStore,
        client: FairPlayOfflineLicenseClient,
        driverFactory: @escaping () -> FairPlayOfflineKeyDriver,
        clock: @escaping () -> Date
    ) {
        self.config = config
        self.store = store
        self.subtitles = subtitles
        self.client = client
        self.driverFactory = driverFactory
        self.clock = clock
    }

    // MARK: Licence lifecycle

    /// Acquires an offline licence for the `skd://` `keyIdentifier` of `downloadId` and stores the
    /// persistable key. Existing state is untouched on failure.
    public func acquire(
        downloadId: String,
        keyIdentifier: String,
        endpoints: OfflineEndpoints
    ) async -> OfflineLicenseResult {
        await mutex.withLock {
            guard let kidHex = FairPlayKeyIds.parse(keyIdentifier)?.kidHex else { return .failure(.unknown) }
            let now = self.clock()
            let failure = await self.obtainKey(
                keyIdentifier: keyIdentifier,
                kidHex: kidHex,
                endpoints: endpoints
            ) { blob, expiresAt in
                try self.store.put(OfflineLicenseRecord(
                    downloadId: downloadId,
                    state: .active,
                    keyBlob: blob,
                    kidHex: kidHex,
                    keyIdentifier: keyIdentifier,
                    endpoints: endpoints,
                    savedAt: now,
                    expiresAt: expiresAt
                ))
            }
            return failure.map { .failure($0.error) } ?? .success
        }
    }

    /// True when the download is not ACTIVE, or `expiresAt` is a day or less away. Unknown ids: false.
    public func needsRenewal(downloadId: String) -> Bool {
        guard let record = store.get(downloadId) else { return false }
        guard record.state == .active, record.keyBlob != nil, let expiresAt = record.expiresAt else { return true }
        return expiresAt.timeIntervalSince(clock()) <= Self.renewalThreshold
    }

    /// Fetches a fresh offline token and a new persistable key that replaces the stored one. A
    /// refused token (403, incl. device limit) expires the download and deletes its key and
    /// subtitles. A lapsed SSO token (`expired`), network or other failures leave all state
    /// unchanged so the host can refresh and retry.
    public func renew(downloadId: String) async -> OfflineLicenseResult {
        await mutex.withLock {
            guard let record = self.store.get(downloadId) else { return .failure(.unknown) }
            guard record.state == .active, record.keyBlob != nil else { return .failure(.expired) }
            let now = self.clock()
            let failure = await self.obtainKey(
                keyIdentifier: record.keyIdentifier,
                kidHex: record.kidHex,
                endpoints: record.endpoints
            ) { blob, expiresAt in
                try self.store.put(OfflineLicenseRecord(
                    downloadId: downloadId,
                    state: .active,
                    keyBlob: blob,
                    kidHex: record.kidHex,
                    keyIdentifier: record.keyIdentifier,
                    endpoints: record.endpoints,
                    savedAt: now,
                    expiresAt: expiresAt
                ))
            }
            if let failure {
                if failure.tokenRefused { self.expire(record) }
                return .failure(failure.error)
            }
            return .success
        }
    }

    /// Forgets `downloadId`: always deletes the stored key, record and subtitles, then invalidates
    /// the persistable key best effort (a failure changes nothing).
    public func release(downloadId: String) async {
        await mutex.withLock {
            let record = self.store.get(downloadId)
            self.store.delete(downloadId)
            self.subtitles.deleteAll(downloadId: downloadId)
            guard let blob = record?.keyBlob else { return }
            let driver = self.driverFactory()
            await driver.invalidate(persistableKey: blob)
            driver.close()
        }
    }

    public func state(downloadId: String) -> OfflineLicenseState {
        store.get(downloadId)?.state ?? .none
    }

    /// Licence expiry (from the offline token's `licenseExpiresAt`), for the "expires in N days" copy.
    public func expiresAt(downloadId: String) -> Date? {
        store.get(downloadId)?.expiresAt
    }

    // MARK: Offline playback

    /// Registers `asset` so its key requests are answered from the stored key of an ACTIVE
    /// download with the same KID, with no network call. Call before the player item loads.
    public func addOfflinePlaybackRecipient(_ asset: AVURLAsset) {
        playback().add(asset)
    }

    public func removeOfflinePlaybackRecipient(_ asset: AVURLAsset) {
        playback().remove(asset)
    }

    /// Answers one key request from the stored keys; no stored key -> key error.
    func answerPlaybackKeyRequest(_ request: FairPlayOfflineKeyRequest) {
        guard let identifier = request.keyIdentifier, let kidHex = FairPlayKeyIds.parse(identifier)?.kidHex else {
            request.processContentKeyResponseError(DrmPlaybackError.unknown)
            return
        }
        let now = clock()
        let sameKid = store.all().filter { $0.kidHex == kidHex }
        let usable = sameKid
            .filter { record in
                guard record.state == .active, record.keyBlob != nil, let expiresAt = record.expiresAt else { return false }
                return expiresAt > now
            }
            .sorted { lhs, rhs in
                let lhsExact = lhs.keyIdentifier == identifier
                let rhsExact = rhs.keyIdentifier == identifier
                return lhsExact != rhsExact ? lhsExact : lhs.savedAt > rhs.savedAt
            }
        if let blob = usable.first?.keyBlob {
            request.processContentKeyResponse(key: blob)
        } else {
            request.processContentKeyResponseError(sameKid.isEmpty ? DrmPlaybackError.notEntitled : DrmPlaybackError.expired)
        }
    }

    private func playback() -> AVOfflinePlaybackSession {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        if let playbackSession { return playbackSession }
        let session = AVOfflinePlaybackSession { [weak self] request in
            self?.answerPlaybackKeyRequest(request)
        }
        playbackSession = session
        return session
    }

    // MARK: Key acquisition

    /// Certificate -> key request -> SPC -> offline token -> licence -> persistable key. `persist`
    /// stores the key before the request is completed with it. Returns nil on success; the request
    /// is failed on every error after it was obtained.
    private func obtainKey(
        keyIdentifier: String,
        kidHex: String,
        endpoints: OfflineEndpoints,
        persist: (Data, Date) throws -> Void
    ) async -> Failure? {
        guard let contentIdentifier = FairPlayKeyIds.contentIdentifier(
            keyIdentifier,
            form: config.contentIdentifierForm
        ) else {
            return Failure(error: .unknown)
        }
        let driver = driverFactory()
        defer { driver.close() }
        let certificate: Data
        do {
            certificate = try await client.fetchCertificate(url: endpoints.certificateUrl)
        } catch {
            return Failure(error: Self.typed(error))
        }
        let request: FairPlayOfflineKeyRequest
        do {
            request = try await driver.request(identifier: keyIdentifier)
        } catch {
            return Failure(error: Self.typed(error))
        }
        func fail(_ failure: Failure) -> Failure {
            request.processContentKeyResponseError(failure.error)
            return failure
        }
        let spc: Data
        do {
            spc = try await request.makeStreamingContentKeyRequestData(
                certificate: certificate,
                contentIdentifier: contentIdentifier
            )
        } catch {
            return fail(Failure(error: .unknown))
        }
        let token: OfflineToken
        do {
            token = try await client.fetchToken(tokenUrl: endpoints.tokenUrl, kidHex: kidHex)
        } catch {
            let typed = Self.typed(error)
            return fail(Failure(error: typed, tokenRefused: typed == .notEntitled || typed == .offlineDeviceLimit))
        }
        let ckc: Data
        do {
            ckc = try await client.acquireLicense(url: endpoints.licenseUrl, spc: spc, token: token.token)
        } catch {
            return fail(Failure(error: Self.typed(error)))
        }
        let blob: Data
        do {
            blob = try request.persistableKey(fromCKC: ckc)
        } catch {
            return fail(Failure(error: .unknown))
        }
        do {
            try persist(blob, token.licenseExpiresAt)
        } catch {
            return fail(Failure(error: .unknown))
        }
        request.processContentKeyResponse(key: blob)
        return nil
    }

    private func expire(_ record: OfflineLicenseRecord) {
        let expired = OfflineLicenseRecord(
            downloadId: record.downloadId,
            state: .expired,
            keyBlob: nil,
            kidHex: record.kidHex,
            keyIdentifier: record.keyIdentifier,
            endpoints: record.endpoints,
            savedAt: record.savedAt,
            expiresAt: record.expiresAt
        )
        if (try? store.put(expired)) == nil {
            store.delete(record.downloadId)
        }
        subtitles.deleteAll(downloadId: record.downloadId)
    }

    private static func typed(_ error: Error) -> DrmPlaybackError {
        (error as? DrmPlaybackError) ?? .unknown
    }
}

/// Minimal FIFO async mutex: serialises licence operations (acquire/renew/release).
final class AsyncMutex {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
