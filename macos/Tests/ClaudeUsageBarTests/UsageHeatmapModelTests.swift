import XCTest
@testable import ClaudeUsageBar

final class UsageHeatmapModelTests: XCTestCase {
    private func day(_ s: String, usd: Double, calls: Int = 1) -> DaySpend {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return DaySpend(dayKey: s, date: f.date(from: s)!, usd: usd, calls: calls)
    }

    func testGridSpansAtLeast53Weeks() {
        let model = UsageHeatmapModel(daySpends: [day("2026-05-11", usd: 1)], referenceDate: day("2026-05-11", usd: 0).date)
        XCTAssertEqual(model.weeks.count, 53)
        XCTAssertTrue(model.weeks.allSatisfy { $0.count == 7 })
    }
    func testZeroSpendDayIsBucketZero() {
        let model = UsageHeatmapModel(daySpends: [day("2026-05-11", usd: 0)], referenceDate: day("2026-05-11", usd: 0).date)
        XCTAssertEqual(model.cell(forDayKey: "2026-05-11")?.bucket, 0)
    }
    func testColorBucketsHaveContrastForLightUser() {
        let days = (1...20).map { day(String(format: "2026-05-%02d", $0), usd: Double($0) * 0.025) }
        let model = UsageHeatmapModel(daySpends: days, referenceDate: days.last!.date)
        let buckets = Set(days.compactMap { model.cell(forDayKey: $0.dayKey)?.bucket })
        XCTAssertGreaterThanOrEqual(buckets.subtracting([0]).count, 3)
    }
    func testNineBucketsMax() {
        let days = (1...28).map { day(String(format: "2026-05-%02d", $0), usd: pow(2.0, Double($0))) }
        let model = UsageHeatmapModel(daySpends: days, referenceDate: days.last!.date)
        let buckets = Set(days.compactMap { model.cell(forDayKey: $0.dayKey)?.bucket })
        XCTAssertLessThanOrEqual(buckets.max() ?? 0, 8)
    }
    func testCrossYearBoundaryIncludesBothYears() {
        let model = UsageHeatmapModel(daySpends: [day("2025-12-31", usd: 1), day("2026-01-01", usd: 2)], referenceDate: day("2026-01-15", usd: 0).date)
        XCTAssertNotNil(model.cell(forDayKey: "2025-12-31"))
        XCTAssertNotNil(model.cell(forDayKey: "2026-01-01"))
    }
    func testIsEmptyWhenAllZeroOrNoDays() {
        XCTAssertTrue(UsageHeatmapModel(daySpends: [], referenceDate: Date()).isEmpty)
        XCTAssertTrue(UsageHeatmapModel(daySpends: [day("2026-05-11", usd: 0)], referenceDate: day("2026-05-11", usd: 0).date).isEmpty)
        XCTAssertFalse(UsageHeatmapModel(daySpends: [day("2026-05-11", usd: 0.5)], referenceDate: day("2026-05-11", usd: 0).date).isEmpty)
    }
}
