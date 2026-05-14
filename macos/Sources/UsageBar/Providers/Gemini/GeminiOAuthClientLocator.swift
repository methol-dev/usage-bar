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

    /// `nil` = 未查；`.some(nil)` = 查过无结果；`.some(.some(r))` = 已命中。
    /// clientId/secret 随 gemini-cli 版本更新才会变，实例生命周期内缓存安全。
    private var _cache: Result?? = nil

    init(candidatePaths: [URL]? = nil, fileManager: FileManager = .default) {
        self.candidatePaths = candidatePaths ?? Self.defaultCandidatePaths(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// 返回首个命中的 client_id/secret；全部失败返回 nil。结果在实例内 lazy 缓存，避免重复读磁盘。
    func findClientIdSecret() -> Result? {
        if case .some(let cached) = _cache { return cached }
        let found = findClientIdSecretUncached()
        _cache = .some(found)
        return found
    }

    private func findClientIdSecretUncached() -> Result? {
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
    /// bundled 安装（npm / bun 新版打包）fallback：扫 `@google/gemini-cli/bundle/*.js`。
    private func locateOauth2Js(under root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("lib/node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
            root.appendingPathComponent("node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
        ]
        if let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return found
        }
        return locateBundledOauth2Js(under: root)
    }

    /// bundled 安装 fallback：扫 `(lib/)node_modules/@google/gemini-cli/bundle/*.js`，
    /// 返回首个含 `OAUTH_CLIENT_ID` 的文件。
    /// 注：各 chunk 中该常量值完全一致（gemini-cli 打包特性），取哪个结果相同。
    private func locateBundledOauth2Js(under root: URL) -> URL? {
        let bundleDirs = [
            root.appendingPathComponent("lib/node_modules/@google/gemini-cli/bundle"),  // npm
            root.appendingPathComponent("node_modules/@google/gemini-cli/bundle"),      // bun / 项目本地
        ]
        for bundleDir in bundleDirs {
            guard let files = try? fileManager.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil) else { continue }
            if let found = files.first(where: { url in
                guard url.pathExtension == "js" else { return false }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("OAUTH_CLIENT_ID")
            }) { return found }
        }
        return nil
    }

    /// 真机四处枚举：Homebrew 默认、npm global 默认、~/.npm-global（npm prefix 自定义）、bun 全局。
    static func defaultCandidatePaths(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew"),                         // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local"),                            // Intel Homebrew + npm global
            home.appendingPathComponent(".npm-global"),                    // npm prefix 自定义（npm config set prefix）
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
