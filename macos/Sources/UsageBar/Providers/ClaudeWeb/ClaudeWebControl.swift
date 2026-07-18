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

/// `~/.config/usage-bar/claude-web-control.json` 的读写(照抄 `ClaudeWebStore` 原子 0600 范式)。
enum ClaudeWebControlStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar/claude-web-control.json")
    }

    /// 原子写(0700 目录 + 0600 文件)。host 只会读到完整文件(write-temp + rename),不会读到半截。
    @discardableResult
    static func write(_ control: ClaudeWebControl) -> Bool {
        guard let data = try? JSONEncoder().encode(control) else { return false }
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
    static func read() -> ClaudeWebControl? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeWebControl.self, from: data)
    }
}
