import Foundation
import XCTest
@testable import Dogwatch

final class MistralAPIProviderTests: XCTestCase {
    private let provider = MistralAPIProvider()
    private let key = "mistral-admin-test-key-not-real"
    private let url = "https://api.mistral.ai/v1/admin/spend-limit"

    private func fetch(_ fixture: String) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        return (try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key)), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        guard case .pastedKey(let spec) = provider.descriptor.credential else { return XCTFail("needs a pasted key") }
        XCTAssertEqual(spec.kind, .adminKey)
        XCTAssertNotNil(spec.warning)
    }

    func testUsageAgainstTheProvidersOwnLimitIsAPercentage() async throws {
        let (snapshot, transport) = try await fetch("mistral-api/spend-limit.json")

        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.id, "spend_month")
        // Whole euros, not cents: 125 of 500.
        XCTAssertEqual(month.amount, Amount(value: 125, unit: .currency("EUR")))
        XCTAssertEqual(month.spend?.budget, Amount(value: 500, unit: .currency("EUR")))
        XCTAssertEqual(month.remainingPercent, 75)
        XCTAssertEqual(month.freshness, MistralAPIProvider.freshness)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 75)
        XCTAssertEqual(item.detail, "€125.00 of €500.00 spent · this month")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testNoMonthlyLimitShowsSpendOnly() async throws {
        let (snapshot, _) = try await fetch("mistral-api/no-limit.json")
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertNil(month.spend?.budget)
        XCTAssertNil(month.remainingPercent)
        XCTAssertEqual(month.amount, Amount(value: 37.25, unit: .currency("USD")))
        XCTAssertEqual(snapshot.label, "No monthly limit")
    }

    func testAReachedLimitSaysSo() async throws {
        let (snapshot, _) = try await fetch("mistral-api/reached.json")
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.remainingPercent, 0)
        XCTAssertEqual(month.detailText, "Monthly spend limit reached")
        XCTAssertTrue(month.isBinding)
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
    }

    func testUnexpectedAnswerNamesWhatIsMissing() async {
        do {
            _ = try await fetch("mistral-api/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("limits"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: url, key: key)
    }
}
