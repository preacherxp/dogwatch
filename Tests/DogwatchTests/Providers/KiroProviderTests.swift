import Foundation
import XCTest
@testable import Dogwatch

final class KiroProviderTests: XCTestCase {
    private let provider = KiroProvider()
    private let token = "sample-kiro-access-token-not-real"
    private var home: URL!

    override func setUpWithError() throws { home = try LocalStoreFixture.makeHome() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func writeState(expiresIn seconds: TimeInterval, arn: String? = nil) throws {
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
        var rows: [(table: String, key: String, value: Data, asBlob: Bool)] = [
            ("auth_kv", "kirocli:odic:token", Data(#"{"access_token": "\#(token)", "expires_at": "\#(expiry)", "refresh_token": "sample-refresh-not-real", "region": "us-east-1"}"#.utf8), false),
        ]
        if let arn { rows.append(("state", "api.codewhisperer.profile", Data(#"{"arn": "\#(arn)", "profile_name": "sample"}"#.utf8), false)) }
        try LocalStoreFixture.sqlite(at: KiroProvider.databasePath, in: home, schema: [
            "CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)",
            "CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT)",
        ], rows: rows)
    }

    private func fetch(_ fixture: String, arn: String? = nil) async throws -> (ProviderSnapshot, FixtureTransport, RecordingGate) {
        try writeState(expiresIn: 3_000, arn: arn)
        let transport = FixtureTransport()
        for url in KiroProvider.endpoints.values { try transport.respond(to: url.absoluteString, fixture: fixture) }
        let gate = RecordingGate()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))
        return (snapshot, transport, gate)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
        XCTAssertEqual(provider.descriptor.commands, [], "Kiro must never start kiro-cli.")
    }

    func testShowsMonthlyCreditsUsedOfThePlan() async throws {
        let (snapshot, transport, gate) = try await fetch("kiro/usage-limits.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["monthly"])
        let window = try XCTUnwrap(snapshot.primary()?.window)
        XCTAssertEqual(window.usedPercent, 41)
        XCTAssertEqual(window.used, Amount(value: 412.5, unit: .credits))
        XCTAssertEqual(window.limit, Amount(value: 1000, unit: .credits))
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertTrue(gate.attempts.isEmpty)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "codewhisperer.us-east-1.amazonaws.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Target"), "AmazonCodeWhispererService.GetUsageLimits")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: token), [])
    }

    func testAFrankfurtProfileGoesToItsRegion() async throws {
        let arn = "arn:aws:codewhisperer:eu-central-1:000000000000:profile/SAMPLE"
        let (_, transport, _) = try await fetch("kiro/usage-limits.json", arn: arn)
        XCTAssertEqual(transport.requests.first?.url?.host, "q.eu-central-1.amazonaws.com")
        XCTAssertEqual(try JSONValue(data: XCTUnwrap(transport.requests.first?.httpBody))["profileArn"]?.stringValue, arn)
        XCTAssertThrowsError(try KiroProvider.endpoint(for: "arn:aws:codewhisperer:ap-south-1:0:profile/X"))
    }

    func testOverageIsSeparatedFromThePlan() async throws {
        let (snapshot, _, _) = try await fetch("kiro/usage-limits-overage.json")
        XCTAssertEqual(snapshot.primary()?.id, "monthly")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 0)
        XCTAssertEqual(snapshot.readings.first { $0.id == "overage" }?.amount, Amount(value: 4, unit: .currency("USD")))
    }

    func testBonusCreditsMixedIntoTheTotalGiveNoPercentage() async throws {
        let (snapshot, _, _) = try await fetch("kiro/usage-limits-bonus.json")
        XCTAssertTrue(snapshot.readings.isEmpty, "Without the split, any percentage would be a guess.")
        XCTAssertNotNil(snapshot.note)
    }

    func testAnExpiredStoredTokenSaysSignInAgainWithNoRequest() async throws {
        try writeState(expiresIn: -60)
        let transport = FixtureTransport()
        let gate = RecordingGate()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Kiro CLI's sign-in has expired. Open Kiro CLI to sign in again.")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testARejectedTokenSaysSignInAgain() async throws {
        try writeState(expiresIn: 3_000)
        let transport = FixtureTransport()
        transport.respond(to: KiroProvider.endpoints["us-east-1"]!.absoluteString, status: 403, body: Data("{}".utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    func testNotInstalled() async {
        XCTAssertEqual(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)), .unavailable("Kiro CLI is not installed"))
    }
}
