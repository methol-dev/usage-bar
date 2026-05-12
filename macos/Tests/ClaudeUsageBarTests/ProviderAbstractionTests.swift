import XCTest
@testable import ClaudeUsageBar

/// v0.2.5 多供应商架构重构 —— 统一模型 + Claude 映射的测试。
/// （阶段 A2 会往本文件追加 registry/coordinator/runtime/spy 用例。）
final class ProviderAbstractionTests: XCTestCase {

    private func decodeUsage(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    // MARK: - UsageResponse → ProviderUsageSnapshot 映射（SC5-b：等价于重构前后字段快照对比）

    func testMapFullFixture() throws {
        let json = """
        {
          "five_hour":       { "utilization": 42.0, "resets_at": "2099-01-01T23:44:00Z" },
          "seven_day":       { "utilization": 73.0, "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_opus":  { "utilization": 12.5, "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_sonnet":{ "utilization": 5.0,  "resets_at": "2099-01-08T00:00:00Z" },
          "extra_usage":     { "is_enabled": true, "utilization": 30.0, "used_credits": 1469, "monthly_limit": 5000 }
        }
        """
        let snap = try decodeUsage(json).asProviderSnapshot()

        XCTAssertEqual(snap.primaryWindow?.label, "Session")
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 42.0)
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 5 * 60 * 60)
        XCTAssertNotNil(snap.primaryWindow?.resetsAt)

        XCTAssertEqual(snap.secondaryWindow?.label, "Weekly")
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct, 73.0)
        XCTAssertEqual(snap.secondaryWindow?.windowDuration, 7 * 24 * 60 * 60)

        XCTAssertEqual(snap.extraWindows.map(\.id), ["opus", "sonnet"])
        XCTAssertEqual(snap.extraWindows.map(\.title), ["Opus", "Sonnet"])
        XCTAssertEqual(snap.extraWindows.first?.window.utilizationPct, 12.5)
        XCTAssertEqual(snap.extraWindows.last?.window.utilizationPct, 5.0)
        XCTAssertEqual(snap.extraWindows.first?.window.windowDuration, 7 * 24 * 60 * 60)

        XCTAssertEqual(snap.creditLine?.isEnabled, true)
        XCTAssertEqual(snap.creditLine?.utilizationPct, 30.0)
        // 分 → 元换算：1469 分 → 14.69 元；5000 分 → 50.00 元
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.usedAmount), 14.69, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.limitAmount), 50.0, accuracy: 1e-9)

        XCTAssertNil(snap.planLabel)
    }

    func testMapResetAtIsParsedToDate() throws {
        let json = #"{ "five_hour": { "utilization": 10.0, "resets_at": "2099-01-01T23:44:00Z" } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        let expected = ISO8601DateFormatter().date(from: "2099-01-01T23:44:00Z")
        XCTAssertEqual(snap.primaryWindow?.resetsAt, expected)
    }

    func testMapMissingFields() throws {
        let json = #"{ "five_hour": { "utilization": 20.0 } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 20.0)
        XCTAssertNil(snap.primaryWindow?.resetsAt)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
        XCTAssertNil(snap.creditLine)
        XCTAssertNil(snap.planLabel)
    }

    func testMapEmptyResponse() throws {
        let snap = try decodeUsage("{}").asProviderSnapshot()
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
        XCTAssertNil(snap.creditLine)
    }

    /// 保留旧 popover 逻辑：Opus 行只在 `seven_day_opus.utilization != nil` 时显示；
    /// Opus 不显示则 Sonnet 也不显示。
    func testMapOpusWithoutUtilizationExcludesPerModel() throws {
        let json = """
        {
          "seven_day_opus":  { "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_sonnet":{ "utilization": 5.0, "resets_at": "2099-01-08T00:00:00Z" }
        }
        """
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }

    func testMapExtraUsageDisabled() throws {
        let json = #"{ "extra_usage": { "is_enabled": false } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertEqual(snap.creditLine?.isEnabled, false)
        XCTAssertNil(snap.creditLine?.usedAmount)
        XCTAssertNil(snap.creditLine?.limitAmount)
    }
}
