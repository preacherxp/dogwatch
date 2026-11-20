import SwiftUI

// Codex: rate limits and token activity from Codex's own app server, a JSON-RPC process on
// stdin/stdout (documented: https://developers.openai.com/codex/app-server).
// Rate limit fields, read 2026-11-19: https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/GetAccountRateLimitsResponse.json
//
// Why it is gated: in ChatGPT sign-in mode Codex "owns the ChatGPT OAuth flow, persists tokens,
// and refreshes them automatically" (same page). Its auth manager refreshes when the access
// token expires within 5 minutes or the last refresh is over 8 days old
// (codex-rs/login/src/auth/manager.rs; the 8-day rule applies only to tokens without an expiry).
// A refresh rotates the stored login, and two processes
// refreshing at once can sign Codex out. So before starting Codex, Dogwatch reads only the
// expiry and `last_refresh` from ~/.codex/auth.json and does not start Codex when a refresh
// would be due; it asks the user to open Codex instead. On a failed refresh Codex keeps the
// stored login (it deletes it only on logout), and reading rate limits starts no thread, so no
// session is left behind.

struct CodexProvider: UsageProvider {
    static let appServer = DeclaredCommand(
        executable: "codex",
        arguments: ["app-server", "--stdio"],
        reason: "Asks Codex's own app server for your rate limits and token activity. Dogwatch starts it only when Codex's sign-in is fresh, so Codex has nothing to refresh."
    )

    let descriptor = ProviderDescriptor(
        id: .codex,
        name: "Codex",
        glyph: ProviderGlyph(symbol: "sailboat.fill", themed: [.ledger: "book.closed.fill", .cyber: "cpu"]),
        tint: Bridge.seafoam,
        category: .subscription,
        // The app server is documented, but starting it can refresh Codex's login, and that
        // command is not documented as read-only.
        stability: .undocumented,
        credential: .toolStore(ToolStore(kind: .file, location: "~/.codex/auth.json (expiry and last refresh only)")),
        summary: "ChatGPT allowance, tokens, and credits",
        reads: "Starts codex app-server --stdio and asks it account/rateLimits/read and account/usage/read over a pipe. Codex makes its own requests with its own sign-in. Before that, Dogwatch reads only the token expiry and last_refresh from ~/.codex/auth.json, and does not start Codex when Codex would refresh its sign-in.",
        source: "Codex app server (local process)",
        minimumRefreshInterval: 60,
        idleLabel: "Codex",
        documentation: URL(string: "https://developers.openai.com/codex/app-server"),
        timeout: 40,
        commands: [CodexProvider.appServer]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.findExecutable(named: "codex", extraDirectories: context.local.commonToolDirectories) == nil
            ? .unavailable("Codex is not installed")
            : .available
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let authURL = context.home.appendingPathComponent(".codex/auth.json")
        guard context.local.fileExists(authURL), let auth = try? context.local.read(authURL) else {
            throw ProviderError.notSignedIn("Codex sign-in not found. Open Codex to sign in.")
        }
        switch CodexUsageClient.authState(auth, now: context.now()) {
        case .ready: break
        case .refreshDue:
            throw ProviderError.expired("Codex needs to refresh its sign-in. Open Codex once, then Dogwatch reads it again.")
        case .signedOut:
            throw ProviderError.notSignedIn("Codex sign-in not found. Open Codex to sign in.")
        }

        let executable: URL
        do {
            executable = try context.local.authorize(Self.appServer)
        } catch ProviderError.notInstalled {
            throw ProviderError.notInstalled(CodexUsageError.executableNotFound.localizedDescription)
        }
        let environment = context.local.processEnvironment(for: Self.appServer)
        let client = CodexUsageClient(executable: executable, arguments: Self.appServer.arguments, environment: environment)
        let result: (usage: UsageSnapshot, extras: CodexExtras) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // One retry: the app server occasionally misses its first answer while starting.
                continuation.resume(with: Result { try (try? client.fetchDetailed()) ?? client.fetchDetailed() }.mapError(Self.providerError))
            }
        }
        return Self.snapshot(from: result.usage, extras: result.extras)
    }

    private static func providerError(_ error: Error) -> Error {
        switch error {
        case CodexUsageError.executableNotFound: return ProviderError.notInstalled(error.localizedDescription)
        case CodexUsageError.timedOut: return ProviderError.timedOut
        case CodexUsageError.launchFailed: return ProviderError.notInstalled(error.localizedDescription)
        case CodexUsageError.server, CodexUsageError.incompleteResponse: return ProviderError.unexpectedResponse(error.localizedDescription)
        default: return error
        }
    }

    /// Readings:
    /// - `primary` and `secondary`: the main Codex windows (unchanged);
    /// - `model:<limitId>` and `model:<limitId>:secondary`: windows of other metered buckets in
    ///   `rateLimitsByLimitId`, such as a model with its own limit;
    /// - `credits`: the purchased credit balance, when Codex reports one and it isn't unlimited.
    static func snapshot(from usage: UsageSnapshot, extras: CodexExtras = CodexExtras()) -> ProviderSnapshot {
        var readings = [Reading(
            id: "primary",
            name: usage.windowLabel,
            value: .window(QuotaWindow(usedPercent: usage.usedPercent, period: .named(usage.windowLabel), resetsAt: usage.resetDate))
        )]
        if let weekly = usage.weeklyUsedPercent {
            readings.append(Reading(
                id: "secondary",
                name: "weekly",
                value: .window(QuotaWindow(usedPercent: weekly, period: .named("weekly"), resetsAt: nil)),
                meterLabel: "Week"
            ))
        }
        for limit in extras.modelLimits {
            readings.append(Reading(
                id: limit.id,
                name: "\(limit.name) \(limit.period.label)",
                value: .window(QuotaWindow(usedPercent: limit.usedPercent, period: limit.period, resetsAt: limit.resetsAt)),
                meterLabel: "\(limit.name) \(limit.period.label)"
            ))
        }
        if let credits = extras.creditBalance {
            readings.append(Reading(
                id: "credits",
                name: "Credits",
                value: .balance(Balance(remaining: Amount(value: credits, unit: .credits)))
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            plan: usage.planName,
            note: extras.ordinaryUsageAllowed == false ? "Codex says included usage is blocked right now" : nil,
            primaryHint: "primary",
            activity: TokenActivity(dailyUsage: usage.dailyUsage, lifetimeTokens: usage.lifetimeTokens, credits: usage.creditBalance),
            historyReadingID: "primary"
        )
    }
}

/// What the app server reports beyond `UsageSnapshot`: other metered buckets, the credit
/// balance as a number, and whether included usage is allowed now.
struct CodexExtras: Equatable {
    struct ModelLimit: Equatable {
        let id: String
        let name: String
        let usedPercent: Int
        let period: WindowPeriod
        let resetsAt: Date?
    }

    var modelLimits: [ModelLimit] = []
    var creditBalance: Double? = nil
    var ordinaryUsageAllowed: Bool? = nil
}

enum CodexUsageError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case server(String)
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install Codex or add it to your PATH."
        case .launchFailed(let message):
            return "Could not start Codex: \(message)"
        case .timedOut:
            return "Codex did not answer in time."
        case .server(let message):
            return "Codex returned an error: \(message)"
        case .incompleteResponse:
            return "Codex returned incomplete usage data."
        }
    }
}

final class CodexUsageClient {
    enum AuthState: Equatable { case ready, refreshDue, signedOut }

    /// Whether Codex would refresh its sign-in on start. Reads only `auth_mode`, the access
    /// token's `exp` claim and `last_refresh`; the token itself is never kept. Margins are wider
    /// than Codex's own (5 minutes, 8 days), so Codex never needs to refresh because of Dogwatch.
    static func authState(_ data: Data, now: Date) -> AuthState {
        guard let auth = try? JSONValue(data: data) else { return .signedOut }
        let tokens = auth["tokens"]
        let accessToken = tokens?["access_token"]?.stringValue
        if accessToken == nil {
            // An API-key login has nothing to refresh.
            return auth["OPENAI_API_KEY"]?.stringValue?.isEmpty == false ? .ready : .signedOut
        }
        // The same order as Codex: a token with an expiry is judged by it alone; only a token
        // without one is judged by the age of the last refresh.
        if let token = accessToken, let expiry = jwtExpiry(token) {
            return expiry <= now.addingTimeInterval(30 * 60) ? .refreshDue : .ready
        }
        if let last = DateParsing.iso8601(auth["last_refresh"]?.stringValue),
           last < now.addingTimeInterval(-7.5 * 86_400) {
            return .refreshDue
        }
        return .ready
    }

    static func jwtExpiry(_ token: String) -> Date? {
        StoredCredential.jwtExpiry(token)
    }

    private let timeout: TimeInterval
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]

    init(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 15) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    func fetch() throws -> UsageSnapshot {
        try fetchDetailed().usage
    }

    /// The parsed snapshot and the fields `UsageSnapshot` has no place for.
    func fetchDetailed() throws -> (usage: UsageSnapshot, extras: CodexExtras) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let state = ResponseState()
        let completion = DispatchSemaphore(value: 0)

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var buffered = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffered.append(chunk)

            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }

                if let error = object["error"] as? [String: Any] {
                    state.error = (error["message"] as? String) ?? "Unknown error"
                    completion.signal()
                    continue
                }

                guard let id = Self.requestID(from: object) else { continue }
                switch id {
                case 1:
                    do {
                        try Self.write([
                            ["method": "initialized"],
                            ["id": 2, "method": "account/rateLimits/read"],
                            ["id": 3, "method": "account/usage/read"]
                        ], to: input.fileHandleForWriting)
                    } catch {
                        state.error = error.localizedDescription
                        completion.signal()
                    }
                case 2:
                    state.rateLimits = object["result"] as? [String: Any]
                case 3:
                    state.tokenUsage = object["result"] as? [String: Any]
                default:
                    break
                }

                if state.rateLimits != nil, state.tokenUsage != nil {
                    completion.signal()
                }
            }
        }

        do {
            try process.run()
            try Self.write([
                [
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "dogwatch",
                            "title": "Dogwatch",
                            "version": "0.1.1"
                        ],
                        "capabilities": ["experimentalApi": true]
                    ]
                ]
            ], to: input.fileHandleForWriting)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw CodexUsageError.launchFailed(error.localizedDescription)
        }

        let finished = completion.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard finished else { throw CodexUsageError.timedOut }
        if let message = state.error { throw CodexUsageError.server(message) }
        guard let rateLimits = state.rateLimits, let tokenUsage = state.tokenUsage else {
            throw CodexUsageError.incompleteResponse
        }

        return (try Self.parse(rateLimits: rateLimits, tokenUsage: tokenUsage), Self.extras(from: rateLimits))
    }

    /// Per-model limits, the credit balance and the "can I use it now" flag from the
    /// `account/rateLimits/read` result. Schema, read 2026-11-19:
    /// https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/GetAccountRateLimitsResponse.json
    /// - `rateLimitsByLimitId`: every metered bucket keyed by `limitId`; the one `rateLimits`
    ///   mirrors (`codex` by default) is skipped, the others become model limits named by
    ///   `limitName`, else `normalModelSlug`, else the id.
    /// - `rateLimits.credits {hasCredits, unlimited, balance}`: `balance` is a decimal string.
    /// - `ordinaryUsageAllowed`: null means unknown and is ignored.
    static func extras(from rateLimits: [String: Any]) -> CodexExtras {
        var extras = CodexExtras()
        let main = rateLimits["rateLimits"] as? [String: Any]
        let mainID = (main?["limitId"] as? String) ?? "codex"
        let buckets = rateLimits["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        for (id, value) in buckets.sorted(by: { $0.key < $1.key }) where id != mainID {
            guard let bucket = value as? [String: Any] else { continue }
            let name = [bucket["limitName"], bucket["normalModelSlug"]].compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }.first ?? id
            for (slot, suffix) in [("primary", ""), ("secondary", ":secondary")] {
                guard let window = bucket[slot] as? [String: Any], let used = intPercent(window["usedPercent"]) else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.doubleValue
                extras.modelLimits.append(CodexExtras.ModelLimit(
                    id: "model:\(id)\(suffix)",
                    name: name,
                    usedPercent: max(0, min(100, used)),
                    period: minutes.map { .duration($0 * 60) } ?? .named("current window"),
                    resetsAt: (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ))
            }
        }
        if let credits = main?["credits"] as? [String: Any], credits["unlimited"] as? Bool != true,
           credits["hasCredits"] as? Bool == true,
           let text = credits["balance"] as? String, let balance = Double(text.trimmingCharacters(in: .whitespaces)) {
            extras.creditBalance = balance
        }
        extras.ordinaryUsageAllowed = rateLimits["ordinaryUsageAllowed"] as? Bool
        return extras
    }

    static func parse(rateLimits: [String: Any], tokenUsage: [String: Any]) throws -> UsageSnapshot {
        guard let limits = rateLimits["rateLimits"] as? [String: Any] else {
            throw CodexUsageError.incompleteResponse
        }

        // The main window is the short one when the plan has it, otherwise the longer one.
        // A plan with neither has no allowance to show, which is reported, not shown as 100%.
        let reportedPrimary = limits["primary"] as? [String: Any]
        let reportedSecondary = limits["secondary"] as? [String: Any]
        guard let primary = reportedPrimary ?? reportedSecondary,
              let usedPercent = intPercent(primary["usedPercent"])
        else {
            throw CodexUsageError.incompleteResponse
        }
        let secondary = reportedPrimary == nil ? nil : reportedSecondary
        let resetTimestamp = primary["resetsAt"] as? TimeInterval
        let resetDate = resetTimestamp.map(Date.init(timeIntervalSince1970:))
        let windowMinutes = primary["windowDurationMins"] as? Int
        let summary = tokenUsage["summary"] as? [String: Any]
        let lifetimeTokens = Self.int64(summary?["lifetimeTokens"])
        let credits = limits["credits"] as? [String: Any]
        let buckets = tokenUsage["dailyUsageBuckets"] as? [[String: Any]] ?? []

        let dailyUsage = buckets.compactMap { bucket -> DailyUsage? in
            guard let dateText = bucket["startDate"] as? String,
                  let date = Self.dayFormatter.date(from: dateText),
                  let tokens = Self.int64(bucket["tokens"])
            else { return nil }
            return DailyUsage(date: date, tokens: tokens)
        }

        return UsageSnapshot(
            planName: UsageFormatters.plan(limits["planType"] as? String),
            usedPercent: max(0, min(100, usedPercent)),
            resetDate: resetDate,
            windowMinutes: windowMinutes,
            lifetimeTokens: lifetimeTokens,
            dailyUsage: dailyUsage,
            creditBalance: credits?["balance"] as? String,
            weeklyUsedPercent: intPercent(secondary?["usedPercent"]).map { max(0, min(100, $0)) }
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func intPercent(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value.rounded()) }
        if let value = value as? NSNumber { return Int(value.doubleValue.rounded()) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func requestID(from object: [String: Any]) -> Int? {
        if let id = object["id"] as? Int { return id }
        if let id = object["id"] as? NSNumber { return id.intValue }
        return nil
    }

    private static func write(_ messages: [[String: Any]], to handle: FileHandle) throws {
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }
    }

    static func findNodeExecutable() -> URL? {
        firstExecutable(named: "node", extras: extraPathEntries())
    }

    private static func firstExecutable(named name: String, extras: [String]) -> URL? {
        let fileManager = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = (pathDirs + extras).map { "\($0)/\(name)" }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func extraPathEntries() -> [String] {
        let home = homePath
        var entries = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.node_modules/bin",
            "\(home)/.local/bin"
        ]
        let nvmRoots = [
            "\(home)/.local/share/nvm",
            "\(home)/.nvm/versions/node"
        ]
        for root in nvmRoots {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            entries.append(contentsOf: versions.map { "\(root)/\($0)/bin" })
        }
        return entries
    }

    private static var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}

private final class ResponseState {
    var rateLimits: [String: Any]?
    var tokenUsage: [String: Any]?
    var error: String?
}
