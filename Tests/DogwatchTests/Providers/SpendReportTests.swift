import Foundation
import XCTest
@testable import Dogwatch

/// The shared spend helpers: UTC periods at month and year boundaries, money conversion that would
/// catch a factor-of-100 or nanos mistake, currency-safe totals and capped paging.
final class SpendReportTests: XCTestCase {
    private func utc(_ text: String) -> Date { DateParsing.iso8601(text)! }

    func testMonthIsTheUTCCalendarMonth() {
        let month = SpendPeriod.month(containing: utc("2026-11-19T15:30:00Z"))
        XCTAssertEqual(month.start, utc("2026-11-01T00:00:00Z"))
        XCTAssertEqual(month.end, utc("2026-12-01T00:00:00Z"))
    }

    func testFirstMinuteOfAMonthBelongsToTheNewMonth() {
        let month = SpendPeriod.month(containing: utc("2026-12-01T00:00:00Z"))
        XCTAssertEqual(month.start, utc("2026-12-01T00:00:00Z"))
        XCTAssertEqual(SpendPeriod.yearMonth(utc("2026-12-01T00:00:00Z")), "2026-12")
        XCTAssertEqual(SpendPeriod.yearMonth(utc("2026-11-30T23:59:59Z")), "2026-11")
    }

    func testYearRollsOverInDecember() {
        let month = SpendPeriod.month(containing: utc("2026-12-31T23:00:00Z"))
        XCTAssertEqual(month.end, utc("2027-01-01T00:00:00Z"))
        XCTAssertEqual(SpendPeriod.day(containing: utc("2026-12-31T23:00:00Z")).end, utc("2027-01-01T00:00:00Z"))
    }

    func testTheUsersTimeZoneDoesNotMoveTheProvidersDay() {
        // 30 November, 23:30 in Los Angeles is already 1 December in UTC: the provider's month is December.
        let evening = utc("2026-11-30T23:30:00-08:00")
        XCTAssertEqual(SpendPeriod.month(containing: evening).start, utc("2026-12-01T00:00:00Z"))
        XCTAssertEqual(SpendPeriod.ymd(evening), "2026-12-01")
        // 1 December, 08:00 in Tokyo is still 30 November in UTC.
        let morning = utc("2026-12-01T08:00:00+09:00")
        XCTAssertEqual(SpendPeriod.month(containing: morning).start, utc("2026-11-01T00:00:00Z"))
        XCTAssertEqual(SpendPeriod.ymd(morning), "2026-11-30")
    }

    func testQueryFormats() {
        let date = utc("2026-11-01T00:00:00Z")
        XCTAssertEqual(SpendPeriod.iso(date), "2026-11-01T00:00:00Z")
        XCTAssertEqual(SpendPeriod.unix(date), "1793491200")
        XCTAssertEqual(SpendPeriod.yearMonth(date, separator: "."), "2026.11")
    }

    func testCentsBecomeWholeUnits() {
        XCTAssertEqual(Money.fromCents(.string("123.45"))!, 1.2345, accuracy: 1e-12)
        XCTAssertEqual(Money.fromCents(.number(1234))!, 12.34, accuracy: 1e-12)
        XCTAssertNil(Money.fromCents(.null))
        XCTAssertNil(Money.fromCents(nil))
    }

    func testUnitsAndNanos() throws {
        let twelve = try JSONValue(data: Data(#"{"currencyCode":"USD","units":"12","nanos":340000000}"#.utf8))
        XCTAssertEqual(Money.fromUnitsAndNanos(twelve)!, 12.34, accuracy: 1e-12)
        let negative = try JSONValue(data: Data(#"{"units":"-1","nanos":-750000000}"#.utf8))
        XCTAssertEqual(Money.fromUnitsAndNanos(negative)!, -1.75, accuracy: 1e-12)
        let nanosOnly = try JSONValue(data: Data(#"{"nanos":50000000}"#.utf8))
        XCTAssertEqual(Money.fromUnitsAndNanos(nanosOnly)!, 0.05, accuracy: 1e-12)
        XCTAssertNil(Money.fromUnitsAndNanos(try JSONValue(data: Data(#"{"currencyCode":"USD"}"#.utf8))))
    }

    func testTotalsRefuseToMixCurrencies() throws {
        var total = MoneyTotal()
        try total.add(1, currency: "usd", provider: "Test")
        try total.add(2, currency: "USD", provider: "Test")
        try total.add(0.5, currency: nil, provider: "Test")
        XCTAssertEqual(total.amount(), Amount(value: 3.5, unit: .currency("USD")))
        XCTAssertThrowsError(try total.add(1, currency: "EUR", provider: "Test")) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "unexpectedResponse")
        }
    }

    func testPagingStopsAtTheCapAndSaysSo() async throws {
        var fetched = 0
        let report = try await PagedReport.collect(
            first: URL(string: "https://api.example.com/r")!, maxPages: 3,
            fetch: { _ in fetched += 1; return .object(["next": .string("x")]) },
            next: { _ in URL(string: "https://api.example.com/r?page=x") }
        )
        XCTAssertEqual(fetched, 3)
        XCTAssertEqual(report.pages.count, 3)
        XCTAssertTrue(report.truncated)
    }

    func testPagingFollowsTheCursorUntilItEnds() async throws {
        var urls: [String] = []
        let report = try await PagedReport.collect(
            first: URL(string: "https://api.example.com/r?limit=31")!, maxPages: 5,
            fetch: { url in urls.append(url.absoluteString); return .object(["n": .number(Double(urls.count))]) },
            next: { page in
                page["n"]?.doubleValue == 1 ? PagedReport.url(URL(string: "https://api.example.com/r?limit=31")!, setting: "page", to: "two") : nil
            }
        )
        XCTAssertEqual(urls, ["https://api.example.com/r?limit=31", "https://api.example.com/r?limit=31&page=two"])
        XCTAssertFalse(report.truncated)
    }

    func testAnIncompleteTotalSaysSoInItsNameAndDetail() {
        let reading = Reading.spendReading(id: "spend_month", name: "This month", amount: Amount(value: 5, unit: .currency("USD")),
                                           period: "this month (UTC)", truncated: true)
        XCTAssertEqual(reading.name, "This month (incomplete)")
        XCTAssertEqual(reading.detailText, "At least $5.00 spent · this month (UTC) · report cut off")
    }

    func testPathIdentifiersRejectAnythingThatCouldChangeTheURL() {
        XCTAssertEqual(try PathIdentifier.validated(" my-account ", field: "account id", provider: "X"), "my-account")
        for bad in ["a/b", "../x", "a b", "a?b", "", "a#b"] {
            XCTAssertThrowsError(try PathIdentifier.validated(bad, field: "account id", provider: "X"), bad) { error in
                XCTAssertEqual((error as? ProviderError)?.kind, "notConfigured")
            }
        }
    }
}
