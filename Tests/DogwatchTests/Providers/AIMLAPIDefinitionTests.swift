import Foundation
import XCTest
@testable import Dogwatch

final class AIMLAPIDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.aimlapi)
    private let url = "https://api.aimlapi.com/v2/billing"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "aimlapi", hosts: ["api.aimlapi.com"])
    }

    func testBalanceInDollars() async throws {
        let (snapshot, transport) = try await harness.fetch("aimlapi/billing.json", prefix: url)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 123.45, unit: .currency("USD")))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
