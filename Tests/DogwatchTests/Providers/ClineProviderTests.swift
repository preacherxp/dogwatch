import Foundation
import XCTest
@testable import Dogwatch

final class ClineProviderTests: XCTestCase {
    private let provider = ClineProvider()
    private let key = "cline-test-key-not-real"

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testPersonalBalanceInDollarsAfterLookingUpTheUser() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: "https://api.cline.bot/api/v1/users/me", fixture: "cline/me.json")
        try transport.respond(to: "https://api.cline.bot/api/v1/users/user-sample-0001/balance", fixture: "cline/balance.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))

        XCTAssertEqual(snapshot.readings.map(\.id), ["balance"])
        XCTAssertEqual(snapshot.primary()?.amount?.unit, .currency("USD"))
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 12.345678, accuracy: 0.000001)
        XCTAssertNil(snapshot.primary()?.remainingPercent)

        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/api/v1/users/me", "/api/v1/users/user-sample-0001/balance"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" })
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testOrganisationBalanceIsOneRequest() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: "https://api.cline.bot/api/v1/organizations/org-sample-0001/balance", fixture: "cline/org-balance.json")
        let snapshot = try await provider.fetch(in: TestContext.make(
            for: provider.descriptor, transport: transport, key: key,
            settings: ProviderSettings(values: ["organization": "org-sample-0001"])
        ))

        XCTAssertEqual(snapshot.primary()?.name, "Organisation balance")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 250, unit: .currency("USD")))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAnErrorInTheEnvelopeIsAnError() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: "https://api.cline.bot/api/v1/users/me", fixture: "cline/error.json")
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("User not found"))
        }
    }

    func testMissingKeyFailsWithoutAnyRequest() async {
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: nil))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: "https://api.cline.bot/", key: key)
    }
}
