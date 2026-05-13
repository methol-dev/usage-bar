import XCTest
@testable import UsageBar

final class GeminiUsageModelTests: XCTestCase {

    private func decode(_ json: String) throws -> GeminiQuotaResponse {
        try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data(json.utf8))
    }

    func testProAndFlashBothPresent() throws {
        let json = """
        { "userQuota": [
            { "model": "gemini-2.5-pro",   "remainingFraction": 0.7, "resetTime": "2026-05-14T00:00:00Z", "dailyLimit": 1000 },
            { "model": "gemini-2.5-flash", "remainingFraction": 0.4, "resetTime": "2026-05-14T00:00:00Z", "dailyLimit": 1500 }
        ] }
        """
        let resp = try decode(json)
        let snap = resp.asProviderSnapshot()
        // utilizationPct = (1 - remainingFraction) * 100
        XCTAssertEqual(snap.primaryWindow?.utilizationPct ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(snap.primaryWindow?.label, "Pro")
        XCTAssertEqual(snap.primaryWindow?.shortLabel, "Pro")
        XCTAssertNotNil(snap.primaryWindow?.resetsAt)
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct ?? -1, 60, accuracy: 1e-6)
        XCTAssertEqual(snap.secondaryWindow?.label, "Flash")
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }

    func testOnlyProPresent() throws {
        let json = #"{ "userQuota": [{ "model": "gemini-2.5-pro", "remainingFraction": 0.5, "resetTime": "2026-05-14T00:00:00Z" }] }"#
        let snap = try decode(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.utilizationPct ?? -1, 50, accuracy: 1e-6)
        XCTAssertNil(snap.secondaryWindow)
    }

    func testProVariantNamesMatch() throws {
        // 各种 Pro 变体都应被识别为 Pro
        for name in ["gemini-2.5-pro-preview", "gemini-2.5-pro-latest", "gemini-pro"] {
            let json = "{ \"userQuota\": [{ \"model\": \"\(name)\", \"remainingFraction\": 0.5 }] }"
            let snap = try decode(json).asProviderSnapshot()
            XCTAssertNotNil(snap.primaryWindow, "\(name) 应识别为 Pro")
        }
    }

    func testUnknownModelsGoToExtraWindows() throws {
        let json = """
        { "userQuota": [
            { "model": "gemini-2.5-pro", "remainingFraction": 0.5 },
            { "model": "future-mystery-model", "remainingFraction": 0.2 }
        ] }
        """
        let snap = try decode(json).asProviderSnapshot()
        XCTAssertNotNil(snap.primaryWindow)
        XCTAssertEqual(snap.extraWindows.count, 1)
        XCTAssertEqual(snap.extraWindows.first?.title, "future-mystery-model")
    }

    func testEmptyQuotaArray() throws {
        let snap = try decode(#"{ "userQuota": [] }"#).asProviderSnapshot()
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }
}
