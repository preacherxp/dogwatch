import Foundation
import XCTest
@testable import Dogwatch

final class DeepgramProviderTests: XCTestCase {
    private let provider = DeepgramProvider()
    private let key = "test-key-not-real"
    private let project = ProviderSettings(values: ["project_id": "sample-project"])
    private let url = "https://api.deepgram.com/v1/projects/sample-project/balances"

    private func fetch(_ fixture: String) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: project))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.stability, .unverified)
        XCTAssertFalse(ProviderRegistry.defaultEnabled.contains("deepgram"))
        XCTAssertTrue(ProviderRegistry.builtIn.contains { $0.descriptor.id == "deepgram" })
        XCTAssertEqual(provider.descriptor.fields.map(\.id), ["project_id"])
    }

    func testBalancesAreSummedPerUnit() async throws {
        let (snapshot, transport) = try await fetch("deepgram/balances.json")
        XCTAssertEqual(snapshot.readings.map(\.id), ["balance_usd", "balance_hour"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "balance_usd")
        XCTAssertEqual(primary.amount, Amount(value: 187.5, unit: .currency("USD")))
        XCTAssertEqual(primary.name, "Balance (USD)")
        XCTAssertEqual(snapshot.readings.last?.amount, Amount(value: 12, unit: .custom("hour")))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testNoBalanceIsANote() async throws {
        let (snapshot, _) = try await fetch("deepgram/balances-empty.json")
        XCTAssertTrue(snapshot.readings.isEmpty)
        XCTAssertNotNil(snapshot.note)
    }

    func testMissingKeyOrProjectFailsWithoutARequest() async {
        for (key, settings, kind) in [(nil, project, "notSignedIn"), (key, ProviderSettings(), "notConfigured")] as [(String?, ProviderSettings, String)] {
            let transport = FixtureTransport()
            do {
                _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
                XCTFail("should fail")
            } catch let error as ProviderError {
                XCTAssertEqual(error.kind, kind)
            } catch {
                XCTFail("\(error)")
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAProjectIdCannotChangeThePath() async throws {
        let transport = FixtureTransport()
        let settings = ProviderSettings(values: ["project_id": "../keys"])
        _ = try? await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.deepgram.com/v1/projects/..%2Fkeys/balances")
    }

    func testAnswerWithoutBalances() async {
        let transport = FixtureTransport()
        transport.respond(to: url, body: Data(#"{"projects": []}"#.utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: project))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: url, key: key, settings: project)
    }
}
