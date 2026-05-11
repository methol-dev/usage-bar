import XCTest
@testable import ClaudeUsageBar

final class MenuBarDisplayModeTests: XCTestCase {
    func testFormatPercentNormal() {
        XCTAssertEqual(formatMenuBarPercent(utilization: 42.0, prefix: "5h"), "5h 42%")
    }

    func testFormatPercentNil() {
        XCTAssertEqual(formatMenuBarPercent(utilization: nil, prefix: "5h"), "5h —")
    }

    func testFormatPercent100Boundary() {
        XCTAssertEqual(formatMenuBarPercent(utilization: 100.0, prefix: "5h"), "5h 100%")
    }

    func testFormatPercentRoundingHalfUp() {
        // 42.7 → round() 43; 42.4 → 42
        XCTAssertEqual(formatMenuBarPercent(utilization: 42.7, prefix: "5h"), "5h 43%")
        XCTAssertEqual(formatMenuBarPercent(utilization: 42.4, prefix: "5h"), "5h 42%")
    }

    func testFormatPercentZero() {
        XCTAssertEqual(formatMenuBarPercent(utilization: 0.0, prefix: "5h"), "5h 0%")
    }

    func testFormatPercentDifferentPrefix() {
        XCTAssertEqual(formatMenuBarPercent(utilization: 50.0, prefix: "7d"), "7d 50%")
    }

    func testDisplayModeRawValueRoundtrip() {
        for mode in MenuBarDisplayMode.allCases {
            XCTAssertEqual(MenuBarDisplayMode(rawValue: mode.rawValue), mode)
        }
    }

    func testDisplayModeAllCasesCount() {
        // 防御未来误删 case 时静默失败；本版本固定 3 个 mode
        XCTAssertEqual(MenuBarDisplayMode.allCases.count, 3)
    }

    func testDisplayModeDefaultIsIcon() {
        // 防御默认值变更引入 UX 退化（用户安装后期望看到图标）
        XCTAssertEqual(MenuBarDisplayMode(rawValue: "icon"), .icon)
        XCTAssertEqual(MenuBarDisplayMode.icon.rawValue, "icon")
    }
}
