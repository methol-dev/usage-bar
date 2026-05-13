import XCTest
@testable import UsageBar

final class GeminiOAuthClientLocatorTests: XCTestCase {

    /// 在临时目录里造一个 gemini-cli 安装结构，把 fixture 拷过去当 oauth2.js。
    private func makeFakeInstall(at relativePath: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oauth2Dir = tmp.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: oauth2Dir, withIntermediateDirectories: true)
        let fixtureURL = Bundle.module.url(forResource: "oauth2-fixture", withExtension: "js", subdirectory: "Gemini")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Gemini/oauth2-fixture.js")
        let dst = oauth2Dir.appendingPathComponent("oauth2.js")
        try FileManager.default.copyItem(at: fixtureURL, to: dst)
        return tmp
    }

    func testHomebrewPathFound() throws {
        let tmp = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        let result = try XCTUnwrap(locator.findClientIdSecret())
        XCTAssertEqual(result.clientId, "FIXTURE_CLIENT_ID.apps.googleusercontent.com")
        XCTAssertEqual(result.clientSecret, "FIXTURE_CLIENT_SECRET_VALUE")
    }

    func testNpmGlobalPathFound() throws {
        let tmp = try makeFakeInstall(at: "node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNotNil(locator.findClientIdSecret())
    }

    func testNoOauth2JsReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNil(locator.findClientIdSecret())
    }

    func testCorruptedOauth2JsRegexMissReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oauth2Dir = tmp.appendingPathComponent("lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        try FileManager.default.createDirectory(at: oauth2Dir, withIntermediateDirectories: true)
        try Data("// no client id here".utf8).write(to: oauth2Dir.appendingPathComponent("oauth2.js"))
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNil(locator.findClientIdSecret())
    }

    func testFirstCandidateWins() throws {
        let first = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let second = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        // 两个都命中，locator 应取第一个就停。
        let locator = GeminiOAuthClientLocator(candidatePaths: [first, second])
        XCTAssertNotNil(locator.findClientIdSecret())
    }
}
