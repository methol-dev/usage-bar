import Foundation

/// 网页用量源的本地交接文件读写（ADR 0012 泛化）—— 按 provider id 分文件：
/// `claude-web.json` / `codex-web.json`（`~/.config/usage-bar/<id>-web.json`）。
///
/// 数据流:Chrome 扩展在用户已登录的 provider 网页会话里取用量 → Native Messaging host
/// (`ClaudeWebNativeHost`)按 payload 的 `provider` 字段原子写对应文件 → 各 web provider 读它。
/// app 从不主动 fetch 任何 provider 网页;这里只碰这些交接文件。
///
/// SC7:文件内容只含用量数字 + status,不含 cookie / token。解析全函数化(见各 `*WebPayload.parse`),
/// 文件是同用户可写的非可信边界,畸形 / 恶意 JSON 绝不能崩溃。
enum WebSourceStore {
    /// `~/.config/usage-bar/<id.rawValue>-web.json`。`.claude` → `claude-web.json`（与既有文件一致，零迁移）。
    static func fileURL(for id: ProviderID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar/\(id.rawValue)-web.json")
    }

    /// Native host 侧:原子写入扩展送来的原始 JSON(已由 host 校验为合法 JSON 对象)。
    /// 目录 0700、文件 0600 —— 照抄 `UsageEventStore` / `ScanCursorStore` 写盘范式。
    @discardableResult
    static func writeRaw(_ data: Data, for id: ProviderID) -> Bool {
        let url = fileURL(for: id)
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

    static func readData(for id: ProviderID) -> Data? { try? Data(contentsOf: fileURL(for: id)) }

    /// 交接文件的最后修改时刻（缺失 → nil）—— coordinator 的快 timer 据此紧跟扩展落盘。
    static func modificationDate(for id: ProviderID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL(for: id).path))?[.modificationDate] as? Date
    }
}
