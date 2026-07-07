import Foundation

actor ScanCursorStore {
    private let cursorURL: URL
    private let fm = FileManager.default
    private var cache: ScanCursorFile?

    init(dataDirOverride: URL? = nil, provider: ProviderID = .claude) {
        let dir: URL
        if let o = dataDirOverride { dir = o }
        else if let cfg = UsageEventStore.defaultConfigDir() { dir = cfg.appendingPathComponent("data", isDirectory: true) }
        else { dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-bar/data", isDirectory: true) }
        // Claude 保旧文件名 scan-cursor.json（兼容已有部署）；其他 provider 用 scan-cursor-<provider>.json，同目录。
        let name = provider == .claude ? "scan-cursor.json" : "scan-cursor-\(provider.rawValue).json"
        self.cursorURL = dir.appendingPathComponent(name)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func loaded() -> ScanCursorFile {
        if let c = cache { return c }
        if let data = try? Data(contentsOf: cursorURL),
           let f = try? Self.decoder.decode(ScanCursorFile.self, from: data), f.schemaVersion == 1 {
            cache = f; return f
        }
        let fresh = ScanCursorFile(schemaVersion: 1, files: [:]); cache = fresh; return fresh
    }

    private func persist(_ f: ScanCursorFile) {
        cache = f
        do {
            try fm.createDirectory(at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder.encode(f)
            try data.write(to: cursorURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorURL.path)
        } catch { NSLog("[usage-bar] cursor write: \(type(of: error))") }
    }

    /// nil = 文件无变化可跳过；0 = 需全读；N = 从第 N 行续读。
    func nextReadOffset(for fileURL: URL, currentSize: Int, currentMTime: Date) -> Int? {
        guard let c = loaded().files[fileURL.path] else { return 0 }   // 首见
        if c.size == currentSize && abs(c.mtime.timeIntervalSince(currentMTime)) < 1 { return nil }   // 没变（mtime 容 1s 抖动）
        if c.size == currentSize { return 0 }                           // 同尺寸但 mtime 变了 → 原地等长改写，续读会漏；全读
        if currentSize < c.size { return 0 }                            // 变小 → 全读
        if currentMTime < c.mtime.addingTimeInterval(-1) { return 0 }   // mtime 跳到更早 → 全读
        return c.lineOffset                                             // 变大 → 续读
    }

    func updateCursor(for fileURL: URL, size: Int, mtime: Date, lineOffset: Int) {
        var f = loaded()
        f.files[fileURL.path] = ScanCursorFile.FileCursor(size: size, mtime: mtime, lineOffset: lineOffset)
        cache = f
    }

    func clearCursor(for fileURL: URL) {
        var f = loaded(); f.files[fileURL.path] = nil; cache = f
    }

    /// 把内存中的游标 cache 一次性写盘。collect() 结束时调用一次，避免每文件都 atomic-write 的 O(n²) 写放大。
    func flush() {
        if let c = cache { persist(c) }
    }
}
