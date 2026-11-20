import Foundation
import XCTest
@testable import Dogwatch

final class VercelAIGatewayDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.vercelAIGateway)
    private let url = "https://ai-gateway.vercel.sh/v1/credits"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "vercel-ai-gateway", hosts: ["ai-gateway.vercel.sh"])
    }

    func testTokenPassIsThePrimaryWithItsReset() async throws {
        let (snapshot, transport) = try await harness.fetch("vercel-ai-gateway/credits-pass.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["token_pass", "balance", "total_used"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "token_pass")
        XCTAssertEqual(primary.amount, Amount(value: 12.34, unit: .currency("USD")))
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2026-12-01T00:00:00.000Z"))
        XCTAssertEqual(harness.reading("balance", in: snapshot)?.amount, Amount(value: 95.5, unit: .currency("USD")))
        XCTAssertEqual(harness.reading("total_used", in: snapshot)?.amount, Amount(value: 4.5, unit: .currency("USD")))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testWithoutAPassTheBalanceIsThePrimary() async throws {
        let (snapshot, _) = try await harness.fetch("vercel-ai-gateway/credits-no-pass.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["balance", "total_used"])
        XCTAssertEqual(snapshot.primary()?.id, "balance")
        let item = BridgeLayout.instrument(descriptor: harness.descriptor, snapshot: snapshot, error: nil)
        XCTAssertNil(item.remaining, "a balance without a total has no percentage")
    }

    func testAnUnreadablePassIsLeftOutNotZero() async throws {
        let (snapshot, _) = try await harness.fetch("vercel-ai-gateway/credits-pass-unreadable.json", prefix: url)
        XCTAssertNil(harness.reading("token_pass", in: snapshot))
        XCTAssertEqual(snapshot.primary()?.id, "balance")
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
