import Foundation

enum PaceState: Equatable {
    case onPace
    case inDeficit(percentOver: Int, runsOutIn: TimeInterval)
    case inReserve(percentUnder: Int)
}

/// 计算 5h 窗口配速状态。
///
/// 算法：
/// 1. timeToReset = resetDate - now；≤ 0（reset 已过）→ .onPace（容错降级）
/// 2. windowStart = resetDate - windowDuration；elapsed = now - windowStart
/// 3. elapsedFraction < 0.03 → 返回 nil（早期窗口噪声大，隐藏避免抖动）
/// 4. expected_pct = elapsedFraction * 100（均匀消耗预期）
/// 5. |deviation| < 3pp → .onPace
/// 6. deviation > 0：rate = currentPct / elapsed (pct/sec)；runsOutIn = (100 - currentPct) / rate
///    runsOutIn ≥ timeToReset → .onPace（按当前 rate 能撑到 reset）
///    否则 → .inDeficit
/// 7. deviation < 0 → .inReserve
///
/// edge case: currentPct=100 → runsOutIn=0 → .inDeficit(runsOutIn:0)，UI
/// 层 formatResetCountdown(0) 返回 nil，显示 "runs out in —"。
func computePaceState(
    currentPct: Double?,
    resetDate: Date?,
    windowDuration: TimeInterval = 5 * 3600,
    now: Date = Date()
) -> PaceState? {
    guard let current = currentPct, let reset = resetDate else { return nil }
    let timeToReset = reset.timeIntervalSince(now)
    // reset 已过统一早退为 .onPace，避免 deviation<0 时误返回 .inReserve（G2 修订）
    guard timeToReset > 0 else { return .onPace }
    let windowStart = reset.addingTimeInterval(-windowDuration)
    let elapsed = now.timeIntervalSince(windowStart)
    guard elapsed > 0 else { return nil }
    let elapsedFraction = elapsed / windowDuration
    guard elapsedFraction >= 0.03 else { return nil }
    let expectedPct = elapsedFraction * 100.0
    let deviation = current - expectedPct
    let absDeviation = abs(deviation)
    if absDeviation < 3.0 { return .onPace }
    if deviation > 0 {
        let rate = current / elapsed
        guard rate > 0 else { return .onPace }
        let remaining = 100.0 - current
        let runsOutIn = remaining / rate
        if runsOutIn >= timeToReset { return .onPace }
        return .inDeficit(percentOver: Int(absDeviation.rounded()), runsOutIn: runsOutIn)
    } else {
        return .inReserve(percentUnder: Int(absDeviation.rounded()))
    }
}
