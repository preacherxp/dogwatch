import Foundation
import SwiftUI
import XCTest
@testable import Dogwatch

/// Reads `Tests/DogwatchTests/Fixtures/<path>` from the source tree.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(path))
    }

    static func json(_ path: String) throws -> JSONValue {
        try JSONValue(data: data(path))
    }
}

/// Answers requests from fixtures and records every request, so tests can check what was sent
/// and that nothing was sent at all.
final class FixtureTransport: HTTPTransport {
    struct Response {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private(set) var requests: [URLRequest] = []
    /// Thrown for every request when set, to simulate a network failure.
    var failure: Error?

    /// Answers requests whose URL starts with `prefix`.
    func respond(to prefix: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        responses[prefix] = Response(status: status, body: body, headers: headers)
    }

    func respond(to prefix: String, status: Int = 200, fixture: String) throws {
        respond(to: prefix, status: status, body: try Fixture.data(fixture))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        let failure = self.failure
        let url = request.url?.absoluteString ?? ""
        let match = responses.filter { url.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
        lock.unlock()
        if let failure { throw failure }
        let response = match ?? Response(status: 404, body: Data("not found".utf8))
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}

/// Records every attempt to start a program and refuses all of them, so tests can prove a
/// provider started nothing.
final class RecordingGate: CommandGate {
    private(set) var attempts: [DeclaredCommand] = []

    func authorize(_ command: DeclaredCommand, tools: LocalTools) throws -> URL {
        attempts.append(command)
        throw ProviderError.commandNotAllowed(command.executable)
    }
}

enum TestContext {
    /// A provider context with fixture HTTP, an in-memory key, a temporary home and a recording gate.
    static func make(
        for descriptor: ProviderDescriptor,
        transport: FixtureTransport = FixtureTransport(),
        key: String? = nil,
        home: URL = FileManager.default.temporaryDirectory,
        gate: CommandGate = RecordingGate(),
        settings: ProviderSettings = ProviderSettings(),
        now: Date = Date()
    ) -> ProviderContext {
        var hosts = descriptor.allowedHosts
        if let host = settings.baseURL?.host { hosts.append(host) }
        return ProviderContext(
            http: HTTPClient(allowedHosts: hosts, transport: transport),
            key: { key },
            settings: settings,
            local: LocalTools(home: home, environment: [:], gate: gate),
            now: { now }
        )
    }
}

/// A provider for testing the store, configuration, menu bar and panel with any number of
/// providers. It returns whatever snapshot or error it was given, after an optional delay.
struct FakeProvider: UsageProvider {
    let descriptor: ProviderDescriptor
    var result: Result<ProviderSnapshot, ProviderError>
    var delay: TimeInterval = 0
    var available = true

    init(_ id: String, category: ProviderCategory = .subscription, result: Result<ProviderSnapshot, ProviderError>, delay: TimeInterval = 0, minimumRefresh: TimeInterval = 60) {
        descriptor = ProviderDescriptor(
            id: ProviderID(id), name: id.capitalized, glyph: ProviderGlyph(symbol: "circle"), tint: .gray,
            category: category, stability: .unverified, credential: .none, summary: "Fake \(id)",
            reads: "Nothing; a test provider.", source: "Tests", minimumRefreshInterval: minimumRefresh, timeout: 2
        )
        self.result = result
        self.delay = delay
    }

    func availability(in context: ProviderContext) -> ProviderAvailability {
        available ? .available : .unavailable("\(descriptor.name) is not installed")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result.get()
    }

    /// A snapshot with one window at `usedPercent`.
    static func window(_ usedPercent: Int, period: String = "weekly") -> ProviderSnapshot {
        ProviderSnapshot(readings: [Reading(id: "window", name: period, value: .window(QuotaWindow(
            usedPercent: usedPercent, period: .named(period), resetsAt: Date().addingTimeInterval(86_400))))])
    }

    /// A snapshot with one bare balance in dollars.
    static func balance(_ dollars: Double, total: Double? = nil) -> ProviderSnapshot {
        ProviderSnapshot(readings: [Reading(id: "balance", name: "Balance", value: .balance(Balance(
            remaining: Amount(value: dollars, unit: .currency("USD")),
            total: total.map { Amount(value: $0, unit: .currency("USD")) })))])
    }
}

/// The rules every provider must follow, as data checks. `violations` returns plain sentences;
/// an empty list means the provider passes. Provider tests call `assertFollowsRules`.
enum ProviderContract {
    /// Words that mean a command or request touches another tool's sign-in.
    static let credentialWords = ["login", "logout", "auth", "refresh", "token", "signin", "sign-in"]

    static func violations(of descriptor: ProviderDescriptor) -> [String] {
        var problems: [String] = []
        let name = descriptor.id.rawValue
        if !descriptor.id.isValid { problems.append("\(name): id must be lowercase a-z, 0-9 and -.") }
        if descriptor.name.isEmpty { problems.append("\(name): needs a display name.") }
        if descriptor.reads.count < 20 { problems.append("\(name): `reads` must say exactly what is read and where it goes.") }
        if descriptor.source.isEmpty { problems.append("\(name): needs a source for the README table.") }
        if descriptor.minimumRefreshInterval < 30 { problems.append("\(name): minimumRefreshInterval must be at least 30 seconds.") }
        if NSImage(systemSymbolName: descriptor.glyph.symbol, accessibilityDescription: nil) == nil {
            problems.append("\(name): glyph \(descriptor.glyph.symbol) is not an SF Symbol on this macOS.")
        }
        for host in descriptor.allowedHosts where host.contains("/") || host.contains(":") {
            problems.append("\(name): allowedHosts lists hosts only, not URLs (\(host)).")
        }
        if descriptor.credential.needsPastedKey, descriptor.allowedHosts.isEmpty, !descriptor.acceptsCustomBaseURL, descriptor.baseURLs.isEmpty {
            problems.append("\(name): a provider with a pasted key must declare the hosts it sends it to.")
        }
        var stores = descriptor.localSources
        if case .toolStore(let store) = descriptor.credential { stores.append(store) }
        for store in stores where store.access != .readOnly {
            problems.append("\(name): declares write access to \(store.location). Another tool's files are read-only.")
        }
        for command in descriptor.commands {
            let words = ([command.executable] + command.arguments).map { $0.lowercased() }
            let touchesSignIn = words.contains { word in credentialWords.contains { word.contains($0) } }
                && !(command.executable == "security" && command.arguments.first == "find-generic-password")
            if touchesSignIn {
                problems.append("\(name): command `\(words.joined(separator: " "))` looks like it touches a sign-in.")
            }
            if !command.documentedReadOnly, descriptor.stability == .documented {
                problems.append("\(name): starts `\(command.executable)`, which isn't documented as read-only, so it can't be labelled documented.")
            }
            if command.reason.isEmpty { problems.append("\(name): every command needs a reason shown in settings.") }
        }
        return problems
    }

    /// Requests a provider made that it must not make: undeclared hosts, plain HTTP off
    /// localhost, sign-in refreshes, and the key anywhere but a header.
    static func violations(in requests: [URLRequest], descriptor: ProviderDescriptor, key: String?) -> [String] {
        var problems: [String] = []
        for request in requests {
            guard let url = request.url else { continue }
            let host = url.host?.lowercased() ?? ""
            if !descriptor.allowedHosts.contains(host), !descriptor.acceptsCustomBaseURL, !descriptor.baseURLs.contains(where: { $0.url.host == host }) {
                problems.append("called undeclared host \(host)")
            }
            let path = url.path.lowercased()
            // `token` only as a whole path segment, so `/v1/token_plan/remains` (MiniMax) isn't
            // mistaken for a token endpoint while `/oauth/token` and `/token` still are.
            let segments = path.split(separator: "/").map(String.init)
            if segments.contains("token") || ["refresh", "login"].contains(where: path.contains) {
                problems.append("called a sign-in endpoint: \(url.path)")
            }
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains("refresh_token") || body.contains("grant_type") {
                problems.append("sent a token refresh")
            }
            if let key, !key.isEmpty {
                if url.absoluteString.contains(key) { problems.append("put the key in the URL") }
                if body.contains(key) { problems.append("put the key in the body") }
            }
        }
        return problems
    }
}

extension XCTestCase {
    func assertFollowsRules(_ provider: any UsageProvider, file: StaticString = #filePath, line: UInt = #line) {
        let problems = ProviderContract.violations(of: provider.descriptor)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"), file: file, line: line)
    }

    /// The credential a provider uses, for `assertMapsHTTPErrors`.
    enum TestCredential {
        /// A key the user pasted: a rejection (401) means "check the key".
        case pastedKey(String)
        /// Another tool's stored sign-in, already set up in the context the closure returns: a
        /// rejection (401 or 403) must say "sign in again" in that tool, never "add a key".
        case storedSignIn(secret: String, context: (FixtureTransport) -> ProviderContext)

        var secret: String {
            switch self {
            case .pastedKey(let key): return key
            case .storedSignIn(let secret, _): return secret
            }
        }
    }

    /// Fetches with a fixture answer for each of 401, 403, 429, 500, a non-JSON body and a
    /// network failure, and checks each becomes the right typed error with no key in its text.
    func assertMapsHTTPErrors(_ provider: any UsageProvider, url: String, key: String, settings: ProviderSettings = ProviderSettings(), file: StaticString = #filePath, line: UInt = #line) async {
        await assertMapsHTTPErrors(provider, url: url, credential: .pastedKey(key), settings: settings, file: file, line: line)
    }

    /// The same, for either kind of credential. With `.storedSignIn`, 401 and 403 must both be
    /// `expired` and say "sign in again", because only the tool itself can renew its sign-in.
    func assertMapsHTTPErrors(_ provider: any UsageProvider, url: String, credential: TestCredential, settings: ProviderSettings = ProviderSettings(), file: StaticString = #filePath, line: UInt = #line) async {
        let isStored: Bool
        if case .storedSignIn = credential { isStored = true } else { isStored = false }
        let cases: [(Int, String, String)] = [
            (401, "{}", isStored ? "expired" : "notSignedIn"), (403, "{}", "expired"), (429, "{}", "rateLimited"),
            (500, "{}", "network"), (200, "<html>not json</html>", "unexpectedResponse"),
        ]
        func context(_ transport: FixtureTransport) -> ProviderContext {
            switch credential {
            case .pastedKey(let key): return TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings)
            case .storedSignIn(_, let make): return make(transport)
            }
        }
        for (status, body, kind) in cases {
            let transport = FixtureTransport()
            transport.respond(to: url, status: status, body: Data(body.utf8))
            do {
                _ = try await provider.fetch(in: context(transport))
                XCTFail("HTTP \(status) should fail", file: file, line: line)
            } catch let error as ProviderError {
                XCTAssertEqual(error.kind, kind, "HTTP \(status)", file: file, line: line)
                XCTAssertFalse(error.localizedDescription.contains(credential.secret), "the secret leaked into an error", file: file, line: line)
                if isStored, status == 401 || status == 403 {
                    XCTAssertTrue(error.localizedDescription.contains("sign in again"), "HTTP \(status): \(error.localizedDescription)", file: file, line: line)
                }
            } catch {
                XCTFail("HTTP \(status): \(error) is not a ProviderError", file: file, line: line)
            }
        }
        let transport = FixtureTransport()
        transport.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await provider.fetch(in: context(transport))
            XCTFail("a network failure should fail", file: file, line: line)
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "network", file: file, line: line)
        } catch {
            XCTFail("\(error) is not a ProviderError", file: file, line: line)
        }
    }
}
