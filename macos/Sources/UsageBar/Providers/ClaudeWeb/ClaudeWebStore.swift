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
    /// ADR 0012 起统一由 `WebSourceStore` 定义路径 —— 这里委托给它，避免路径字符串两处漂移。
    static var fileURL: URL { WebSourceStore.fileURL(for: .claude) }

    static func readData() -> Data? { WebSourceStore.readData(for: .claude) }
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
