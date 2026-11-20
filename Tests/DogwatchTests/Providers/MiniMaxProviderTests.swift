import Foundation
import XCTest
@testable import Dogwatch

final class MiniMaxProviderTests: XCTestCase {
    private let provider = MiniMaxProvider()
    private let key = "sk-cp-test-key-not-real"
    private let url = "https://www.minimax.io/v1/token_plan/remains"

    private func fetch(_ fixture: String, settings: ProviderSettings = ProviderSettings(), prefix: String? = nil) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix ?? url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        return (snapshot, transport)
    }

    private func expectError(_ fixture: String, kind: String, containing text: String) async {
        do {
            _ = try await fetch(fixture)
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, kind)
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(key))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testWindowsPerModelWithTheTightestAsPrimary() async throws {
        let (snapshot, transport) = try await fetch("minimax/remains.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["five_hour:MiniMax-M3", "weekly:MiniMax-M3", "five_hour:speech-3.0"],
                       "A model not in the plan is left out, and a window with no weekly cap shows no weekly reading.")
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "weekly:MiniMax-M3")
        XCTAssertEqual(primary.remainingPercent, 30)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_795_996_800))

        let fiveHour = try XCTUnwrap(snapshot.readings.first { $0.id == "five_hour:MiniMax-M3" }?.window)
        XCTAssertEqual(fiveHour.usedPercent, 20, "The reported remaining percentage wins.")
        XCTAssertEqual(fiveHour.period, .duration(5 * 3_600))
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_795_611_600))
        XCTAssertNil(fiveHour.used, "Counts are ambiguous and not shown.")

        let speech = try XCTUnwrap(snapshot.readings.first { $0.id == "five_hour:speech-3.0" }?.window)
        XCTAssertEqual(speech.usedPercent, 25, "Without a percentage, usage_count / total is the share left, as MiniMax's CLI reads it.")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testChinaRegion() async throws {
        let (_, transport) = try await fetch(
            "minimax/remains.json",
            settings: ProviderSettings(baseURL: URL(string: "https://www.minimax.cn")),
            prefix: "https://www.minimax.cn/v1/token_plan/remains"
        )
        XCTAssertEqual(transport.requests.first?.url?.host, "www.minimax.cn")
    }

    func testNoActivePlanSentWithHTTP200IsAnError() async {
        await expectError("minimax/no-plan.json", kind: "unexpectedResponse", containing: "no active M Plan")
    }

    func testInvalidKeySentWithHTTP200SaysSignIn() async {
        await expectError("minimax/invalid-key.json", kind: "notSignedIn", containing: "rejected the key")
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
