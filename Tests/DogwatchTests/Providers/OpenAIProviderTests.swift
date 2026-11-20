import Foundation
import XCTest
@testable import Dogwatch

final class OpenAIProviderTests: XCTestCase {
    private let provider = OpenAIProvider()
    private let key = "sk-admin-test-key-not-real"
    private let now = DateParsing.iso8601("2026-11-19T15:30:00Z")!
    private let costsPrefix = "https://api.openai.com/v1/organization/costs"
    private let limitURL = "https://api.openai.com/v1/organization/spend_limit"

    private func firstURL(at date: Date? = nil, project: String? = nil) -> String {
        OpenAIProvider.firstURL(now: date ?? now, project: project).absoluteString
    }

    private func fetch(
        _ responses: [String: String],
        settings: ProviderSettings = ProviderSettings(),
        at date: Date? = nil
    ) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        for (prefix, fixture) in responses { try transport.respond(to: prefix, fixture: fixture) }
        let context = TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings, now: date ?? now)
        return (try await provider.fetch(in: context), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        guard case .pastedKey(let spec) = provider.descriptor.credential else { return XCTFail("needs a pasted key") }
        XCTAssertEqual(spec.kind, .adminKey)
        XCTAssertTrue(spec.isPowerful)
        XCTAssertNotNil(spec.warning)
        XCTAssertNotNil(spec.advice)
        XCTAssertEqual(provider.descriptor.stability, .unverified)
        XCTAssertGreaterThanOrEqual(provider.descriptor.minimumRefreshInterval, 900)
    }

    func testSumsTheMonthsDailyBucketsAndToday() async throws {
        let (snapshot, transport) = try await fetch([costsPrefix: "openai/costs-month.json", limitURL: "openai/spend-limit.json"])

        XCTAssertEqual(snapshot.readings.map(\.id), ["spend_month", "spend_today"])
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.id, "spend_month")
        XCTAssertEqual(month.amount, Amount(value: 4.5, unit: .currency("USD")))
        XCTAssertNil(month.remainingPercent, "Spend without a budget has no percentage.")
        XCTAssertEqual(month.spend?.period, "this month (UTC)")
        XCTAssertEqual(month.resetsAt, DateParsing.iso8601("2026-12-01T00:00:00Z"))
        XCTAssertEqual(month.freshness, OpenAIProvider.freshness)
        XCTAssertEqual(snapshot.readings[1].amount, Amount(value: 2.5, unit: .currency("USD")))
        XCTAssertEqual(snapshot.readings[1].spend?.period, "today (UTC)")

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertNil(item.remaining)
        XCTAssertEqual(item.amount, "$4.50")
        XCTAssertEqual(item.menuValue, "$4.50")
        XCTAssertEqual(item.detail, "$4.50 spent · this month (UTC)")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "start_time" }?.value, "1793491200", "The UTC start of November.")
        XCTAssertEqual(query.first { $0.name == "bucket_width" }?.value, "1d")
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testTheSpendLimitIsANoteNotAPercentageAndNoRecipientLeaks() async throws {
        let (snapshot, _) = try await fetch([costsPrefix: "openai/costs-month.json", limitURL: "openai/spend-limit.json"])
        XCTAssertEqual(snapshot.note, "Organization hard limit $100.00 a month (enforcing).")
        XCTAssertNil(snapshot.primary()?.remainingPercent)
        XCTAssertFalse("\(snapshot)".contains("@"), "Notification recipients must never be read into the snapshot.")
    }

    func testAMissingSpendLimitIsLeftOut() async throws {
        let (snapshot, _) = try await fetch([costsPrefix: "openai/costs-month.json"])
        XCTAssertNil(snapshot.note)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 4.5, unit: .currency("USD")))
    }

    func testAUserBudgetTurnsSpendIntoAPercentage() async throws {
        let (snapshot, _) = try await fetch([costsPrefix: "openai/costs-month.json"])
        var options = InstrumentOptions()
        options.userLimits = ["spend_month": 10]
        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil, options: options)
        XCTAssertEqual(item.remaining, 55)
        XCTAssertEqual(item.detail, "$4.50 of $10.00 spent · this month (UTC)")
    }

    func testFollowsPagesAndAddsThemUp() async throws {
        let first = firstURL()
        let (snapshot, transport) = try await fetch([first: "openai/costs-page1.json", first + "&page=page_sample_2": "openai/costs-page2.json"])
        XCTAssertEqual(transport.requests.filter { $0.url!.path.hasSuffix("/costs") }.count, 2)
        XCTAssertEqual(snapshot.primary()?.amount?.value ?? 0, 10.4, accuracy: 1e-9)
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount, Amount(value: 0.4, unit: .currency("USD")))
    }

    func testARunawayCursorIsCappedAndTheTotalMarkedIncomplete() async throws {
        let (snapshot, transport) = try await fetch([costsPrefix: "openai/costs-endless.json"])
        XCTAssertEqual(transport.requests.filter { $0.url!.path.hasSuffix("/costs") }.count, OpenAIProvider.maxPages)
        let month = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(month.name, "This month (incomplete)")
        XCTAssertEqual(month.detail, "At least $5.00 spent · this month (UTC) · report cut off")
        XCTAssertTrue(snapshot.note?.contains("incomplete") == true)
    }

    func testOnTheFirstOfTheMonthOnlyTheNewMonthCounts() async throws {
        let firstOfDecember = DateParsing.iso8601("2026-12-01T00:20:00Z")!
        let (snapshot, transport) = try await fetch([costsPrefix: "openai/costs-december-boundary.json"], at: firstOfDecember)
        let query = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "start_time" }?.value, "1796083200", "The UTC start of December.")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0.3, unit: .currency("USD")), "October's bucket must not count.")
        XCTAssertEqual(snapshot.readings.first { $0.id == "spend_today" }?.amount, Amount(value: 0.3, unit: .currency("USD")))
        XCTAssertEqual(snapshot.primary()?.resetsAt, DateParsing.iso8601("2027-01-01T00:00:00Z"))
    }

    func testAProjectFilterIsSentAndTheOrgLimitIsNotRead() async throws {
        let settings = ProviderSettings(values: ["project_id": "proj_sample"])
        let (snapshot, transport) = try await fetch([costsPrefix: "openai/costs-month.json", limitURL: "openai/spend-limit.json"], settings: settings)
        let query = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "project_ids[]" }?.value, "proj_sample")
        XCTAssertFalse(transport.requests.contains { $0.url!.path.hasSuffix("spend_limit") }, "The org-wide limit doesn't apply to one project.")
        XCTAssertNil(snapshot.note)
        XCTAssertEqual(snapshot.primary()?.name, "Project this month")
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
            _ = try await fetch([costsPrefix: "openai/unexpected.json"])
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("data"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(provider, url: costsPrefix, key: key)
    }
}
