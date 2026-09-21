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

    /// AES-128-CBC without padding: first 16 bytes of the communication key, IV = KID bytes.
    public static func encryptContentKeyForAxinom(
        contentKey: Data,
        communicationKey: Data,
        kidBytes: Data
    ) throws -> Data {
        let aesKey = communicationKey.prefix(16)
        guard contentKey.count == 16, aesKey.count == 16, kidBytes.count == 16 else {
            throw DrmIdentifiersError.invalidArgument("Expected 16-byte AES inputs")
        }
        return try cryptAES128CBC(
            data: contentKey,
            key: Data(aesKey),
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
        let aesKey = communicationKey.prefix(16)
        guard encrypted.count == 16, aesKey.count == 16, kidBytes.count == 16 else {
            throw DrmIdentifiersError.invalidArgument("Expected 16-byte AES inputs")
        }
        return try cryptAES128CBC(
            data: encrypted,
            key: Data(aesKey),
            iv: kidBytes,
            operation: CCOperation(kCCDecrypt)
        )
    }

    private static func cryptAES128CBC(
        data: Data,
        key: Data,
        iv: Data,
        operation: CCOperation
    ) throws -> Data {
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
                            kCCKeySizeAES128,
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
