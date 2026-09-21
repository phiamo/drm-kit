import CommonCrypto
import XCTest
@testable import DrmKit

final class DrmIdentifiersTests: XCTestCase {
    func testEncodingsMatchCommittedVector() throws {
        let vector = try loadVector()
        let encodings = vector.encodings

        let kidBytes = try DrmIdentifiers.hexToBytes(vector.kidHex)
        let ivBytes = try DrmIdentifiers.hexToBytes(vector.ivHex)
        let keyBytes = try DrmIdentifiers.hexToBytes(vector.keyHex)
        let packageUuidBytes = try DrmIdentifiers.uuidToBytes(vector.packageUuid)

        XCTAssertNotEqual(vector.kidHex, vector.keyHex)
        XCTAssertNotEqual(vector.ivHex, vector.keyHex)

        XCTAssertEqual(encodings.shakaKidHex, DrmIdentifiers.toHex(kidBytes))
        XCTAssertEqual(encodings.shakaIvHex, DrmIdentifiers.toHex(ivBytes))
        XCTAssertEqual(encodings.shakaKeyHex, DrmIdentifiers.toHex(keyBytes))
        XCTAssertEqual(
            encodings.fairPlayUri,
            DrmIdentifiers.fairPlayUri(kidHex: vector.kidHex, ivHex: vector.ivHex)
        )
        XCTAssertEqual(encodings.axinomKeyId, DrmIdentifiers.axinomKeyId(kidBytes))
        XCTAssertEqual(encodings.axinomKeyValue, DrmIdentifiers.axinomKeyValue(keyBytes))

        let commKey = try DrmIdentifiers.communicationKeyBytes("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let encrypted = try DrmIdentifiers.encryptContentKeyForAxinom(
            contentKey: keyBytes,
            communicationKey: commKey,
            kidBytes: kidBytes
        )
        XCTAssertEqual(16, encrypted.count)
        XCTAssertEqual(
            keyBytes,
            try decryptAes128CbcNoPadding(ciphertext: encrypted, key: commKey, iv: kidBytes)
        )

        XCTAssertEqual(
            vector.adHex,
            DrmIdentifiers.toHex(DrmIdentifiers.additionalData(kidBytes: kidBytes, packageUuidBytes: packageUuidBytes))
        )

        let commKey32 = try DrmIdentifiers.communicationKeyBytes(
            Data(repeating: 0x02, count: 32).base64EncodedString()
        )
        XCTAssertEqual(32, commKey32.count)
        let encrypted128 = try DrmIdentifiers.encryptContentKeyForAxinom(
            contentKey: keyBytes,
            communicationKey: commKey32,
            kidBytes: kidBytes
        )
        XCTAssertEqual(16, encrypted128.count)
        XCTAssertEqual(
            keyBytes,
            try decryptAes128CbcNoPadding(
                ciphertext: encrypted128,
                key: Data(commKey32.prefix(16)),
                iv: kidBytes
            )
        )

        XCTAssertTrue(encodings.fairPlayUri.hasPrefix("skd://"))
        XCTAssertFalse(encodings.fairPlayUri.contains("skd://\(kidBytes.base64EncodedString())"))
        XCTAssertEqual("00112233-4455-6677-8899-aabbccddeeff", encodings.axinomKeyId)
        XCTAssertNotEqual("33221100-5544-7766-8899-aabbccddeeff", encodings.axinomKeyId)
    }

    func testHexAndUriAreLowercase() throws {
        let vector = try loadVector()
        let upperKid = vector.kidHex.uppercased()
        let upperIv = vector.ivHex.uppercased()
        XCTAssertEqual(vector.encodings.shakaKidHex, DrmIdentifiers.toHex(try DrmIdentifiers.hexToBytes(upperKid)))
        XCTAssertEqual(
            vector.encodings.fairPlayUri,
            DrmIdentifiers.fairPlayUri(kidHex: upperKid, ivHex: upperIv)
        )
    }

    func testBadHexThrows() {
        XCTAssertThrowsError(try DrmIdentifiers.hexToBytes("not-hex"))
        XCTAssertThrowsError(try DrmIdentifiers.hexToBytes("00112233"))
        XCTAssertThrowsError(try DrmIdentifiers.hexToBytes("00112233445566778899aabbccddeeff00"))
        XCTAssertThrowsError(try DrmIdentifiers.hexToBytes(""))
        XCTAssertThrowsError(try DrmIdentifiers.communicationKeyBytes("not-a-key"))
    }

    private struct Vector: Decodable {
        let kidHex: String
        let ivHex: String
        let keyHex: String
        let packageUuid: String
        let adHex: String
        let kdfCiphertext: String
        let encodings: Encodings
    }

    private struct Encodings: Decodable {
        let shakaKidHex: String
        let shakaIvHex: String
        let shakaKeyHex: String
        let fairPlayUri: String
        let axinomKeyId: String
        let axinomKeyValue: String
    }

    private func decryptAes128CbcNoPadding(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: ciphertext.count)
        var outputLength: size_t = 0
        let status = ciphertext.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            ciphertext.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength == ciphertext.count else {
            throw NSError(domain: "DrmIdentifiersTests", code: Int(status))
        }
        return output
    }

    private func loadVector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testdata/identifiers-test-vector.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vector.self, from: data)
    }
}
