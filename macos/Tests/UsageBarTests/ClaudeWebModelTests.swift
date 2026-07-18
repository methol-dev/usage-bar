import XCTest
@testable import UsageBar

/// 信封解析 / 映射 / native messaging framing —— 全部 schema 无关，可在无浏览器环境跑。
final class ClaudeWebModelTests: XCTestCase {

    // MARK: ClaudeWebPayload.parse

    private func parse(_ json: String) -> ClaudeWebPayload? {
        ClaudeWebPayload.parse(Data(json.utf8))
    }

    func testParseOkWithTimestamp() {
        let p = parse(#"{"status":"ok","ts":1778520574000,"usage":{"five_hour":{"utilization":42}}}"#)
        XCTAssertEqual(p?.status, .ok)
        XCTAssertEqual(p?.timestamp?.timeIntervalSince1970 ?? 0, 1778520574.0, accuracy: 0.001)
        XCTAssertNotNil(p?.usage)
    }

    func testParseLoggedOut() {
        XCTAssertEqual(parse(#"{"status":"logged_out","ts":1}"#)?.status, .loggedOut)
    }

    func testParseNoSession() {
        XCTAssertEqual(parse(#"{"status":"no_session","ts":1}"#)?.status, .noSession)
    }

    func testParseError() {
        XCTAssertEqual(parse(#"{"status":"error","error":"orgs_http_500","ts":1}"#)?.status, .error)
    }

    func testUnknownStatusMapsToUnknown() {
        XCTAssertEqual(parse(#"{"status":"weird","ts":1}"#)?.status, .unknown)
    }

    func testMissingStatusMapsToUnknown() {
        XCTAssertEqual(parse(#"{"ts":1}"#)?.status, .unknown)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse("[1,2,3]"))   // 顶层非对象
    }

    func testMissingTimestampIsNil() {
        XCTAssertNil(parse(#"{"status":"ok"}"#)?.timestamp)
    }

    // MARK: ClaudeWebUsageMapper（基本形状；真实 schema 定稿断言见 ClaudeWebMapperTests）

    func testMapsFiveHourAndSevenDay() {
        let usage: [String: Any] = [
            "five_hour": ["utilization": 42.0, "resets_at": 1778520574.0],
            "seven_day": ["utilization": 88.0]
        ]
        let snap = ClaudeWebUsageMapper.snapshot(from: usage)
        XCTAssertEqual(snap?.primaryWindow?.utilizationPct, 42.0)
        XCTAssertEqual(snap?.primaryWindow?.shortLabel, "5h")
        XCTAssertEqual(snap?.secondaryWindow?.utilizationPct, 88.0)
        XCTAssertNotNil(snap?.primaryWindow?.resetsAt)
    }

    func testMapsNothingWhenNoWindows() {
        XCTAssertNil(ClaudeWebUsageMapper.snapshot(from: ["unrelated": 1]))
        XCTAssertNil(ClaudeWebUsageMapper.snapshot(from: nil))
    }

    // MARK: Native messaging framing

    func testDecodeLengthLittleEndian() {
        XCTAssertEqual(ClaudeWebNativeHost.decodeLength([0x01, 0x00, 0x00, 0x00]), 1)
        XCTAssertEqual(ClaudeWebNativeHost.decodeLength([0x00, 0x01, 0x00, 0x00]), 256)
        XCTAssertEqual(ClaudeWebNativeHost.decodeLength([0xff, 0xff, 0xff, 0xff]), 4_294_967_295)
        XCTAssertNil(ClaudeWebNativeHost.decodeLength([0x01, 0x02, 0x03]))   // 长度不足 4
    }

    func testFrameRoundTrips() {
        let body = Data(#"{"ok":true}"#.utf8)
        let framed = ClaudeWebNativeHost.frame(body)
        XCTAssertEqual(framed.count, 4 + body.count)
        let prefix = [UInt8](framed.prefix(4))
        XCTAssertEqual(ClaudeWebNativeHost.decodeLength(prefix), UInt32(body.count))
        XCTAssertEqual(framed.suffix(body.count), body)
    }
}
