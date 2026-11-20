import Foundation
import XCTest
@testable import Dogwatch

final class DeepInfraProviderTests: XCTestCase {
    private let provider = DeepInfraProvider()
    private let key = "deepinfra-test-key-not-real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let usageURL = "https://api.deepinfra.com/payment/usage"
    private let keyLimitsURL = "https://api.deepinfra.com/payment/key-limits"
    private let configURL = "https://api.deepinfra.com/payment/config"

    private func fetch(_ responses: [String: String], at date: Date? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        for (url, fixture) in responses { try transport.respond(to: url, fixture: fixture) }
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        guard case .pastedKey(let spec) = provider.descriptor.credential else { return XCTFail("needs a pasted key") }
        XCTAssertTrue(spec.advice?.contains("billing:read") == true, "Recommend the read-only billing scope.")
    }

    func testTotalCostIsCents() async throws {
        let (snapshot, transport) = try await fetch([
            usageURL: "deepinfra/usage.json", keyLimitsURL: "deepinfra/key-limits.json", configURL: "deepinfra/config.json",
        ])

        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.id, "spend_month")
        // 1234 cents = $12.34, not $1,234.
        XCTAssertEqual(month.amount, Amount(value: 12.34, unit: .currency("USD")))
        XCTAssertEqual(month.spend?.period, "this month (UTC)")
        XCTAssertEqual(month.resetsAt, DateParsing.iso8601("2026-12-01T00:00:00Z"))
        XCTAssertNil(month.remainingPercent)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepinfra.com/payment/usage?from=current")
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" })
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testTheTightestKeyLimitIsShownWithoutItsName() async throws {
        let (snapshot, _) = try await fetch([
            usageURL: "deepinfra/usage.json", keyLimitsURL: "deepinfra/key-limits.json", configURL: "deepinfra/config.json",
        ])
        let keyLimit = try XCTUnwrap(snapshot.readings.first { $0.id == "key_limit" })
        // $10 limit with $9 spent beats $20 with $5 spent; keys without a limit or a computed spend are skipped.
        XCTAssertEqual(keyLimit.balance?.remaining, Amount(value: 1, unit: .currency("USD")))
        XCTAssertEqual(keyLimit.balance?.total, Amount(value: 10, unit: .currency("USD")))
        XCTAssertEqual(keyLimit.remainingPercent, 10)
        XCTAssertFalse("\(snapshot)".contains("sample-"), "Key names must not reach the snapshot.")
        XCTAssertEqual(snapshot.primary()?.id, "spend_month", "Spend stays the primary; the key limit is a note.")
        XCTAssertEqual(snapshot.note, "Account spending limit $50.00.")
    }

    func testNoAccountLimitAndNoKeyLimitsLeaveOnlySpend() async throws {
        let (snapshot, _) = try await fetch([usageURL: "deepinfra/usage.json", configURL: "deepinfra/config-none.json"])
        XCTAssertEqual(snapshot.readings.map(\.id), ["spend_month"])
        XCTAssertNil(snapshot.note)
    }

    func testAnEmptyAccountIsZero() async throws {
        let (snapshot, _) = try await fetch([usageURL: "deepinfra/usage-empty.json"])
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0, unit: .currency("USD")))
    }

    func testAnotherMonthIsLabelledAsThatMonth() async throws {
        // On 1 December (UTC) a lagging answer for November must not be shown as December.
        let (snapshot, _) = try await fetch([usageURL: "deepinfra/usage.json"], at: DateParsing.iso8601("2026-12-01T00:05:00Z")!)
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.name, "Month 2026.11")
        XCTAssertEqual(month.spend?.period, "2026.11 (UTC)")
        XCTAssertNil(month.resetsAt)
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
            _ = try await fetch([usageURL: "deepinfra/unexpected.json"])
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("months"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAKeyWithoutBillingReadSaysWhichScopeIsMissing() async {
        let transport = FixtureTransport()
        transport.respond(to: usageURL, status: 403, body: Data(#"{"detail":{"error":"sample"}}"#.utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertTrue(error.localizedDescription.contains("billing:read"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: "https://api.deepinfra.com/", key: key)
    }
}
