import CommonCrypto
import Foundation

public enum DrmIdentifiersError: Error, Equatable {
    case invalidArgument(String)
    case encryptionFailed
}

public enum DrmIdentifiers {
    public static func toHex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexToBytes(_ hex: String) throws -> Data {
        let normalized = hex.lowercased()
        guard normalized.count == 32, normalized.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw DrmIdentifiersError.invalidArgument("Expected 16-byte hex")
        }
        var bytes = Data(capacity: 16)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw DrmIdentifiersError.invalidArgument("Expected 16-byte hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func uuidToBytes(_ uuid: String) throws -> Data {
        try hexToBytes(uuid.replacingOccurrences(of: "-", with: ""))
    }

    public static func fairPlayUri(kidHex: String, ivHex: String) -> String {
        "skd://\(kidHex.lowercased()):\(ivHex.lowercased())"
    }

    /// RFC 4122 UUID from KID bytes (big-endian, lowercase, dashed). Not mixed-endian.
    public static func axinomKeyId(_ kidBytes: Data) -> String {
        let hex = toHex(kidBytes)
        let start = hex.startIndex
        func slice(_ offset: Int, _ count: Int) -> Substring {
            let from = hex.index(start, offsetBy: offset)
            let to = hex.index(from, offsetBy: count)
            return hex[from..<to]
        }
        return "\(slice(0, 8))-\(slice(8, 4))-\(slice(12, 4))-\(slice(16, 4))-\(slice(20, 12))"
    }

    public static func axinomKeyValue(_ keyBytes: Data) -> String {
        keyBytes.base64EncodedString()
    }

    /// AES-CBC without padding, IV = KID bytes. 32-byte communication key uses AES-256; 16-byte uses AES-128.
    public static func encryptContentKeyForAxinom(
        contentKey: Data,
        communicationKey: Data,
        kidBytes: Data
    ) throws -> Data {
        guard contentKey.count == 16, kidBytes.count == 16,
              communicationKey.count == 16 || communicationKey.count == 32 else {
            throw DrmIdentifiersError.invalidArgument("Expected a 16-byte content key and a 16- or 32-byte communication key")
        }
        return try cryptAESCBC(
            data: contentKey,
            key: communicationKey,
            iv: kidBytes,
            operation: CCOperation(kCCEncrypt)
        )
    }

    public static func communicationKeyBytes(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuidRange = NSRange(location: 0, length: trimmed.utf16.count)
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        if let regex = try? NSRegularExpression(pattern: uuidPattern),
           regex.firstMatch(in: trimmed, range: uuidRange) != nil {
            return try uuidToBytes(trimmed)
        }
        let raw = Data(trimmed.utf8)
        if raw.count == 16 {
            return raw
        }
        if let decoded = Data(base64Encoded: trimmed), decoded.count == 16 || decoded.count == 32 {
            return decoded
        }
        throw DrmIdentifiersError.invalidArgument("Invalid communication key")
    }

    public static func communicationKeyBytes(_ value: Data) throws -> Data {
        guard value.count == 16 else {
            throw DrmIdentifiersError.invalidArgument("Invalid communication key")
        }
        return value
    }

    public static func additionalData(kidBytes: Data, packageUuidBytes: Data) -> Data {
        kidBytes + packageUuidBytes
    }

    static func decryptContentKeyForAxinom(
        encrypted: Data,
        communicationKey: Data,
        kidBytes: Data
    ) throws -> Data {
        guard encrypted.count == 16, kidBytes.count == 16,
              communicationKey.count == 16 || communicationKey.count == 32 else {
            throw DrmIdentifiersError.invalidArgument("Expected a 16-byte ciphertext and a 16- or 32-byte communication key")
        }
        return try cryptAESCBC(
            data: encrypted,
            key: communicationKey,
            iv: kidBytes,
            operation: CCOperation(kCCDecrypt)
        )
    }

    private static func cryptAESCBC(
        data: Data,
        key: Data,
        iv: Data,
        operation: CCOperation
    ) throws -> Data {
        let keySize: size_t
        switch key.count {
        case kCCKeySizeAES128:
            keySize = size_t(kCCKeySizeAES128)
        case kCCKeySizeAES256:
            keySize = size_t(kCCKeySizeAES256)
        default:
            throw DrmIdentifiersError.invalidArgument("Expected a 16- or 32-byte AES key")
        }
        var output = Data(count: data.count)
        var outputLength: size_t = 0
        let status = data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            keySize,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            data.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength == data.count else {
            throw DrmIdentifiersError.encryptionFailed
        }
        return output
    }
}
