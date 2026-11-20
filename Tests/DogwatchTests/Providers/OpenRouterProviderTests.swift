import Foundation
import XCTest
@testable import Dogwatch

/// The reference tests for a pasted-key provider. Copy this file for a new provider: one test per
/// fixture shape, the shared error mapping, and the request checks.
final class OpenRouterProviderTests: XCTestCase {
    private let provider = OpenRouterProvider()
    private let key = "sk-or-v1-test-key-not-real"
    private let url = "https://openrouter.ai/api/v1/key"

    private func fetch(_ fixture: String, key: String? = "sk-or-v1-test-key-not-real") async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testCappedKeyShowsWhatIsLeftOfTheCap() async throws {
        let (snapshot, transport) = try await fetch("openrouter/key-capped.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["budget", "spend_month", "spend_today"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "budget")
        XCTAssertEqual(primary.balance?.remaining, Amount(value: 12.41, unit: .currency("USD")))
        XCTAssertEqual(primary.remainingPercent, 62)
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_month" }?.amount, Amount(value: 3.4, unit: .currency("USD")))

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 62)
        XCTAssertEqual(item.detail, "$12.41 of $20.00 left")
        XCTAssertEqual(item.menuValue, "62%")
        XCTAssertTrue(item.notes.contains("This month $3.40 spent"))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testWeeklyBudgetIsTheBindingReadingWithItsReset() async throws {
        let (snapshot, _) = try await fetch("openrouter/key-weekly-budget.json")
        let primary = try XCTUnwrap(snapshot.primary())

        XCTAssertEqual(primary.id, "budget")
        XCTAssertEqual(primary.name, "Member budget")
        XCTAssertEqual(primary.remainingPercent, 20)
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2026-11-23T00:00:00.000Z"))
        XCTAssertNil(snapshot.readings.first { $0.id == "key_limit" }, "No key cap was set.")
        XCTAssertNil(snapshot.readings.first { $0.id == "free_requests" }, "Paid accounts aren't gated by the free-model counter.")
    }

    func testUncappedKeyShowsSpendWithoutAMadeUpPercentage() async throws {
        let (snapshot, _) = try await fetch("openrouter/key-uncapped.json")
        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)

        XCTAssertEqual(snapshot.primary()?.id, "spend_month")
        XCTAssertNil(snapshot.primary()?.remainingPercent, "Spend without a budget has no percentage.")
        XCTAssertNil(item.remaining)
        XCTAssertEqual(item.amount, "$3.40")
        XCTAssertEqual(item.amountCaption, "spent")
        XCTAssertEqual(item.menuValue, "$3.40")
        XCTAssertEqual(item.secondaryLabel, "No credit limit")
        XCTAssertEqual(snapshot.readings.first { $0.id == "free_requests" }?.remainingPercent, 76)
    }

    func testAUserBudgetTurnsSpendIntoAPercentage() async throws {
        let (snapshot, _) = try await fetch("openrouter/key-uncapped.json")
        var options = InstrumentOptions()
        options.userLimits = ["spend_month": 10]
        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil, options: options)

        XCTAssertEqual(item.remaining, 66)
        XCTAssertEqual(item.detail, "$3.40 of $10.00 spent · this month")
    }

    func testMissingKeyFailsWithoutAnyRequest() async {
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: nil))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(provider.availability(in: TestContext.make(for: provider.descriptor, key: nil)), .unavailable("No key set"))
    }

    func testUnexpectedAnswerNamesWhatIsMissing() async {
        do {
            _ = try await fetch("openrouter/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("data"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: url, key: key)
    }
}
