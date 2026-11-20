import Foundation
import XCTest
@testable import Dogwatch

final class FireworksProviderTests: XCTestCase {
    private let provider = FireworksProvider()
    private let key = "fireworks-test-key-not-real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let prefix = "https://api.fireworks.ai/v1/accounts/sample-account/billing/summary"
    private let settings = ProviderSettings(values: ["account_id": "sample-account"])

    private func fetch(_ fixture: String, at date: Date? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix, fixture: fixture)
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.fields.map(\.id), ["account_id"])
    }

    func testUnitsPlusNanosAddUp() async throws {
        let (snapshot, transport) = try await fetch("fireworks/summary.json")

        // 12 units + 340,000,000 nanos + 50,000,000 nanos = $12.39.
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.amount?.value ?? 0, 12.39, accuracy: 1e-9)
        XCTAssertEqual(month.amount?.unit, .currency("USD"))
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount?.value ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(month.freshness, FireworksProvider.freshness)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "startTime" }?.value, "2026-11-01T00:00:00Z")
        XCTAssertEqual(query.first { $0.name == "endTime" }?.value, "2026-11-20T00:00:00Z", "endTime is exclusive: tomorrow, so today counts.")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testTheLastDayOfTheMonthEndsAtTheNextMonth() async throws {
        let transport = FixtureTransport()
        try transport.respond(to: "https://api.fireworks.ai/", fixture: "fireworks/empty.json")
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings,
                                       now: DateParsing.iso8601("2026-11-30T23:59:00Z")!)
        let snapshot = try await provider.fetch(in: context)
        let query = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "startTime" }?.value, "2026-11-01T00:00:00Z")
        XCTAssertEqual(query.first { $0.name == "endTime" }?.value, "2026-12-01T00:00:00Z")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0, unit: .currency("USD")), "An empty summary is a month with no usage.")
    }

    func testAMissingAccountIDFailsWithoutAnyRequest() async {
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
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, key: key)).isAvailable)
    }

    func testAnAccountIDCannotChangeThePath() async {
        let transport = FixtureTransport()
        let bad = ProviderSettings(values: ["account_id": "../other"])
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: bad))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingKeyFailsWithoutAnyRequest() async {
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: nil, settings: settings))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnexpectedAnswerNamesWhatIsMissing() async {
        do {
            _ = try await fetch("fireworks/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("lineItems"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: prefix, key: key, settings: settings)
    }
}
