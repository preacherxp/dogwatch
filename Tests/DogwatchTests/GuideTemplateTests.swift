import Foundation
import SwiftUI
import XCTest
@testable import Dogwatch

// The templates in docs/ADDING-A-PROVIDER.md, copied verbatim, so the guide can't drift from
// what compiles. Regenerate this file when the guide's templates change.


// <Name>: what it reads and why this source.
// API reference, read <date>: <URL>

struct ExampleProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "example",
        name: "Example",
        glyph: ProviderGlyph(symbol: "creditcard"),
        tint: .teal,
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(label: "API key", placeholder: "ex-…", helpURL: URL(string: "https://example.com/keys"))),
        summary: "Prepaid balance",
        reads: "One GET to https://api.example.com/v1/balance, with your key from the Keychain in the Authorization header.",
        source: "Example API `GET /v1/balance`",
        allowedHosts: ["api.example.com"],
        minimumRefreshInterval: 60,
        idleLabel: "Add an API key"
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else { throw ProviderError.notSignedIn("No Example key set. Add one in settings.") }
        let json = try await context.http.getJSON(URL(string: "https://api.example.com/v1/balance")!, headers: ["Authorization": "Bearer \(key)"])
        guard let cents = json.value(at: "data.balance_cents")?.doubleValue else {
            throw ProviderError.unexpectedResponse("Example's answer has no data.balance_cents.")
        }
        return ProviderSnapshot(readings: [Reading(
            id: "balance", name: "Balance",
            value: .balance(Balance(remaining: Amount(value: cents / 100, unit: .currency("USD"))))
        )], fetchedAt: context.now())
    }
}

extension DeclarativeProviders {
    /// Example: prepaid balance in cents.
    /// API reference, read <date>: <URL>
    static let example = """
    {
      "id": "example",
      "name": "Example",
      "stability": "unverified",
      "summary": "Prepaid balance",
      "source": "Example API `GET /v1/balance`",
      "documentation": "https://example.com/docs/balance",
      "glyph": "creditcard",
      "keyHelpURL": "https://example.com/keys",
      "url": "https://api.example.com/v1/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Balance", "kind": "balance",
          "remaining": "data.balance_cents", "unit": "USD", "scale": 0.01 }
      ]
    }
    """
}

final class GuideTemplateTests: XCTestCase {
    func testTheSwiftTemplateWorks() async throws {
        let provider = ExampleProvider()
        assertFollowsRules(provider)
        let transport = FixtureTransport()
        transport.respond(to: "https://api.example.com/v1/balance", body: Data(#"{"data": {"balance_cents": 2450}}"#.utf8))
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: "ex-test"))
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 24.5, unit: .currency("USD")))
        await assertMapsHTTPErrors(provider, url: "https://api.example.com/", key: "ex-test")
    }

    func testTheDeclarativeTemplateWorks() async throws {
        let provider = DeclarativeProvider(definition: DeclarativeProviders.example)
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.allowedHosts, ["api.example.com"])
        let transport = FixtureTransport()
        transport.respond(to: "https://api.example.com/v1/balance", body: Data(#"{"data": {"balance_cents": 2450}}"#.utf8))
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: "ex-test"))
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 24.5, unit: .currency("USD")))
    }
}
