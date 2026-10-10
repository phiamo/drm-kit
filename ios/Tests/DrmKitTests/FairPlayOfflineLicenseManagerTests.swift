import AVFoundation
import XCTest
@testable import DrmKit

final class FairPlayOfflineLicenseManagerTests: XCTestCase {
    private static let kid = "00112233445566778899aabbccddeeff"
    private static let iv = "ffeeddccbbaa99887766554433221100"
    private static let skd = "skd://\(kid):\(iv)"
    private static let certificate = Data("der-certificate".utf8)
    private static let day: TimeInterval = 86_400
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var dir: URL!
    private var now = FairPlayOfflineLicenseManagerTests.start
    private var driver: FakeOfflineKeyDriver!
    private var accessToken = "access-token"

    private let endpoints = OfflineEndpoints(
        tokenUrl: "https://api.test/drm-token?slug=test-1",
        licenseUrl: "https://license.test/AcquireLicense",
        certificateUrl: "https://cdn.test/cert.cer"
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drmkit-offline-\(UUID().uuidString)")
        driver = FakeOfflineKeyDriver()
        now = Self.start
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Acquire

    func testAcquireStoresPersistableKeyAndExpiryFromToken() async {
        let manager = makeManager()
        enqueueAcquire(token: "tok-1", ckc: "ckc-1", expiresIn: 27 * Self.day)

        let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(.active, manager.state(downloadId: "dl-1"))
        XCTAssertEqual(Self.start.addingTimeInterval(27 * Self.day), manager.expiresAt(downloadId: "dl-1"))
        XCTAssertFalse(manager.needsRenewal(downloadId: "dl-1"))
        let request = driver.issued[0]
        XCTAssertEqual(Data("persistable-ckc-1".utf8), request.responseKey)
        XCTAssertEqual([Self.certificate], request.certificates)
        XCTAssertEqual([Data(Self.skd.utf8)], request.contentIdentifiers)
        XCTAssertEqual([Self.skd], driver.requested)
        XCTAssertEqual(1, driver.closeCalls)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(["/cert.cer", "/drm-token", "/AcquireLicense"], requests.map(\.url.path))
        XCTAssertNil(requests[0].header("Authorization"))
        assertOfflineTokenRequest(requests[1])
        XCTAssertEqual("POST", requests[2].method)
        XCTAssertEqual(Data("spc-without-kid".utf8), requests[2].body)
        XCTAssertEqual("tok-1", requests[2].header("X-AxDRM-Message"))
    }

    func testAcquireReleasesLeftoverPersistableKey() async {
        let manager = makeManager()
        enqueueAcquire(token: "tok-1", ckc: "ckc-1", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        enqueueAcquire(token: "tok-2", ckc: "ckc-2", expiresIn: 27 * Self.day)

        let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual([Data("persistable-ckc-1".utf8)], driver.invalidated)
        XCTAssertEqual(Data("persistable-ckc-2".utf8), driver.issued.last?.responseKey)
    }

    func testAcquirePersistsAcrossManagerInstances() async {
        enqueueAcquire(expiresIn: 27 * Self.day)
        _ = await makeManager().acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        let restarted = makeManager()
        XCTAssertEqual(.active, restarted.state(downloadId: "dl-1"))
        XCTAssertEqual(Self.start.addingTimeInterval(27 * Self.day), restarted.expiresAt(downloadId: "dl-1"))
    }

    func testKidComesFromTheKeyIdentifierInEveryAcceptedForm() async {
        let forms = [
            Self.skd,
            "skd://00112233-4455-6677-8899-aabbccddeeff:\(Self.iv)",
            "skd://ABEiM0RVZneImaq7zN3u/w==",
        ]
        for form in forms {
            StubURLProtocol.reset()
            enqueueAcquire(expiresIn: Self.day * 27)
            let result = await makeManager().acquire(downloadId: "dl-\(form)", keyIdentifier: form, endpoints: endpoints)
            XCTAssertTrue(result.isSuccess, form)
            XCTAssertEqual(Self.kid, StubURLProtocol.requests[1].query("kid"), form)
        }
    }

    func testAcquireRejectsUnparseableIdentifierWithoutNetwork() async {
        let result = await makeManager().acquire(downloadId: "dl-1", keyIdentifier: "not-a-key", endpoints: endpoints)
        XCTAssertEqual(.failure(.unknown), result)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testTokenWithoutOrWithInvalidExpiryStoresNothing() async {
        for json in [
            "{\"token\":\"tok\"}",
            "{\"token\":\"tok\",\"licenseExpiresAt\":\"tomorrow\"}",
            "{\"licenseExpiresAt\":\"2026-10-30T12:00:00+00:00\"}",
        ] {
            StubURLProtocol.reset()
            driver = FakeOfflineKeyDriver()
            let manager = makeManager()
            StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
            StubURLProtocol.enqueue("/drm-token", .http(200, body: Data(json.utf8)))

            let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

            XCTAssertEqual(.failure(.unknown), result, json)
            XCTAssertEqual(.none, manager.state(downloadId: "dl-1"), json)
            XCTAssertEqual(.unknown, driver.issued[0].playbackError, json)
            XCTAssertNil(driver.issued[0].responseKey, json)
            XCTAssertFalse(StubURLProtocol.requests.map(\.url.path).contains("/AcquireLicense"), json)
        }
    }

    func testFractionalSecondExpiryIsAccepted() async {
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        StubURLProtocol.enqueue("/drm-token", .http(200, body: Data(
            "{\"token\":\"tok\",\"licenseExpiresAt\":\"2027-01-01T00:00:00.500Z\"}".utf8)))
        StubURLProtocol.enqueue("/AcquireLicense", .http(200, body: Data("ckc".utf8)))
        let manager = makeManager()

        let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(1_798_761_600.5, manager.expiresAt(downloadId: "dl-1")?.timeIntervalSince1970)
    }

    func testAcquireRefusalsStoreNothingAndMapReason() async {
        let cases: [(String, StubURLProtocol.Reply, DrmPlaybackError)] = [
            ("/drm-token", .http(403), .notEntitled),
            ("/drm-token", .http(403, body: Data("{\"error\":\"offline_device_limit\"}".utf8)), .offlineDeviceLimit),
            ("/drm-token", .http(401), .expired),
            ("/drm-token", .http(429), .rateLimited),
            ("/drm-token", .transportError, .network),
            ("/AcquireLicense", .http(403), .notEntitled),
            ("/AcquireLicense", .http(403, body: Data("{\"error\":\"offline_device_limit\"}".utf8)), .offlineDeviceLimit),
            ("/AcquireLicense", .http(500), .unknown),
        ]
        for (path, reply, expected) in cases {
            StubURLProtocol.reset()
            driver = FakeOfflineKeyDriver()
            let manager = makeManager()
            StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
            if path == "/AcquireLicense" { enqueueToken(expiresIn: Self.day * 27) }
            StubURLProtocol.enqueue(path, reply)

            let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

            XCTAssertEqual(.failure(expected), result, "\(path) \(expected)")
            XCTAssertEqual(.none, manager.state(downloadId: "dl-1"))
            XCTAssertEqual(expected, driver.issued[0].playbackError)
            XCTAssertNil(driver.issued[0].responseKey)
        }
    }

    func testPreloadStoredKeyOnlyForLocalPackages() {
        XCTAssertTrue(FairPlayOfflineLicenseManager.shouldPreloadStoredKey(url: URL(fileURLWithPath: "/tmp/a.movpkg")))
        XCTAssertFalse(FairPlayOfflineLicenseManager.shouldPreloadStoredKey(url: URL(string: "https://cdn.example/audio.m3u8")!))
    }

    func testCertificateAndKeyRequestFailures() async {
        StubURLProtocol.enqueue("/cert.cer", .http(404))
        var result = await makeManager().acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        XCTAssertEqual(.failure(.unknown), result)
        XCTAssertTrue(driver.requested.isEmpty)

        StubURLProtocol.reset()
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        driver.requestError = DrmPlaybackError.unknown
        result = await makeManager().acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        XCTAssertEqual(.failure(.unknown), result)
        XCTAssertFalse(StubURLProtocol.requests.map(\.url.path).contains("/drm-token"))
    }

    func testPersistableKeyFailureStoresNothing() async {
        let failing = FailingKeyDriver()
        let manager = makeManager(driver: failing)
        enqueueAcquire(expiresIn: Self.day * 27)

        let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertEqual(.failure(.unknown), result)
        XCTAssertEqual(.none, manager.state(downloadId: "dl-1"))
        XCTAssertEqual(.unknown, failing.last?.playbackError)
    }

    func testFailedAcquireKeepsExistingDownload() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "first", expiresIn: Self.day * 27)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        StubURLProtocol.enqueue("/drm-token", .http(403))

        let result = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertEqual(.failure(.notEntitled), result)
        XCTAssertEqual(.active, manager.state(downloadId: "dl-1"))
        XCTAssertEqual(Data("persistable-first".utf8), playbackKey(manager))
    }

    // MARK: Renewal

    func testNeedsRenewalWithinOneDayExpiredOrUnknown() async {
        let manager = makeManager()
        enqueueAcquire(expiresIn: 2 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        XCTAssertFalse(manager.needsRenewal(downloadId: "dl-1"))
        now = Self.start.addingTimeInterval(Self.day - 1)
        XCTAssertFalse(manager.needsRenewal(downloadId: "dl-1"))
        now = Self.start.addingTimeInterval(Self.day)
        XCTAssertTrue(manager.needsRenewal(downloadId: "dl-1"))
        now = Self.start.addingTimeInterval(3 * Self.day)
        XCTAssertTrue(manager.needsRenewal(downloadId: "dl-1"))
        XCTAssertFalse(manager.needsRenewal(downloadId: "never-stored"))
    }

    func testNotActiveNeedsRenewal() async {
        let manager = makeManager()
        enqueueAcquire(expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue("/drm-token", .http(403))
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        _ = await manager.renew(downloadId: "dl-1")

        XCTAssertEqual(.expired, manager.state(downloadId: "dl-1"))
        XCTAssertTrue(manager.needsRenewal(downloadId: "dl-1"))
    }

    func testRenewReplacesKeyAndResetsExpiryUsingStoredEndpoints() async {
        let manager = makeManager()
        enqueueAcquire(token: "tok-1", ckc: "old", expiresIn: Self.day / 2)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        XCTAssertTrue(manager.needsRenewal(downloadId: "dl-1"))
        now = Self.start.addingTimeInterval(3_600)
        StubURLProtocol.reset()
        accessToken = "fresh-access-token"
        enqueueAcquire(token: "tok-2", ckc: "new", expiresIn: 27 * Self.day)
        let restarted = makeManager()

        let result = await restarted.renew(downloadId: "dl-1")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(.active, restarted.state(downloadId: "dl-1"))
        XCTAssertEqual(now.addingTimeInterval(27 * Self.day), restarted.expiresAt(downloadId: "dl-1"))
        XCTAssertFalse(restarted.needsRenewal(downloadId: "dl-1"))
        XCTAssertEqual(Data("persistable-new".utf8), playbackKey(restarted))
        XCTAssertEqual(Data("persistable-new".utf8), driver.issued.last?.responseKey)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(["/cert.cer", "/drm-token", "/AcquireLicense"], requests.map(\.url.path))
        assertOfflineTokenRequest(requests[1], bearer: "Bearer fresh-access-token")
        XCTAssertEqual("tok-2", requests[2].header("X-AxDRM-Message"))
    }

    func testRenewRefusalExpiresAndDeletesKey() async {
        for body in [Data(), Data("{\"error\":\"offline_device_limit\"}".utf8)] {
            StubURLProtocol.reset()
            driver = FakeOfflineKeyDriver()
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("drmkit-offline-\(UUID().uuidString)")
            let manager = makeManager()
            enqueueAcquire(expiresIn: 27 * Self.day)
            _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
            StubURLProtocol.reset()
            StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
            StubURLProtocol.enqueue("/drm-token", .http(403, body: body))

            let result = await manager.renew(downloadId: "dl-1")

            XCTAssertEqual(.failure(body.isEmpty ? .notEntitled : .offlineDeviceLimit), result)
            XCTAssertEqual(.expired, manager.state(downloadId: "dl-1"))
            XCTAssertNil(playbackKey(manager))
            XCTAssertTrue(manager.needsRenewal(downloadId: "dl-1"))
            let again = await manager.renew(downloadId: "dl-1")
            XCTAssertEqual(.failure(.expired), again)
        }
    }

    func testRenewWithLapsedBearerKeepsStateAndKey() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "kept", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        StubURLProtocol.enqueue("/drm-token", .http(401))

        let result = await manager.renew(downloadId: "dl-1")

        XCTAssertEqual(.failure(.expired), result)
        XCTAssertEqual(.active, manager.state(downloadId: "dl-1"))
        XCTAssertEqual(Data("persistable-kept".utf8), playbackKey(manager))
    }

    func testRenewFailuresOtherThanTokenRefusalLeaveStateUntouched() async throws {
        let cases: [(String, StubURLProtocol.Reply, DrmPlaybackError)] = [
            ("/drm-token", .transportError, .network),
            ("/drm-token", .http(500), .unknown),
            ("/AcquireLicense", .http(403), .notEntitled),
            ("/AcquireLicense", .transportError, .network),
        ]
        for (path, reply, expected) in cases {
            StubURLProtocol.reset()
            let manager = makeManager()
            enqueueAcquire(ckc: "kept", expiresIn: 27 * Self.day)
            _ = await manager.acquire(downloadId: "dl-\(path)-\(expected)", keyIdentifier: Self.skd, endpoints: endpoints)
            let id = "dl-\(path)-\(expected)"
            StubURLProtocol.reset()
            StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
            if path == "/AcquireLicense" { enqueueToken(expiresIn: 27 * Self.day) }
            StubURLProtocol.enqueue(path, reply)

            let result = await manager.renew(downloadId: id)

            XCTAssertEqual(.failure(expected), result, "\(path) \(expected)")
            XCTAssertEqual(.active, manager.state(downloadId: id))
        }
    }

    func testRenewUnknownDownloadIsANoOp() async {
        let result = await makeManager().renew(downloadId: "never-stored")
        XCTAssertEqual(.failure(.unknown), result)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: Offline playback

    func testOfflinePlaybackAnswersFromStoredKeyWithoutNetwork() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "stored", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()

        let request = FakeOfflineKeyRequest("skd://\(Self.kid):00000000000000000000000000000001")
        manager.answerPlaybackKeyRequest(request)

        XCTAssertEqual(Data("persistable-stored".utf8), request.responseKey)
        XCTAssertNil(request.error)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        manager.persistUpdatedPlaybackKey(Data("persistable-updated".utf8), identifier: Self.skd)
        let updated = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(updated)
        XCTAssertEqual(Data("persistable-updated".utf8), updated.responseKey)
    }

    func testOfflinePlaybackWithoutStoredKeyFails() async {
        let manager = makeManager()
        let missing = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(missing)
        XCTAssertEqual(.notEntitled, missing.playbackError)
        XCTAssertNil(missing.responseKey)

        enqueueAcquire(expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        let otherKid = FakeOfflineKeyRequest("skd://ffeeddccbbaa99887766554433221100:\(Self.iv)")
        manager.answerPlaybackKeyRequest(otherKid)
        XCTAssertEqual(.notEntitled, otherKid.playbackError)

        let unparseable = FakeOfflineKeyRequest(nil)
        manager.answerPlaybackKeyRequest(unparseable)
        XCTAssertEqual(.unknown, unparseable.playbackError)
    }

    func testOfflinePlaybackFallsBackToAttachedDownloadWhenIdentifierUnparsed() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "stored", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        manager.registerAttachedDownloadId("dl-1")

        let request = FakeOfflineKeyRequest(nil)
        manager.answerPlaybackKeyRequest(request)
        XCTAssertEqual(Data("persistable-stored".utf8), request.responseKey)
        XCTAssertNil(request.error)
    }

    func testOfflinePlaybackRefusesExpiredDownload() async {
        let manager = makeManager()
        enqueueAcquire(expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        StubURLProtocol.enqueue("/drm-token", .http(403))
        _ = await manager.renew(downloadId: "dl-1")

        let request = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(request)

        XCTAssertEqual(.expired, request.playbackError)
        XCTAssertNil(request.responseKey)
    }

    func testOfflinePlaybackStreamingRequestMustUpgradeToPersistable() {
        XCTAssertEqual(.requestPersistable, OfflinePlaybackKeyPolicy.action(for: false))
        XCTAssertEqual(.answerStoredKey, OfflinePlaybackKeyPolicy.action(for: true))
    }

    func testOfflinePlaybackPrefersTheMatchingIdentifierThenTheNewest() async {
        let manager = makeManager()
        let other = "skd://\(Self.kid):00000000000000000000000000000002"
        enqueueAcquire(ckc: "a", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-a", keyIdentifier: Self.skd, endpoints: endpoints)
        now = Self.start.addingTimeInterval(60)
        enqueueAcquire(ckc: "b", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-b", keyIdentifier: other, endpoints: endpoints)

        let exact = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(exact)
        XCTAssertEqual(Data("persistable-a".utf8), exact.responseKey)
        let unmatched = FakeOfflineKeyRequest("skd://\(Self.kid):00000000000000000000000000000003")
        manager.answerPlaybackKeyRequest(unmatched)
        XCTAssertEqual(Data("persistable-b".utf8), unmatched.responseKey)
    }

    // MARK: Release / state

    func testReleaseRemovesKeyAndRecordAndInvalidatesBestEffort() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "gone", expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)

        await manager.release(downloadId: "dl-1")

        XCTAssertEqual(.none, manager.state(downloadId: "dl-1"))
        XCTAssertNil(manager.expiresAt(downloadId: "dl-1"))
        XCTAssertNil(playbackKey(manager))
        XCTAssertEqual([Data("persistable-gone".utf8)], driver.invalidated)
    }

    func testUnknownDownloadHasNoStateAndReleaseIsANoOp() async {
        let manager = makeManager()
        XCTAssertEqual(.none, manager.state(downloadId: "never-stored"))
        XCTAssertNil(manager.expiresAt(downloadId: "never-stored"))
        await manager.release(downloadId: "never-stored")
        XCTAssertTrue(driver.invalidated.isEmpty)
        XCTAssertEqual(0, driver.closeCalls)
    }

    func testStateStoresNoSecretsInRecordFileNames() async throws {
        let manager = makeManager()
        enqueueAcquire(expiresIn: 27 * Self.day)
        _ = await manager.acquire(downloadId: "dl-secret-name", keyIdentifier: Self.skd, endpoints: endpoints)

        let names = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("offline-licenses").path)
        XCTAssertEqual(1, names.count)
        XCTAssertFalse(names[0].contains("dl-secret-name"))
        let values = try dir.appendingPathComponent("offline-licenses").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(true, values.isExcludedFromBackup)
        XCTAssertEqual(true, try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    func testReleaseWaitsForARunningAcquireOnTheSameDownload() async {
        let manager = makeManager()
        enqueueAcquire(ckc: "late", expiresIn: 27 * Self.day)
        driver.gated = true
        let releaseDone = LockedFlag()

        let acquire = Task { await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: self.endpoints) }
        await waitUntil { self.driver.waitingAtGate == 1 }
        let release = Task {
            await manager.release(downloadId: "dl-1")
            releaseDone.set()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(releaseDone.value, "release must wait for the running acquire")

        driver.openGate()
        let result = await acquire.value
        await release.value

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(releaseDone.value)
        XCTAssertEqual(.none, manager.state(downloadId: "dl-1"))
        XCTAssertNil(playbackKey(manager))
        XCTAssertEqual([Data("persistable-late".utf8)], driver.invalidated)
    }

    func testPlaybackRefusedAfterExpiresAtWithoutNetwork() async {
        let manager = makeManager()
        enqueueAcquire(expiresIn: 2 * Self.day)
        _ = await manager.acquire(downloadId: "dl-1", keyIdentifier: Self.skd, endpoints: endpoints)
        StubURLProtocol.reset()
        XCTAssertNotNil(playbackKey(manager))

        now = Self.start.addingTimeInterval(2 * Self.day)
        let request = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(request)

        XCTAssertEqual(.expired, request.playbackError)
        XCTAssertNil(request.responseKey)
        XCTAssertEqual(.active, manager.state(downloadId: "dl-1"))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: Helpers

    private func makeManager(driver override: FairPlayOfflineKeyDriver? = nil) -> FairPlayOfflineLicenseManager {
        let config = OfflineLicenseConfig(deviceId: "device-uuid", authorization: { [unowned self] in self.accessToken })
        let provided = override ?? driver!
        return FairPlayOfflineLicenseManager(
            config: config,
            store: FileOfflineLicenseStore(dir: dir.appendingPathComponent("offline-licenses")),
            client: FairPlayOfflineLicenseClient(config: config, urlSession: StubURLProtocol.session()),
            driverFactory: { provided },
            clock: { [unowned self] in self.now }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func playbackKey(_ manager: FairPlayOfflineLicenseManager) -> Data? {
        let request = FakeOfflineKeyRequest(Self.skd)
        manager.answerPlaybackKeyRequest(request)
        return request.responseKey
    }

    private func enqueueAcquire(token: String = "token", ckc: String = "ckc", expiresIn: TimeInterval) {
        StubURLProtocol.enqueue("/cert.cer", .http(200, body: Self.certificate))
        enqueueToken(token, expiresIn: expiresIn)
        StubURLProtocol.enqueue("/AcquireLicense", .http(200, body: Data(ckc.utf8)))
    }

    private func enqueueToken(_ token: String = "token", expiresIn: TimeInterval) {
        let formatter = ISO8601DateFormatter()
        let expiry = formatter.string(from: now.addingTimeInterval(expiresIn))
        let json = "{\"token\":\"\(token)\",\"expiresAt\":\"2026-09-27T12:00:00+00:00\",\"licenseExpiresAt\":\"\(expiry)\"}"
        StubURLProtocol.enqueue("/drm-token", .http(200, headers: ["Content-Type": "application/json"], body: Data(json.utf8)))
    }

    private func assertOfflineTokenRequest(
        _ request: StubURLProtocol.Recorded,
        bearer: String = "Bearer access-token",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual("GET", request.method, file: file, line: line)
        XCTAssertEqual(Self.kid, request.query("kid"), file: file, line: line)
        XCTAssertEqual("download:device-uuid", request.query("session"), file: file, line: line)
        XCTAssertEqual("offline", request.query("purpose"), file: file, line: line)
        XCTAssertEqual("test-1", request.query("slug"), file: file, line: line)
        XCTAssertEqual(bearer, request.header("Authorization"), file: file, line: line)
        XCTAssertNil(request.header("X-Renewal-Credential"), file: file, line: line)
    }
}

/// Driver whose requests fail when turning the CKC into a persistable key.
private final class FailingKeyDriver: FairPlayOfflineKeyDriver {
    private(set) var last: FakeOfflineKeyRequest?

    func request(identifier: String) async throws -> FairPlayOfflineKeyRequest {
        let request = FakeOfflineKeyRequest(identifier)
        request.persistableError = DrmPlaybackError.unknown
        last = request
        return request
    }

    func invalidate(persistableKey: Data) async {}
    func close() {}
}

private final class LockedFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
