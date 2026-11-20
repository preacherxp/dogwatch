import Foundation
import XCTest
@testable import Dogwatch

final class HyperbolicDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.hyperbolic)
    private let url = "https://api.hyperbolic.ai/v2/customer/balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "hyperbolic", hosts: ["api.hyperbolic.ai"])
    }

    func testBalanceIsInCents() async throws {
        let (snapshot, transport) = try await harness.fetch("hyperbolic/balance.json", prefix: url)
        // 2450 cents is $24.50, not $2,450.
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 24.5, unit: .currency("USD")))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
