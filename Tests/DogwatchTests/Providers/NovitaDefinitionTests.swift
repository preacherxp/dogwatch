import Foundation
import XCTest
@testable import Dogwatch

final class NovitaDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.novita)
    private let url = "https://api.novita.ai/openapi/v1/billing/balance/detail"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "novita", hosts: ["api.novita.ai"])
    }

    func testBalanceIsInTenThousandthsOfADollar() async throws {
        let (snapshot, transport) = try await harness.fetch("novita/balance.json", prefix: url)
        // "1253400" is $125.34; reading it as cents would give $12,534.00.
        XCTAssertEqual(snapshot.primary()?.id, "balance")
        XCTAssertEqual(snapshot.primary()?.amount?.unit, .currency("USD"))
        XCTAssertEqual(try XCTUnwrap(snapshot.primary()?.amount?.value), 125.34, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(harness.reading("cash", in: snapshot)?.amount?.value), 80, accuracy: 0.0001)
        let item = BridgeLayout.instrument(descriptor: harness.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.detail, "$125.34 left")
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
