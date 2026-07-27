import XCTest
@testable import UsageBar

// 原 `ProviderTab` / `UsageProvider` 枚举已并入 `ProviderID`（v0.2.5）。
// 「某 provider 是否可用」现在由 `ProviderRegistry.availableIDs` 决定 ——
// 见 `ProviderAbstractionTests.testRegistryClaudeOnly` / `testCoordinator...`。
final class ProviderTabTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(ProviderID.allCases, [.claude, .codex, .cursor, .copilot, .gemini, .claudeWeb, .codexWeb])
    }

    func testDisplayNames() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
        XCTAssertEqual(ProviderID.copilot.displayName, "Copilot")
        XCTAssertEqual(ProviderID.gemini.displayName, "Gemini")
        XCTAssertEqual(ProviderID.claudeWeb.displayName, "Claude Web")   // 驼峰/连字符需 override
        XCTAssertEqual(ProviderID.codexWeb.displayName, "Codex Web")
    }

    func testIdIsRawValue() {
        XCTAssertEqual(ProviderID.claude.id, "claude")
        XCTAssertEqual(ProviderID(rawValue: "codex"), .codex)
        XCTAssertEqual(ProviderID.claudeWeb.id, "claude-web")           // rawValue = 磁盘目录名
        XCTAssertEqual(ProviderID(rawValue: "claude-web"), .claudeWeb)
    }

    // MARK: - 未配置提示文案按数据源择取

    private let webOnly: Set<UsageSource> = [.web]
    private let cliOnly: Set<UsageSource> = [.cli]
    private let bothSources: Set<UsageSource> = [.web, .cli]

    // 只启用 Web 源 → 给 Web 视角的引导；让 web-only 用户去装 CLI 是答非所问。
    func testWebOnlyUsesWebHint() {
        XCTAssertEqual(ProviderSignInHint.text(for: .codex, enabledSources: webOnly),
                       ProviderID.codexWeb.signInHint)
        XCTAssertEqual(ProviderSignInHint.text(for: .claude, enabledSources: webOnly),
                       ProviderID.claudeWeb.signInHint)
    }

    // 启用了 CLI（含双源）→ 维持 CLI 文案：CLI 才是能靠用户自己动手恢复的那条路。
    func testCLIEnabledKeepsCLIHint() {
        XCTAssertEqual(ProviderSignInHint.text(for: .codex, enabledSources: cliOnly), ProviderID.codex.signInHint)
        XCTAssertEqual(ProviderSignInHint.text(for: .codex, enabledSources: bothSources), ProviderID.codex.signInHint)
    }

    // 源信息缺失（单源 provider，如 Gemini）→ 原样回退，不臆造 Web 引导。
    func testUnknownSourcesFallsBackToDefaultHint() {
        XCTAssertEqual(ProviderSignInHint.text(for: .gemini, enabledSources: nil), ProviderID.gemini.signInHint)
        XCTAssertEqual(ProviderSignInHint.text(for: .gemini, enabledSources: webOnly), ProviderID.gemini.signInHint)
    }
}
