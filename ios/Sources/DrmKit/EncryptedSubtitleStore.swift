import CryptoKit
import Foundation
import Security

/// Holds the 256-bit subtitle key. Generated once, then returned unchanged.
protocol SubtitleKeyProvider: AnyObject {
    func key() throws -> SymmetricKey
}

enum SubtitleKeyError: Error {
    case keychain(OSStatus)
    case invalidKey
}

/// Subtitle key in the Keychain: generic password, `AfterFirstUnlockThisDeviceOnly`, not synced.
final class KeychainSubtitleKeyProvider: SubtitleKeyProvider {
    static let defaultService = "org.dwbn.drmkit.subtitles"
    private static let account = "subtitle-key"

    private let service: String
    private let lock = NSLock()
    private var cached: SymmetricKey?

    init(service: String = KeychainSubtitleKeyProvider.defaultService) {
        self.service = service
    }

    func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let data = try load() {
            return try remember(data)
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = fresh
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let data = try load() {
            return try remember(data)
        }
        guard status == errSecSuccess else { throw SubtitleKeyError.keychain(status) }
        return try remember(fresh)
    }

    private func remember(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw SubtitleKeyError.invalidKey }
        let key = SymmetricKey(data: data)
        cached = key
        return key
    }

    private func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SubtitleKeyError.keychain(status) }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Subtitles (VTT) for offline downloads. Only ciphertext (AES-256-GCM, random nonce, AAD binding
/// download and name) ever reaches disk; `read` returns the plaintext in memory. File and
/// directory names are hashes, so neither download ids nor languages leak. The root directory is
/// excluded from backup and protected until first user authentication.
public final class EncryptedSubtitleStore {
    private static let fileExtension = ".sub"

    private let root: URL
    private let keyProvider: SubtitleKeyProvider
    private let lock = NSLock()

    /// Production store: ciphertext under `root` (inside the backup-excluded `drm-kit/`), key in the Keychain.
    public convenience init(root: URL) {
        self.init(root: root, keyProvider: KeychainSubtitleKeyProvider())
    }

    init(root: URL, keyProvider: SubtitleKeyProvider) {
        self.root = root
        self.keyProvider = keyProvider
    }

    /// Encrypts `plain` and stores it for `downloadId`/`name` (e.g. a language code), replacing any previous file.
    public func put(downloadId: String, name: String, plain: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let sealed = try AES.GCM.seal(plain, using: try keyProvider.key(), authenticating: aad(downloadId, name))
        guard let combined = sealed.combined else { throw SubtitleKeyError.invalidKey }
        let dir = downloadDir(downloadId)
        try DrmKitFiles.prepareDirectory(dir)
        try combined.write(to: file(downloadId, name), options: DrmKitFiles.writeOptions)
    }

    /// Returns the original bytes, or nil when missing, corrupt or not decryptable.
    public func read(downloadId: String, name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let blob = try? Data(contentsOf: file(downloadId, name)),
              let key = try? keyProvider.key(),
              let box = try? AES.GCM.SealedBox(combined: blob) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key, authenticating: aad(downloadId, name))
    }

    public func delete(downloadId: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(downloadId, name))
    }

    /// Removes every subtitle of `downloadId`.
    public func deleteAll(downloadId: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: downloadDir(downloadId))
    }

    private func downloadDir(_ downloadId: String) -> URL {
        root.appendingPathComponent(DrmKitFiles.sha256Hex(downloadId), isDirectory: true)
    }

    private func file(_ downloadId: String, _ name: String) -> URL {
        downloadDir(downloadId).appendingPathComponent(DrmKitFiles.sha256Hex(name) + Self.fileExtension)
    }

    private func aad(_ downloadId: String, _ name: String) -> Data {
        Data("\(downloadId)\u{0}\(name)".utf8)
    }
}
