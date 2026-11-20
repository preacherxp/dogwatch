import Foundation
import XCTest
@testable import Dogwatch

final class AntigravityProviderTests: XCTestCase {
    private let provider = AntigravityProvider()
    private var home: URL!

    override func setUpWithError() throws { home = try LocalStoreFixture.makeHome() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.commands, [], "Antigravity must never start agy.")
    }

    func testReadsEveryEnabledBucketFromTheStatusLineFile() async throws {
        let url = home.appendingPathComponent(AntigravityProvider.filePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.data("antigravity/statusline.json").write(to: url)
        let transport = FixtureTransport()
        let gate = RecordingGate()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))

        XCTAssertEqual(snapshot.readings.map(\.id), ["bucket:3p-5h", "bucket:gemini-5h", "bucket:3p-weekly", "bucket:gemini-weekly"],
                       "Disabled buckets and buckets without a fraction are skipped.")
        XCTAssertEqual(snapshot.primary()?.id, "bucket:gemini-5h")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 71)
        XCTAssertEqual(snapshot.primary()?.name, "Gemini 5h")
        XCTAssertEqual(snapshot.primary()?.window?.period, .duration(5 * 3_600))
        let reset = try XCTUnwrap(snapshot.readings.first { $0.id == "bucket:3p-5h" })
        XCTAssertEqual(reset.remainingPercent, 100, "Its reset passed, so it is a new window.")
        XCTAssertEqual(reset.name, "Claude and GPT 5h")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.historyReadingID, "bucket:3p-weekly")
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 71)
    }

    func testNoFileMeansSetUpTheStatusLine() async {
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAFileWithoutQuotaNamesWhatIsMissing() throws {
        XCTAssertThrowsError(try AntigravityProvider.snapshot(from: .object([:]), writtenAt: Date(), now: Date())) { error in
            XCTAssertTrue(error.localizedDescription.contains("quota"))
        }
    }

    func testUnknownBucketNamesAreShownAsGiven() {
        XCTAssertEqual(AntigravityProvider.describe("argon-weekly").name, "Argon weekly")
        XCTAssertEqual(AntigravityProvider.describe("gemini-monthly").period, .named("monthly"))
    }
}
