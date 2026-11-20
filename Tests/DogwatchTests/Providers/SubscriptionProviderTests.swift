import Foundation
import XCTest
@testable import Dogwatch

/// Claude, Codex and Grok through the provider interface: the parsed answers become the right
/// readings, and an expired login stops them before any request or process.
final class SubscriptionProviderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func jwt(expiresIn seconds: TimeInterval) -> String {
        let claims = Data(#"{"exp": \#(Int(Date().timeIntervalSince1970 + seconds))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(claims).signature"
    }

    // MARK: Claude

    func testClaudeShowsTheBindingModelLimitAndTheTightestInTheMenuBar() throws {
        let claude = try ClaudeUsageClient.parseUsage(Fixture.data("claude/usage-weekly-scoped.json"), fetchedAt: Date())
        let snapshot = ClaudeProvider.snapshot(from: claude)
        let item = BridgeLayout.instrument(descriptor: ClaudeProvider().descriptor, snapshot: snapshot, error: nil)

        XCTAssertEqual(snapshot.readings.map(\.id), ["seven_day", "scoped:fable"])
        XCTAssertEqual(snapshot.primary()?.id, "scoped:fable", "The active model limit is the one being hit.")
        XCTAssertEqual(item.remaining, 20)
        XCTAssertEqual(item.secondaryLabel, "Fable weekly")
        XCTAssertEqual(item.detail, "80% used · Fable weekly")
        XCTAssertEqual(item.meters.map(\.label), ["Week"])
        XCTAssertEqual(item.meters.first?.remaining, 21)
        XCTAssertEqual(item.menuValue, "20%")
    }

    func testClaudeExpiredSignInStopsBeforeAnyRequest() async throws {
        // A stand-in for /usr/bin/security that prints an expired Claude Code credential.
        let script = home.appendingPathComponent("security")
        let expired = Int((Date().timeIntervalSince1970 - 3_600) * 1000)
        try Data("#!/bin/sh\necho '{\"claudeAiOauth\":{\"accessToken\":\"expired-token\",\"expiresAt\":\(expired)}}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        struct ScriptGate: CommandGate {
            let script: URL
            func authorize(_ command: DeclaredCommand, tools: LocalTools) throws -> URL {
                guard command == ClaudeProvider.keychainCommand else { throw ProviderError.commandNotAllowed(command.executable) }
                return script
            }
        }
        let transport = FixtureTransport()
        let provider = ClaudeProvider()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: ScriptGate(script: script)))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Claude Code's sign-in has expired. Open Claude Code to sign in again.")
        }
        XCTAssertTrue(transport.requests.isEmpty, "An expired token must never reach the network.")
    }

    // MARK: Codex

    func testCodexStartsOnlyWhenItsSignInIsFresh() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func state(_ json: String) -> CodexUsageClient.AuthState { CodexUsageClient.authState(Data(json.utf8), now: now) }

        XCTAssertEqual(state(#"{"tokens": {"access_token": "\#(jwt(expiresIn: 86_400))"}, "last_refresh": "\#(iso.string(from: now.addingTimeInterval(-86_400)))"}"#), .ready)
        XCTAssertEqual(state(#"{"tokens": {"access_token": "\#(jwt(expiresIn: 600))"}, "last_refresh": "\#(iso.string(from: now))"}"#), .refreshDue, "Codex refreshes tokens that expire within minutes.")
        XCTAssertEqual(state(#"{"tokens": {"access_token": "\#(jwt(expiresIn: 86_400))"}, "last_refresh": "\#(iso.string(from: now.addingTimeInterval(-9 * 86_400)))"}"#), .ready, "A token with an expiry is judged by it alone, as Codex does.")
        XCTAssertEqual(state(#"{"tokens": {"access_token": "opaque-token"}, "last_refresh": "\#(iso.string(from: now.addingTimeInterval(-8 * 86_400)))"}"#), .refreshDue, "Without an expiry, Codex refreshes after 8 days.")
        XCTAssertEqual(state(#"{"OPENAI_API_KEY": "sk-test", "tokens": null}"#), .ready, "An API-key login has nothing to refresh.")
        XCTAssertEqual(state("not json"), .signedOut)
    }

    func testCodexDueForRefreshStartsNothing() async throws {
        try write(#"{"tokens": {"access_token": "\#(jwt(expiresIn: 60))"}, "last_refresh": "2026-11-19T00:00:00Z"}"#, to: ".codex/auth.json")
        let gate = RecordingGate()
        let provider = CodexProvider()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, home: home, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertTrue(error.localizedDescription.contains("Open Codex"))
        }
        XCTAssertTrue(gate.attempts.isEmpty, "Codex must not be started when it would refresh its sign-in.")
    }

    func testCodexWithoutASignInStartsNothing() async {
        let gate = RecordingGate()
        let provider = CodexProvider()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, home: home, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testCodexAskedOnlyForItsDeclaredCommand() throws {
        try write(#"{"tokens": {"access_token": "\#(jwt(expiresIn: 86_400))"}, "last_refresh": "\#(ISO8601DateFormatter().string(from: Date()))"}"#, to: ".codex/auth.json")
        let gate = RecordingGate()
        let provider = CodexProvider()
        let expectation = expectation(description: "fetch")
        Task {
            _ = try? await provider.fetch(in: TestContext.make(for: provider.descriptor, home: home, gate: gate))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(gate.attempts, [CodexProvider.appServer])
    }

    // MARK: Grok

    func testGrokReadsOnlyItsLogAndStartsNothing() async throws {
        let line = #"{"ts":"2026-11-16T10:00:00.000000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":4.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-11-17T19:45:41+00:00"}},"subscriptionTier":"SuperGrok"}}"#
        try write("noise\n\(line)\n", to: ".grok/logs/unified.jsonl")
        let gate = RecordingGate()
        let transport = FixtureTransport()
        let provider = GrokProvider()
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, gate: gate))

        XCTAssertEqual(snapshot.primary()?.remainingPercent, 96)
        XCTAssertEqual(snapshot.label, "SuperGrok")
        XCTAssertTrue(gate.attempts.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Stored credentials

    func testAnExpiredStoredTokenIsSignInAgainWithoutRefreshing() throws {
        let json = try JSONValue(data: Data(#"{"auth": {"access": "abc", "expires": \#(Int((Date().timeIntervalSince1970 - 10) * 1000))}}"#.utf8))
        XCTAssertThrowsError(try StoredCredential.token(in: json, tokenPath: "auth.access", expiryPath: "auth.expires", tool: "Tool", now: Date())) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Tool's sign-in has expired. Open Tool to sign in again.")
        }
        XCTAssertThrowsError(try StoredCredential.token(in: .object([:]), tokenPath: "auth.access", tool: "Tool", now: Date())) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "notSignedIn")
        }
        let fresh = try JSONValue(data: Data(#"{"auth": {"access": "\#(jwt(expiresIn: 3_600))"}}"#.utf8))
        XCTAssertNoThrow(try StoredCredential.token(in: fresh, tokenPath: "auth.access", tool: "Tool", now: Date()))
    }
}
