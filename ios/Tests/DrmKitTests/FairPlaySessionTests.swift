import XCTest
@testable import DrmKit

final class FairPlaySessionTests: XCTestCase {
    private static let kid = "00112233445566778899aabbccddeeff"
    private static let iv = "ffeeddccbbaa99887766554433221100"
    private static let skd = "skd://\(kid):\(iv)"
    private static let certificate = Data("der-certificate".utf8)

    private var errors: [DrmPlaybackError] = []
    private let errorLock = NSLock()

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        errors = []
    }

    // MARK: Key request

    func testKeyRequestFetchesCertificateOnceThenTokenAndLicensePerRequest() async {
        enqueueCertificate()
        enqueueToken("token-one")
        enqueueLicense("ckc-one")
        enqueueToken("token-two")
        enqueueLicense("ckc-two")
        let session = makeSession(.none)

        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        let second = FakeKeyRequest(Self.skd)
        await session.handle(second)

        XCTAssertEqual(Data("ckc-one".utf8), first.ckc)
        XCTAssertEqual(Data("ckc-two".utf8), second.ckc)
        XCTAssertEqual([Self.certificate], first.certificates)
        XCTAssertEqual([Self.certificate], second.certificates)
        XCTAssertEqual([Data(Self.skd.utf8)], first.contentIdentifiers)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(["/cert.cer", "/drm-token", "/AcquireLicense", "/drm-token", "/AcquireLicense"], requests.map(\.url.path))
        XCTAssertEqual("GET", requests[0].method)
        XCTAssertNil(requests[0].header("Authorization"))
        assertTokenRequest(requests[1])
        assertLicenseRequest(requests[2], token: "token-one")
        assertTokenRequest(requests[3])
        assertLicenseRequest(requests[4], token: "token-two")
        XCTAssertEqual(
            FairPlayLicenseClient.RequestCounts(certificate: 1, token: 2, license: 2, heartbeat: 0),
            session.client.requestCounts
        )
        XCTAssertEqual([Self.skd], session.keyIdentifiers)
        XCTAssertTrue(recordedErrors.isEmpty)
    }

    func testKidComesFromTheSkdIdentifierInEveryAcceptedForm() async {
        let forms = [
            Self.skd,
            "skd://00112233-4455-6677-8899-aabbccddeeff:\(Self.iv.uppercased())",
            "skd://ABEiM0RVZneImaq7zN3u/w==",
            "skd://ABEiM0RVZneImaq7zN3u_w",
            "00112233445566778899AABBCCDDEEFF",
        ]
        for form in forms {
            StubURLProtocol.reset()
            enqueueCertificate()
            enqueueToken("token")
            enqueueLicense("ckc")
            let request = FakeKeyRequest(form, spc: Data("spc-without-kid".utf8))
            await makeSession(.none).handle(request)
            XCTAssertNotNil(request.ckc, form)
            XCTAssertEqual(Self.kid, StubURLProtocol.requests[1].query("kid"), form)
        }
    }

    func testAxinomGuidFormRewritesTheContentIdentifier() async {
        enqueueCertificate()
        enqueueToken("token")
        enqueueLicense("ckc")
        let request = FakeKeyRequest(Self.skd)
        await makeSession(.none, form: .axinomGuid).handle(request)
        XCTAssertEqual(
            [Data("skd://00112233-4455-6677-8899-aabbccddeeff:FFEEDDCCBBAA99887766554433221100".utf8)],
            request.contentIdentifiers
        )
        XCTAssertEqual(Self.kid, StubURLProtocol.requests[1].query("kid"))
    }

    func testUnparsableIdentifierIsUnknownWithoutNetwork() async {
        for identifier in [nil, "skd://not-a-kid", "skd://\(Self.kid):zz", ""] as [String?] {
            errors = []
            let request = FakeKeyRequest(identifier)
            await makeSession(.none).handle(request)
            XCTAssertEqual(.unknown, request.playbackError)
            XCTAssertEqual([.unknown], recordedErrors)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testCertificateTransportFailureIsNetworkAndIsRefetchedNextTime() async {
        StubURLProtocol.enqueue("/cert.cer", .transportError)
        let session = makeSession(.none)
        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        XCTAssertEqual(.network, first.playbackError)
        XCTAssertEqual([.network], recordedErrors)
        XCTAssertEqual(["/cert.cer"], StubURLProtocol.requests.map(\.url.path))

        enqueueCertificate()
        enqueueToken("token")
        enqueueLicense("ckc")
        let second = FakeKeyRequest(Self.skd)
        await session.handle(second)
        XCTAssertNotNil(second.ckc)
        XCTAssertEqual(2, session.client.requestCounts.certificate)
    }

    func testCertificateHttpErrorOrEmptyBodyIsUnknown() async {
        StubURLProtocol.enqueue("/cert.cer", .http(404))
        let session = makeSession(.none)
        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        XCTAssertEqual(.unknown, first.playbackError)

        StubURLProtocol.enqueue("/cert.cer", .http(200))
        let second = FakeKeyRequest(Self.skd)
        await session.handle(second)
        XCTAssertEqual(.unknown, second.playbackError)
        XCTAssertEqual([.unknown, .unknown], recordedErrors)
        XCTAssertEqual(0, session.client.requestCounts.token)
    }

    func testSpcFailureIsUnknownWithoutToken() async {
        enqueueCertificate()
        let request = FakeKeyRequest(Self.skd)
        request.spcError = NSError(domain: "AVFoundationErrorDomain", code: -42)
        let session = makeSession(.none)
        await session.handle(request)
        XCTAssertEqual(.unknown, request.playbackError)
        XCTAssertEqual([.unknown], recordedErrors)
        XCTAssertEqual(0, session.client.requestCounts.token)
    }

    // MARK: Token errors

    func testToken409IsBlockedByStreamLimitTerminalOnceAndNotRetried() async {
        enqueueCertificate()
        StubURLProtocol.enqueue("/drm-token", .http(409))
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: StreamLimit.modeAxinomCsl, renewalIntervalSeconds: 7, heartbeatIntervalSeconds: 0), scheduler: scheduler)
        session.start()
        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        XCTAssertEqual(.blockedByStreamLimit, first.playbackError)
        XCTAssertTrue(session.isReleased)
        XCTAssertTrue(scheduler.tasks.allSatisfy(\.cancelled))
        let networkCalls = StubURLProtocol.requests.count

        let second = FakeKeyRequest(Self.skd)
        await session.handle(second)
        XCTAssertEqual(.blockedByStreamLimit, second.playbackError)
        XCTAssertEqual(networkCalls, StubURLProtocol.requests.count)
        XCTAssertEqual([.blockedByStreamLimit], recordedErrors)
    }

    func testToken403IsNotEntitled() async {
        await expectTokenError(403, .notEntitled)
    }

    func testToken401IsExpired() async {
        await expectTokenError(401, .expired)
    }

    func testToken500IsUnknownAndNotTerminal() async {
        let session = await expectTokenError(500, .unknown)
        XCTAssertFalse(session.isReleased)
    }

    func testTokenTransportFailureIsNetwork() async {
        enqueueCertificate()
        StubURLProtocol.enqueue("/drm-token", .transportError)
        let request = FakeKeyRequest(Self.skd)
        await makeSession(.none).handle(request)
        XCTAssertEqual(.network, request.playbackError)
        XCTAssertEqual([.network], recordedErrors)
    }

    func testTokenWithoutTokenFieldIsUnknown() async {
        enqueueCertificate()
        StubURLProtocol.enqueue("/drm-token", .http(200, body: Data("{\"expiresAt\":\"x\"}".utf8)))
        let request = FakeKeyRequest(Self.skd)
        await makeSession(.none).handle(request)
        XCTAssertEqual(.unknown, request.playbackError)
    }

    func testTokenReadsTheBearerOnEveryRequest() async {
        var bearer = "first"
        enqueueCertificate()
        enqueueToken("t1")
        enqueueLicense("c1")
        enqueueToken("t2")
        enqueueLicense("c2")
        let session = makeSession(.none, authorization: { bearer })
        await session.handle(FakeKeyRequest(Self.skd))
        bearer = "Bearer second"
        await session.handle(FakeKeyRequest(Self.skd))
        let tokens = StubURLProtocol.requests.filter { $0.url.path == "/drm-token" }
        XCTAssertEqual(["Bearer first", "Bearer second"], tokens.map { $0.header("Authorization") })
    }

    // MARK: License errors

    func testLicenseCslDenyIsBlockedByStreamLimitTerminal() async {
        enqueueCertificate()
        enqueueToken("token")
        StubURLProtocol.enqueue("/AcquireLicense", .http(403, headers: ["X-AxDrm-ErrorCode": "1"]))
        let session = makeSession(.none)
        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        XCTAssertEqual(.blockedByStreamLimit, first.playbackError)
        XCTAssertTrue(session.isReleased)

        let second = FakeKeyRequest(Self.skd)
        await session.handle(second)
        XCTAssertEqual(.blockedByStreamLimit, second.playbackError)
        XCTAssertEqual(3, StubURLProtocol.requests.count)
        XCTAssertEqual([.blockedByStreamLimit], recordedErrors)
    }

    func testLicense403WithoutCslHeaderIsUnknown() async {
        enqueueCertificate()
        enqueueToken("token")
        StubURLProtocol.enqueue("/AcquireLicense", .http(403))
        let request = FakeKeyRequest(Self.skd)
        let session = makeSession(.none)
        await session.handle(request)
        XCTAssertEqual(.unknown, request.playbackError)
        XCTAssertFalse(session.isReleased)
    }

    func testWrappedCkcIsDecoded() {
        let raw = Data([0x01, 0x02, 0x03])
        let wrapped = Data("<ckc>\(raw.base64EncodedString())</ckc>".utf8)
        XCTAssertEqual(raw, FairPlayLicenseClient.ckc(from: wrapped))
        XCTAssertEqual(raw, FairPlayLicenseClient.ckc(from: raw))
        XCTAssertNil(FairPlayLicenseClient.ckc(from: Data()))
    }

    // MARK: Renewal

    func testAxinomCslRenewsAt70PercentThenEveryInterval() async {
        await assertRenewal(mode: StreamLimit.modeAxinomCsl, period: 7)
    }

    func testLongLicenseRenewsAtConfiguredInterval() async {
        await assertRenewal(mode: StreamLimit.modeLongLicense, period: 300)
    }

    func testRenewalFailureMapsLikeTheFirstRequest() async {
        enqueueCertificate()
        enqueueToken("token")
        enqueueLicense("ckc")
        StubURLProtocol.enqueue("/drm-token", .http(409))
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: StreamLimit.modeAxinomCsl, renewalIntervalSeconds: 10, heartbeatIntervalSeconds: 0), scheduler: scheduler)
        var renewed: [FairPlayKeyRequest] = []
        session.renewer = { renewed.append($0) }
        session.start()
        await session.handle(FakeKeyRequest(Self.skd))
        await scheduler.runPending()
        XCTAssertEqual(1, renewed.count)

        let renewing = FakeKeyRequest(Self.skd)
        await session.handle(renewing)
        XCTAssertEqual(.blockedByStreamLimit, renewing.playbackError)
        XCTAssertEqual([.blockedByStreamLimit], recordedErrors)
        XCTAssertTrue(session.isReleased)
        await scheduler.runPending()
        XCTAssertEqual(1, renewed.count)
    }

    func testRenewalWithoutAnsweredRequestDoesNothing() async {
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: StreamLimit.modeAxinomCsl, renewalIntervalSeconds: 10, heartbeatIntervalSeconds: 0), scheduler: scheduler)
        var renewed = 0
        session.renewer = { _ in renewed += 1 }
        session.start()
        await scheduler.runPending()
        XCTAssertEqual(0, renewed)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testFirstRenewalDelayIsBeforeConfiguredPeriod() {
        XCTAssertEqual(210, FairPlaySession.firstRenewalDelaySeconds(300))
        XCTAssertEqual(4, FairPlaySession.firstRenewalDelaySeconds(7))
        XCTAssertEqual(1, FairPlaySession.firstRenewalDelaySeconds(1))
        XCTAssertEqual(1, FairPlaySession.firstRenewalDelaySeconds(0))
    }

    // MARK: Heartbeat

    func testAppHeartbeatPostsEveryIntervalAndMaps409() async {
        StubURLProtocol.enqueue("/playback-sessions/sess-1/heartbeat", .http(204))
        StubURLProtocol.enqueue("/playback-sessions/sess-1/heartbeat", .http(409))
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: StreamLimit.modeAppHeartbeat, renewalIntervalSeconds: 0, heartbeatIntervalSeconds: 4), scheduler: scheduler)
        session.start()
        XCTAssertEqual([4], scheduler.periods)
        XCTAssertEqual([4], scheduler.initialDelays)

        await scheduler.runPending()
        XCTAssertTrue(recordedErrors.isEmpty)
        await scheduler.runPending()
        XCTAssertEqual([.blockedByStreamLimit], recordedErrors)
        XCTAssertTrue(session.isReleased)

        let heartbeats = StubURLProtocol.requests
        XCTAssertEqual(2, heartbeats.count)
        for heartbeat in heartbeats {
            XCTAssertEqual("POST", heartbeat.method)
            XCTAssertEqual("Bearer access-token", heartbeat.header("Authorization"))
            XCTAssertEqual("renew-cred", heartbeat.header("X-Renewal-Credential"))
            XCTAssertTrue(heartbeat.body.isEmpty)
        }
        await scheduler.runPending()
        XCTAssertEqual(2, StubURLProtocol.requests.count)
    }

    func testHeartbeat403And401AreNotEntitledAndExpired() async {
        for (status, expected) in [(403, DrmPlaybackError.notEntitled), (401, .expired)] {
            StubURLProtocol.reset()
            errors = []
            StubURLProtocol.enqueue("/playback-sessions/sess-1/heartbeat", .http(status))
            let scheduler = FakeScheduler()
            let session = makeSession(StreamLimit(mode: StreamLimit.modeAppHeartbeat, renewalIntervalSeconds: 0, heartbeatIntervalSeconds: 1), scheduler: scheduler)
            session.start()
            await scheduler.runPending()
            XCTAssertEqual([expected], recordedErrors)
            XCTAssertTrue(session.isReleased)
        }
    }

    // MARK: none / release / unknown mode

    func testNoneModeHasNoTimersButStillFetchesToken() async {
        enqueueCertificate()
        enqueueToken("token")
        enqueueLicense("ckc")
        let scheduler = FakeScheduler()
        let session = makeSession(.none, scheduler: scheduler)
        session.start()
        XCTAssertTrue(scheduler.tasks.isEmpty)
        await session.handle(FakeKeyRequest(Self.skd))
        XCTAssertEqual(1, session.client.requestCounts.token)
        XCTAssertEqual(0, session.client.requestCounts.heartbeat)
    }

    func testKeyRequestAfterReleaseIsRefusedWithUnknownAndNoNetwork() async {
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: StreamLimit.modeAppHeartbeat, renewalIntervalSeconds: 0, heartbeatIntervalSeconds: 5), scheduler: scheduler)
        session.start()
        session.release()
        session.release()
        XCTAssertTrue(scheduler.tasks.allSatisfy(\.cancelled))
        XCTAssertEqual(1, scheduler.shutdownCalls)

        let request = FakeKeyRequest(Self.skd)
        await session.handle(request)
        XCTAssertEqual(.unknown, request.playbackError)
        XCTAssertEqual([.unknown], recordedErrors)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        session.start()
        XCTAssertEqual(1, scheduler.tasks.count)
    }

    func testUnknownStreamLimitModeIsUnknown() {
        let scheduler = FakeScheduler()
        makeSession(StreamLimit(mode: "weird", renewalIntervalSeconds: 5, heartbeatIntervalSeconds: 5), scheduler: scheduler).start()
        XCTAssertEqual([.unknown], recordedErrors)
        XCTAssertTrue(scheduler.tasks.isEmpty)
    }

    func testErrorsCarryNoSecrets() {
        for error in DrmPlaybackError.allCases {
            XCTAssertFalse(String(describing: error).contains("eyJ"))
        }
    }

    // MARK: Helpers

    private var recordedErrors: [DrmPlaybackError] {
        errorLock.lock()
        defer { errorLock.unlock() }
        return errors
    }

    private func makeSession(
        _ limit: StreamLimit,
        scheduler: FakeScheduler = FakeScheduler(),
        form: FairPlaySession.ContentIdentifierForm = .keyUri,
        authorization: @escaping () -> String = { "access-token" }
    ) -> FairPlaySession {
        let config = FairPlaySession.Config(
            tokenUrl: "https://api.test/drm-token?slug=test-1",
            licenseUrl: "https://license.test/AcquireLicense",
            certificateUrl: "https://cdn.test/cert.cer",
            heartbeatUrl: "https://api.test/playback-sessions/sess-1/heartbeat",
            playbackSessionId: "sess-1",
            renewalCredential: "renew-cred",
            authorization: authorization,
            streamLimit: limit,
            contentIdentifierForm: form
        )
        return FairPlaySession(
            config: config,
            client: FairPlayLicenseClient(config: config, urlSession: StubURLProtocol.session()),
            scheduler: scheduler
        ) { [weak self] error in
            guard let self else { return }
            self.errorLock.lock()
            self.errors.append(error)
            self.errorLock.unlock()
        }
    }

    @discardableResult
    private func expectTokenError(_ status: Int, _ expected: DrmPlaybackError) async -> FairPlaySession {
        enqueueCertificate()
        StubURLProtocol.enqueue("/drm-token", .http(status))
        let session = makeSession(.none)
        let request = FakeKeyRequest(Self.skd)
        await session.handle(request)
        XCTAssertEqual(expected, request.playbackError)
        XCTAssertEqual([expected], recordedErrors)
        XCTAssertEqual(expected.isTerminal, session.isReleased)
        return session
    }

    private func assertRenewal(mode: String, period: Int) async {
        enqueueCertificate()
        enqueueToken("token-one")
        enqueueLicense("ckc-one")
        enqueueToken("token-renew")
        enqueueLicense("ckc-renew")
        let scheduler = FakeScheduler()
        let session = makeSession(StreamLimit(mode: mode, renewalIntervalSeconds: period, heartbeatIntervalSeconds: 0), scheduler: scheduler)
        var renewed: [FairPlayKeyRequest] = []
        session.renewer = { renewed.append($0) }
        session.start()
        XCTAssertEqual([period], scheduler.periods)
        XCTAssertEqual([period * 7 / 10], scheduler.initialDelays)

        let first = FakeKeyRequest(Self.skd)
        await session.handle(first)
        await scheduler.runPending()
        XCTAssertEqual(1, renewed.count)
        XCTAssertTrue(renewed.first === first)

        // AVFoundation answers renewExpiringResponseData with a renewing key request.
        let renewing = FakeKeyRequest(Self.skd, spc: Data("renewal-spc".utf8))
        await session.handle(renewing)
        XCTAssertEqual(Data("ckc-renew".utf8), renewing.ckc)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(["/cert.cer", "/drm-token", "/AcquireLicense", "/drm-token", "/AcquireLicense"], requests.map(\.url.path))
        XCTAssertEqual(Data("renewal-spc".utf8), requests[4].body)
        assertLicenseRequest(requests[4], token: "token-renew", spc: "renewal-spc")

        await scheduler.runPending()
        XCTAssertEqual(2, renewed.count)
        XCTAssertTrue(renewed.last === renewing)
        XCTAssertEqual(0, session.client.requestCounts.heartbeat)
        XCTAssertTrue(recordedErrors.isEmpty)
    }

    private func assertTokenRequest(_ request: StubURLProtocol.Recorded, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual("GET", request.method, file: file, line: line)
        XCTAssertEqual(Self.kid, request.query("kid"), file: file, line: line)
        XCTAssertEqual("sess-1", request.query("session"), file: file, line: line)
        XCTAssertEqual("stream", request.query("purpose"), file: file, line: line)
        XCTAssertEqual("test-1", request.query("slug"), file: file, line: line)
        XCTAssertEqual("Bearer access-token", request.header("Authorization"), file: file, line: line)
        XCTAssertEqual("renew-cred", request.header("X-Renewal-Credential"), file: file, line: line)
    }

    private func assertLicenseRequest(
        _ request: StubURLProtocol.Recorded,
        token: String,
        spc: String = "spc-bytes",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual("POST", request.method, file: file, line: line)
        XCTAssertEqual(Data(spc.utf8), request.body, file: file, line: line)
        XCTAssertEqual(token, request.header("X-AxDRM-Message"), file: file, line: line)
        XCTAssertNil(request.header("Authorization"), file: file, line: line)
        XCTAssertNil(request.header("X-Renewal-Credential"), file: file, line: line)
    }

    private func enqueueCertificate() {
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
    }

    private func enqueueToken(_ token: String) {
        let json = "{\"token\":\"\(token)\",\"expiresAt\":\"2026-09-27T12:00:00+00:00\",\"renewalIntervalSeconds\":300}"
        StubURLProtocol.enqueue("/drm-token", .http(200, headers: ["Content-Type": "application/json"], body: Data(json.utf8)))
    }

    private func enqueueLicense(_ ckc: String) {
        StubURLProtocol.enqueue("/AcquireLicense", .http(200, body: Data(ckc.utf8)))
    }
}

private extension StreamLimit {
    static let none = StreamLimit(mode: StreamLimit.modeNone, renewalIntervalSeconds: 300, heartbeatIntervalSeconds: 0)
}
