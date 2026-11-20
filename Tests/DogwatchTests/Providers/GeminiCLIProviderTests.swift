import Foundation
import XCTest
@testable import Dogwatch

final class GeminiCLIProviderTests: XCTestCase {
    private let provider = GeminiCLIProvider()
    private let token = "sample-access-token-not-real"
    private var home: URL!

    override func setUpWithError() throws { home = try LocalStoreFixture.makeHome() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func writeCredentials(expiresIn seconds: TimeInterval) throws {
        let url = home.appendingPathComponent(GeminiCLIProvider.credentialsPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expiry = Int((Date().timeIntervalSince1970 + seconds) * 1000)
        try Data(#"{"access_token": "\#(token)", "refresh_token": "sample-refresh-not-real", "token_type": "Bearer", "expiry_date": \#(expiry)}"#.utf8).write(to: url)
    }

    private func transport(load: String, quota: String = "gemini-cli/quota.json") throws -> FixtureTransport {
        let transport = FixtureTransport()
        try transport.respond(to: GeminiCLIProvider.loadURL.absoluteString, fixture: load)
        try transport.respond(to: GeminiCLIProvider.quotaURL.absoluteString, fixture: quota)
        return transport
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testMapsHTTPErrors() async throws {
        try writeCredentials(expiresIn: 3_000)
        await assertMapsHTTPErrors(provider, url: GeminiCLIProvider.loadURL.absoluteString, credential: .storedSignIn(secret: token) { [home] transport in
            TestContext.make(for: self.provider.descriptor, transport: transport, home: home!)
        })
    }

    func testWorkspaceAccountShowsTheTightestBucketPerModel() async throws {
        try writeCredentials(expiresIn: 3_000)
        let transport = try transport(load: "gemini-cli/load-workspace.json")
        let gate = RecordingGate()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))

        XCTAssertEqual(snapshot.readings.map(\.id), ["model:gemini-2.5-flash", "model:gemini-2.5-pro"])
        XCTAssertEqual(snapshot.primary()?.id, "model:gemini-2.5-pro")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 65, "The lower of the model's two buckets.")
        XCTAssertEqual(snapshot.plan, "Gemini Code Assist Standard")
        XCTAssertTrue(gate.attempts.isEmpty)

        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "POST"])
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        }
        let quotaBody = try JSONValue(data: XCTUnwrap(transport.requests.last?.httpBody))
        XCTAssertEqual(quotaBody["project"]?.stringValue, "sample-project-123")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: token), [])
    }

    func testAnExpiredStoredTokenSaysSignInAgainWithNoRequest() async throws {
        try writeCredentials(expiresIn: -60)
        let transport = FixtureTransport()
        let gate = RecordingGate()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Gemini CLI's sign-in has expired. Open Gemini CLI to sign in again.")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testAPersonalAccountPointsToAntigravity() async throws {
        try writeCredentials(expiresIn: 3_000)
        let transport = try transport(load: "gemini-cli/load-consumer.json")
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
            XCTAssertTrue(error.localizedDescription.contains("Antigravity"))
        }
        XCTAssertEqual(transport.requests.count, 1, "The quota isn't asked for once the account is known to be unsupported.")
    }

    func testARejectedTokenSaysSignInAgain() async throws {
        try writeCredentials(expiresIn: 3_000)
        let transport = FixtureTransport()
        transport.respond(to: GeminiCLIProvider.loadURL.absoluteString, status: 401, body: Data("{}".utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertTrue(error.localizedDescription.contains("Open Gemini CLI"))
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    func testNoCredentialsFileMeansNotSignedIn() async {
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, home: home))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnAnswerWithoutBucketsNamesWhatIsMissing() {
        XCTAssertThrowsError(try GeminiCLIProvider.snapshot(quota: .object([:]), plan: nil, now: Date())) { error in
            XCTAssertTrue(error.localizedDescription.contains("buckets"))
        }
    }
}
