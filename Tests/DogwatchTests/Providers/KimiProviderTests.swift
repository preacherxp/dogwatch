import Foundation
import XCTest
@testable import Dogwatch

final class KimiProviderTests: XCTestCase {
    private let provider = KimiProvider()
    private let key = "kimi-test-key-not-real"
    private let url = "https://api.kimi.com/coding/v1/usages"
    private let now = Date(timeIntervalSince1970: 1_795_600_000)

    private func fetch(_ fixture: String, settings: ProviderSettings = ProviderSettings(), prefix: String? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix ?? url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings, now: now))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testSummaryAndWindowsAsTheKimiCLIReadsThem() async throws {
        let (snapshot, transport) = try await fetch("kimi/usages.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["summary", "window_300m", "limit_2"])
        let summary = try XCTUnwrap(snapshot.readings.first { $0.id == "summary" })
        XCTAssertEqual(summary.name, "Weekly limit")
        XCTAssertEqual(summary.window?.usedPercent, 25)
        XCTAssertEqual(summary.resetsAt, DateParsing.iso8601("2026-11-23T00:00:00Z"))

        let fiveHour = try XCTUnwrap(snapshot.readings.first { $0.id == "window_300m" })
        XCTAssertEqual(fiveHour.window?.usedPercent, 60, "used = limit - remaining")
        XCTAssertEqual(fiveHour.window?.period, .duration(5 * 3_600))
        XCTAssertEqual(fiveHour.name, "5h limit")

        let monthly = try XCTUnwrap(snapshot.readings.first { $0.id == "limit_2" })
        XCTAssertEqual(monthly.name, "Monthly total")
        XCTAssertEqual(monthly.window?.usedPercent, 10)
        XCTAssertEqual(monthly.resetsAt, now.addingTimeInterval(86_400))

        XCTAssertEqual(snapshot.primary()?.id, "window_300m", "The window with the least left is the primary.")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testOverseasRegion() async throws {
        let (_, transport) = try await fetch(
            "kimi/usages.json",
            settings: ProviderSettings(baseURL: URL(string: "https://api.kimi.ai")),
            prefix: "https://api.kimi.ai/coding/v1/usages"
        )
        XCTAssertEqual(transport.requests.first?.url?.host, "api.kimi.ai")
    }

    func testUnexpectedAnswerIsAnError() async {
        do {
            _ = try await fetch("kimi/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
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
        await assertMapsHTTPErrors(provider, url: url, key: key)
    }
}
