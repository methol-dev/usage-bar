import XCTest
@testable import UsageBar

/// ClaudeWebUsageMapper 定稿测试 —— 依据 owner 抓取的真实 claude.ai /usage 响应(2026-07)。
final class ClaudeWebMapperTests: XCTestCase {

    private func usage(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// owner 抓到的真实样本(截断无关的花名字段,保留结构)。
    private let realSample = """
    {
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null},
      "five_hour": {"resets_at": "2026-07-18T16:09:59.774291+00:00", "utilization": 4},
      "seven_day": {"resets_at": "2026-07-21T02:59:59.774313+00:00", "utilization": 29},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "spend": {"enabled": false, "percent": 0, "used": {"amount_minor": 0, "currency": "USD", "exponent": 2}}
    }
    """

    func testRealSampleMapsPrimaryAndSecondary() throws {
        let snap = try XCTUnwrap(ClaudeWebUsageMapper.snapshot(from: usage(realSample)))
        XCTAssertEqual(snap.primaryWindow?.label, "Session")
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 4)
        XCTAssertEqual(snap.primaryWindow?.shortLabel, "5h")
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 5 * 60 * 60)
        XCTAssertNotNil(snap.primaryWindow?.resetsAt, "6 位小数秒的 resets_at 应能解析")

        XCTAssertEqual(snap.secondaryWindow?.label, "Weekly")
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct, 29)
        XCTAssertEqual(snap.secondaryWindow?.windowDuration, 7 * 24 * 60 * 60)

        XCTAssertTrue(snap.extraWindows.isEmpty, "opus/sonnet 为 null → 无 per-model 行")
        XCTAssertNil(snap.creditLine, "extra_usage 未启用 + spend 未启用/为 0 → 无额度线")
    }

    func testResetsAtSixDigitFractionParses() throws {
        let snap = try XCTUnwrap(ClaudeWebUsageMapper.snapshot(from: usage(realSample)))
        let expected = ISO8601DateFormatter().date(from: "2026-07-18T16:09:59+00:00")
        XCTAssertEqual(snap.primaryWindow?.resetsAt, expected, "剥掉 .774291 后应等于整秒时刻")
    }

    func testPerModelWindowsWhenPresent() throws {
        let json = """
        {
          "five_hour": {"utilization": 10},
          "seven_day_opus": {"utilization": 12.5, "resets_at": "2026-07-21T02:59:59+00:00"},
          "seven_day_sonnet": {"utilization": 5}
        }
        """
        let snap = try XCTUnwrap(ClaudeWebUsageMapper.snapshot(from: usage(json)))
        XCTAssertEqual(snap.extraWindows.map(\.id), ["opus", "sonnet"])
        XCTAssertEqual(snap.extraWindows.map(\.title), ["Opus", "Sonnet"])
        XCTAssertEqual(snap.extraWindows.first?.window.utilizationPct, 12.5)
    }

    func testExtraUsageEnabledMapsCreditLine() throws {
        let json = """
        { "five_hour": {"utilization": 1},
          "extra_usage": {"is_enabled": true, "utilization": 30, "used_credits": 1469, "monthly_limit": 5000} }
        """
        let snap = try XCTUnwrap(ClaudeWebUsageMapper.snapshot(from: usage(json)))
        XCTAssertEqual(snap.creditLine?.isEnabled, true)
        XCTAssertEqual(snap.creditLine?.utilizationPct, 30)
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.usedAmount), 14.69, accuracy: 1e-9)  // 分→元
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.limitAmount), 50.0, accuracy: 1e-9)
    }

    func testSpendFallbackWhenEnabled() throws {
        let json = """
        { "five_hour": {"utilization": 1},
          "spend": {"enabled": true, "percent": 12, "used": {"amount_minor": 250, "exponent": 2}} }
        """
        let snap = try XCTUnwrap(ClaudeWebUsageMapper.snapshot(from: usage(json)))
        XCTAssertEqual(snap.creditLine?.isEnabled, true)
        XCTAssertEqual(snap.creditLine?.utilizationPct, 12)
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.usedAmount), 2.50, accuracy: 1e-9)  // 250 minor / 10^2
    }

    func testEmptyOrUnmappableReturnsNil() throws {
        XCTAssertNil(ClaudeWebUsageMapper.snapshot(from: [:]))
        XCTAssertNil(ClaudeWebUsageMapper.snapshot(from: nil))
        // 只有花名 null 字段、无任何窗口 → nil
        XCTAssertNil(ClaudeWebUsageMapper.snapshot(from: try usage(#"{"amber_ladder": null, "tangelo": null}"#)))
    }
}
