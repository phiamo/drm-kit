import CryptoKit
import XCTest
@testable import DrmKit

final class EncryptedSubtitleStoreTests: XCTestCase {
    private static let vtt = "WEBVTT\n\n00:00.000 --> 00:02.000\nFull-text secret teaching line\n"

    private var root: URL!
    private var keys: InMemorySubtitleKeyProvider!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drmkit-subs-\(UUID().uuidString)")
        keys = InMemorySubtitleKeyProvider()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testDiskHoldsCiphertextOnlyAndReadReturnsOriginal() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "lang-german", plain: Data(Self.vtt.utf8))

        let files = try allFiles()
        XCTAssertEqual(1, files.count)
        for file in files {
            let raw = try Data(contentsOf: file)
            XCTAssertNil(raw.range(of: Data("secret teaching".utf8)))
            XCTAssertNil(raw.range(of: Data("WEBVTT".utf8)))
            XCTAssertFalse(file.path.replacingOccurrences(of: root.path, with: "").contains("dl-1"))
            XCTAssertFalse(file.path.contains("german"))
        }
        XCTAssertEqual(Data(Self.vtt.utf8), store.read(downloadId: "dl-1", name: "lang-german"))
    }

    func testEveryPutUsesAFreshNonce() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "de", plain: Data(Self.vtt.utf8))
        let first = try Data(contentsOf: try allFiles()[0])
        try store.put(downloadId: "dl-1", name: "de", plain: Data(Self.vtt.utf8))
        let second = try Data(contentsOf: try allFiles()[0])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Data(Self.vtt.utf8), store.read(downloadId: "dl-1", name: "de"))
    }

    func testWrongKeyCorruptFileAndMissingReadAsNil() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "de", plain: Data(Self.vtt.utf8))
        XCTAssertNil(store.read(downloadId: "dl-1", name: "en"))
        XCTAssertNil(store.read(downloadId: "other", name: "de"))

        let wrongKey = EncryptedSubtitleStore(root: root, keyProvider: InMemorySubtitleKeyProvider())
        XCTAssertNil(wrongKey.read(downloadId: "dl-1", name: "de"))

        let file = try allFiles()[0]
        var raw = try Data(contentsOf: file)
        raw[raw.count - 1] ^= 0xff
        try raw.write(to: file)
        XCTAssertNil(store.read(downloadId: "dl-1", name: "de"))
        try Data([1, 2, 3]).write(to: file)
        XCTAssertNil(store.read(downloadId: "dl-1", name: "de"))
    }

    func testCiphertextIsBoundToDownloadAndName() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "de", plain: Data(Self.vtt.utf8))
        let source = try allFiles()[0]
        let targetDir = root.appendingPathComponent(DrmKitFiles.sha256Hex("dl-2"), isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: targetDir.appendingPathComponent(DrmKitFiles.sha256Hex("de") + ".sub"))
        try FileManager.default.copyItem(at: source, to: source.deletingLastPathComponent()
            .appendingPathComponent(DrmKitFiles.sha256Hex("en") + ".sub"))

        XCTAssertNil(store.read(downloadId: "dl-2", name: "de"))
        XCTAssertNil(store.read(downloadId: "dl-1", name: "en"))
    }

    func testDeleteAndDeleteAll() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "de", plain: Data("a".utf8))
        try store.put(downloadId: "dl-1", name: "en", plain: Data("b".utf8))
        try store.put(downloadId: "dl-2", name: "de", plain: Data("c".utf8))

        store.delete(downloadId: "dl-1", name: "de")
        XCTAssertNil(store.read(downloadId: "dl-1", name: "de"))
        XCTAssertEqual(Data("b".utf8), store.read(downloadId: "dl-1", name: "en"))

        store.deleteAll(downloadId: "dl-1")
        XCTAssertNil(store.read(downloadId: "dl-1", name: "en"))
        XCTAssertEqual(Data("c".utf8), store.read(downloadId: "dl-2", name: "de"))
        store.deleteAll(downloadId: "never-stored")
    }

    func testStoreDirectoryIsExcludedFromBackup() throws {
        try makeStore().put(downloadId: "dl-1", name: "de", plain: Data("a".utf8))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(true, values.isExcludedFromBackup)
    }

    func testKeyProviderFailureOnPutThrowsAndOnReadIsNil() throws {
        let store = makeStore()
        try store.put(downloadId: "dl-1", name: "de", plain: Data("a".utf8))
        let broken = EncryptedSubtitleStore(root: root, keyProvider: ThrowingKeyProvider())
        XCTAssertThrowsError(try broken.put(downloadId: "dl-1", name: "en", plain: Data("a".utf8)))
        XCTAssertNil(broken.read(downloadId: "dl-1", name: "de"))
    }

    func testConcurrentPreparationOfASharedParentSucceeds() async throws {
        let licences = FileOfflineLicenseStore(dir: root.appendingPathComponent("offline-licenses"))
        let store = makeStore(at: root.appendingPathComponent("subtitles"))
        let record = OfflineLicenseRecord(
            downloadId: "dl-1", state: .active, keyBlob: Data("k".utf8), kidHex: "00", keyIdentifier: "skd://00",
            endpoints: OfflineEndpoints(tokenUrl: "t", licenseUrl: "l", certificateUrl: "c"),
            savedAt: Date(timeIntervalSince1970: 1), expiresAt: nil)

        for _ in 0..<20 {
            try? FileManager.default.removeItem(at: root)
            async let first: Void = Task.detached { try licences.put(record) }.value
            async let second: Void = Task.detached { try store.put(downloadId: "dl-1", name: "de", plain: Data("a".utf8)) }.value
            _ = try await (first, second)
        }
        XCTAssertEqual(true, try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
        XCTAssertEqual(Data("a".utf8), store.read(downloadId: "dl-1", name: "de"))
        XCTAssertNotNil(licences.get("dl-1"))
    }

    func testOneShotFirstFinishWinsAndResumesOnce() async throws {
        let box = OneShotBox()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let shot = OneShot<Int>(continuation)
            box.shot = shot
            shot.finish(.success(1))
            shot.finish(.success(2))
            shot.finish(.failure(DrmPlaybackError.unknown))
        }
        XCTAssertEqual(1, value)
        box.shot?.finish(.success(3)) // would trap on a double resume

        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let shot = OneShot<Int>(continuation)
                shot.finish(.failure(DrmPlaybackError.network))
                shot.finish(.success(9))
            }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(DrmPlaybackError.network, error as? DrmPlaybackError)
        }
    }

    func testOfflineDeviceLimitIsTerminal() {
        XCTAssertTrue(DrmPlaybackError.offlineDeviceLimit.isTerminal)
    }

    private func makeStore(at url: URL? = nil) -> EncryptedSubtitleStore {
        EncryptedSubtitleStore(root: url ?? root, keyProvider: keys)
    }

    private func allFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

private final class ThrowingKeyProvider: SubtitleKeyProvider {
    func key() throws -> SymmetricKey { throw SubtitleKeyError.invalidKey }
}

private final class OneShotBox {
    var shot: OneShot<Int>?
}
