import XCTest
@testable import DrmKit

final class FairPlayKeyIdsTests: XCTestCase {
    private let kidHex = "7069bfc1a1ad7985a2e836b424992752"
    private let ivHex = "e8f9094593402aaad4b266884d54b6de"

    func testParsesSkdWithKidAndIv() {
        let parsed = FairPlayKeyIds.parse("skd://\(kidHex):\(ivHex)")
        XCTAssertEqual(parsed?.kidHex, kidHex)
        XCTAssertEqual(parsed?.ivHex, ivHex)
    }

    func testParsesKidWithoutIv() {
        let parsed = FairPlayKeyIds.parse("skd://\(kidHex)")
        XCTAssertEqual(parsed?.kidHex, kidHex)
        XCTAssertNil(parsed?.ivHex)
    }

    /// Review finding: a short/malformed IV segment must not be silently accepted and forwarded
    /// to the license server as part of the content identifier.
    func testShortIvIsRejected() {
        XCTAssertNil(FairPlayKeyIds.parse("skd://\(kidHex):aabb"))
    }

    func testOverlongIvIsRejected() {
        XCTAssertNil(FairPlayKeyIds.parse("skd://\(kidHex):\(ivHex)00"))
    }

    func testParsesGuidKid() {
        let guid = "7069BFC1-A1AD-7985-A2E8-36B424992752"
        XCTAssertEqual(FairPlayKeyIds.parse("skd://\(guid)")?.kidHex, kidHex)
    }
}
