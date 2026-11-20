import Foundation
import XCTest
@testable import Dogwatch

final class KiloDefinitionTests: XCTestCase {
    private let provider = DeclarativeProvider(definition: DeclarativeProviders.kilo)
    private let key = "kilo-test-key-not-real"
    private let url = "https://api.kilo.ai/api/profile/balance"

    func testDefinitionIsValidAndFollowsTheRules() {
        XCTAssertNotNil(provider.spec, provider.descriptor.summary)
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.id, "kilo")
        XCTAssertEqual(provider.descriptor.stability, .unverified)
        XCTAssertEqual(provider.descriptor.allowedHosts, ["api.kilo.ai"])
        XCTAssertEqual(provider.descriptor.category, .subscription)
    }

    func testBalanceInDollars() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: "kilo/balance.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))

        XCTAssertEqual(snapshot.primary()?.id, "balance")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 18.37, unit: .currency("USD")))
        XCTAssertNil(snapshot.primary()?.remainingPercent)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: url, key: key)
    }
}
