import XCTest
@testable import UniServerCore

final class ServerStoreTests: XCTestCase {

    func testPairAuthenticateRevoke() throws {
        let f = try Fixture()
        let s = try ServerStore(paths: f.paths)
        defer { s.close() }
        let code = try s.pairingCode()
        XCTAssertEqual(code.count, 10)
        XCTAssertEqual(try s.pairingCode(), code, "配对码重启后不变")

        XCTAssertThrowsError(try s.pair(code: "WRONGCODE1", deviceName: "平板")) {
            XCTAssertEqual($0 as? ServerError, .badPairingCode)
        }
        let (dev, token) = try s.pair(code: code.lowercased(), deviceName: "小米平板 6")
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(s.authenticate(token: token)?.id, dev.id)
        XCTAssertNil(s.authenticate(token: "x" + token.dropFirst()))
        XCTAssertNil(s.authenticate(token: ""))

        // 库里只有哈希，没有令牌原文
        let raw = try Data(contentsOf: f.paths.serverDB)
        XCTAssertNil(raw.range(of: Data(token.utf8)))

        try s.revoke(deviceId: dev.id)
        XCTAssertNil(s.authenticate(token: token), "吊销后不认")
        XCTAssertTrue(try s.devices().first!.revoked)

        let newCode = try s.resetPairingCode()
        XCTAssertNotEqual(newCode, code)
        XCTAssertThrowsError(try s.pair(code: code, deviceName: "Mac"), "旧配对码作废")
    }
}
