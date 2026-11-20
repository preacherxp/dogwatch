import Foundation
import XCTest
@testable import Dogwatch

final class DevinProviderTests: XCTestCase {
    private let provider = DevinProvider()
    private var home: URL!

    override func setUpWithError() throws { home = try LocalStoreFixture.makeHome() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func writeCache(_ fixture: String, folder: String = "Devin", asBlob: Bool = false) throws {
        let value = try Fixture.data(fixture)
        try LocalStoreFixture.vscodeState(
            at: "Library/Application Support/\(folder)/User/globalStorage/state.vscdb", in: home,
            [DevinProvider.planKey: asBlob ? String(decoding: value, as: UTF8.self).data(using: .utf16LittleEndian)! : value],
            asBlob: asBlob
        )
    }

    private func fetch() async throws -> (ProviderSnapshot, FixtureTransport, RecordingGate) {
        let transport = FixtureTransport()
        let gate = RecordingGate()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))
        return (snapshot, transport, gate)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testReadsDailyAndWeeklyFromTheLocalCacheWithNoNetwork() async throws {
        try writeCache("devin/plan-info.json")
        let (snapshot, transport, gate) = try await fetch()

        XCTAssertEqual(snapshot.readings.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(snapshot.primary()?.id, "daily", "The window with less left is the primary.")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 64)
        XCTAssertEqual(snapshot.readings.last?.remainingPercent, 82)
        XCTAssertEqual(snapshot.primary()?.resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.historyReadingID, "weekly")
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 64)
        XCTAssertEqual(item.menuValue, "64%")
    }

    func testOlderWindsurfInstallsAndUTF16ValuesAreRead() async throws {
        try writeCache("devin/plan-info-weekly-only.json", folder: "Windsurf", asBlob: true)
        let (snapshot, _, _) = try await fetch()
        XCTAssertEqual(snapshot.readings.map(\.id), ["weekly"], "Max plans have no daily quota.")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 40)
        XCTAssertEqual(snapshot.plan, "Max")
    }

    func testAResetThatPassedSinceTheCacheIsANewWindow() throws {
        let json = try JSONValue(data: Data(#"{"quotaUsage": {"dailyRemainingPercent": 5, "dailyResetAtUnix": 1700000000, "weeklyRemainingPercent": 30, "weeklyResetAtUnix": 4102444800}}"#.utf8))
        let snapshot = try DevinProvider.snapshot(from: json, savedAt: Date(timeIntervalSince1970: 1_690_000_000), now: Date())
        let daily = try XCTUnwrap(snapshot.readings.first { $0.id == "daily" })
        XCTAssertEqual(daily.remainingPercent, 100)
        XCTAssertNil(daily.resetsAt)
        XCTAssertEqual(daily.detail, "New daily quota since Devin Desktop last updated")
    }

    func testACacheWithoutQuotasNamesWhatIsMissing() throws {
        let json = try JSONValue(data: Data(#"{"planName": "Pro", "usage": {"messages": 500, "usedMessages": 20}}"#.utf8))
        XCTAssertThrowsError(try DevinProvider.snapshot(from: json, savedAt: Date(), now: Date())) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("quotaUsage"))
        }
    }

    func testNotInstalledAndNotSignedIn() async throws {
        XCTAssertEqual(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)), .unavailable("Devin Desktop is not installed"))
        try LocalStoreFixture.vscodeState(at: DevinProvider.databases[0], in: home, ["other": Data("x".utf8)])
        XCTAssertTrue(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
        do {
            _ = try await fetch()
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        }
    }
}
