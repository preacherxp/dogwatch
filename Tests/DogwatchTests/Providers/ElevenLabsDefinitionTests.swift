import Foundation
import XCTest
@testable import Dogwatch

final class ElevenLabsDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.elevenlabs)

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "elevenlabs", hosts: [
            "api.elevenlabs.io", "api.us.elevenlabs.io", "api.eu.residency.elevenlabs.io",
            "api.in.residency.elevenlabs.io", "api.sg.residency.elevenlabs.io",
        ])
    }

    func testCreditsUsedOfTheLimitWithTheReset() async throws {
        let (snapshot, transport) = try await harness.fetch("elevenlabs/subscription.json", prefix: "https://api.elevenlabs.io/")
        let window = try XCTUnwrap(snapshot.primary()?.window)
        XCTAssertEqual(window.usedPercent, 12)
        XCTAssertEqual(window.used, Amount(value: 12_000, unit: .credits))
        XCTAssertEqual(window.limit, Amount(value: 100_000, unit: .credits))
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
        let item = BridgeLayout.instrument(descriptor: harness.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 88)
        assertSentKey(transport, harness: harness, header: "xi-api-key", value: harness.key, url: "https://api.elevenlabs.io/v1/user/subscription")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testARegionalHost() async throws {
        let settings = ProviderSettings(baseURL: URL(string: "https://api.eu.residency.elevenlabs.io"))
        let (_, transport) = try await harness.fetch("elevenlabs/subscription.json", prefix: "https://api.eu.residency.elevenlabs.io/", settings: settings)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.eu.residency.elevenlabs.io/v1/user/subscription")
    }

    func testNoLimitIsNotAPercentage() async throws {
        let (snapshot, _) = try await harness.fetch("elevenlabs/subscription-disabled.json", prefix: "https://api.elevenlabs.io/")
        XCTAssertTrue(snapshot.readings.isEmpty, "a limit of 0 gives no percentage, not 100% used")
        XCTAssertNotNil(snapshot.note)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: "https://api.elevenlabs.io/", key: harness.key)
    }
}
