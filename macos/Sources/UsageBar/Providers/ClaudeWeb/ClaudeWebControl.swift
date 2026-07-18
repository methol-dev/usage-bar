import Foundation

/// 主程序 → 扩展的「控制配置」(ADR 0011 反向控制通道)。
///
/// 扩展每 ~1min 轮询 host 拉本配置;host 读本文件原文回传(不解析业务)。扩展据此:
/// - `paused`：停止 claude.ai 取数(app 里 Claude 或其 Web 源被关时);
/// - `syncNonce`：app 端「Refresh」时自增 → 扩展见变化即立即取数一次(app 控制扩展的闭环);
/// - `intervalSeconds`：自主取数节奏(跟随 app 轮询间隔);
/// - `ts`：写入时刻(epoch 秒)—— liveness。app 关/崩后文件不再刷新,扩展据陈旧判定「无人在世」→ 休眠。
///
/// 文件同用户可写、非权限边界(同 `claude-web.json` 威胁模型);只含配置数字,无 cookie/凭证(SC7)。
struct ClaudeWebControl: Codable, Equatable {
    var paused: Bool
    var intervalSeconds: Int
    var syncNonce: Int
    var ts: Double
}

/// 多 provider 控制信封（ADR 0012）—— 一个扩展同时管 claude.ai 与 chatgpt.com，一次 poll 要拿到
/// **两个** provider 的控制配置，故 host 回传的 control 文件是本信封。
///
/// 顶层 `paused/intervalSeconds/syncNonce/ts` = **Claude 的**控制（向后兼容：旧扩展只读顶层扁平字段即得
/// Claude 配置，行为不变）；`byProvider` 携带每个 web-capable provider 的独立控制（`claude` / `codex`）。
/// 新扩展按 `byProvider[provider]` 取,缺失时对 Claude 回退顶层扁平字段、对其它 provider 视为「本 app 不支持」。
struct WebControlEnvelope: Codable, Equatable {
    var paused: Bool
    var intervalSeconds: Int
    var syncNonce: Int
    var ts: Double
    var byProvider: [String: ClaudeWebControl]
}

/// `~/.config/usage-bar/claude-web-control.json` 的读写(照抄 `ClaudeWebStore` 原子 0600 范式)。
enum ClaudeWebControlStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar/claude-web-control.json")
    }

    /// 原子写(0700 目录 + 0600 文件)。host 只会读到完整文件(write-temp + rename),不会读到半截。
    @discardableResult
    static func writeEnvelope(_ envelope: WebControlEnvelope) -> Bool {
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// 全函数化解码(缺失 / 畸形 → nil,不崩)。
    static func read() -> WebControlEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WebControlEnvelope.self, from: data)
    }
}
