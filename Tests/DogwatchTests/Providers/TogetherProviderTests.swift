import Foundation
import XCTest
@testable import Dogwatch

final class TogetherProviderTests: XCTestCase {
    private let provider = TogetherProvider()
    private let key = "together-test-key-not-real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let prefix = "https://api.together.ai/v1/billing/usage"

    private func fetch(_ responses: [String: String], at date: Date? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        for (url, fixture) in responses { try transport.respond(to: url, fixture: fixture) }
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertGreaterThanOrEqual(provider.descriptor.minimumRefreshInterval, 900, "Finalised windows change at most hourly.")
    }

    func testSumsDecimalStringCostsForTheMonthAndToday() async throws {
        let (snapshot, transport) = try await fetch([prefix: "together/usage-month.json"])

        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.id, "spend_month")
        XCTAssertEqual(month.amount?.value ?? 0, 1.84, accuracy: 1e-9)
        XCTAssertEqual(month.amount?.unit, .currency("USD"))
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount?.value ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(month.freshness, TogetherProvider.freshness)
        XCTAssertEqual(month.resetsAt, DateParsing.iso8601("2026-12-01T00:00:00Z"))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "month" }?.value, "2026-11")
        XCTAssertEqual(query.first { $0.name == "granularity" }?.value, "hour")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testFollowsTheCursor() async throws {
        let first = TogetherProvider.firstURL(now: now).absoluteString
        let (snapshot, transport) = try await fetch([first: "together/usage-page1.json", first + "&after=cursor_sample": "together/usage-page2.json"])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 3.25, accuracy: 1e-9)
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount?.value ?? 0, 0.25, accuracy: 1e-9)
    }

    func testAnEmptyMonthIsZeroNotAnError() async throws {
        let (snapshot, _) = try await fetch([prefix: "together/usage-empty.json"])
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0, unit: .currency("USD")))
    }

    func testOnTheFirstOfTheMonthItAsksForTheNewMonthAndRefusesAnotherOne() async throws {
        let firstOfDecember = DateParsing.iso8601("2026-12-01T00:10:00Z")!
        do {
            _ = try await fetch([prefix: "together/usage-month.json"], at: firstOfDecember)
            XCTFail("November's report must not be shown as December's")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
        }
        let transport = FixtureTransport()
        try transport.respond(to: prefix, fixture: "together/usage-month.json")
        _ = try? await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, now: firstOfDecember))
        let query = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "month" }?.value, "2026-12")
    }

    func testNotEnabledForTheOrganizationSaysSo() async {
        let transport = FixtureTransport()
        transport.respond(to: prefix, status: 404, body: Data(#"{"error":{"type":"not_found","message":"sample"}}"#.utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, now: now))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertTrue(error.localizedDescription.contains("isn't enabled"))
        } catch {
            XCTFail("\(error)")
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
        await assertMapsHTTPErrors(provider, url: prefix, key: key)
    }
}
