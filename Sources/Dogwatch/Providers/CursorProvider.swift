import SwiftUI

// Cursor: the endpoints cursor.com's own dashboard calls, with a cursor.com session.
//
// Sources, read 2026-11-19:
// - Plans and pools: https://cursor.com/help/models-and-usage/usage-limits (The X Subscription:
//   one weekly pool for Cursor models; legacy plans: monthly included usage plus on-demand).
// - Endpoints and fields (undocumented; no official reference exists): the open source CodexBar,
//   https://github.com/steipete/CodexBar/blob/main/docs/cursor.md and its
//   `Sources/CodexBarCore/Providers/Cursor/` parsers.
//   - `GET https://cursor.com/api/usage-summary`: `billingCycleStart`, `billingCycleEnd`,
//     `membershipType`, `individualUsage.plan {used, limit (cents), totalPercentUsed,
//     autoPercentUsed, apiPercentUsed (percent units)}`, `individualUsage.onDemand {enabled, used,
//     limit (cents, null = no limit)}`, `individualUsage.overall` (team member cap, cents).
//   - `POST https://cursor.com/api/dashboard/get-sand-usage-status` with `{}`: `isUnified`,
//     `usagePercent`, `nextResetTimestampUtc`, `hasNonZeroIncludedLimit`/`includedLimitZero`:
//     the weekly pool shared with Grok on The X Subscription.
//   - The session is the cookie `WorkosCursorSessionToken=<user id>%3A%3A<JWT>`.
//
// Credential, in order:
// 1. A cursor.com cookie the user pastes (the default; no prompt).
// 2. Only if the user turns on "Read Cursor's own sign-in": Cursor.app's token from its
//    `state.vscdb` (`cursorAuth/accessToken`). Current Cursor versions encrypt it
//    (`cursor-safe-storage:v1:` + base64 Chromium v10), so decrypting it reads the
//    "Cursor Safe Storage" password from the login Keychain, which shows a macOS prompt.
//    The JWT's expiry is checked locally; it is never refreshed.
// Not verified against a real account.

struct CursorProvider: UsageProvider {
    static let readAppSignIn = "readAppSignIn"
    static let databasePath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let tokenKey = "cursorAuth/accessToken"
    static let encryptedPrefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"
    /// Cursor 3.27 uses "Cursor Key"; older versions "Cursor".
    static let keychainAccounts = ["Cursor Key", "Cursor"]
    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let poolURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!

    var keychain: SafeStoragePasswordReading = KeychainSafeStoragePasswordReader()

    let descriptor = ProviderDescriptor(
        id: "cursor",
        name: "Cursor",
        glyph: ProviderGlyph(symbol: "cursorarrow.rays"),
        tint: Color(red: 0.62, green: 0.66, blue: 0.74),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .cookie,
            label: "cursor.com cookie",
            placeholder: "WorkosCursorSessionToken=…",
            helpURL: URL(string: "https://cursor.com/dashboard"),
            warning: "A session cookie gives full access to your Cursor account, not only to usage: whoever has it can change your plan and billing. It can also stop working at any time, for example when you sign out of cursor.com or Cursor changes how sessions work; then paste a fresh one.",
            advice: "Cursor has no read-only key for personal usage. Copy the Cookie header of a cursor.com/dashboard request from your browser's network panel."
        )),
        summary: "Weekly pool or monthly included usage, and on-demand spend",
        reads: "GET https://cursor.com/api/usage-summary and POST https://cursor.com/api/dashboard/get-sand-usage-status (an empty body), the endpoints Cursor's dashboard uses, with your cursor.com cookie from the Keychain in the Cookie header. Only if you turn on “Read Cursor's own sign-in”: instead of a pasted cookie, Dogwatch reads cursorAuth/accessToken from ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb (read-only) and, because Cursor encrypts it, the “Cursor Safe Storage” password from your login Keychain to decrypt it in memory. That token is only sent to cursor.com, is never refreshed or stored, and when it has expired Dogwatch asks you to open Cursor.",
        source: "cursor.com dashboard endpoints, with a pasted cookie or Cursor's own sign-in (opt-in)",
        allowedHosts: ["cursor.com"],
        minimumRefreshInterval: 120,
        idleLabel: "Add a cookie",
        documentation: URL(string: "https://cursor.com/help/models-and-usage/usage-limits"),
        timeout: 30,
        fields: [SettingField(
            id: CursorProvider.readAppSignIn,
            label: "Read Cursor's own sign-in",
            help: "Off by default. When it is on and no cookie is pasted, Dogwatch reads Cursor's stored sign-in instead. Cursor keeps it encrypted, so macOS asks you for permission for Dogwatch to read Cursor's stored password (“Cursor Safe Storage”) from your Keychain. If you deny it, Dogwatch doesn't ask again until you press Refresh.",
            isRequired: false,
            kind: .toggle
        )],
        localSources: [
            ToolStore(kind: .file, location: "~/\(CursorProvider.databasePath)", onlyWhen: CursorProvider.readAppSignIn),
            ToolStore(kind: .keychain, location: "Cursor's stored password (“Cursor Safe Storage” in your login Keychain)", mayPrompt: true, onlyWhen: CursorProvider.readAppSignIn),
        ]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        if let key = context.key(), !key.isEmpty { return .available }
        guard context.settings.isOn(Self.readAppSignIn) else {
            return .unavailable("Paste a cursor.com cookie, or turn on “Read Cursor's own sign-in”")
        }
        return context.local.fileExists(context.home.appendingPathComponent(Self.databasePath))
            ? .available : .unavailable("Cursor is not installed")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let cookie: String
        let fromApp: Bool
        if let key = context.key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            cookie = key.contains("=") ? key : "WorkosCursorSessionToken=\(key)"
            fromApp = false
        } else if context.settings.isOn(Self.readAppSignIn) {
            cookie = try Self.sessionCookie(token: appToken(in: context), now: context.now())
            fromApp = true
        } else {
            throw ProviderError.notSignedIn("No cursor.com cookie set. Add one in settings, or turn on “Read Cursor's own sign-in”.")
        }

        let summary: JSONValue
        do {
            summary = try await context.http.getJSON(Self.summaryURL, headers: ["Cookie": cookie])
        } catch let error as ProviderError where error.kind == "notSignedIn" || error.kind == "expired" {
            if fromApp { throw ProviderError.expired("Cursor's sign-in was rejected. Open Cursor to sign in again.") }
            throw error.kind == "expired"
                ? ProviderError.expired("cursor.com refused the cookie; it may have expired. Paste a fresh one in settings.")
                : ProviderError.notSignedIn("cursor.com rejected the cookie. Paste a fresh one in settings.")
        }

        // The weekly pool is a second, best-effort request: a failure keeps the summary. It is sent
        // as itself, without an Origin header pretending to be cursor.com's own page; if Cursor
        // insists on one, the pool is left out rather than impersonating the dashboard.
        var pool: JSONValue?
        var request = URLRequest(url: Self.poolURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let data = try? await context.http.send(request) { pool = try? JSONValue(data: data) }

        return try Self.snapshot(summary: summary, pool: pool, now: context.now())
    }

    /// Cursor.app's stored token, decrypted when it is encrypted. Read only after the user opted in.
    private func appToken(in context: ProviderContext) throws -> String {
        let database = context.home.appendingPathComponent(Self.databasePath)
        guard context.local.fileExists(database) else { throw ProviderError.notInstalled("Cursor is not installed") }
        guard let stored = try context.local.vscodeStateValue(database, key: Self.tokenKey), !stored.isEmpty else {
            throw ProviderError.notSignedIn("Cursor sign-in not found. Open Cursor to sign in.")
        }
        guard stored.hasPrefix(Self.encryptedPrefix) else { return stored }
        guard let blob = Data(base64Encoded: String(stored.dropFirst(Self.encryptedPrefix.count))) else {
            throw ProviderError.unexpectedResponse("Cursor's stored sign-in isn't in a format Dogwatch knows.")
        }
        var lastError = ProviderError.notSignedIn("“Cursor Safe Storage” is not in your login Keychain. Open Cursor to sign in.")
        for account in Self.keychainAccounts {
            let password: String
            do {
                password = try keychain.password(service: Self.keychainService, account: account)
            } catch let error as ProviderError where error.kind == "notSignedIn" {
                continue
            }
            if let plain = ElectronSafeStorage.decrypt(blob, password: password), let token = String(data: plain, encoding: .utf8) {
                return token
            }
            lastError = .unexpectedResponse("Cursor's stored sign-in could not be decrypted.")
        }
        throw lastError
    }

    /// The cookie cursor.com expects for an app token: `<user id>::<JWT>`, URL-encoded.
    /// Expired tokens stop here, before any request.
    static func sessionCookie(token: String, now: Date) throws -> String {
        let jwt = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expiry = StoredCredential.jwtExpiry(jwt), let subject = jwtSubject(jwt),
              let userID = subject.split(separator: "|").last.map(String.init), !userID.isEmpty,
              userID.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else {
            throw ProviderError.notSignedIn("Cursor's stored sign-in isn't a token Dogwatch can use. Paste a cookie instead.")
        }
        if expiry <= now.addingTimeInterval(StoredCredential.margin) {
            throw ProviderError.expired("Cursor's sign-in has expired. Open Cursor to sign in again.")
        }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(jwt)"
    }

    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONValue(data: data) else { return nil }
        return claims["sub"]?.stringValue
    }

    /// Readings from the summary and the optional weekly pool:
    /// - `weekly`: The X Subscription's weekly pool, when Cursor says the account is unified;
    /// - `included`: legacy plans' included usage this billing cycle, with `auto` and `api` meters;
    /// - `on_demand`: on-demand spend this cycle, against its limit when there is one.
    static func snapshot(summary: JSONValue, pool: JSONValue?, now: Date) throws -> ProviderSnapshot {
        guard summary.objectValue != nil else {
            throw ProviderError.unexpectedResponse("Cursor's usage summary isn't a JSON object.")
        }
        let cycleEnd = DateParsing.date(summary["billingCycleEnd"])
        let cycle = cycleEnd.flatMap { $0 > now ? $0 : nil }
        var readings: [Reading] = []

        let weekly = weeklyPool(pool, now: now)
        if let weekly { readings.append(weekly) }

        let individual = summary["individualUsage"]
        if weekly == nil {
            let plan = individual?["plan"]
            let overall = individual?["overall"]
            if let window = includedWindow(plan, resetsAt: cycle) ?? includedWindow(overall, resetsAt: cycle) {
                readings.append(Reading(id: "included", name: "Included usage", value: .window(window), meterLabel: "Included"))
            }
            for (id, field, label) in [("auto", "autoPercentUsed", "Auto"), ("api", "apiPercentUsed", "API")] {
                guard let percent = plan?[field]?.doubleValue else { continue }
                readings.append(Reading(
                    id: id, name: "\(label) usage",
                    value: .window(QuotaWindow(usedPercent: clampPercent(percent), period: .named("billing cycle"), resetsAt: cycle)),
                    meterLabel: label
                ))
            }
        }

        if let onDemand = individual?["onDemand"], let usedCents = onDemand["used"]?.doubleValue,
           onDemand["enabled"]?.boolValue == true || usedCents > 0 {
            let limit = onDemand["limit"]?.doubleValue.flatMap { $0 > 0 ? $0 / 100 : nil }
            readings.append(Reading(
                id: "on_demand", name: "On-demand",
                value: .spend(Spend(
                    amount: Amount(value: usedCents / 100, unit: .currency("USD")),
                    period: "billing cycle",
                    budget: limit.map { Amount(value: $0, unit: .currency("USD")) },
                    resetsAt: cycle
                ))
            ))
        }

        let primary = weekly != nil ? "weekly" : readings.first { $0.id == "included" }?.id
        return ProviderSnapshot(
            readings: readings,
            plan: planName(summary["membershipType"]?.stringValue),
            note: readings.isEmpty ? "Cursor reported no included usage for this account." : nil,
            primaryHint: primary,
            menuBar: .tightest,
            historyReadingID: primary,
            fetchedAt: now
        )
    }

    /// The weekly pool, only when Cursor marks the account unified, gives a percentage, and the
    /// reset is still ahead.
    private static func weeklyPool(_ pool: JSONValue?, now: Date) -> Reading? {
        guard let pool, pool["isUnified"]?.boolValue == true,
              let percent = pool["usagePercent"]?.doubleValue,
              let reset = DateParsing.date(pool["nextResetTimestampUtc"]), reset > now
        else { return nil }
        let hasLimit = pool["includedLimitZero"]?.boolValue.map { !$0 } ?? pool["hasNonZeroIncludedLimit"]?.boolValue
        guard hasLimit != false else { return nil }
        return Reading(
            id: "weekly", name: "Weekly pool",
            value: .window(QuotaWindow(usedPercent: clampPercent(percent), period: .named("weekly"), resetsAt: reset)),
            meterLabel: "Week"
        )
    }

    /// Included usage from a `{used, limit, totalPercentUsed}` block in cents. nil without a
    /// percentage or a positive limit.
    private static func includedWindow(_ block: JSONValue?, resetsAt: Date?) -> QuotaWindow? {
        guard let block, block.objectValue != nil else { return nil }
        let used = block["used"]?.doubleValue
        let limit = block["limit"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        let percent: Double
        if let total = block["totalPercentUsed"]?.doubleValue {
            percent = total
        } else if let used, let limit {
            percent = used / limit * 100
        } else {
            return nil
        }
        return QuotaWindow(
            usedPercent: clampPercent(percent),
            period: .named("billing cycle"),
            resetsAt: resetsAt,
            used: limit != nil ? used.map { Amount(value: $0 / 100, unit: .currency("USD")) } : nil,
            limit: limit.map { Amount(value: $0 / 100, unit: .currency("USD")) }
        )
    }

    private static func clampPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }

    /// "pro" → "Pro", "unified_premium" → "Premium", "pro_plus" → "Pro Plus".
    static func planName(_ raw: String?) -> String? {
        guard var raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("unified_") { raw = String(raw.dropFirst("unified_".count)) }
        return raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}
