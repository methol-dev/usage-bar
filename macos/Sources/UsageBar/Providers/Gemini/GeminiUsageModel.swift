import Foundation

/// 单个模型的配额条目（`retrieveUserQuota` response 元素）。
struct GeminiPerModelQuota: Decodable, Equatable {
    let model: String
    let remainingFraction: Double
    let resetTime: Date?
    let dailyLimit: Int?

    enum CodingKeys: String, CodingKey {
        case model, remainingFraction, resetTime, dailyLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.remainingFraction = (try? c.decode(Double.self, forKey: .remainingFraction)) ?? 0
        if let s = try? c.decode(String.self, forKey: .resetTime) {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.resetTime = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } else {
            self.resetTime = nil
        }
        self.dailyLimit = try? c.decode(Int.self, forKey: .dailyLimit)
    }

    /// 0...1 fraction → 0...100 used percent。
    var utilizationPct: Double { max(0, min(100, (1.0 - remainingFraction) * 100.0)) }
}

/// `retrieveUserQuota` 响应顶层。
struct GeminiQuotaResponse: Decodable, Equatable {
    let userQuota: [GeminiPerModelQuota]

    enum CodingKeys: String, CodingKey { case userQuota }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userQuota = (try? c.decode([GeminiPerModelQuota].self, forKey: .userQuota)) ?? []
    }
}

extension GeminiQuotaResponse {
    /// 模型名分桶：**Flash 优先匹配**（避免假设性 `gemini-pro-flash` 被 Pro 桶吞掉）；
    /// `flash` 关键词 → Flash 槽；`pro` → Pro 槽；其它 → extraWindows。
    /// 同类多个（如 pro-preview + pro-latest）取第一个，其余进 extraWindows。
    func asProviderSnapshot() -> ProviderUsageSnapshot {
        var pro: GeminiPerModelQuota?
        var flash: GeminiPerModelQuota?
        var extras: [GeminiPerModelQuota] = []
        for q in userQuota {
            let lower = q.model.lowercased()
            // Flash 优先匹配：避免 `gemini-pro-flash` 等假设性命名被 Pro 桶吞掉（G3 reviewer optional 提示）
            if lower.contains("flash") && flash == nil { flash = q }
            else if lower.contains("pro") && pro == nil { pro = q }
            else { extras.append(q) }
        }
        func window(from q: GeminiPerModelQuota?, label: String) -> UsageWindow? {
            guard let q else { return nil }
            return UsageWindow(label: label, utilizationPct: q.utilizationPct, resetsAt: q.resetTime,
                               windowDuration: nil, shortLabel: label)
        }
        let extraWins = extras.map { q in
            NamedUsageWindow(id: q.model, title: q.model, window: UsageWindow(
                label: q.model, utilizationPct: q.utilizationPct, resetsAt: q.resetTime,
                windowDuration: nil, shortLabel: String(q.model.prefix(2))))
        }
        return ProviderUsageSnapshot(
            primaryWindow: window(from: pro, label: "Pro"),
            secondaryWindow: window(from: flash, label: "Flash"),
            extraWindows: extraWins,
            creditLine: nil,
            planLabel: nil   // tier 由 GeminiUsageClient.loadCodeAssist 拿，装配时塞；本 model 层不知道
        )
    }
}
