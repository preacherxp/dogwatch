import Foundation
import XCTest
@testable import Dogwatch

final class PoeDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.poe)
    private let url = "https://api.poe.com/usage/current_balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "poe", hosts: ["api.poe.com"])
    }

    func testPointsAreNotMoney() async throws {
        let (snapshot, transport) = try await harness.fetch("poe/balance.json", prefix: url)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 295_932, unit: .custom("points")))
        XCTAssertFalse(snapshot.primary()?.amount?.unit.isCurrency ?? true)
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
