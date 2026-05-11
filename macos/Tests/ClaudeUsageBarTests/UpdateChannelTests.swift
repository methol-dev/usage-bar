import XCTest
@testable import ClaudeUsageBar

final class UpdateChannelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.update-channel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.beta.rawValue, "beta")
        XCTAssertEqual(UpdateChannel(rawValue: "stable"), .stable)
        XCTAssertEqual(UpdateChannel(rawValue: "beta"), .beta)
        XCTAssertNil(UpdateChannel(rawValue: "alpha"))
    }

    func testCurrentFallsBackForNil() {
        XCTAssertNil(defaults.string(forKey: UpdateChannel.storageKey))
        XCTAssertEqual(UpdateChannel.current(defaults: defaults), .stable)
    }

    func testCurrentFallsBackForUnknownRawValue() {
        defaults.set("canary", forKey: UpdateChannel.storageKey)
        XCTAssertEqual(UpdateChannel.current(defaults: defaults), .stable)
    }

    func testCurrentRetrievesPersistedValue() {
        defaults.set("beta", forKey: UpdateChannel.storageKey)
        XCTAssertEqual(UpdateChannel.current(defaults: defaults), .beta)
    }

    func testAllowedChannelsForStable() {
        XCTAssertEqual(UpdateChannel.allowedChannelStrings(for: .stable), ["stable"])
    }

    func testAllowedChannelsForBeta() {
        XCTAssertEqual(UpdateChannel.allowedChannelStrings(for: .beta), ["stable", "beta"])
    }

    func testDisplayName() {
        XCTAssertEqual(UpdateChannel.stable.displayName, "稳定版")
        XCTAssertEqual(UpdateChannel.beta.displayName, "Beta（实验性）")
    }

    func testAllCases() {
        XCTAssertEqual(UpdateChannel.allCases.count, 2)
    }
}
