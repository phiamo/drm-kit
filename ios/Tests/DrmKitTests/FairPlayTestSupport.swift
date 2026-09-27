import Foundation
@testable import DrmKit

/// URLProtocol stub: FIFO responses per URL path, records every request (with its body).
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        case transportError
    }

    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    private static var replies: [String: [Reply]] = [:]
    private static var recorded: [Recorded] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        replies = [:]
        recorded = []
    }

    static func enqueue(_ path: String, _ reply: Reply) {
        lock.lock()
        defer { lock.unlock() }
        replies[path, default: []].append(reply)
    }

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = request.httpBody ?? Self.readStream(request.httpBodyStream)
        Self.lock.lock()
        Self.recorded.append(Recorded(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        ))
        var reply: Reply = .http(599)
        if var queue = Self.replies[url.path], !queue.isEmpty {
            reply = queue.removeFirst()
            Self.replies[url.path] = queue
        }
        Self.lock.unlock()

        switch reply {
        case .transportError:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .http(status, headers, data):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class FakeKeyRequest: FairPlayKeyRequest {
    let keyIdentifier: String?
    var spc: Data
    var spcError: Error?
    private(set) var certificates: [Data] = []
    private(set) var contentIdentifiers: [Data] = []
    private(set) var ckc: Data?
    private(set) var error: Error?

    init(_ identifier: String?, spc: Data = Data("spc-bytes".utf8)) {
        self.keyIdentifier = identifier
        self.spc = spc
    }

    func makeStreamingContentKeyRequestData(certificate: Data, contentIdentifier: Data) async throws -> Data {
        certificates.append(certificate)
        contentIdentifiers.append(contentIdentifier)
        if let spcError { throw spcError }
        return spc
    }

    func processContentKeyResponse(ckc: Data) {
        self.ckc = ckc
    }

    func processContentKeyResponseError(_ error: Error) {
        self.error = error
    }

    var playbackError: DrmPlaybackError? { error as? DrmPlaybackError }
}

final class FakeScheduler: DrmTaskScheduler {
    final class Scheduled: DrmScheduledTask {
        let initialDelay: Int
        let period: Int
        let work: () async -> Void
        var cancelled = false

        init(initialDelay: Int, period: Int, work: @escaping () async -> Void) {
            self.initialDelay = initialDelay
            self.period = period
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private(set) var tasks: [Scheduled] = []
    private(set) var shutdownCalls = 0

    var initialDelays: [Int] { tasks.map(\.initialDelay) }
    var periods: [Int] { tasks.map(\.period) }

    func scheduleAtFixedRate(
        initialDelaySeconds: Int,
        periodSeconds: Int,
        _ work: @escaping () async -> Void
    ) -> DrmScheduledTask {
        let task = Scheduled(initialDelay: initialDelaySeconds, period: periodSeconds, work: work)
        tasks.append(task)
        return task
    }

    func shutdown() { shutdownCalls += 1 }

    /// Fires every live timer once and waits for its work.
    func runPending() async {
        for task in tasks where !task.cancelled {
            await task.work()
        }
    }
}
