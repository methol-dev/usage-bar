import XCTest
@testable import UsageBar

/// 渠道面板优雅降级：`ProviderUsageArea` 的布局决策 + 未登录提示文案。
/// 背景：订阅用量拿不到时不再整屏替换 —— 有本地数据源（历史折线 / 本机费用）的 provider
/// 保持完整布局（hero 卡骨架化），只有两者皆无的 provider 才显示整屏「未登录」视图。
final class ProviderPanelLayoutTests: XCTestCase {
    func testConfiguredAlwaysShowsFullLayout() {
        XCTAssertTrue(ProviderPanelLayout.showsFullLayout(
            isConfigured: true, hasLocalHistory: false, hasLocalCost: false))
        XCTAssertTrue(ProviderPanelLayout.showsFullLayout(
            isConfigured: true, hasLocalHistory: true, hasLocalCost: true))
    }

    func testUnconfiguredWithLocalDataDegradesInPlace() {
        // Codex：auth.json 缺失但有本地历史/费用 → 仍渲染完整布局（hero 卡骨架化 + 本地图表照常）
        XCTAssertTrue(ProviderPanelLayout.showsFullLayout(
            isConfigured: false, hasLocalHistory: true, hasLocalCost: true))
        XCTAssertTrue(ProviderPanelLayout.showsFullLayout(
            isConfigured: false, hasLocalHistory: true, hasLocalCost: false))
        XCTAssertTrue(ProviderPanelLayout.showsFullLayout(
            isConfigured: false, hasLocalHistory: false, hasLocalCost: true))
    }

    func testUnconfiguredWithoutLocalDataShowsUnconfiguredView() {
        // Gemini：无任何本地数据源 → 维持整屏 ProviderUnconfiguredView
        XCTAssertFalse(ProviderPanelLayout.showsFullLayout(
            isConfigured: false, hasLocalHistory: false, hasLocalCost: false))
    }

    func testSignInHints() {
        XCTAssertEqual(ProviderID.codex.signInHint, "Run `codex` in your terminal, then come back.")
        XCTAssertEqual(ProviderID.gemini.signInHint, "Sign in via the Gemini CLI / app.")
        XCTAssertEqual(ProviderID.claude.signInHint, "Sign in via the Claude CLI / app.")
    }
}
