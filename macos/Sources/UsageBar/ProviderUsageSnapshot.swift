import Foundation

/// 一个滚动额度窗口的「provider 无关」统一形状。
///
/// 各 provider 的原生 API 形状（Claude 的 `UsageBucket`、Codex 的 `wham/usage` window 等）
/// 由该 provider 的实现映射到这里；菜单栏 / popover 用量区只认本类型。
struct UsageWindow: Equatable {
    /// 窗口标题（如 `"Session"` / `"Weekly"`）。nil = 调用方自己决定文案。
    var label: String?
    /// 菜单栏用的短标签（≤3 字符，如 `"5h"` / `"7d"`）。默认取 `label` 前 2 字符。
    var shortLabel: String
    /// 已用百分比，`0...100`（与 Claude `UsageBucket.utilization` 同语义）。nil = 无数据。
    var utilizationPct: Double?
    /// 窗口重置的绝对时刻。nil = 未知。
    var resetsAt: Date?
    /// 窗口总长（秒）—— 用于算「此刻匀速应该用到多少 %」的 pace 标记。nil = 不画 pace。
    var windowDuration: TimeInterval?

    init(label: String? = nil,
         utilizationPct: Double? = nil,
         resetsAt: Date? = nil,
         windowDuration: TimeInterval? = nil,
         shortLabel: String? = nil) {
        self.label = label
        self.shortLabel = shortLabel ?? (label.map { String($0.prefix(2)) } ?? "")
        self.utilizationPct = utilizationPct
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
    }
}

/// 带稳定 id + 标题的窗口（承载 Claude 的 per-model 行 Opus/Sonnet 等）。
struct NamedUsageWindow: Equatable, Identifiable {
    var id: String
    var title: String
    var window: UsageWindow
}

/// 「按量计费 / 额外用量」统一行 —— 覆盖 Claude 的 `extra_usage` 与 Codex 的 `credits`。
/// 金额一律已换算成货币单位（元 / 美元），不是分。
struct CreditLine: Equatable {
    /// 该计费方式是否启用 / 有余额。false → 调用方不渲染本行。
    var isEnabled: Bool
    /// 已用百分比 `0...100`（若 provider 提供）。
    var utilizationPct: Double?
    /// 已用金额（货币单位）—— Claude `extra_usage`。
    var usedAmount: Double?
    /// 上限金额（货币单位）—— Claude `extra_usage`。
    var limitAmount: Double?
    /// 剩余余额（货币单位）—— Codex `credits.balance`。与「已用/上限」语义不同，单列。
    var remainingAmount: Double?
    /// 无限额度 —— Codex `credits.unlimited`。
    var isUnlimited: Bool

    init(isEnabled: Bool,
         utilizationPct: Double? = nil,
         usedAmount: Double? = nil,
         limitAmount: Double? = nil,
         remainingAmount: Double? = nil,
         isUnlimited: Bool = false) {
        self.isEnabled = isEnabled
        self.utilizationPct = utilizationPct
        self.usedAmount = usedAmount
        self.limitAmount = limitAmount
        self.remainingAmount = remainingAmount
        self.isUnlimited = isUnlimited
    }
}

/// 一次「拉取用量」的统一结果。`UsageProvider.refreshNow()` 把它写进自己的 `ProviderRuntime`。
struct ProviderUsageSnapshot: Equatable {
    /// 主窗口（Claude 的 5 小时 / Codex 的 session）。
    var primaryWindow: UsageWindow?
    /// 次窗口（Claude 的 7 天 / Codex 的 weekly）。
    var secondaryWindow: UsageWindow?
    /// 额外窗口（Claude 的 per-model Opus/Sonnet 等）。空数组 = 无。
    var extraWindows: [NamedUsageWindow]
    /// 按量计费行（Claude 的 extra usage / Codex 的 credits）。
    var creditLine: CreditLine?
    /// 套餐标签（如 `"Plus"` / `"Pro"`）。Claude 暂无 → nil。
    var planLabel: String?

    init(primaryWindow: UsageWindow? = nil,
         secondaryWindow: UsageWindow? = nil,
         extraWindows: [NamedUsageWindow] = [],
         creditLine: CreditLine? = nil,
         planLabel: String? = nil) {
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.extraWindows = extraWindows
        self.creditLine = creditLine
        self.planLabel = planLabel
    }
}
