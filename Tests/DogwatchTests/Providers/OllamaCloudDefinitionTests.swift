import Foundation
import XCTest
@testable import Dogwatch

final class OllamaCloudDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.ollamaCloud)
    private let url = "https://ollama.com/api/balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "ollama-cloud", hosts: ["ollama.com"])
    }

    func testRespectsTheSharedRateLimit() {
        // 10 requests a minute across all of the user's keys and devices.
        XCTAssertGreaterThanOrEqual(harness.descriptor.minimumRefreshInterval, 120)
        XCTAssertGreaterThanOrEqual(harness.descriptor.defaultRefreshInterval, harness.descriptor.minimumRefreshInterval)
    }

    func testCurrentPlanIncludedCreditsOfTheAllowance() async throws {
        let (snapshot, transport) = try await harness.fetch("ollama-cloud/balance-current.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["included", "purchased"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "included")
        XCTAssertEqual(primary.balance?.remaining, Amount(value: 72.5, unit: .currency("USD")))
        XCTAssertEqual(primary.balance?.total, Amount(value: 100, unit: .currency("USD")))
        XCTAssertEqual(primary.remainingPercent, 73)
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2026-12-15T09:30:00Z"))
        XCTAssertEqual(harness.reading("purchased", in: snapshot)?.amount, Amount(value: 25, unit: .currency("USD")))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testLegacyPlanShowsTheLowerOfSessionAndWeekly() async throws {
        let (snapshot, _) = try await harness.fetch("ollama-cloud/balance-legacy.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["session", "weekly", "purchased"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "weekly")
        XCTAssertEqual(primary.remainingPercent, 40, "remaining_percent is what is left, not what is used")
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2026-11-23T00:00:00Z"))
        XCTAssertEqual(harness.reading("session", in: snapshot)?.remainingPercent, 75)
        XCTAssertEqual(harness.reading("session", in: snapshot)?.meterLabel, "Session")
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
