import CryptoKit
import Foundation

/// Lifecycle of one download's offline licence.
public enum OfflineLicenseState: String, Equatable, Codable {
    case none = "NONE"
    case active = "ACTIVE"
    case expired = "EXPIRED"
}

/// Persisted offline licence of one download. `keyBlob` (the persistable FairPlay key) is nil
/// once the licence is `expired`.
struct OfflineLicenseRecord: Equatable, Codable {
    let downloadId: String
    let state: OfflineLicenseState
    let keyBlob: Data?
    let kidHex: String
    let keyIdentifier: String
    let endpoints: OfflineEndpoints
    let savedAt: Date
    let expiresAt: Date?
}

protocol OfflineLicenseStore: AnyObject {
    func get(_ downloadId: String) -> OfflineLicenseRecord?
    func all() -> [OfflineLicenseRecord]
    func put(_ record: OfflineLicenseRecord) throws
    func delete(_ downloadId: String)
}

/// Application Support `drm-kit/` helpers: the directory is excluded from backup and protected
/// until first user authentication.
enum DrmKitFiles {
    static func defaultRoot() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("drm-kit", isDirectory: true)
    }

    static var writeOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Creates `url` and any missing parents; every directory created here is protected and
    /// excluded from backup (so `drm-kit/` itself is, and the exclusion covers its contents).
    static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var missing: [URL] = []
        var current = url
        while !manager.fileExists(atPath: current.path) {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            var created = true
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            } catch {
                // "Already exists" (another store created it concurrently) is success.
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw error
                }
                created = false
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            do {
                try mutable.setResourceValues(values)
            } catch {
                if created { try? manager.removeItem(at: directory) }
                throw error
            }
        }
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One small JSON file per download, written atomically with first-unlock protection. Keep the
/// directory inside the backup-excluded `drm-kit/` root: the persistable keys must never reach a backup.
final class FileOfflineLicenseStore: OfflineLicenseStore {
    private let dir: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(dir: URL) {
        self.dir = dir
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func get(_ downloadId: String) -> OfflineLicenseRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = read(fileFor(downloadId)), record.downloadId == downloadId else { return nil }
        return record
    }

    func all() -> [OfflineLicenseRecord] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    func put(_ record: OfflineLicenseRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try DrmKitFiles.prepareDirectory(dir)
        try encoder.encode(record).write(to: fileFor(record.downloadId), options: DrmKitFiles.writeOptions)
    }

    func delete(_ downloadId: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileFor(downloadId))
    }

    private func read(_ url: URL) -> OfflineLicenseRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OfflineLicenseRecord.self, from: data)
    }

    private func fileFor(_ downloadId: String) -> URL {
        dir.appendingPathComponent(DrmKitFiles.sha256Hex(downloadId) + ".json")
    }
}
