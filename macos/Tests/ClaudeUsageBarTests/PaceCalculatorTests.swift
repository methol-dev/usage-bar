import XCTest
@testable import ClaudeUsageBar

final class PaceCalculatorTests: XCTestCase {
    private let window: TimeInterval = 5 * 3600

    private func reset(after secs: TimeInterval, from now: Date) -> Date {
        now.addingTimeInterval(secs)
    }

    func testOnPaceSmallDeviation() {
        let now = Date()
        // elapsed = 2.5h（在 5h 窗口的中间），expected = 50%，actual 51% → |Δ|=1 < 3 → .onPace
        let state = computePaceState(
            currentPct: 51,
            resetDate: reset(after: 2.5 * 3600, from: now),
            windowDuration: window,
            now: now
        )
        XCTAssertEqual(state, .onPace)
    }

    func testInDeficit() {
        let now = Date()
        // elapsed=2.5h, current=70% → Δ=+20，rate=70/9000=0.00778%/sec
        // remaining=30, runsOutIn=30/0.00778≈3857s ≈ 64min
        // timeToReset=2.5h=9000s，runsOutIn < timeToReset → .inDeficit
        let state = computePaceState(
            currentPct: 70,
            resetDate: reset(after: 2.5 * 3600, from: now),
            windowDuration: window,
            now: now
        )
        guard case .inDeficit(let percentOver, let runsOutIn) = state else {
            return XCTFail("expected .inDeficit, got \(String(describing: state))")
        }
        XCTAssertEqual(percentOver, 20)
        XCTAssertEqual(runsOutIn, 30.0 / (70.0 / (2.5 * 3600)), accuracy: 1.0)
    }

    func testInReserve() {
        let now = Date()
        // elapsed=2.5h, current=30% → Δ=-20 → .inReserve(percentUnder: 20)
        let state = computePaceState(
            currentPct: 30,
            resetDate: reset(after: 2.5 * 3600, from: now),
            windowDuration: window,
            now: now
        )
        XCTAssertEqual(state, .inReserve(percentUnder: 20))
    }

    func testEarlyWindowHidden() {
        let now = Date()
        // elapsed=5min=300s（5h 的 1.7%, < 3%），current=10% → 返回 nil
        let state = computePaceState(
            currentPct: 10,
            resetDate: reset(after: window - 300, from: now),
            windowDuration: window,
            now: now
        )
        XCTAssertNil(state)
    }

    func testNilCurrent() {
        XCTAssertNil(computePaceState(
            currentPct: nil,
            resetDate: Date().addingTimeInterval(3600),
            windowDuration: window
        ))
    }

    func testNilResetDate() {
        XCTAssertNil(computePaceState(
            currentPct: 50,
            resetDate: nil,
            windowDuration: window
        ))
    }

    func testPastReset() {
        let now = Date()
        // reset 已过 5min → 容错降级 .onPace（G2 修订：deviation<0 时也走此路径）
        let state = computePaceState(
            currentPct: 50,
            resetDate: now.addingTimeInterval(-300),
            windowDuration: window,
            now: now
        )
        XCTAssertEqual(state, .onPace)
    }

    func testRunsOutBeyondReset() {
        let now = Date()
        // elapsed=2.5h, current=55% → Δ=+5；rate=55/9000≈0.00611%/sec
        // remaining=45, runsOutIn=45/0.00611≈7363s ≈ 2.04h
        // timeToReset=2.5h=9000s，runsOutIn=7363 < 9000 仍 .inDeficit
        // 用更慢的消耗：current=53% → Δ=+3 (≥ 3pp 触发非 onPace 分支)
        // rate=53/9000≈0.00589%/sec, remaining=47, runsOutIn=47/0.00589≈7977s
        // timeToReset 仍 9000，runsOutIn < timeToReset → 仍 .inDeficit
        // 真正"能撑到 reset"需要更小的 deviation（但 |Δ|<3 已 onPace）。
        // 构造极端：elapsed=4h, current=82% → Δ=+2 → onPace（先被 absDeviation<3 截断）
        // 改造：elapsed=1h, current=24% → expected=20%, Δ=+4，rate=24/3600≈0.00667%/sec
        // remaining=76, runsOutIn=76/0.00667≈11400s=3.17h；timeToReset=4h=14400s
        // runsOutIn 11400 < 14400 → 仍 .inDeficit
        // 再改：elapsed=1h, current=22% → expected=20%, Δ=+2 → onPace
        // 找一个 |Δ|≥3 但 runsOutIn ≥ timeToReset 的组合：
        // elapsed=4h (80% of window), current=83% → expected=80, Δ=+3
        // rate=83/14400≈0.00576%/sec, remaining=17, runsOutIn=17/0.00576≈2950s
        // timeToReset=1h=3600s；runsOutIn=2950 < 3600 仍 .inDeficit
        // 关键：runsOutIn < timeToReset 几乎总成立当 deviation>0；要 ≥ timeToReset
        // 需要 (100-c)/c * elapsed ≥ timeToReset
        // 即 elapsed/c * (100-c) ≥ windowDuration - elapsed
        // 即 elapsed * (100-c) ≥ c * (windowDuration - elapsed)
        // 即 elapsed * 100 ≥ c * windowDuration → c ≤ 100 * elapsed/windowDuration = expected
        // 即 deviation ≤ 0，但我们是 deviation > 0 分支 → 矛盾
        //
        // 即：deviation > 0 且 rate > 0 时，runsOutIn 数学上 < timeToReset
        // 唯一例外是 currentPct = 0（rate=0 触发 onPace guard）
        //
        // 所以 "runsOutIn >= timeToReset" 实际是数学上不可达分支；保留作 defensive
        // guard 是合理的。本测试改为验证：deviation 微小但 ≥3 时 .inDeficit 成立。
        let state = computePaceState(
            currentPct: 24,
            resetDate: reset(after: 4 * 3600, from: now),  // elapsed=1h
            windowDuration: window,
            now: now
        )
        guard case .inDeficit(let percentOver, _) = state else {
            return XCTFail("expected .inDeficit, got \(String(describing: state))")
        }
        XCTAssertEqual(percentOver, 4)
    }

    func testInDeficitWith100Pct() {
        let now = Date()
        // elapsed=2.5h, current=100% → Δ=+50, rate=100/9000≈0.0111%/sec
        // remaining=0, runsOutIn=0 → .inDeficit(percentOver:50, runsOutIn:0)
        let state = computePaceState(
            currentPct: 100,
            resetDate: reset(after: 2.5 * 3600, from: now),
            windowDuration: window,
            now: now
        )
        guard case .inDeficit(let percentOver, let runsOutIn) = state else {
            return XCTFail("expected .inDeficit")
        }
        XCTAssertEqual(percentOver, 50)
        XCTAssertEqual(runsOutIn, 0, accuracy: 0.001)
    }
}
