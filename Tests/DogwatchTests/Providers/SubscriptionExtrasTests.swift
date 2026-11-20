import Foundation
import XCTest
@testable import Dogwatch

/// The data Codex, Claude and Grok already read and now show: Codex's per-model limits and
/// credits, Claude's extra usage and spend when switched on, Grok's prepaid balance.
final class SubscriptionExtrasTests: XCTestCase {
    private func codexResult(_ fixture: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data(fixture)) as? [String: Any])
    }

    // MARK: Codex

    func testCodexShowsPerModelLimitsAndCreditsWithoutChangingItsPrimary() throws {
        let rateLimits = try codexResult("codex/rate-limits-by-model.json")
        let usage = try CodexUsageClient.parse(rateLimits: rateLimits, tokenUsage: ["summary": [:], "dailyUsageBuckets": []])
        let snapshot = CodexProvider.snapshot(from: usage, extras: CodexUsageClient.extras(from: rateLimits))

        XCTAssertEqual(snapshot.readings.map(\.id), ["primary", "model:codex_other", "model:codex_other:secondary", "credits"])
        XCTAssertEqual(snapshot.primary()?.id, "primary", "The main window stays the gauge.")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 60)
        let spark = try XCTUnwrap(snapshot.readings.first { $0.id == "model:codex_other" })
        XCTAssertEqual(spark.name, "Spark 5h")
        XCTAssertEqual(spark.remainingPercent, 37)
        XCTAssertEqual(spark.resetsAt, Date(timeIntervalSince1970: 4_099_990_000))
        XCTAssertEqual(snapshot.readings.first { $0.id == "model:codex_other:secondary" }?.name, "Spark weekly")
        XCTAssertEqual(snapshot.readings.last?.balance?.remaining, Amount(value: 1_250.5, unit: .credits))
        XCTAssertNil(snapshot.note)

        let item = BridgeLayout.instrument(descriptor: CodexProvider().descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 60)
        XCTAssertEqual(item.meters.map(\.label), ["Spark 5h", "Spark weekly"])
        XCTAssertTrue(item.notes.contains("Credits 1.3k credits left"), "\(item.notes)")
    }

    func testCodexWithoutCreditsOrModelLimitsIsUnchangedAndSaysWhenBlocked() throws {
        let rateLimits = try codexResult("codex/rate-limits-blocked.json")
        let usage = try CodexUsageClient.parse(rateLimits: rateLimits, tokenUsage: ["summary": [:], "dailyUsageBuckets": []])
        let snapshot = CodexProvider.snapshot(from: usage, extras: CodexUsageClient.extras(from: rateLimits))

        XCTAssertEqual(snapshot.readings.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(snapshot.note, "Codex says included usage is blocked right now")
        XCTAssertEqual(snapshot.readings.map(\.id), CodexProvider.snapshot(from: usage).readings.map(\.id))
    }

    // MARK: Claude

    func testClaudeWithExtraUsageOffLooksExactlyAsBefore() throws {
        let claude = try ClaudeUsageClient.parseUsage(Fixture.data("claude/usage-weekly-scoped.json"), fetchedAt: Date())
        XCTAssertNil(claude.extraUsage)
        XCTAssertNil(claude.spend)
        let off = try ClaudeUsageClient.parseUsage(Fixture.data("claude/usage-spend-off.json"), fetchedAt: Date())
        XCTAssertEqual(ClaudeProvider.snapshot(from: off).readings.map(\.id), ["five_hour", "seven_day"])
    }

    func testClaudeShowsExtraUsageAndSpendWhenOnWithoutTouchingTheGaugeOrMenuBar() throws {
        let claude = try ClaudeUsageClient.parseUsage(Fixture.data("claude/usage-extra-usage-on.json"), fetchedAt: Date())
        let snapshot = ClaudeProvider.snapshot(from: claude)
        let item = BridgeLayout.instrument(descriptor: ClaudeProvider().descriptor, snapshot: snapshot, error: nil)

        XCTAssertEqual(snapshot.readings.map(\.id), ["seven_day", "scoped:fable", "extra_usage", "spend"])
        XCTAssertEqual(snapshot.primary()?.id, "scoped:fable", "The model-scoped weekly limit stays primary.")
        XCTAssertEqual(item.remaining, 20)
        XCTAssertEqual(item.meters.map(\.label), ["Week"], "The overall week stays under it.")
        XCTAssertEqual(item.menuValue, "20%", "Extra usage never stands in for the plan's limit.")

        let extra = try XCTUnwrap(snapshot.readings.first { $0.id == "extra_usage" })
        XCTAssertEqual(extra.amount, Amount(value: 12.4, unit: .currency("USD")))
        XCTAssertEqual(extra.remainingPercent, 75, "Its own cap is a real total.")
        XCTAssertFalse(extra.canHeadline, "But it is never the plan's headline number.")
        XCTAssertEqual(snapshot.tightestRemainingPercent, 20)
        XCTAssertEqual(extra.detailText, "$12.40 of $50.00 spent · this month")
        let spend = try XCTUnwrap(snapshot.readings.first { $0.id == "spend" })
        XCTAssertEqual(spend.amount, Amount(value: 18.9, unit: .currency("EUR")))
        XCTAssertTrue(item.notes.contains("Extra usage 75% left"), "\(item.notes)")
    }

    // MARK: Grok

    func testGrokPrepaidBalanceIsItsOwnReading() throws {
        let line = #"{"ts":"2026-08-16T10:00:00.000000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":39.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-08-17T19:45:41+00:00"},"prepaidBalance":{"val":500}},"subscriptionTier":"X Premium+"}}"#
        let record = try XCTUnwrap(GrokUsageClient.lastBillingRecord(in: Data(line.utf8)))
        let snapshot = GrokProvider.snapshot(from: try GrokUsageClient.parse(context: record.context))
        let item = BridgeLayout.instrument(descriptor: GrokProvider().descriptor, snapshot: snapshot, error: nil)

        XCTAssertEqual(snapshot.readings.map(\.id), ["credits", "prepaid"])
        XCTAssertEqual(snapshot.primary()?.id, "credits")
        XCTAssertEqual(snapshot.readings.last?.balance?.remaining, Amount(value: 5, unit: .currency("USD")))
        XCTAssertEqual(snapshot.label, "X Premium+", "The balance is no longer text in the label.")
        XCTAssertEqual(item.remaining, 61)
        XCTAssertTrue(item.notes.contains("Prepaid balance $5.00 left"), "\(item.notes)")
    }

    func testGrokWithoutABalanceHasOnlyTheWindow() throws {
        let snapshot = GrokProvider.snapshot(from: try GrokUsageClient.parse(context: ["config": ["creditUsagePercent": 10]]))
        XCTAssertEqual(snapshot.readings.map(\.id), ["credits"])
    }
}
