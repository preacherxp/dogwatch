import Foundation
import XCTest
@testable import Dogwatch

final class V0ProviderTests: XCTestCase {
    private let provider = V0Provider()
    private let key = "v0-test-key-not-real"

    private func fetch(billing: String, rateLimits: String?, settings: ProviderSettings = ProviderSettings()) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: V0Provider.billingURL, fixture: billing)
        if let rateLimits { try transport.respond(to: V0Provider.rateLimitsURL, fixture: rateLimits) }
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.stability, .unverified)
    }

    func testTokenBillingShowsCreditsLeftOfTheCycle() async throws {
        let (snapshot, transport) = try await fetch(billing: "v0/billing-token.json", rateLimits: "v0/rate-limits-paid.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["credits", "on_demand"])
        XCTAssertEqual(snapshot.plan, "Premium")
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "credits")
        XCTAssertEqual(primary.balance?.remaining, Amount(value: 12.5, unit: .credits))
        XCTAssertEqual(primary.balance?.total, Amount(value: 20, unit: .credits))
        XCTAssertEqual(primary.remainingPercent, 63)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
        let onDemand = try XCTUnwrap(snapshot.readings.first { $0.id == "on_demand" })
        XCTAssertEqual(onDemand.amount, Amount(value: 4.25, unit: .credits))
        XCTAssertNil(onDemand.remainingPercent, "On-demand credits have no total.")

        XCTAssertEqual(transport.requests.count, 2)
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        }
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testLegacyAllowanceAndTheFreeDailyMessageLimit() async throws {
        let (snapshot, _) = try await fetch(billing: "v0/billing-legacy.json", rateLimits: "v0/rate-limits-free.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["credits", "daily_messages"])
        XCTAssertEqual(snapshot.primary()?.id, "credits")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 15)
        let daily = try XCTUnwrap(snapshot.readings.first { $0.id == "daily_messages" }?.window)
        XCTAssertEqual(daily.usedPercent, 29)
        XCTAssertEqual(daily.used, Amount(value: 2, unit: .custom("messages")))
        XCTAssertEqual(daily.limit, Amount(value: 7, unit: .custom("messages")))
        XCTAssertEqual(daily.resetsAt, Date(timeIntervalSince1970: 1_795_651_200))
    }

    func testScopeIsSentAsAQueryParameter() async throws {
        let (_, transport) = try await fetch(billing: "v0/billing-token.json", rateLimits: "v0/rate-limits-paid.json",
                                             settings: ProviderSettings(values: ["scope": "my-project"]))
        XCTAssertTrue(transport.requests.allSatisfy { $0.url?.query == "scope=my-project" })
    }

    func testAFailingRateLimitCallDoesNotHideTheBalance() async throws {
        let (snapshot, _) = try await fetch(billing: "v0/billing-token.json", rateLimits: nil)
        XCTAssertEqual(snapshot.readings.map(\.id), ["credits", "on_demand"])
    }

    func testUnknownBillingTypeIsAnError() async {
        do {
            _ = try await fetch(billing: "v0/unknown-type.json", rateLimits: nil)
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
        } catch {
            XCTFail("\(error)")
        }
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

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: "https://api.v0.dev/", key: key)
    }
}
