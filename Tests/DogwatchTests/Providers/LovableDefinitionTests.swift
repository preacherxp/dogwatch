import Foundation
import XCTest
@testable import Dogwatch

final class LovableDefinitionTests: XCTestCase {
    private let provider = DeclarativeProvider(definition: DeclarativeProviders.lovable)
    private let key = "lov_test-key-not-real"
    private let settings = ProviderSettings(values: ["workspace": "ws-sample-0001"])
    private let url = "https://api.lovable.dev/v1/workspaces/ws-sample-0001/credits/balance"

    func testDefinitionIsValidAndFollowsTheRules() {
        XCTAssertNotNil(provider.spec, provider.descriptor.summary)
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.id, "lovable")
        XCTAssertEqual(provider.descriptor.stability, .unverified)
        XCTAssertEqual(provider.descriptor.allowedHosts, ["api.lovable.dev"])
        XCTAssertEqual(provider.descriptor.fields.map(\.id), ["workspace"])
    }

    func testCreditsLeftFromADecimalString() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: "lovable/balance.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))

        XCTAssertEqual(snapshot.primary()?.id, "credits")
        XCTAssertEqual(snapshot.primary()?.amount?.unit, .credits)
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 124.456789123, accuracy: 0.000000001)
        XCTAssertNil(snapshot.primary()?.remainingPercent)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Lovable-API-Key"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Lovable-Version"), "2026-09-11")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testWithoutAWorkspaceItAsksForOneAndSendsNothing() async {
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: url, key: key, settings: settings)
    }
}
