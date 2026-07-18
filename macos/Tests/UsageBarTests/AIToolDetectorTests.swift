import XCTest
@testable import UsageBar

final class AIToolDetectorTests: XCTestCase {
    private var tmpDir: URL!
    private var fm: FileManager!

    override func setUpWithError() throws {
        fm = FileManager.default
        tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmpDir)
    }

    // MARK: - 各 provider 正向检测

    func testDetectsClaudeViaDotClaudeDir() throws {
        let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.contains(.claude))
    }

    func testDetectsCodexViaDefaultDir() throws {
        let codexDir = tmpDir.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.contains(.codex))
    }

    func testDetectsCodexViaEnvOverride() throws {
        let customDir = tmpDir.appendingPathComponent("custom-codex", isDirectory: true)
        try fm.createDirectory(at: customDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: ["CODEX_HOME": customDir.path])
        XCTAssertTrue(result.contains(.codex))
    }

    func testDetectsGeminiViaDefaultDir() throws {
        let geminiDir = tmpDir.appendingPathComponent(".gemini", isDirectory: true)
        try fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.contains(.gemini))
    }

    func testDetectsGeminiViaEnvOverride() throws {
        let customDir = tmpDir.appendingPathComponent("custom-gemini", isDirectory: true)
        try fm.createDirectory(at: customDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: ["GEMINI_HOME": customDir.path])
        XCTAssertTrue(result.contains(.gemini))
    }

    func testDetectsCopilotViaGithubCopilotDir() throws {
        let configDir = tmpDir.appendingPathComponent(".config/github-copilot", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.contains(.copilot))
    }

    func testSyncedFileDoesNotAddClaudeWebTopLevel() throws {
        // ADR 0010：Claude Web 是 Claude 的**数据源**、不再是顶层 provider —— 即便扩展同步文件存在,
        // detect() 也不返回 .claudeWeb（web 源是否默认勾选由 ProviderCoordinator/ClaudeProvider 决定）。
        let dir = tmpDir.appendingPathComponent(".config/usage-bar", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("claude-web.json"))
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertFalse(result.contains(.claudeWeb))
    }

    // MARK: - 空结果

    func testNoToolsInstalledReturnsEmptySet() {
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.isEmpty, "无工具目录时应返回空集")
    }

    // MARK: - 多工具并存

    func testDetectsMultipleTools() throws {
        for name in [".claude", ".codex", ".gemini"] {
            try fm.createDirectory(at: tmpDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: [:])
        XCTAssertTrue(result.isSuperset(of: [.claude, .codex, .gemini]))
        XCTAssertFalse(result.contains(.cursor), "未创建 Cursor.app，不应检测到")
    }

    // MARK: - 空 env 变量不覆盖默认路径

    func testEmptyEnvVarFallsBackToDefaultPath() throws {
        let codexDir = tmpDir.appendingPathComponent(".codex", isDirectory: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let mockFM = MockHomeFileManager(home: tmpDir, real: fm)
        let result = AIToolDetector.detect(fileManager: mockFM, environment: ["CODEX_HOME": ""])
        XCTAssertTrue(result.contains(.codex), "空字符串 CODEX_HOME 应 fallback 到 ~/.codex/")
    }
}

// MARK: - FileManager 子类：重定向 homeDirectoryForCurrentUser

/// 测试辅助：把 `homeDirectoryForCurrentUser` 重定向到临时目录，其余调用透传。
private final class MockHomeFileManager: FileManager {
    let home: URL
    let real: FileManager

    init(home: URL, real: FileManager) {
        self.home = home
        self.real = real
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { home }

    override func fileExists(atPath path: String) -> Bool {
        real.fileExists(atPath: path)
    }
}
