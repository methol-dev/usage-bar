import Foundation
import Security
import LocalAuthentication

struct ClaudeCLICredentialsStrategy: ClaudeUsageStrategy {
    static let serviceName = "Claude Code-credentials"

    /// Claude CLI 的文件凭证（`claude` 在部分环境/版本不写 Keychain 而写这个文件；
    /// schema 与 Keychain payload 相同）。Keychain 读不到或 decode 失败时作为回退源。
    /// `CLAUDE_CONFIG_DIR` 设了就用 `$CLAUDE_CONFIG_DIR/.credentials.json`（与 Claude CLI 一致；
    /// `environment` 注入以便测试 —— 同 `CodexCredentialStore.authFileURL` 模式）。
    static func defaultCredentialsFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dir: URL
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            dir = URL(fileURLWithPath: configDir, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        }
        return dir.appendingPathComponent(".credentials.json")
    }

    /// `internal` + 可注入 —— 单测用临时文件替换，避免依赖真实 `~/.claude/`。
    var credentialsFileURL: URL = ClaudeCLICredentialsStrategy.defaultCredentialsFileURL()

    /// Keychain JSON 顶层 schema (实测自 macOS 14 Claude CLI)：
    /// { "claudeAiOauth": { accessToken, refreshToken?, expiresAt(ms), scopes? },
    ///   "mcpOAuth": { ... } }  // mcpOAuth 不读
    /// `internal` 而非 `private` — 让 @testable import 单测能直接 decode 验证 schema
    /// 而无需 Keychain 实测。
    struct KeychainPayload: Decodable {
        let claudeAiOauth: ClaudeOauth

        struct ClaudeOauth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Int64?  // ms timestamp
            let scopes: [String]?
        }
    }

    /// SC7 安全约束：CustomStringConvertible 仅输出 case 名，不带 OSStatus
    /// 数值（避免日志聚合工具二次解析数值码暴露异常类型分布）
    enum LoadError: Error, CustomStringConvertible {
        case keychainQueryFailed
        case payloadDecodeFailed

        var description: String {
            switch self {
            case .keychainQueryFailed: return "keychainQueryFailed"
            case .payloadDecodeFailed: return "payloadDecodeFailed"
            }
        }
    }

    /// 协议要求的入口 —— 等价于 `loadCredentials(allowInteraction: true)`（前台可弹 ACL）。
    func loadCredentials() async throws -> StoredCredentials? {
        try await loadCredentials(allowInteraction: true)
    }

    /// - Parameter allowInteraction: `false` 时给 query 挂一个 `interactionNotAllowed` 的 `LAContext` ——
    ///   `SecItemCopyMatching` 不弹 ACL 授权框、直接返回 `errSecInteractionNotAllowed`（下面 switch 已把它降级为
    ///   返回 nil）。v0.2.7：`expireSession` 走的 Keychain 恢复读取可能发生在后台 polling 里，绝不能弹框 → 传 false；
    ///   App 启动 / Retry 按钮路径（`UsageService.retrySignIn`）沿用 `loadCredentials()` = true，允许弹一次 ACL。
    func loadCredentials(allowInteraction: Bool) async throws -> StoredCredentials? {
        // G3 B1 修订：SecItemCopyMatching 是同步 blocking C API；用 Task.detached
        // 把它挪到后台线程，避免主线程阻塞（首次 ACL 弹窗时尤其重要）
        let queryResult: (status: OSStatus, item: AnyObject?) = await Task.detached {
            var query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.serviceName,
                kSecAttrAccount: NSUserName(),  // G2 E 修订：补 account 防 multi-account 顺序歧义
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            if !allowInteraction {
                // 非交互式：不允许弹 ACL 授权框（后台 polling 安全）。用 LAContext.interactionNotAllowed
                // 而非已弃用的 kSecUseAuthenticationUIFail。
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext] = context
            }
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        }.value

        // Keychain 读取结果分类，除「成功且可解析」与「用户明确拒绝」外都尝试文件回退：
        // Claude Code 2.1.x 起该 Keychain 项可能只剩 `mcpOAuth`（订阅 OAuth 移出，
        // 见 steipete/CodexBar#1844），文件 `~/.claude/.credentials.json` 是等价凭证源。
        // 文件也读不到时抛出/返回值与回退前语义一致（deferredError）。
        var deferredError: LoadError?
        switch queryResult.status {
        case errSecSuccess:
            if let data = queryResult.item as? Data {
                if let creds = Self.parseCredentials(data) {
                    DiagnosticLog.claudeCredentials.info("keychain: ok")
                    return creds
                }
                if Self.isMcpOAuthOnlyPayload(data) {
                    DiagnosticLog.claudeCredentials.warning("keychain: mcpOAuth-only payload (Claude Code >= 2.1.x storage change), trying file fallback")
                } else {
                    deferredError = .payloadDecodeFailed
                    DiagnosticLog.claudeCredentials.error("keychain: payloadDecodeFailed, trying file fallback")
                }
            } else {
                DiagnosticLog.claudeCredentials.error("keychain: item present but no data, trying file fallback")
            }
        case errSecUserCanceled:          // -128 用户在 ACL prompt 上点取消
            // 用户对「读 Claude 凭证」明确说了不 —— 不能再从文件把同一份凭证捞回来，直接降级。
            DiagnosticLog.claudeCredentials.notice("keychain: user canceled ACL prompt, skipping file fallback")
            return nil
        case errSecItemNotFound,         // -25300 未装 Claude CLI 或无该 account 项
             errSecAuthFailed,            // -25293 ACL 验证失败
             errSecInteractionNotAllowed: // -25308 后台进程无法弹 ACL prompt
            // G2 F 修订："权限/不存在"OSStatus 静默降级（现在先走文件回退再降级）
            DiagnosticLog.claudeCredentials.info("keychain: unavailable (notFound/auth category), trying file fallback")
        default:
            deferredError = .keychainQueryFailed
            DiagnosticLog.claudeCredentials.error("keychain: keychainQueryFailed, trying file fallback")
        }

        if let creds = Self.loadFromFile(credentialsFileURL) {
            DiagnosticLog.claudeCredentials.info("file fallback: ok")
            return creds
        }
        DiagnosticLog.claudeCredentials.info("file fallback: unavailable")
        if let deferredError { throw deferredError }
        return nil
    }

    // MARK: - Payload helpers（`internal` static，单测直接覆盖，无需 Keychain / 文件系统实测）

    /// Keychain payload / `~/.claude/.credentials.json` 共用同一 schema。
    static func parseCredentials(_ data: Data) -> StoredCredentials? {
        guard let payload = try? JSONDecoder().decode(KeychainPayload.self, from: data) else { return nil }
        let oauth = payload.claudeAiOauth
        let expiry: Date? = oauth.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        return StoredCredentials(
            accessToken: oauth.accessToken,
            refreshToken: oauth.refreshToken,
            expiresAt: expiry,
            scopes: oauth.scopes ?? []
        )
    }

    /// Claude Code 2.1.x 已知形态：顶层只有 `mcpOAuth`、没有 `claudeAiOauth`。
    /// 区分它与「schema 真坏了」，日志里给出可行动的根因。
    static func isMcpOAuthOnlyPayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["claudeAiOauth"] == nil && object["mcpOAuth"] != nil
    }

    static func loadFromFile(_ url: URL) -> StoredCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let creds = parseCredentials(data) else { return nil }
        // 文件可能是老 CLI 安装的陈年残留，而我们没有它的 refresh 能力：过期 token 直接丢弃，
        // 否则会以已知过期的 bearer 反复打 401，并把用户引向修不好它的 `claude` 重登录提示。
        guard !creds.isExpired() else {
            DiagnosticLog.claudeCredentials.notice("file fallback: credentials expired, ignoring file")
            return nil
        }
        return creds
    }
}
