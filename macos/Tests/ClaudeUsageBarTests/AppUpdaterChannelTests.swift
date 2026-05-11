import XCTest
@testable import ClaudeUsageBar

@MainActor
final class AppUpdaterChannelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.app-updater-channel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testAllowedChannelsReflectsStableValue() {
        defaults.set(UpdateChannel.stable.rawValue, forKey: UpdateChannel.storageKey)
        let delegate = UpdaterDelegateImpl(defaults: defaults)
        // 注：传 nil 是因为我们的 impl 不依赖 updater 参数
        let result = delegate.allowedChannels(for: SPUUpdaterStub())
        XCTAssertEqual(result, ["stable"])
    }

    func testAllowedChannelsReflectsBetaValue() {
        defaults.set(UpdateChannel.beta.rawValue, forKey: UpdateChannel.storageKey)
        let delegate = UpdaterDelegateImpl(defaults: defaults)
        let result = delegate.allowedChannels(for: SPUUpdaterStub())
        XCTAssertEqual(result, ["stable", "beta"])
    }

    func testAllowedChannelsDefaultsToStableWhenUnset() {
        // 不设值
        let delegate = UpdaterDelegateImpl(defaults: defaults)
        let result = delegate.allowedChannels(for: SPUUpdaterStub())
        XCTAssertEqual(result, ["stable"])
    }
}

// MARK: - SPUUpdater Stub
// 我们的 allowedChannels impl 不读 updater 参数；用 stub 满足函数签名
// （SPUUpdater 没有公开 init，我们传一个真实但不启动的 instance）
import Sparkle

@MainActor
private func SPUUpdaterStub() -> SPUUpdater {
    // SPUStandardUpdaterController 创建一个不启动的 updater
    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    return controller.updater
}
