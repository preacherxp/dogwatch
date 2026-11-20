import Foundation
import XCTest
@testable import Dogwatch

final class ZaiProviderTests: XCTestCase {
    private let provider = ZaiProvider()
    private let key = "zai-test-key-not-real"
    private let url = "https://api.z.ai/api/monitor/usage/quota/limit"

    private func fetch(_ fixture: String, settings: ProviderSettings = ProviderSettings(), prefix: String? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix ?? url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        return (snapshot, transport)
    }

    private func expectError(_ fixture: String, kind: String, containing text: String? = nil) async {
        do {
            _ = try await fetch(fixture)
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, kind)
            if let text { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) }
            XCTAssertFalse(error.localizedDescription.contains(key))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testFiveHourAndWeeklyWindowsWithTheTighterAsPrimary() async throws {
        let (snapshot, transport) = try await fetch("zai/quota.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["five_hour", "weekly", "mcp_monthly"])
        XCTAssertEqual(snapshot.plan, "Pro")
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "weekly")
        XCTAssertEqual(primary.remainingPercent, 35)
        XCTAssertEqual(primary.window?.period, .duration(7 * 86_400))
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
        let fiveHour = try XCTUnwrap(snapshot.readings.first { $0.id == "five_hour" }?.window)
        XCTAssertEqual(fiveHour.usedPercent, 42)
        XCTAssertEqual(fiveHour.period, .duration(5 * 3_600))
        XCTAssertNil(fiveHour.used, "Token counts aren't shown; their unit isn't documented.")
        let mcp = try XCTUnwrap(snapshot.readings.first { $0.id == "mcp_monthly" }?.window)
        XCTAssertEqual(mcp.usedPercent, 12)
        XCTAssertEqual(mcp.used, Amount(value: 120, unit: .custom("calls")))
        XCTAssertEqual(mcp.limit, Amount(value: 1000, unit: .custom("calls")))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testChinaRegionCallsBigModel() async throws {
        let (_, transport) = try await fetch(
            "zai/quota.json",
            settings: ProviderSettings(baseURL: URL(string: "https://open.bigmodel.cn")),
            prefix: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
        XCTAssertEqual(transport.requests.first?.url?.host, "open.bigmodel.cn")
    }

    func testAnErrorSentWithHTTP200IsAnError() async {
        await expectError("zai/no-plan.json", kind: "unexpectedResponse", containing: "no coding plan")
    }

    func testEmptyLimitsShowNoMadeUpPercentage() async throws {
        let (snapshot, _) = try await fetch("zai/empty-limits.json")
        XCTAssertTrue(snapshot.readings.isEmpty)
        XCTAssertNil(snapshot.primary())
        XCTAssertNotNil(snapshot.note)
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
