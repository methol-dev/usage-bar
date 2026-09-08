import XCTest
@testable import UsageBar

final class ScanCursorStoreTests: XCTestCase {
    private var tmpDir: URL!
    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cursor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    private func makeStore() -> ScanCursorStore { ScanCursorStore(dataDirOverride: tmpDir) }
    private let fakeURL = URL(fileURLWithPath: "/tmp/projects/foo/00000000-mock-0000-0000-000000000000.jsonl")

    func testFirstSeenFileReturnsZero() async {
        let s = makeStore()
        let result = await s.nextReadOffset(for: fakeURL, currentSize: 100, currentMTime: Date())
        XCTAssertEqual(result, 0)
    }
    func testUnchangedSizeAndMTimeReturnsNil() async {
        let s = makeStore()
        let m = Date(timeIntervalSince1970: 1_000_000)
        await s.updateCursor(for: fakeURL, size: 100, mtime: m, lineOffset: 5)
        let result = await s.nextReadOffset(for: fakeURL, currentSize: 100, currentMTime: m)
        XCTAssertNil(result)
    }
    func testGrownSizeReturnsLastLineOffset() async {
        let s = makeStore()
        let m1 = Date(timeIntervalSince1970: 1_000_000), m2 = Date(timeIntervalSince1970: 1_000_500)
        await s.updateCursor(for: fakeURL, size: 100, mtime: m1, lineOffset: 5)
        let result = await s.nextReadOffset(for: fakeURL, currentSize: 250, currentMTime: m2)
        XCTAssertEqual(result, 5)
    }
    func testShrunkSizeReturnsZero() async {
        let s = makeStore()
        let m1 = Date(timeIntervalSince1970: 1_000_000), m2 = Date(timeIntervalSince1970: 1_000_500)
        await s.updateCursor(for: fakeURL, size: 100, mtime: m1, lineOffset: 5)
        let result = await s.nextReadOffset(for: fakeURL, currentSize: 30, currentMTime: m2)
        XCTAssertEqual(result, 0)
    }
    func testCorruptedCursorFileDegradesToFullScan() async throws {
        try "{ not json".data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("scan-cursor.json"))
        let s = makeStore()
        let result = await s.nextReadOffset(for: fakeURL, currentSize: 100, currentMTime: Date())
        XCTAssertEqual(result, 0)
    }
    func testPersistAcrossInstances() async {
        let m = Date(timeIntervalSince1970: 1_000_000)
        let s1 = makeStore()
        await s1.updateCursor(for: fakeURL, size: 100, mtime: m, lineOffset: 7)
        await s1.flush()
        let result = await makeStore().nextReadOffset(for: fakeURL, currentSize: 100, currentMTime: m)
        XCTAssertNil(result)
    }
    func testLegacySchemaVersionForcesFullRescan() async throws {
        let m = Date(timeIntervalSince1970: 1_000_000)
        let s1 = makeStore()
        await s1.updateCursor(for: fakeURL, size: 100, mtime: m, lineOffset: 5)
        await s1.flush()
        let url = tmpDir.appendingPathComponent("scan-cursor.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        obj["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]).write(to: url)
        let s2 = makeStore()
        let result = await s2.nextReadOffset(for: fakeURL, currentSize: 100, currentMTime: m)
        XCTAssertEqual(result, 0)
        let reset = await s2.consumeDidResetStaleSchema()
        XCTAssertTrue(reset)
    }

    func testCursorFilePermissionsAre0600() async throws {
        let s = makeStore()
        await s.updateCursor(for: fakeURL, size: 100, mtime: Date(), lineOffset: 1)
        await s.flush()
        let perms = try FileManager.default.attributesOfItem(atPath: tmpDir.appendingPathComponent("scan-cursor.json").path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.int16Value, 0o600)
    }
}
