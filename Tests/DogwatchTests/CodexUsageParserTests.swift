import XCTest
@testable import Dogwatch

final class CodexUsageParserTests: XCTestCase {
    func testParsesRateLimitAndTokenUsage() throws {
        let rateLimits: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 21,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_786_177_398
                ],
                "credits": ["balance": "2500"],
                "planType": "plus"
            ]
        ]
        let tokenUsage: [String: Any] = [
            "summary": ["lifetimeTokens": 858_356_160],
            "dailyUsageBuckets": [
                ["startDate": "2026-08-04", "tokens": 41_280_196]
            ]
        ]

        let snapshot = try CodexUsageClient.parse(rateLimits: rateLimits, tokenUsage: tokenUsage)

        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.usedPercent, 21)
        XCTAssertEqual(snapshot.remainingPercent, 79)
        XCTAssertEqual(snapshot.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.lifetimeTokens, 858_356_160)
        XCTAssertEqual(snapshot.dailyUsage.first?.tokens, 41_280_196)
        XCTAssertEqual(snapshot.creditBalance, "2500")
    }

    func testParsesFractionalUsedPercent() throws {
        let rateLimits: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 21.6,
                    "windowDurationMins": 10_080
                ],
                "planType": "plus"
            ]
        ]

        let snapshot = try CodexUsageClient.parse(
            rateLimits: rateLimits,
            tokenUsage: ["summary": [:], "dailyUsageBuckets": []]
        )

        XCTAssertEqual(snapshot.usedPercent, 22)
        XCTAssertEqual(snapshot.remainingPercent, 78)
    }

    func testParsesSessionAndWeeklyWindows() throws {
        let rateLimits: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 6, "windowDurationMins": 300],
                "secondary": ["usedPercent": 74, "windowDurationMins": 10_080],
                "planType": "plus"
            ]
        ]

        let snapshot = try CodexUsageClient.parse(
            rateLimits: rateLimits,
            tokenUsage: ["summary": [:], "dailyUsageBuckets": []]
        )

        XCTAssertEqual(snapshot.remainingPercent, 94)
        XCTAssertEqual(snapshot.windowLabel, "5h")
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 26)
    }

    func testFindsNodeOutsideGUIPath() {
        XCTAssertNotNil(CodexUsageClient.findNodeExecutable())
    }

    func testTokenFormatting() {
        XCTAssertEqual(UsageFormatters.tokens(950), "950")
        XCTAssertEqual(UsageFormatters.tokens(12_500), "12.5K")
        XCTAssertEqual(UsageFormatters.tokens(8_550_000), "8.6M")
    }

    func testCreditFormattingFitsStatPlate() {
        XCTAssertEqual(UsageFormatters.credits(nil), "—")
        XCTAssertEqual(UsageFormatters.credits("2500"), "2,500")
        XCTAssertEqual(UsageFormatters.credits("2464.0446"), "2,464.04")
        XCTAssertEqual(UsageFormatters.credits("12.5"), "12.5")
    }

    func testClaudeExpiredOrDroppedWindowIsFresh() {
        let snapshot = ClaudeUsageSnapshot(
            fiveHourUsedPercent: 100,
            fiveHourResetDate: Date().addingTimeInterval(-60),
            weeklyUsedPercent: 35,
            weeklyResetDate: Date().addingTimeInterval(3_600),
            cacheUpdatedAt: Date()
        )

        XCTAssertFalse(snapshot.isFiveHourActive)
        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 100)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 65)

        let dropped = ClaudeUsageSnapshot(
            fiveHourUsedPercent: nil, fiveHourResetDate: nil,
            weeklyUsedPercent: 4, weeklyResetDate: Date().addingTimeInterval(3_600),
            cacheUpdatedAt: Date()
        )
        XCTAssertEqual(dropped.fiveHourRemainingPercent, 100)
        XCTAssertEqual(dropped.weeklyRemainingPercent, 96)
    }

    func testParsesClaudeOAuthUsageResponse() throws {
        let data = Data("""
        {
          "five_hour": {"utilization": 27.4, "resets_at": "2026-11-01T23:49:59.978138+00:00"},
          "seven_day": {"utilization": 81.6, "resets_at": "2026-11-02T21:59:59+00:00"},
          "seven_day_opus": null
        }
        """.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_793_500_000)

        let snapshot = try ClaudeUsageClient.parseUsage(data, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.fiveHourUsedPercent, 27)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 82)
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHourResetDate).timeIntervalSince1970, 1_793_576_999.978, accuracy: 0.01)
        XCTAssertEqual(snapshot.weeklyResetDate, Date(timeIntervalSince1970: 1_793_656_799))
        XCTAssertEqual(snapshot.cacheUpdatedAt, fetchedAt)

        let empty = try ClaudeUsageClient.parseUsage(Data(#"{"five_hour": null, "seven_day": null}"#.utf8), fetchedAt: fetchedAt)
        XCTAssertNil(empty.fiveHourUsedPercent)
        XCTAssertNil(empty.weeklyResetDate)
    }
}
