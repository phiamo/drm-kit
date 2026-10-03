import CryptoKit
import Foundation
@testable import DrmKit

final class FakeOfflineKeyRequest: FairPlayOfflineKeyRequest {
    let keyIdentifier: String?
    var spc: Data
    var spcError: Error?
    var persistableError: Error?
    private(set) var certificates: [Data] = []
    private(set) var contentIdentifiers: [Data] = []
    private(set) var ckcs: [Data] = []
    private(set) var responseKey: Data?
    private(set) var error: Error?

    init(_ identifier: String?, spc: Data = Data("spc-without-kid".utf8)) {
        keyIdentifier = identifier
        self.spc = spc
    }

    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data {
        certificates.append(certificate)
        contentIdentifiers.append(contentIdentifier)
        if let spcError { throw spcError }
        return spc
    }

    func persistableKey(fromCKC ckc: Data) throws -> Data {
        ckcs.append(ckc)
        if let persistableError { throw persistableError }
        return Data("persistable-".utf8) + ckc
    }

    func processContentKeyResponse(key: Data) { responseKey = key }
    func processContentKeyResponseError(_ error: Error) { self.error = error }
    var playbackError: DrmPlaybackError? { error as? DrmPlaybackError }
}

/// Hands out one prepared request per `request(identifier:)` call.
final class FakeOfflineKeyDriver: FairPlayOfflineKeyDriver {
    var requestError: Error?
    /// When set, `request(identifier:)` suspends until `openGate()` is called.
    var gated = false
    private let gateLock = NSLock()
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [String] = []
    private(set) var invalidated: [Data] = []
    private(set) var closeCalls = 0
    private(set) var issued: [FakeOfflineKeyRequest] = []

    func request(identifier: String) async throws -> FairPlayOfflineKeyRequest {
        requested.append(identifier)
        if gated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gateLock.lock()
                gateWaiters.append(continuation)
                gateLock.unlock()
            }
        }
        if let requestError { throw requestError }
        let request = FakeOfflineKeyRequest(identifier)
        issued.append(request)
        return request
    }

    var waitingAtGate: Int {
        gateLock.lock()
        defer { gateLock.unlock() }
        return gateWaiters.count
    }

    func openGate() {
        gateLock.lock()
        let waiters = gateWaiters
        gateWaiters = []
        gated = false
        gateLock.unlock()
        waiters.forEach { $0.resume() }
    }

    func invalidate(persistableKey: Data) async { invalidated.append(persistableKey) }
    func close() { closeCalls += 1 }
}

final class InMemorySubtitleKeyProvider: SubtitleKeyProvider {
    private let symmetricKey: SymmetricKey
    init(_ key: SymmetricKey = SymmetricKey(size: .bits256)) { symmetricKey = key }
    func key() throws -> SymmetricKey { symmetricKey }
}
