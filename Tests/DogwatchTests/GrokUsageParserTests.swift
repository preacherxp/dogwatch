import XCTest
@testable import Dogwatch

final class GrokUsageParserTests: XCTestCase {
    func testParsesWeeklyCreditsFromUnifiedLog() throws {
        let line = """
        {"ts":"2026-08-16T10:00:00.000000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":39.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-10T19:45:41.406527+00:00","end":"2026-08-17T19:45:41.406527+00:00"},"prepaidBalance":{"val":500}},"subscriptionTier":"X Premium+"}}
        """

        let record = GrokUsageClient.lastBillingRecord(in: Data(line.utf8))
        XCTAssertNotNil(record?.context)

        let snapshot = try GrokUsageClient.parse(context: record!.context)

        XCTAssertEqual(snapshot.usedPercent, 39)
        XCTAssertEqual(snapshot.remainingPercent, 61)
        XCTAssertEqual(snapshot.periodLabel, "weekly")
        XCTAssertEqual(snapshot.planName, "X Premium+")
        XCTAssertEqual(snapshot.prepaidBalance, "$5.00")
        XCTAssertNotNil(snapshot.resetDate)
    }

    func testFallsBackToMonthlyLimitRatio() throws {
        let context: [String: Any] = [
            "config": [
                "used": ["val": 250],
                "monthlyLimit": ["val": 1000],
                "billingPeriodEnd": "2026-09-01T00:00:00Z"
            ],
            "subscriptionTier": "SuperGrok"
        ]

        let snapshot = try GrokUsageClient.parse(context: context)

        XCTAssertEqual(snapshot.usedPercent, 25)
        XCTAssertEqual(snapshot.remainingPercent, 75)
        XCTAssertEqual(snapshot.planName, "SuperGrok")
        XCTAssertEqual(snapshot.periodLabel, "credits")
    }

    func testExpiredWindowHasNoRemainingPercent() throws {
        let context: [String: Any] = [
            "config": [
                "creditUsagePercent": 10,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2020-01-01T00:00:00Z"
                ]
            ]
        ]

        let snapshot = try GrokUsageClient.parse(context: context)
        XCTAssertTrue(snapshot.isWindowExpired)
        XCTAssertEqual(snapshot.remainingPercent, 90)
    }
}
