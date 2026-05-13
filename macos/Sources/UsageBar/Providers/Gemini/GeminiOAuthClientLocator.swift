import Foundation

/// 从本机已安装的 gemini-cli 的 `oauth2.js` 中用 regex 抠出 OAuth client_id/secret。
///
/// **合规理由**：不在 app 二进制中硬编码 Google secret（避免二次分发），仅在运行时从用户本机
/// 已合法持有的 gemini-cli 安装中读取（详见 spec §2.2 / §3.5）。
final class GeminiOAuthClientLocator {
    struct Result: Equatable {
        let clientId: String
        let clientSecret: String
    }

    private let candidatePaths: [URL]
    private let fileManager: FileManager
    /// gemini-cli `code_assist/oauth2.js` 在三种主流安装方式下的相对路径。
    /// 末段固定为 `code_assist/oauth2.js`（上游 source code 路径稳定）；中段差异主要在
    /// `lib/node_modules` (homebrew / npm global) vs `node_modules` (bun / 项目本地) vs `.bun/install/global/node_modules` (bun 全局)。
    static let oauth2RelativePathInside = "@google/gemini-cli-core/dist/src/code_assist/oauth2.js"

    init(candidatePaths: [URL]? = nil, fileManager: FileManager = .default) {
        self.candidatePaths = candidatePaths ?? Self.defaultCandidatePaths(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// 返回首个命中的 client_id/secret；全部失败返回 nil。
    func findClientIdSecret() -> Result? {
        for root in candidatePaths {
            guard let oauth2URL = locateOauth2Js(under: root) else { continue }
            guard let text = try? String(contentsOf: oauth2URL, encoding: .utf8) else { continue }
            guard let id = Self.match(in: text, key: "OAUTH_CLIENT_ID"),
                  let secret = Self.match(in: text, key: "OAUTH_CLIENT_SECRET") else { continue }
            return Result(clientId: id, clientSecret: secret)
        }
        return nil
    }

    /// 在 root 下查 `lib/node_modules/<oauth2RelativePathInside>`(homebrew / npm global)
    /// 或 `node_modules/<...>`(bun / 项目本地)。不深度遍历整树。
    private func locateOauth2Js(under root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("lib/node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
            root.appendingPathComponent("node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// 真机三处枚举：Homebrew 默认、npm global 默认、bun 全局。
    static func defaultCandidatePaths(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew"),                         // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local"),                            // Intel Homebrew + npm global
            home.appendingPathComponent(".bun/install/global"),            // bun 全局
        ]
    }

    /// 匹配形如 `OAUTH_CLIENT_ID = 'value'` 或 `OAUTH_CLIENT_ID="value"`，捕获引号内的 value。
    static func match(in text: String, key: String) -> String? {
        let pattern = #"\#(key)\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let valueRange = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }
}
