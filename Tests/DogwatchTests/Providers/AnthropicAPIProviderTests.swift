import Foundation
import XCTest
@testable import Dogwatch

final class AnthropicAPIProviderTests: XCTestCase {
    private let provider = AnthropicAPIProvider()
    private let key = "sk-ant-admin01-test-key-not-real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let prefix = "https://api.anthropic.com/v1/organizations/cost_report"

    private func fetch(_ responses: [String: String], at date: Date? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        for (url, fixture) in responses { try transport.respond(to: url, fixture: fixture) }
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        guard case .pastedKey(let spec) = provider.descriptor.credential else { return XCTFail("needs a pasted key") }
        XCTAssertEqual(spec.kind, .adminKey)
        XCTAssertNotNil(spec.warning)
        XCTAssertNotNil(spec.advice)
        XCTAssertNotEqual(provider.descriptor.id, ProviderID.claude, "The Claude Code subscription is a different provider.")
    }

    func testAmountsAreCentsNotDollars() async throws {
        let (snapshot, transport) = try await fetch([prefix: "anthropic-api/cost-month.json"])

        XCTAssertEqual(snapshot.readings.map(\.id), ["spend_month", "spend_today"])
        // "123.45" + "1000" + "250.5" cents = 1373.95 cents = $13.7395. A dollars-as-sent mistake would give $1,373.95.
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.amount?.value ?? 0, 13.7395, accuracy: 1e-9)
        XCTAssertEqual(month.amount?.unit, .currency("USD"))
        XCTAssertEqual(snapshot.readings[1].amount?.value ?? 0, 2.505, accuracy: 1e-9)
        XCTAssertEqual(month.spend?.period, "this month (UTC)")
        XCTAssertEqual(month.freshness, AnthropicAPIProvider.freshness)
        XCTAssertNil(month.remainingPercent)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.amount, "$13.74")
        XCTAssertEqual(item.amountCaption, "spent")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), AnthropicAPIProvider.apiVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "starting_at" }?.value, "2026-11-01T00:00:00Z")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testFollowsPages() async throws {
        let first = AnthropicAPIProvider.firstURL(now: now).absoluteString
        let (snapshot, transport) = try await fetch([first: "anthropic-api/cost-page1.json", first + "&page=page_c2FtcGxl": "anthropic-api/cost-page2.json"])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 5.75, accuracy: 1e-9)
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount?.value ?? 0, 0.75, accuracy: 1e-9)
    }

    func testNoBucketForTodayMeansNoTodayReading() async throws {
        let (snapshot, _) = try await fetch([prefix: "anthropic-api/no-today.json"])
        XCTAssertEqual(snapshot.readings.map(\.id), ["spend_month"])
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 0.42, accuracy: 1e-9)
    }

    func testAUserBudgetTurnsSpendIntoAPercentage() async throws {
        let (snapshot, _) = try await fetch([prefix: "anthropic-api/cost-month.json"])
        var options = InstrumentOptions()
        options.userLimits = ["spend_month": 100]
        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil, options: options)
        XCTAssertEqual(item.remaining, 86)
    }

    func testOnTheFirstOfTheMonthTheReportStartsAtTheNewMonth() async throws {
        let (snapshot, transport) = try await fetch([prefix: "anthropic-api/cost-month.json"], at: DateParsing.iso8601("2026-12-01T00:05:00Z")!)
        let query = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "starting_at" }?.value, "2026-12-01T00:00:00Z")
        XCTAssertEqual(snapshot.primary()?.amount?.value, 0, "November buckets in the answer must not count in December.")
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

    func testUnexpectedAnswerNamesWhatIsMissing() async {
        do {
            _ = try await fetch([prefix: "anthropic-api/unexpected.json"])
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("data"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: prefix, key: key)
    }
}
