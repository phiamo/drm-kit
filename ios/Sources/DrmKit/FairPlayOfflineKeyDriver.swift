import AVFoundation
import Foundation

/// One persistable FairPlay key request, abstracted from `AVPersistableContentKeyRequest` so
/// tests can drive the flow. Offline playback requests use only the identifier and the response.
protocol FairPlayOfflineKeyRequest: AnyObject {
    /// The `EXT-X-KEY` URI (`skd://…`) of the request.
    var keyIdentifier: String? { get }
    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data
    /// Turns the CKC into the persistable key blob that is stored per download.
    func persistableKey(fromCKC ckc: Data) throws -> Data
    /// Completes the request with a persistable key (also used to answer offline playback).
    func processContentKeyResponse(key: Data)
    func processContentKeyResponseError(_ error: Error)
}

/// Obtains persistable key requests from `AVContentKeySession`. One driver serves one operation.
protocol FairPlayOfflineKeyDriver: AnyObject {
    /// Triggers a key request for `identifier` (no asset needed) and returns its persistable form.
    func request(identifier: String) async throws -> FairPlayOfflineKeyRequest
    /// Best-effort local invalidation of a persistable key; never throws.
    func invalidate(persistableKey: Data) async
    func close()
}

/// Resumes a continuation exactly once (first caller wins), e.g. for delegate callback vs. timeout.
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class AVOfflineKeyRequestAdapter: FairPlayOfflineKeyRequest {
    private let base: AVKeyRequestAdapter

    init(_ request: AVContentKeyRequest) {
        base = AVKeyRequestAdapter(request)
    }

    var keyIdentifier: String? { base.keyIdentifier }

    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data {
        try await base.makeStreamingContentKeyRequestData(certificate: certificate, contentIdentifier: contentIdentifier)
    }

    func persistableKey(fromCKC ckc: Data) throws -> Data {
        guard let persistable = base.request as? AVPersistableContentKeyRequest else {
            throw DrmPlaybackError.unknown
        }
        return try persistable.persistableContentKey(fromKeyVendorResponse: ckc, options: nil)
    }

    func processContentKeyResponse(key: Data) {
        base.processContentKeyResponse(ckc: key)
    }

    func processContentKeyResponseError(_ error: Error) {
        base.processContentKeyResponseError(error)
    }
}

/// `AVContentKeySession` driver: `processContentKeyRequest(withIdentifier:)` -> the delegate gets
/// a plain request, which is answered with `respondByRequestingPersistableContentKeyRequest`,
/// which yields the persistable request. FairPlay never runs on the simulator: device-verified.
final class AVOfflineKeyDriver: NSObject, FairPlayOfflineKeyDriver, AVContentKeySessionDelegate {
    static let requestTimeoutSeconds: Double = 30
    static let invalidateTimeoutSeconds: Double = 5

    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let queue = DispatchQueue(label: "org.dwbn.drmkit.fairplay.offline-keys")
    private let lock = NSLock()
    private var pending: OneShot<FairPlayOfflineKeyRequest>?

    override init() {
        super.init()
        session.setDelegate(self, queue: queue)
    }

    func request(identifier: String) async throws -> FairPlayOfflineKeyRequest {
        try await withCheckedThrowingContinuation { continuation in
            let shot = OneShot(continuation)
            lock.lock()
            pending = shot
            lock.unlock()
            queue.asyncAfter(deadline: .now() + Self.requestTimeoutSeconds) {
                shot.finish(.failure(DrmPlaybackError.unknown))
            }
            session.processContentKeyRequest(withIdentifier: identifier, initializationData: nil, options: nil)
        }
    }

    func invalidate(persistableKey: Data) async {
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shot = OneShot(continuation)
            queue.asyncAfter(deadline: .now() + Self.invalidateTimeoutSeconds) {
                shot.finish(.success(()))
            }
            session.invalidatePersistableContentKey(persistableKey, options: nil) { _, _ in
                shot.finish(.success(()))
            }
        }
    }

    func close() {
        session.expire()
    }

    private var currentPending: OneShot<FairPlayOfflineKeyRequest>? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    // MARK: AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        do {
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch {
            currentPending?.finish(.failure(DrmPlaybackError.unknown))
        }
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        currentPending?.finish(.success(AVOfflineKeyRequestAdapter(keyRequest)))
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError err: Error
    ) {
        currentPending?.finish(.failure(DrmPlaybackError.unknown))
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        false
    }
}

/// Manager-owned key session for offline playback: answers key requests of registered assets via
/// `answer`, with no network call.
final class AVOfflinePlaybackSession: NSObject, AVContentKeySessionDelegate {
    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let queue = DispatchQueue(label: "org.dwbn.drmkit.fairplay.offline-playback")
    private let answer: (FairPlayOfflineKeyRequest) -> Void

    init(answer: @escaping (FairPlayOfflineKeyRequest) -> Void) {
        self.answer = answer
        super.init()
        session.setDelegate(self, queue: queue)
    }

    func add(_ asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
    }

    func remove(_ asset: AVURLAsset) {
        session.removeContentKeyRecipient(asset)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        answer(AVOfflineKeyRequestAdapter(keyRequest))
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        answer(AVOfflineKeyRequestAdapter(keyRequest))
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        false
    }
}
