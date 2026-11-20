import Foundation
import XCTest
@testable import Dogwatch

final class FactoryProviderTests: XCTestCase {
    private let provider = FactoryProvider()
    private let key = "fk-sample-key-not-real"
    private let url = FactoryProvider.limitsURL.absoluteString

    private func fetch(_ fixture: String) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testShowsTheThreeRollingWindowsAndExtraUsage() async throws {
        let (snapshot, transport) = try await fetch("factory/limits.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["five_hour", "seven_day", "thirty_day", "extra_usage"],
                       "Droid Core windows without data are left out.")
        XCTAssertEqual(snapshot.primary()?.id, "seven_day", "The window with the least left.")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 35)
        XCTAssertEqual(snapshot.readings.first?.remainingPercent, 82)
        XCTAssertEqual(snapshot.readings.first { $0.id == "thirty_day" }?.resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(snapshot.readings.last?.balance?.remaining, Amount(value: 12.5, unit: .currency("USD")))
        XCTAssertNil(snapshot.readings.last?.remainingPercent, "Extra Usage has no total.")

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 35)
        XCTAssertEqual(item.menuValue, "35%")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
    }

    func testAnEndedRollingWindowShowsAsUnused() async throws {
        let (snapshot, _) = try await fetch("factory/limits-expired-window.json")
        let fiveHour = try XCTUnwrap(snapshot.readings.first { $0.id == "five_hour" })
        XCTAssertEqual(fiveHour.remainingPercent, 100)
        XCTAssertNil(fiveHour.resetsAt)
        XCTAssertNil(snapshot.readings.first { $0.id == "extra_usage" }, "No balance and Extra Usage off.")
    }

    func testBYOKPlansHaveNoLimitsAndSaySo() async throws {
        let (snapshot, _) = try await fetch("factory/limits-byok.json")
        XCTAssertTrue(snapshot.readings.isEmpty)
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
