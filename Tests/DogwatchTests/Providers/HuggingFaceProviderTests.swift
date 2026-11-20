import Foundation
import XCTest
@testable import Dogwatch

final class HuggingFaceProviderTests: XCTestCase {
    private let provider = HuggingFaceProvider()
    private let key = "hf_test_token_not_real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let prefix = "https://huggingface.co/api/organizations/sample-org/billing/usage/inference"
    private let settings = ProviderSettings(values: ["organization": "sample-org"])

    private func fetch(_ fixture: String, at date: Date? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix, fixture: fixture)
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.fields.map(\.id), ["organization"])
    }

    func testCostCentsAreAddedAcrossMembersAndDays() async throws {
        let (snapshot, transport) = try await fetch("huggingface/usage.json")

        let month = try XCTUnwrap(snapshot.primary())
        // 150 + 25 + 1234 cents = $14.09, not $1,409.
        XCTAssertEqual(month.amount?.value ?? 0, 14.09, accuracy: 1e-9)
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount?.value ?? 0, 12.34, accuracy: 1e-9)
        XCTAssertEqual(month.freshness, HuggingFaceProvider.freshness)
        XCTAssertFalse("\(snapshot)".contains("sample-member"), "Member names must not reach the snapshot.")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "startDate" }?.value, "2026-11-01T00:00:00Z")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "31", "One page holds a whole month.")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testOnTheFirstOfTheMonthOldPeriodsDoNotCount() async throws {
        let (snapshot, _) = try await fetch("huggingface/usage.json", at: DateParsing.iso8601("2026-12-01T00:30:00Z")!)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0, unit: .currency("USD")))
    }

    func testAMissingOrganizationFailsWithoutAnyRequest() async {
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
            _ = try await fetch("huggingface/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: prefix, key: key, settings: settings)
    }
}
