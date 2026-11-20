import Foundation
import XCTest
@testable import Dogwatch

final class StabilityDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.stability)
    private let url = "https://api.stability.ai/v1/user/balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "stability", hosts: ["api.stability.ai"])
    }

    func testCreditsStayCredits() async throws {
        let (snapshot, transport) = try await harness.fetch("stability/balance.json", prefix: url)
        // 412.5 credits, shown as credits; never relabelled as $412.50.
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 412.5, unit: .credits))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
