import Foundation

/// Chrome Native Messaging host manifest 安装器。
///
/// Chrome 只会拉起「已注册」的 host —— manifest 必须落在 Chrome 的固定目录、指向 host 可执行文件的
/// 绝对路径、并在 `allowed_origins` 列出允许调用的扩展 id。app 每次正常启动幂等重写(路径随 .app 位置
/// 变化,幂等能自愈)。写盘照抄 `UsageEventStore` / `ScanCursorStore` 范式。
///
/// host 可执行文件是 bundle 内 wrapper `Contents/MacOS/usagebar-native-host`(shell 脚本,`exec` 主
/// binary 补 `--native-host`;因 Chrome 无法给 manifest path 注入自定义 flag)。
enum NativeHostInstaller {
    static let hostName = "com.tuzhihao.usagebar.host"
    /// 固定扩展 id —— 由 `extension/manifest.json` 的 `key`(固定公钥)决定,跨机器稳定。
    /// load-unpacked 与 Web Store 分发下都一致(前提:manifest 保留该 key)。
    static let extensionID = "aaehoepakaalddpmbhljnhlbbigioeid"

    static func install(fileManager: FileManager = .default) {
        guard let wrapper = wrapperURL() else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "UsageBar Claude Web usage bridge",
            "path": wrapper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }

        for dir in targetDirectories(fileManager: fileManager) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(hostName).json")
            try? data.write(to: dest, options: .atomic)
        }
    }

    /// bundle 内 wrapper 的运行时绝对路径:与主 binary 并列在 `Contents/MacOS/`。
    /// 必须运行时解析(.app 可能被拖到任意目录),且保持原位(勿拷出 bundle,否则主 binary rpath 断裂)。
    static func wrapperURL() -> URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        return exe.deletingLastPathComponent().appendingPathComponent("usagebar-native-host")
    }

    /// v1 仅 Chrome(Chrome 级目录,跨 profile 共享)。Chromium / Brave / Edge 各有独立目录,列 follow-up。
    static func targetDirectories(fileManager: FileManager = .default) -> [URL] {
        let appSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return [
            appSupport.appendingPathComponent("Google/Chrome/NativeMessagingHosts")
        ]
    }
}
