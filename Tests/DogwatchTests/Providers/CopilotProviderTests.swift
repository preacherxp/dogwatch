import Foundation
import XCTest
@testable import Dogwatch

/// GitHub Copilot: quotas GitHub gives a total for become windows; AI credits stay an amount
/// unless the user sets their allowance; the plugins' sign-in is read as stored and a rejected
/// one means signing in again in the editor.
final class CopilotProviderTests: XCTestCase {
    private let provider = CopilotProvider()
    private let token = "gho_sampleTokenNotReal0000000000000000"
    private let url = "https://api.github.com/copilot_internal/user"
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-copilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeApps(_ token: String, file: String = CopilotProvider.appsPath, key: String = "github.com:Iv1.sample") throws {
        let url = home.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"\#(key)": {"user": "sample-login", "oauth_token": "\#(token)", "githubAppId": "Iv1.sample"}}"#
        try Data(json.utf8).write(to: url)
    }

    private func fetch(_ fixture: String) async throws -> (ProviderSnapshot, FixtureTransport) {
        try writeApps(token)
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
        return (snapshot, transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testFreePlanShowsGitHubsOwnQuotasAsWindows() async throws {
        let (snapshot, transport) = try await fetch("copilot/free.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["chat", "completions", "ai_credits"])
        XCTAssertEqual(snapshot.plan, "Free")
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "chat", "The quota with least left.")
        XCTAssertEqual(primary.remainingPercent, 75)
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2099-12-01T00:00:00.000Z"))
        XCTAssertEqual(snapshot.readings.first { $0.id == "completions" }?.remainingPercent, 99)
        XCTAssertEqual(snapshot.readings.first { $0.id == "ai_credits" }?.amount, Amount(value: 0, unit: .credits))

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 75)
        XCTAssertEqual(item.detail, "25% used · monthly")
        XCTAssertEqual(item.menuValue, "75%")
        XCTAssertEqual(item.meters.map(\.label), ["Completions"])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: token), [])
    }

    func testAICreditsAreAnAmountWithoutAnInventedPercentage() async throws {
        let (snapshot, _) = try await fetch("copilot/pro-credits.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["ai_credits"], "Unlimited quotas and a quota without a total are not windows.")
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.amount, Amount(value: 312, unit: .credits))
        XCTAssertNil(primary.remainingPercent, "GitHub publishes no allowance.")

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertNil(item.remaining)
        XCTAssertEqual(item.amount, "312 credits")
        XCTAssertEqual(item.amountCaption, "used")
        XCTAssertEqual(primary.window?.isMetered, false, "A monthly window GitHub gives no total for.")
        XCTAssertEqual(item.menuValue, "312")
        XCTAssertNil(snapshot.plan, "An unknown SKU is not shown raw.")
    }

    func testAnAllowanceInConfigTurnsCreditsIntoAPercentage() async throws {
        let (snapshot, _) = try await fetch("copilot/pro-credits.json")
        var options = InstrumentOptions()
        options.userLimits = ["ai_credits": 1_500]
        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil, options: options)

        XCTAssertEqual(item.remaining, 79)
        XCTAssertEqual(item.detail, "21% used · this month")
        let limited = snapshot.applying(userLimits: ["ai_credits": 1_500])
        XCTAssertEqual(limited.primary()?.window?.limit, Amount(value: 1_500, unit: .credits))
        XCTAssertEqual(item.menuValue, "79%")
    }

    func testLegacyPremiumRequestsAreAWindowFromGitHubsTotal() async throws {
        let (snapshot, _) = try await fetch("copilot/legacy-premium.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["premium"])
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 15)
        XCTAssertEqual(snapshot.primary()?.name, "Premium requests")
    }

    func testAnEndedSubscriptionSaysSo() async {
        do {
            _ = try await fetch("copilot/ended.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
            XCTAssertEqual(error.localizedDescription, "Your Copilot subscription has ended.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNoPersonalDataInWhatIsShown() async throws {
        let (snapshot, _) = try await fetch("copilot/free.json")
        let shown = snapshot.readings.flatMap { [$0.name, $0.detailText, $0.meterLabel ?? ""] }
            + [snapshot.plan, snapshot.label, snapshot.note].compactMap { $0 }
        XCTAssertFalse(shown.joined().contains("sample-login"))
        XCTAssertFalse(shown.joined().contains("1000001"))
    }

    func testReadsTheOlderHostsFile() async throws {
        try writeApps(token, file: CopilotProvider.hostsPath, key: "github.com")
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: "copilot/free.json")
        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "token \(token)")
    }

    func testNoSignInFailsWithoutAnyRequest() async {
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
    }

    func testAnExpiredStoredTokenIsSignInAgainWithNoRequestAndNoProcess() async throws {
        let claims = Data(#"{"exp": \#(Int(Date().timeIntervalSince1970 - 60))}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try writeApps("eyJhbGciOiJub25lIn0.\(claims).signature")
        let transport = FixtureTransport()
        let gate = RecordingGate()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Copilot's sign-in has expired. Open Copilot in your editor to sign in again.")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testMapsHTTPErrors() async throws {
        try writeApps(token)
        await assertMapsHTTPErrors(provider, url: url, credential: .storedSignIn(secret: token) { [home] transport in
            TestContext.make(for: self.provider.descriptor, transport: transport, home: home!)
        })
    }
}
