import Foundation

/// 首次启动时检测用户已安装的 AI 工具，用于决定哪些 provider 默认开启。
/// 纯文件系统检测（同步，无网络/进程调用），注入 `fileManager` + `environment` 以便测试。
enum AIToolDetector {
    static func detect(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<ProviderID> {
        var detected: Set<ProviderID> = []
        let home = fileManager.homeDirectoryForCurrentUser

        // Claude Code CLI（~/.claude/）或 Claude Desktop（/Applications/Claude.app）
        if fileManager.fileExists(atPath: home.appendingPathComponent(".claude").path) ||
           fileManager.fileExists(atPath: "/Applications/Claude.app") {
            detected.insert(.claude)
        }

        // Codex CLI：$CODEX_HOME 或 ~/.codex/（与 CodexCredentialStore 路径一致）
        let codexDir: URL
        if let h = environment["CODEX_HOME"], !h.isEmpty {
            codexDir = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        }
        if fileManager.fileExists(atPath: codexDir.path) {
            detected.insert(.codex)
        }

        // Gemini CLI：$GEMINI_HOME 或 ~/.gemini/（与 GeminiCredentialStore 路径一致）
        let geminiDir: URL
        if let h = environment["GEMINI_HOME"], !h.isEmpty {
            geminiDir = URL(fileURLWithPath: h, isDirectory: true)
        } else {
            geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        }
        if fileManager.fileExists(atPath: geminiDir.path) {
            detected.insert(.gemini)
        }

        // Cursor：/Applications/Cursor.app
        if fileManager.fileExists(atPath: "/Applications/Cursor.app") {
            detected.insert(.cursor)
        }

        // GitHub Copilot CLI：~/.config/github-copilot/（暂定路径，待 CopilotCredentialStore 实现时对齐）
        if fileManager.fileExists(atPath: home.appendingPathComponent(".config/github-copilot").path) {
            detected.insert(.copilot)
        }

        // 注:Claude Web 自 ADR 0010 起是 Claude 的**数据源**、非顶层 provider —— 这里不再返回 `.claudeWeb`。
        // 扩展同步文件(claude-web.json)是否存在,由 `ProviderCoordinator` 决定 Claude 的 web 源是否默认勾选。

        return detected
    }
}
