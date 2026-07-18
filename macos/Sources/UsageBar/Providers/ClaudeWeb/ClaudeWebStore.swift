import Foundation

/// Claude Web 源的本地交接文件读写。
///
/// 数据流:Chrome 扩展在用户 claude.ai 会话里取用量 → Native Messaging host
/// (`ClaudeWebNativeHost`)原子写本文件 → `ClaudeWebProvider` 在轮询 tick 读它。
/// app 从不主动 fetch claude.ai;这里只碰这一个文件。
///
/// SC7:文件内容只含用量数字 + status,不含 cookie / token。解析全函数化(见 `ClaudeWebPayload.parse`),
/// 文件是同用户可写的非可信边界,畸形 / 恶意 JSON 绝不能崩溃。
enum ClaudeWebStore {
    /// `~/.config/usage-bar/claude-web.json`(与 history.json 等同目录)。
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar/claude-web.json")
    }

    /// Native host 侧:原子写入扩展送来的原始 JSON(已由 host 校验为合法 JSON 对象)。
    /// 目录 0700、文件 0600 —— 照抄 `UsageEventStore` / `ScanCursorStore` 写盘范式。
    @discardableResult
    static func writeRaw(_ data: Data) -> Bool {
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

    static func readData() -> Data? { try? Data(contentsOf: fileURL) }
}

/// provider 侧读取抽象 —— 单测注入内存 stub,避免依赖真实 `~/.config/`。
protocol ClaudeWebLoading {
    func load() -> ClaudeWebPayload?
}

struct ClaudeWebFileLoader: ClaudeWebLoading {
    func load() -> ClaudeWebPayload? {
        guard let data = ClaudeWebStore.readData() else { return nil }
        return ClaudeWebPayload.parse(data)
    }
}
