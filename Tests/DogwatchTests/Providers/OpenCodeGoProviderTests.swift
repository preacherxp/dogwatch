import Foundation
import XCTest
@testable import Dogwatch

/// OpenCode Go: three windows, the binding one primary; OpenCode's stored credentials read as
/// stored, an expired sign-in never sent, a rejected Go key followed by the sign-in.
final class OpenCodeGoProviderTests: XCTestCase {
    private let provider = OpenCodeGoProvider()
    private let url = "https://opencode.ai/zen/go/v1/usage"
    private let goKey = "sk-go-sample-key-not-real"
    private let access = "sample-access-token-not-real"
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share/opencode"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var expiresLater: Int { Int((now.timeIntervalSince1970 + 3_600) * 1000) }
    private var expiredAgo: Int { Int((now.timeIntervalSince1970 - 3_600) * 1000) }

    private func writeLegacy(_ json: String) throws {
        try Data(json.utf8).write(to: home.appendingPathComponent(".local/share/opencode/auth.json"))
    }

    /// A v2 database with a credential table, made with the system's sqlite3.
    private func writeDatabase(_ rows: [(integration: String, value: String, active: String)]) throws {
        let db = home.appendingPathComponent(".local/share/opencode/opencode.db")
        var sql = "CREATE TABLE credential (id TEXT, integration_id TEXT, label TEXT, value TEXT, connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER, time_updated INTEGER);"
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO credential (id, integration_id, value, active) VALUES ('c\(index)', '\(row.integration)', '\(row.value)', \(row.active));"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func context(_ transport: HTTPTransport, gate: CommandGate = RecordingGate()) -> ProviderContext {
        ProviderContext(
            http: HTTPClient(allowedHosts: provider.descriptor.allowedHosts, transport: transport),
            key: { nil },
            settings: ProviderSettings(),
            local: LocalTools(home: home, environment: [:], gate: gate),
            now: { self.now }
        )
    }

    private func fetch(_ fixture: String) async throws -> (ProviderSnapshot, FixtureTransport) {
        try writeLegacy(#"{"opencode": {"type": "oauth", "access": "\#(access)", "refresh": "sample-refresh", "expires": \#(expiresLater)}}"#)
        let transport = FixtureTransport()
        try transport.respond(to: url, fixture: fixture)
        return (try await provider.fetch(in: context(transport)), transport)
    }

    func testFollowsTheRules() {
        assertFollowsRules(provider)
    }

    func testAllThreeWindowsWithTheTightestPrimary() async throws {
        let (snapshot, transport) = try await fetch("opencode-go/usage.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["five_hour", "weekly", "monthly"])
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.id, "monthly")
        XCTAssertEqual(primary.remainingPercent, 59)
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2099-12-16T18:22:32.000Z"))
        XCTAssertEqual(snapshot.historyReadingID, "weekly")

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 59)
        XCTAssertEqual(item.meters.map(\.label), ["5h", "Week"])
        XCTAssertEqual(item.meters.map(\.remaining), [88, 70])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(access)")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: access), [])
    }

    func testALimitedWindowIsBindingAndPrimary() async throws {
        let (snapshot, _) = try await fetch("opencode-go/usage-limited.json")
        let primary = try XCTUnwrap(snapshot.primary())

        XCTAssertEqual(primary.id, "five_hour")
        XCTAssertTrue(primary.isBinding)
        XCTAssertEqual(primary.remainingPercent, 0)
        XCTAssertEqual(primary.detailText, "Limit reached · 5h")
    }

    func testAnEndedFiveHourWindowIsFreshAndAMissingWindowIsLeftOut() async throws {
        let (snapshot, _) = try await fetch("opencode-go/usage-rolling-ended.json")

        XCTAssertEqual(snapshot.readings.map(\.id), ["five_hour", "weekly"], "monthly: null is no window, not zero.")
        let fiveHour = try XCTUnwrap(snapshot.readings.first)
        XCTAssertEqual(fiveHour.remainingPercent, 100)
        XCTAssertNil(fiveHour.resetsAt)
        XCTAssertEqual(fiveHour.detailText, "New 5h window · starts with your next request")
        XCTAssertEqual(snapshot.primary()?.id, "weekly")
    }

    func testUnexpectedAnswerNamesWhatIsMissing() async {
        do {
            _ = try await fetch("opencode-go/unexpected.json")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("usage"))
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Credentials

    func testTheDatabaseIsAuthoritativeAndARejectedGoKeyFallsBackToTheSignIn() async throws {
        try writeDatabase([
            ("opencode-go", #"{"type":"key","key":"\#(goKey)"}"#, "NULL"),
            ("opencode", #"{"type":"oauth","access":"\#(access)","refresh":"sample-refresh","expires":\#(expiresLater)}"#, "1"),
        ])
        try writeLegacy(#"{"opencode-go": {"type": "api", "key": "stale-legacy-key"}}"#)
        let transport = KeyedTransport(rejecting: goKey, body: try Fixture.data("opencode-go/usage.json"))
        let snapshot = try await provider.fetch(in: context(transport))

        XCTAssertEqual(transport.authorizations, ["Bearer \(goKey)", "Bearer \(access)"], "The Go key first, then the sign-in; never the stale auth.json.")
        XCTAssertEqual(snapshot.primary()?.id, "monthly")
        XCTAssertEqual(snapshot.note, "Read with your OpenCode sign-in: the OpenCode Go key stored in OpenCode was rejected.")
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: goKey), [])
    }

    func testAWorkingGoKeyIsTheOnlyRequest() async throws {
        try writeDatabase([
            ("opencode-go", #"{"type":"key","key":"\#(goKey)"}"#, "NULL"),
            ("opencode", #"{"type":"oauth","access":"\#(access)","expires":\#(expiresLater)}"#, "1"),
        ])
        let transport = KeyedTransport(rejecting: "nothing", body: try Fixture.data("opencode-go/usage.json"))
        let snapshot = try await provider.fetch(in: context(transport))
        XCTAssertEqual(transport.authorizations, ["Bearer \(goKey)"])
        XCTAssertNil(snapshot.note)
    }

    func testAnInactiveRowIsNeverUsed() throws {
        try writeDatabase([
            ("opencode-go", #"{"type":"key","key":"\#(goKey)"}"#, "0"),
            ("opencode", #"{"type":"oauth","access":"\#(access)","expires":\#(expiresLater)}"#, "1"),
        ])
        XCTAssertEqual(try OpenCodeGoProvider.candidates(in: context(FixtureTransport())).map(\.kind), [.openCodeSignIn])
    }

    func testAnExpiredSignInIsSignInAgainWithNoRequestAndNoProcess() async throws {
        try writeLegacy(#"{"opencode": {"type": "oauth", "access": "\#(access)", "refresh": "sample-refresh", "expires": \#(expiredAgo)}}"#)
        let transport = FixtureTransport()
        let gate = RecordingGate()
        do {
            _ = try await provider.fetch(in: context(transport, gate: gate))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "OpenCode's sign-in has expired. Open OpenCode to sign in again.")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(gate.attempts.isEmpty)
    }

    func testNoCredentialFailsWithoutAnyRequest() async throws {
        try writeLegacy(#"{"anthropic": {"type": "api", "key": "another-providers-key"}}"#)
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: context(transport))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        }
        XCTAssertTrue(transport.requests.isEmpty, "Another provider's key in OpenCode's store is never borrowed.")
    }

    func testNotInstalled() async throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/share/opencode"))
        XCTAssertFalse(provider.availability(in: context(FixtureTransport())).isAvailable)
        do {
            _ = try await provider.fetch(in: context(FixtureTransport()))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notInstalled")
        }
    }

    func testMapsHTTPErrors() async throws {
        try writeLegacy(#"{"opencode": {"type": "oauth", "access": "\#(access)", "expires": \#(expiresLater)}}"#)
        await assertMapsHTTPErrors(provider, url: url, credential: .storedSignIn(secret: access) { transport in self.context(transport) })
    }
}

/// Answers 401 to one bearer token and the fixture to every other, recording what was sent.
private final class KeyedTransport: HTTPTransport {
    let rejected: String
    let body: Data
    private(set) var requests: [URLRequest] = []
    var authorizations: [String] { requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") } }

    init(rejecting rejected: String, body: Data) {
        self.rejected = rejected
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(rejected)" ? 401 : 200
        return (status == 200 ? body : Data(#"{"error":"api_key_expired"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
