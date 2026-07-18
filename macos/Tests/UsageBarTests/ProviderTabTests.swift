import XCTest
@testable import UsageBar

// 原 `ProviderTab` / `UsageProvider` 枚举已并入 `ProviderID`（v0.2.5）。
// 「某 provider 是否可用」现在由 `ProviderRegistry.availableIDs` 决定 ——
// 见 `ProviderAbstractionTests.testRegistryClaudeOnly` / `testCoordinator...`。
final class ProviderTabTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(ProviderID.allCases, [.claude, .codex, .cursor, .copilot, .gemini, .claudeWeb])
    }

    func testDisplayNames() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
        XCTAssertEqual(ProviderID.copilot.displayName, "Copilot")
        XCTAssertEqual(ProviderID.gemini.displayName, "Gemini")
        XCTAssertEqual(ProviderID.claudeWeb.displayName, "Claude Web")   // 驼峰/连字符需 override
    }

    func testIdIsRawValue() {
        XCTAssertEqual(ProviderID.claude.id, "claude")
        XCTAssertEqual(ProviderID(rawValue: "codex"), .codex)
        XCTAssertEqual(ProviderID.claudeWeb.id, "claude-web")           // rawValue = 磁盘目录名
        XCTAssertEqual(ProviderID(rawValue: "claude-web"), .claudeWeb)
    }
}
