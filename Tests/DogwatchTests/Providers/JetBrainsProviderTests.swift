import Foundation
import XCTest
@testable import Dogwatch

/// JetBrains AI: the IDE's saved quota file, the newest of several IDEs, nothing sent.
final class JetBrainsProviderTests: XCTestCase {
    private let provider = JetBrainsProvider()
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-jetbrains-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func install(_ fixture: String, ide: String, vendor: String = "JetBrains", modified: Date) throws -> URL {
        let url = home.appendingPathComponent("Library/Application Support/\(vendor)/\(ide)/options/AIAssistantQuotaManager2.xml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.data("jetbrains/\(fixture)").write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func fetch() async throws -> (ProviderSnapshot, FixtureTransport, RecordingGate) {
        let transport = FixtureTransport()
        let gate = RecordingGate()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate, now: now))
        return (snapshot, transport, gate)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testMonthlyCreditsAndTopUpFromTheNewestIDE() async throws {
        try install("no-licence.xml", ide: "IdeaIC2025.1", modified: now.addingTimeInterval(-86_400 * 30))
        try install("available.xml", ide: "IntelliJIdea2026.2", modified: now.addingTimeInterval(-3_600))
        let (snapshot, transport, gate) = try await fetch()

        XCTAssertEqual(snapshot.readings.map(\.id), ["monthly", "top_up"])
        let monthly = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(monthly.id, "monthly")
        XCTAssertEqual(monthly.remainingPercent, 24)
        XCTAssertEqual(monthly.window?.used, Amount(value: 7.6, unit: .credits))
        XCTAssertEqual(monthly.window?.limit, Amount(value: 10, unit: .credits))
        XCTAssertEqual(monthly.resetsAt, DateParsing.iso8601("2099-12-05T09:30:00Z"))
        let topUp = try XCTUnwrap(snapshot.readings.last)
        XCTAssertEqual(topUp.balance?.remaining, Amount(value: 14.9, unit: .credits))
        XCTAssertNil(topUp.remainingPercent, "Top-ups are spent only after the monthly quota; a share of them means nothing.")
        XCTAssertTrue(snapshot.note?.hasPrefix("Saved by IntelliJIdea2026.2") == true)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 24)
        XCTAssertEqual(item.detail, "76% used · 30 days")
        XCTAssertTrue(item.notes.contains("Top-up credits 14.9 credits left"))
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testAnUnknownRefillLeavesTheResetEmptyAndNoTopUpMeansNoReading() async throws {
        try install("available-no-topup.xml", ide: "AndroidStudio2025.3.3", vendor: "Google", modified: now)
        let (snapshot, _, _) = try await fetch()

        XCTAssertEqual(snapshot.readings.map(\.id), ["monthly"])
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 83)
        XCTAssertNil(snapshot.primary()?.resetsAt)
    }

    func testNoLicenceSaysSo() async throws {
        try install("no-licence.xml", ide: "IntelliJIdea2026.2", modified: now)
        do {
            _ = try await fetch()
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
            XCTAssertTrue(error.localizedDescription.contains("no AI licence"))
        }
    }

    func testNoIDEIsNotInstalled() async {
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
        do {
            _ = try await fetch()
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notInstalled")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnUnknownQuotaStateNamesIt() throws {
        let xml = #"<application><component name="AIAssistantQuotaManager2"><option name="quotaInfo" value="{&quot;type&quot;:&quot;Exhausted&quot;}" /></component></application>"#
        XCTAssertThrowsError(try JetBrainsProvider.snapshot(fromXML: xml, now: now)) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("Exhausted"))
        }
        XCTAssertThrowsError(try JetBrainsProvider.snapshot(fromXML: "<application/>", now: now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("quotaInfo"))
        }
    }
}
