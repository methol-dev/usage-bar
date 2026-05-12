import Foundation

/// 把 reset 目标时间格式化为 hero / secondary 卡片用的紧凑 countdown。
///
/// - 输出形如 `"1h 23m"`（≥1 小时）/ `"12m"`（仅分钟）/ `"<1m"`（不足 1 分钟）。
/// - `nil` 输入或已过期返回 `nil`，调用方据此隐藏 countdown UI。
func formatResetCountdown(date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = Int(date.timeIntervalSince(now))
    if secs <= 0 { return nil }
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
}

/// 卡片底行 "Resets in:" 文案：
/// - `nil` 或已过期 → `nil`（调用方据此隐藏左半）。
/// - < 24h → `"2h 44m at 11:44 PM"`（`formatResetCountdown` + " at " + 本地化时钟时间）。
/// - ≥ 24h → `"4 days 5h 59m"` / `"1 day 1h 0m"`（自带 days —— `formatResetCountdown` 不含 days）。
func formatResetWithClock(date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = Int(date.timeIntervalSince(now))
    guard secs > 0 else { return nil }
    if secs < 86400 {
        guard let countdown = formatResetCountdown(date: date, now: now) else { return nil }
        let timeStr = date.formatted(.dateTime.hour().minute())
        return "\(countdown) at \(timeStr)"
    }
    let days = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    let dayWord = days == 1 ? "day" : "days"
    return "\(days) \(dayWord) \(h)h \(m)m"
}
