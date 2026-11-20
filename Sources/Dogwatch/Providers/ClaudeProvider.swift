import SwiftUI

// Claude: the usage endpoint Claude Code's own `/usage` calls, with the OAuth token Claude Code
// keeps in the login Keychain. This is the model to follow for any provider that reads another
// tool's login: the token is read as stored, its expiry is checked locally, and an expired or
// rejected token becomes "open Claude Code to sign in again". Dogwatch never refreshes it,
// never writes it and never starts Claude Code.
//
// Sources:
// - Endpoint and fields: what Claude Code 2.1 calls for `/usage` (undocumented).
// - Status line fallback: https://code.claude.com/docs/en/statusline (documented `rate_limits`).
// - `limits[]`, `extra_usage` and `spend`: shape checked live on this Mac (research, 2026-11-19);
//   amounts in minor units per CodexBar docs/claude.md (https://github.com/steipete/CodexBar),
//   read 2026-11-19. Extra usage and spend were switched off on this account, so those two
//   readings are built from that description and fixtures only.

struct ClaudeProvider: UsageProvider {
    static let keychainCommand = DeclaredCommand(
        executable: "security",
        arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
        reason: "Reads the sign-in Claude Code keeps in your login Keychain, without changing it.",
        documentedReadOnly: true
    )

    let descriptor = ProviderDescriptor(
        id: .claude,
        name: "Claude",
        glyph: ProviderGlyph(symbol: "asterisk"),
        tint: Bridge.amber,
        category: .subscription,
        stability: .undocumented,
        credential: .toolStore(ToolStore(kind: .keychain, location: "login Keychain item “Claude Code-credentials”")),
        summary: "Claude Code limits: weekly, and five-hour if your plan has one",
        reads: "The OAuth token Claude Code keeps in your login Keychain, read with /usr/bin/security. It is sent only as the Authorization header of GET https://api.anthropic.com/api/oauth/usage and held in memory for that one request. If it is missing, expired or rejected, Dogwatch shows “open Claude Code to sign in again” and, if you set one up, reads ~/Library/Application Support/Dogwatch/claude-rate-limits.json instead.",
        source: "Claude Code's usage endpoint, with Claude Code's Keychain sign-in",
        allowedHosts: ["api.anthropic.com"],
        minimumRefreshInterval: 60,
        idleLabel: "Open Claude Code",
        documentation: URL(string: "https://code.claude.com/docs/en/statusline"),
        localSources: [ToolStore(kind: .file, location: "~/Library/Application Support/Dogwatch/claude-rate-limits.json")],
        commands: [ClaudeProvider.keychainCommand]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.findExecutable(named: "security", extraDirectories: ["/usr/bin"]) == nil
            ? .unavailable("/usr/bin/security is missing")
            : .available
    }

    /// Live usage from the account Claude Code is signed in to, which counts every client on that
    /// subscription. Falls back to the status line file when the sign-in is missing or rejected.
    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        do {
            let token = try await accessToken(in: context)
            let data = try await context.http.send(ClaudeUsageClient.makeUsageRequest(token: token))
            do {
                return Self.snapshot(from: try ClaudeUsageClient.parseUsage(data, fetchedAt: context.now()))
            } catch {
                throw ProviderError.unexpectedResponse("Claude answered in an unexpected format.")
            }
        } catch let error as ProviderError {
            if let cached = try? statusLineSnapshot(in: context) { return cached }
            switch error {
            case .notSignedIn, .expired:
                throw ProviderError.expired("Claude Code's sign-in has expired. Open Claude Code to sign in again.")
            default:
                throw error
            }
        }
    }

    /// The access token as Claude Code stored it. Expired tokens are refused here, before any
    /// network call; refreshing is Claude Code's job.
    private func accessToken(in context: ProviderContext) async throws -> String {
        let result = try await context.local.run(Self.keychainCommand, timeout: 10)
        switch result.status {
        case 0: break
        case 128: throw ProviderError.accessDenied("Keychain access to Claude Code's sign-in was denied. Choose Try again to be asked once more.")
        default: throw ProviderError.notSignedIn("Claude Code sign-in not found. Open Claude Code to sign in.")
        }
        guard let oauth = (try? JSONDecoder().decode(ClaudeUsageClient.Credentials.self, from: result.output))?.claudeAiOauth else {
            throw ProviderError.notSignedIn("Claude Code sign-in not found. Open Claude Code to sign in.")
        }
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) <= context.now() {
            throw ProviderError.expired("Claude Code's sign-in has expired. Open Claude Code to sign in again.")
        }
        return oauth.accessToken
    }

    private func statusLineSnapshot(in context: ProviderContext) throws -> ProviderSnapshot {
        let url = context.home.appendingPathComponent("Library/Application Support/Dogwatch/claude-rate-limits.json")
        guard context.local.fileExists(url) else { throw ProviderError.notSignedIn("No status line file") }
        let data = try context.local.read(url)
        let modified = context.local.modificationDate(of: url) ?? context.now()
        var snapshot = Self.snapshot(from: try ClaudeUsageClient.parseStatusLineCache(data, modifiedAt: modified))
        snapshot.note = "From Claude Code's status line, \(modified.formatted(.relative(presentation: .named)))"
        return snapshot
    }

    /// Claude's windows as readings. The five-hour window is shown when the plan has one, with
    /// the week as a second meter; otherwise the binding limit (`limits[].is_active`), which may be
    /// a model-scoped weekly limit tighter than the overall week. The menu bar shows the tightest.
    static func snapshot(from claude: ClaudeUsageSnapshot) -> ProviderSnapshot {
        // Whether a window is running is judged at the time it was read, so history records what
        // Claude reported then.
        let readAt = claude.cacheUpdatedAt
        func isActive(_ used: Int?, _ reset: Date?) -> Bool { used != nil && (reset.map { $0 > readAt } ?? true) }
        let fiveHourActive = isActive(claude.fiveHourUsedPercent, claude.fiveHourResetDate)
        let weeklyActive = isActive(claude.weeklyUsedPercent, claude.weeklyResetDate)
        var readings: [Reading] = []
        if claude.hasFiveHourWindow {
            readings.append(Reading(
                id: "five_hour",
                name: "5h session",
                value: .window(QuotaWindow(
                    usedPercent: fiveHourActive ? claude.fiveHourUsedPercent ?? 0 : 0,
                    period: .duration(5 * 3_600),
                    resetsAt: fiveHourActive ? claude.fiveHourResetDate : nil
                )),
                meterLabel: "5h",
                detail: fiveHourActive ? nil : "New 5h window · starts with your next message"
            ))
        }
        if claude.hasWeeklyWindow {
            readings.append(Reading(
                id: "seven_day",
                name: "weekly",
                value: .window(QuotaWindow(
                    usedPercent: weeklyActive ? claude.weeklyUsedPercent ?? 0 : 0,
                    period: .named("weekly"),
                    resetsAt: weeklyActive ? claude.weeklyResetDate : nil
                )),
                meterLabel: "Week",
                detail: weeklyActive ? nil : "New weekly window · starts with your next message"
            ))
        }
        for limit in claude.scopedLimits {
            let reset = limit.resetDate.flatMap { $0 > readAt ? $0 : nil }
            readings.append(Reading(
                id: "scoped:\(limit.name.lowercased())",
                name: "\(limit.name) weekly",
                value: .window(QuotaWindow(
                    usedPercent: reset == nil && limit.resetDate != nil ? 0 : limit.usedPercent,
                    period: .named("\(limit.name) weekly"),
                    resetsAt: reset
                )),
                meterLabel: "\(limit.name) week",
                isBinding: limit.isActive
            ))
        }
        // Pay-as-you-go money, only when the account has it switched on. The cap is a real total,
        // so it is the budget, but extra usage isn't the plan's limit: `canHeadline: false` keeps
        // it from ever being the gauge or the menu bar's tightest.
        for (id, money) in [("extra_usage", claude.extraUsage), ("spend", claude.spend)] {
            guard let money else { continue }
            let spent = Amount(value: money.used, unit: .currency(money.currency))
            let cap = money.limit.map { Amount(value: $0, unit: .currency(money.currency)) }
            readings.append(Reading(
                id: id,
                name: id == "extra_usage" ? "Extra usage" : "Spend",
                value: .spend(Spend(amount: spent, period: "this month", budget: cap)),
                canHeadline: false
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "No usage window reported" : nil,
            primaryHint: claude.hasFiveHourWindow ? "five_hour" : nil,
            menuBar: .tightest,
            historyReadingID: "seven_day",
            fetchedAt: claude.cacheUpdatedAt
        )
    }
}

struct ClaudeUsageSnapshot: Equatable {
    struct ScopedLimit: Equatable {
        /// The model or surface it applies to, as Claude names it: "Fable".
        let name: String
        let usedPercent: Int
        let resetDate: Date?
        let isActive: Bool
    }

    let fiveHourUsedPercent: Int?
    let fiveHourResetDate: Date?
    let weeklyUsedPercent: Int?
    let weeklyResetDate: Date?
    let cacheUpdatedAt: Date
    /// Whether the account has a five-hour window at all. The usage endpoint sends
    /// `"five_hour": null` for plans without one, and an object, possibly with null fields,
    /// for plans that have one. The status line drops expired windows, so there a missing
    /// window may be either; the parser says false then, which never overstates what is left.
    var hasFiveHourWindow = true
    /// Whether the provider reported a weekly window at all.
    var hasWeeklyWindow = true
    /// Weekly limits for one model or surface, from `limits[]` entries with a scope.
    var scopedLimits: [ScopedLimit] = []
    /// Pay-as-you-go money in whole currency units, only when the account has it switched on.
    struct Money: Equatable {
        let used: Double
        let limit: Double?
        let currency: String
    }

    /// `extra_usage` when `is_enabled` is true: used and monthly cap, sent in cents.
    var extraUsage: Money? = nil
    /// `spend` when `enabled` is true: `used` and `limit` as `{amount_minor, currency, exponent}`.
    var spend: Money? = nil

    enum Window { case fiveHour, weekly }

    var isFiveHourActive: Bool { isActive(used: fiveHourUsedPercent, reset: fiveHourResetDate) }
    var isWeeklyActive: Bool { isActive(used: weeklyUsedPercent, reset: weeklyResetDate) }

    // A window the account has but whose resets_at has passed, or that has not started,
    // is a fresh one with nothing used yet.
    var fiveHourRemainingPercent: Int {
        isFiveHourActive ? max(0, min(100, 100 - (fiveHourUsedPercent ?? 0))) : 100
    }

    /// nil when no weekly window was reported, so it is never shown as 100% left.
    var weeklyRemainingPercent: Int? {
        guard hasWeeklyWindow else { return nil }
        return isWeeklyActive ? max(0, min(100, 100 - (weeklyUsedPercent ?? 0))) : 100
    }

    /// The window the gauge shows: the five-hour one when the account has it, otherwise
    /// the weekly one, otherwise none.
    var mainWindow: Window? {
        if hasFiveHourWindow { return .fiveHour }
        return hasWeeklyWindow ? .weekly : nil
    }

    /// For the menu bar: the tightest of the windows the account has.
    var lowestRemainingPercent: Int? {
        [hasFiveHourWindow ? fiveHourRemainingPercent : nil, weeklyRemainingPercent].compactMap { $0 }.min()
    }

    private func isActive(used: Int?, reset: Date?) -> Bool {
        guard used != nil else { return false }
        if let reset, reset <= Date() { return false }
        return true
    }
}

/// The parsers and request for Claude's usage endpoint and status line file.
enum ClaudeUsageClient {
    private struct CachePayload: Decodable {
        let fiveHour: CacheWindow?
        let sevenDay: CacheWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct CacheWindow: Decodable {
        let usedPercentage: Double?
        let resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    private struct UsagePayload: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// One `limits[]` entry. Only scoped entries become readings; the unscoped weekly entry
    /// repeats `seven_day`.
    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let displayName: String?; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            let model: Model?
            let surface: String?
        }

        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
            percent = try? container.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
            scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
            if let flag = try? container.decodeIfPresent(Bool.self, forKey: .isActive) {
                isActive = flag
            } else {
                isActive = (try? container.decodeIfPresent(Int.self, forKey: .isActive)).flatMap { $0.map { $0 != 0 } }
            }
        }
    }

    struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }

        let claudeAiOauth: OAuth?
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Optional fallback: the `rate_limits` object from Claude Code's status line JSON, written
    /// by a status line script the user sets up themselves. Dogwatch only reads it.
    static var statusLineCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dogwatch/claude-rate-limits.json")
    }

    /// The hardened session every provider request goes through. See `HTTPClient`.
    static var session: URLSession { HTTPClient.hardenedSession }

    static func makeUsageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func parseUsage(_ data: Data, fetchedAt: Date) throws -> ClaudeUsageSnapshot {
        let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        let scoped = (payload.limits ?? []).compactMap { limit -> ClaudeUsageSnapshot.ScopedLimit? in
            guard let name = limit.scope?.model?.displayName ?? limit.scope?.surface,
                  !name.isEmpty, let percent = limit.percent
            else { return nil }
            return ClaudeUsageSnapshot.ScopedLimit(
                name: name,
                usedPercent: Int(percent.rounded()),
                resetDate: limit.resetsAt.flatMap(DateParsing.iso8601),
                isActive: limit.isActive ?? false
            )
        }
        let json = try? JSONValue(data: data)
        return ClaudeUsageSnapshot(
            fiveHourUsedPercent: payload.fiveHour?.utilization.map { Int($0.rounded()) },
            fiveHourResetDate: payload.fiveHour?.resetsAt.flatMap(DateParsing.iso8601),
            weeklyUsedPercent: payload.sevenDay?.utilization.map { Int($0.rounded()) },
            weeklyResetDate: payload.sevenDay?.resetsAt.flatMap(DateParsing.iso8601),
            cacheUpdatedAt: fetchedAt,
            hasFiveHourWindow: payload.fiveHour != nil,
            hasWeeklyWindow: payload.sevenDay != nil,
            scopedLimits: scoped,
            extraUsage: json.flatMap { extraUsage(in: $0) },
            spend: json.flatMap { spend(in: $0) }
        )
    }

    /// `extra_usage {is_enabled, monthly_limit, used_credits, currency}`, only when enabled.
    /// Amounts are in cents (minor units), as Claude's own clients and CodexBar
    /// (docs/claude.md, ClaudeUsageFetcher.swift, read 2026-11-19) read them. Not seen switched
    /// on from this Mac.
    static func extraUsage(in json: JSONValue) -> ClaudeUsageSnapshot.Money? {
        guard let extra = json["extra_usage"], extra["is_enabled"]?.boolValue == true,
              let used = extra["used_credits"]?.doubleValue
        else { return nil }
        let currency = extra["currency"]?.stringValue.flatMap { $0.count == 3 ? $0.uppercased() : nil } ?? "USD"
        return ClaudeUsageSnapshot.Money(
            used: used / 100,
            limit: extra["monthly_limit"]?.doubleValue.map { $0 / 100 },
            currency: currency
        )
    }

    /// `spend {enabled, used {amount_minor, currency, exponent}, limit}`, only when enabled.
    /// `limit` is read only in the same `{amount_minor, …}` shape; anything else is no cap.
    static func spend(in json: JSONValue) -> ClaudeUsageSnapshot.Money? {
        guard let spend = json["spend"], spend["enabled"]?.boolValue == true,
              let used = spend["used"], let usedValue = minorAmount(used)
        else { return nil }
        let currency = used["currency"]?.stringValue.flatMap { $0.count == 3 ? $0.uppercased() : nil } ?? "USD"
        return ClaudeUsageSnapshot.Money(used: usedValue, limit: spend["limit"].flatMap(minorAmount), currency: currency)
    }

    private static func minorAmount(_ value: JSONValue) -> Double? {
        guard let minor = value["amount_minor"]?.doubleValue else { return nil }
        let exponent = value["exponent"]?.doubleValue ?? 2
        guard exponent >= 0, exponent <= 6 else { return nil }
        return minor / pow(10, exponent)
    }

    static func parseStatusLineCache(_ data: Data, modifiedAt: Date) throws -> ClaudeUsageSnapshot {
        let payload = try JSONDecoder().decode(CachePayload.self, from: data)
        return ClaudeUsageSnapshot(
            fiveHourUsedPercent: payload.fiveHour?.usedPercentage.map { Int($0.rounded()) },
            fiveHourResetDate: payload.fiveHour?.resetsAt.map(Date.init(timeIntervalSince1970:)),
            weeklyUsedPercent: payload.sevenDay?.usedPercentage.map { Int($0.rounded()) },
            weeklyResetDate: payload.sevenDay?.resetsAt.map(Date.init(timeIntervalSince1970:)),
            cacheUpdatedAt: modifiedAt,
            hasFiveHourWindow: payload.fiveHour != nil,
            hasWeeklyWindow: payload.sevenDay != nil
        )
    }
}
