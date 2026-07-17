import os

/// 统一诊断日志出口（os.Logger / unified logging，仅存本机、不出设备）。
///
/// 背景：Claude 用量查询失败时 app 内只有一行 `lastError` 文案，无法区分
/// 「凭证读不到 / 被限流 / 网络层失败」三类根因。这里按 provider + 环节分 category，
/// 排查时在终端执行：
/// ```sh
/// log stream --level info --predicate 'subsystem == "com.tuzhihao.app.UsageBar"'
/// ```
/// 或在 Console.app 按 subsystem 过滤。
///
/// SC7 安全约束：日志内容只允许「环节 + 结果类别 + HTTP 状态码 + 传输层错误码
/// （URLError code，用于区分离线 / DNS / TLS / 代理故障）+ 时长」，
/// 绝不写入 token、URL query、response body 或 Keychain payload 原文。
enum DiagnosticLog {
    private static let subsystem = "com.tuzhihao.app.UsageBar"

    /// Claude 用量 fetch 主路径（HTTP 状态、退避、传输层错误类别）。
    static let claudeUsage = Logger(subsystem: subsystem, category: "claude.usage")
    /// Claude 凭证读取（Keychain / 文件回退的结果类别）。
    static let claudeCredentials = Logger(subsystem: subsystem, category: "claude.credentials")
}
