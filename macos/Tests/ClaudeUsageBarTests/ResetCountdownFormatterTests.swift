import XCTest
@testable import ClaudeUsageBar

final class ResetCountdownFormatterTests: XCTestCase {
    func testHourMinute() {
        let now = Date()
        let target = now.addingTimeInterval(3600 + 23 * 60)  // 1h 23m
        XCTAssertEqual(formatResetCountdown(date: target, now: now), "1h 23m")
    }

    func testMinuteOnly() {
        let now = Date()
        let target = now.addingTimeInterval(12 * 60)  // 12m
        XCTAssertEqual(formatResetCountdown(date: target, now: now), "12m")
    }

    func testNilDate() {
        XCTAssertNil(formatResetCountdown(date: nil, now: Date()))
    }

    func testPastDate() {
        let now = Date()
        let target = now.addingTimeInterval(-5 * 60)  // 5m ago
        XCTAssertNil(formatResetCountdown(date: target, now: now))
    }

    func testSubMinute() {
        let now = Date()
        let target = now.addingTimeInterval(30)  // 30s
        XCTAssertEqual(formatResetCountdown(date: target, now: now), "<1m")
    }

    func testExactHour() {
        let now = Date()
        let target = now.addingTimeInterval(3600)  // 60s 边界：1h 0m
        XCTAssertEqual(formatResetCountdown(date: target, now: now), "1h 0m")
    }

    // MARK: - formatResetWithClock

    func testResetWithClock_nil() {
        XCTAssertNil(formatResetWithClock(date: nil, now: Date()))
    }

    func testResetWithClock_expired() {
        let now = Date()
        XCTAssertNil(formatResetWithClock(date: now.addingTimeInterval(-60), now: now))
    }

    func testResetWithClock_underOneDay_appendsClockTime() {
        let now = Date()
        let delta: TimeInterval = 2 * 3600 + 44 * 60  // 2h 44m
        let s = formatResetWithClock(date: now.addingTimeInterval(delta), now: now)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.hasPrefix("2h 44m at "), "got: \(s!)")
        XCTAssertTrue(s!.contains("44"), "got: \(s!)")
    }

    func testResetWithClock_overOneDay_showsDays_noClockTime() {
        let now = Date()
        let delta: TimeInterval = 367_170  // 4d 5h 59m 30s
        let s = formatResetWithClock(date: now.addingTimeInterval(delta), now: now)
        XCTAssertEqual(s, "4 days 5h 59m")
        XCTAssertFalse(s!.contains(" at "))
    }

    func testResetWithClock_exactlyOneDay_singular() {
        let now = Date()
        let delta: TimeInterval = 86400 + 3600  // 1d 1h
        let s = formatResetWithClock(date: now.addingTimeInterval(delta), now: now)
        XCTAssertEqual(s, "1 day 1h 0m")
    }
}
