import XCTest
@testable import ClaudeUsageBar

// 原 `ProviderTab` 枚举已并入 `ProviderID`（v0.2.5 阶段 A0）。
// `isAvailable` 暂仍硬编码 `== .claude`（ProviderTabBar.swift 里的临时扩展）——
// v0.2.5 阶段 C 改由 ProviderRegistry 决定后，本测试的 `isAvailable` 部分会随之调整。
final class ProviderTabTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(ProviderID.allCases, [.claude, .codex, .cursor, .copilot, .gemini])
    }

    func testDisplayNames() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
        XCTAssertEqual(ProviderID.copilot.displayName, "Copilot")
        XCTAssertEqual(ProviderID.gemini.displayName, "Gemini")
    }

    func testIdIsRawValue() {
        XCTAssertEqual(ProviderID.claude.id, "claude")
    }

    func testOnlyClaudeAvailableForNow() {
        XCTAssertTrue(ProviderID.claude.isAvailable)
        for p in ProviderID.allCases where p != .claude {
            XCTAssertFalse(p.isAvailable, "\(p) should not be available yet")
        }
    }
}
