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
/// keys. FairPlay does not run on the simulator.
public final class FairPlayOfflineLicenseManager {
    /// Renewal is due when a day or less of the licence remains.
    public static let renewalThreshold: TimeInterval = 24 * 60 * 60

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
    private var attachedDownloadIds = Set<String>()
    private var attachedAssets = [ObjectIdentifier: String]()

    /// Production manager. State lives in Application Support `drm-kit/` (excluded from backup,
    /// protected until first unlock).
    public convenience init(config: OfflineLicenseConfig) throws {
        let root = try DrmKitFiles.defaultRoot()
        self.init(
            config: config,
            store: FileOfflineLicenseStore(dir: root.appendingPathComponent("offline-licenses", isDirectory: true)),
            client: FairPlayOfflineLicenseClient(config: config),
            driverFactory: { AVOfflineKeyDriver() },
            clock: Date.init
        )
    }

    init(
        config: OfflineLicenseConfig,
        store: OfflineLicenseStore,
        client: FairPlayOfflineLicenseClient,
        driverFactory: @escaping () -> FairPlayOfflineKeyDriver,
        clock: @escaping () -> Date
    ) {
        self.config = config
        self.store = store
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
    /// refused token (403, incl. device limit) expires the download and deletes its key. A lapsed
    /// SSO token (`expired`), network or other failures leave all state unchanged so the host can
    /// refresh and retry.
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

    /// Forgets `downloadId`: always deletes the stored key and record, then invalidates the
    /// persistable key best effort (a failure changes nothing).
    public func release(downloadId: String) async {
        await mutex.withLock {
            let record = self.store.get(downloadId)
            self.store.delete(downloadId)
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
    /// `process(identifier:)` starts the Apple persistable-key flow (`streaming request` →
    /// `respondByRequestingPersistableContentKeyRequest` → stored blob). A `.movpkg` does not
    /// always emit that request on its own.
    public func addOfflinePlaybackRecipient(_ asset: AVURLAsset, downloadId: String? = nil) {
        if let downloadId {
            registerAttachedDownloadId(downloadId)
            playbackLock.lock()
            attachedAssets[ObjectIdentifier(asset)] = downloadId
            playbackLock.unlock()
        }
        playback().add(asset)
        guard
            let downloadId,
            let record = store.get(downloadId),
            record.state == .active,
            record.keyBlob != nil
        else { return }
        NSLog("FairPlay offline preload downloadId=%@ id=%@", downloadId, record.keyIdentifier)
        playback().process(identifier: record.keyIdentifier)
    }

    func registerAttachedDownloadId(_ downloadId: String) {
        playbackLock.lock()
        attachedDownloadIds.insert(downloadId)
        playbackLock.unlock()
    }

    public func removeOfflinePlaybackRecipient(_ asset: AVURLAsset) {
        playbackLock.lock()
        if let downloadId = attachedAssets.removeValue(forKey: ObjectIdentifier(asset)),
           !attachedAssets.values.contains(downloadId) {
            attachedDownloadIds.remove(downloadId)
        }
        playbackLock.unlock()
        playback().remove(asset)
    }

    /// Answers one key request from the stored keys; no stored key -> key error.
    func answerPlaybackKeyRequest(_ request: FairPlayOfflineKeyRequest) {
        let identifier = request.keyIdentifier
        let now = clock()
        if let identifier, let kidHex = FairPlayKeyIds.parse(identifier)?.kidHex {
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
                NSLog("FairPlay offline answer id=%@ kid=%@ blob=%lu", identifier, kidHex, blob.count)
                request.processContentKeyResponse(key: blob)
                return
            }
            if let fallback = attachedActiveBlob(now: now) {
                NSLog("FairPlay offline answer fallback id=%@ kid=%@ downloadId=%@", identifier, kidHex, fallback.downloadId)
                request.processContentKeyResponse(key: fallback.blob)
                return
            }
            NSLog("FairPlay offline answer failed id=%@ kid=%@ sameKid=%lu", identifier, kidHex, sameKid.count)
            request.processContentKeyResponseError(sameKid.isEmpty ? DrmPlaybackError.notEntitled : DrmPlaybackError.expired)
            return
        }
        if let fallback = attachedActiveBlob(now: now) {
            NSLog("FairPlay offline answer fallback unparsed id=%@ downloadId=%@", identifier ?? "nil", fallback.downloadId)
            request.processContentKeyResponse(key: fallback.blob)
            return
        }
        request.processContentKeyResponseError(DrmPlaybackError.unknown)
    }

    private func attachedActiveBlob(now: Date) -> (downloadId: String, blob: Data)? {
        playbackLock.lock()
        let ids = attachedDownloadIds
        playbackLock.unlock()
        let records = ids.compactMap { store.get($0) }.filter { record in
            guard record.state == .active, record.keyBlob != nil, let expiresAt = record.expiresAt else { return false }
            return expiresAt > now
        }
        guard records.count == 1, let blob = records[0].keyBlob else { return nil }
        return (records[0].downloadId, blob)
    }

    func persistUpdatedPlaybackKey(_ key: Data, identifier: Any) {
        guard let raw = FairPlayKeyIds.string(from: identifier), let kidHex = FairPlayKeyIds.parse(raw)?.kidHex else {
            return
        }
        for record in store.all() where record.kidHex == kidHex && record.state == .active {
            let updated = OfflineLicenseRecord(
                downloadId: record.downloadId,
                state: record.state,
                keyBlob: key,
                kidHex: record.kidHex,
                keyIdentifier: record.keyIdentifier,
                endpoints: record.endpoints,
                savedAt: clock(),
                expiresAt: record.expiresAt
            )
            try? store.put(updated)
        }
    }

    private func playback() -> AVOfflinePlaybackSession {
        playbackLock.lock()
        defer { playbackLock.unlock() }
        if let playbackSession { return playbackSession }
        let session = AVOfflinePlaybackSession(
            answer: { [weak self] request in
                self?.answerPlaybackKeyRequest(request)
            },
            onUpdatedKey: { [weak self] key, identifier in
                self?.persistUpdatedPlaybackKey(key, identifier: identifier)
            }
        )
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
