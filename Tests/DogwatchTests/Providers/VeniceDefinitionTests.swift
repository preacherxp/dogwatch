import Foundation
import XCTest
@testable import Dogwatch

final class VeniceDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.venice)
    private let url = "https://api.venice.ai/api/v1/billing/balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "venice", hosts: ["api.venice.ai"])
    }

    func testDiemIsThePrimaryWhenVeniceSpendsIt() async throws {
        let (snapshot, transport) = try await harness.fetch("venice/balance-diem.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["usd", "diem", "bundled", "earned"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "diem")
        XCTAssertEqual(primary.balance?.remaining, Amount(value: 90.5, unit: .custom("DIEM")))
        XCTAssertEqual(primary.remainingPercent, 91)
        XCTAssertEqual(harness.reading("usd", in: snapshot)?.amount, Amount(value: 25, unit: .currency("USD")))
        XCTAssertEqual(harness.reading("bundled", in: snapshot)?.amount, Amount(value: 10, unit: .credits))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testAnEmptyDollarBalanceShowsAsZero() async throws {
        // Venice documents `usd` as null when zero; that is "nothing left", not "no balance".
        let (snapshot, _) = try await harness.fetch("venice/balance-usd-empty.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["usd"])
        XCTAssertEqual(snapshot.primary()?.id, "usd")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0, unit: .currency("USD")))
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
