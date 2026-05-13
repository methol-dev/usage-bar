import Foundation

// MARK: - wham/usage 线缆形状（字段名取自调研 docs/research/codex-data-sources.md §2）

/// Codex ChatGPT 套餐。已知值映射成 case，未知保留原串（不崩）。
enum CodexPlan: Equatable {
    case free, plus, pro, team, business, education, enterprise
    case unknown(String)          // 已知列表外的任意串（空串也走这里）

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "free", "free_workspace": self = .free
        case "plus":       self = .plus
        case "pro":        self = .pro
        case "team":       self = .team
        case "business":   self = .business
        case "education", "edu", "k12": self = .education
        case "enterprise": self = .enterprise
        default:           self = .unknown(rawValue ?? "")   // 注意：保留原始大小写
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .team: return "Team"
        case .business: return "Business"
        case .education: return "Education"
        case .enterprise: return "Enterprise"
        case .unknown(let s): return s.isEmpty ? "Codex" : s.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// 一个额度窗口（5h "session" / 7d "weekly"，由 windowSeconds 区分）。
struct CodexRateWindow: Equatable {
    let usedPercent: Double
    let resetAt: Date
    let windowSeconds: Int

    /// windowSeconds/60 == 300 → 5h；== 10080 → 7d。
    var windowMinutes: Int { windowSeconds / 60 }
    var isSessionWindow: Bool { windowMinutes == 300 }
    var isWeeklyWindow: Bool { windowMinutes == 10080 }
}

struct CodexCredits: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?
}

/// `GET /backend-api/wham/usage` 的响应。子结构解码 try?-tolerant —— 坏一处不整段失败。
struct CodexUsageResponse: Decodable {
    let plan: CodexPlan
    let primaryWindow: CodexRateWindow?
    let secondaryWindow: CodexRateWindow?
    let credits: CodexCredits?

    private enum CodingKeys: String, CodingKey { case planType = "plan_type", rateLimit = "rate_limit", credits }
    private enum RateKeys: String, CodingKey { case primary = "primary_window", secondary = "secondary_window" }
    private enum WindowKeys: String, CodingKey { case usedPercent = "used_percent", resetAt = "reset_at", limitWindowSeconds = "limit_window_seconds" }
    private enum CreditKeys: String, CodingKey { case hasCredits = "has_credits", unlimited, balance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.plan = CodexPlan(rawValue: (try? c.decodeIfPresent(String.self, forKey: .planType)) ?? nil)

        if let rl = try? c.nestedContainer(keyedBy: RateKeys.self, forKey: .rateLimit) {
            self.primaryWindow = Self.decodeWindow(rl, .primary)
            self.secondaryWindow = Self.decodeWindow(rl, .secondary)
        } else {
            self.primaryWindow = nil; self.secondaryWindow = nil
        }

        if let cc = try? c.nestedContainer(keyedBy: CreditKeys.self, forKey: .credits) {
            let balNum: Double? = (try? cc.decodeIfPresent(Double.self, forKey: .balance)) ?? nil
            let balStr: Double? = ((try? cc.decodeIfPresent(String.self, forKey: .balance)) ?? nil).flatMap { Double($0) }
            self.credits = CodexCredits(
                hasCredits: ((try? cc.decodeIfPresent(Bool.self, forKey: .hasCredits)) ?? nil) ?? false,
                unlimited:  ((try? cc.decodeIfPresent(Bool.self, forKey: .unlimited))  ?? nil) ?? false,
                balance: balNum ?? balStr
            )
        } else {
            self.credits = nil
        }
    }

    private static func decodeWindow(_ container: KeyedDecodingContainer<RateKeys>, _ key: RateKeys) -> CodexRateWindow? {
        guard let w = try? container.nestedContainer(keyedBy: WindowKeys.self, forKey: key) else { return nil }
        guard let used = (try? w.decodeIfPresent(Double.self, forKey: .usedPercent)) ?? nil,
              let resetUnix = (try? w.decodeIfPresent(Double.self, forKey: .resetAt)) ?? nil,
              let secs = (try? w.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)) ?? nil else { return nil }
        return CodexRateWindow(usedPercent: used, resetAt: Date(timeIntervalSince1970: resetUnix), windowSeconds: secs)
    }
}

// MARK: - 归一 + 映射到统一 snapshot

extension CodexUsageResponse {
    /// 把 (primary, secondary) 摆正成 (session=短窗口, weekly=长窗口)：
    /// 先按确切的 5h(18000s) / 7d(604800s) 标识；都不匹配时按 windowSeconds 升序取「短=session，长=weekly」。
    func normalizedWindows() -> (session: CodexRateWindow?, weekly: CodexRateWindow?) {
        let all = [primaryWindow, secondaryWindow].compactMap { $0 }
        let exactSession = all.first(where: { $0.isSessionWindow })
        let exactWeekly  = all.first(where: { $0.isWeeklyWindow })
        if exactSession != nil || exactWeekly != nil {
            return (exactSession, exactWeekly)
        }
        // 兜底：按窗口长度升序，短的当 session、长的当 weekly（顺序颠倒也能纠正）。
        let sorted = all.sorted { $0.windowSeconds < $1.windowSeconds }
        return (sorted.first, sorted.dropFirst().first)
    }

    func asProviderSnapshot() -> ProviderUsageSnapshot {
        let (session, weekly) = normalizedWindows()
        func win(_ w: CodexRateWindow?, _ label: String, _ short: String) -> UsageWindow? {
            guard let w else { return nil }
            return UsageWindow(label: label, utilizationPct: w.usedPercent,
                               resetsAt: w.resetAt, windowDuration: TimeInterval(w.windowSeconds), shortLabel: short)
        }
        var credit: CreditLine?
        if let c = credits {
            // 只在「有具体余额」或「unlimited」时显示卡片——避免 has_credits=true 但 balance 缺失时出现空卡。
            let enabled = (c.hasCredits && c.balance != nil) || c.unlimited
            credit = CreditLine(isEnabled: enabled,
                                remainingAmount: c.unlimited ? nil : c.balance,
                                isUnlimited: c.unlimited)
        }
        return ProviderUsageSnapshot(
            primaryWindow: win(session, "Session", "5h"),
            secondaryWindow: win(weekly, "Weekly", "7d"),
            extraWindows: [],
            creditLine: credit,
            planLabel: planLabel
        )
    }

    var planLabel: String? {
        if case .unknown(let s) = plan, s.isEmpty { return nil }
        return plan.displayName
    }
}
