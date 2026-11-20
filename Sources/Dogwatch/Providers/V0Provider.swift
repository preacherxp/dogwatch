import SwiftUI

// v0 (Vercel): the account's credit balance, with a pasted v0 Platform API key.
//
// API reference, read 2026-11-19:
// - https://v0.app/docs/api/v1/reference/user/get-billing
// - https://v0.app/docs/api/v1/reference/rate-limits/find
// - https://v0.app/docs/pricing (credits, rollover, daily login credits)
// `GET https://api.v0.dev/v1/user/billing` with `Authorization: Bearer <key>` answers one of two
// shapes. The documentation page lists only the legacy one; v0's own SDK (`v0-sdk` 0.16.7,
// `UserGetBillingResponse`) declares both:
// - `billingType: "token"`: `data.plan`, `data.billingCycle {start, end}`,
//   `data.balance {remaining, total}`, `data.onDemand {balance, blocks[]}`;
// - `billingType: "legacy"`: `data {limit, remaining?, reset?}`.
// Neither page states the unit of these amounts. v0 prices its credits in dollars, but the API
// doesn't say so, so they are shown as credits, not converted to a currency.
// `GET https://api.v0.dev/v1/rate-limits` adds `dailyLimit {limit, remaining, reset (Unix ms),
// isWithinGracePeriod}`: the daily message limit of free accounts. Its top-level
// `limit/remaining/reset` are an API request rate limit, not an allowance, and are not shown.

struct V0Provider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "v0",
        name: "v0",
        glyph: ProviderGlyph(symbol: "square.on.square"),
        tint: Color(red: 0.85, green: 0.85, blue: 0.88),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "v0 API key",
            placeholder: "Paste your v0 API key",
            helpURL: URL(string: "https://v0.app/settings/keys"),
            warning: "A v0 API key can create chats and projects and spend your v0 credits, not only read usage.",
            advice: "v0 has no read-only key. Create one just for Dogwatch so you can revoke it on its own."
        )),
        summary: "Credit balance, on-demand credits and the free daily message limit",
        reads: "Two GETs with your key from the Keychain in the Authorization header: https://api.v0.dev/v1/user/billing for your credit balance and billing cycle, and https://api.v0.dev/v1/rate-limits for the daily message limit of free accounts. A scope you enter in settings is sent as the scope query parameter.",
        source: "v0 Platform API `GET /v1/user/billing`, `GET /v1/rate-limits`",
        allowedHosts: ["api.v0.dev"],
        minimumRefreshInterval: 120,
        defaultRefreshInterval: 900,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://v0.app/docs/api/v1/reference/user/get-billing"),
        timeout: 20,
        fields: [SettingField(
            id: "scope", label: "Scope", placeholder: "project id or slug",
            help: "Optional. Limits the billing data to a project or team scope, as v0's API defines it.",
            isRequired: false
        )]
    )

    static let billingURL = "https://api.v0.dev/v1/user/billing"
    static let rateLimitsURL = "https://api.v0.dev/v1/rate-limits"

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No v0 API key set. Add one in settings.")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        let scope = context.settings.value("scope")
        let billing: JSONValue
        do {
            billing = try await context.http.getJSON(Self.url(Self.billingURL, scope: scope), headers: headers)
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("v0 rejected the key (HTTP 401). Check it in settings.")
        }
        // The daily limit is extra information for free accounts; the balance stands without it.
        var rateLimits: JSONValue?
        do {
            rateLimits = try await context.http.getJSON(Self.url(Self.rateLimitsURL, scope: scope), headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            rateLimits = nil
        }
        return try Self.snapshot(billing: billing, rateLimits: rateLimits, now: context.now())
    }

    private static func url(_ base: String, scope: String?) -> URL {
        var components = URLComponents(string: base)!
        if let scope { components.queryItems = [URLQueryItem(name: "scope", value: scope)] }
        return components.url!
    }

    /// Readings:
    /// - `credits`: the plan's credit balance out of the cycle's total (token billing), resetting
    ///   at the end of the billing cycle; or the legacy allowance out of its limit;
    /// - `on_demand`: purchased on-demand credits, an amount with no total;
    /// - `daily_messages`: the free daily message limit, when v0 reports one.
    static func snapshot(billing: JSONValue, rateLimits: JSONValue?, now: Date) throws -> ProviderSnapshot {
        guard let data = billing["data"]?.objectValue else {
            throw ProviderError.unexpectedResponse("v0's billing answer has no \"data\" object.")
        }
        var readings: [Reading] = []
        var plan: String?
        let type = billing["billingType"]?.stringValue
        switch type {
        case "token":
            plan = data["plan"]?.stringValue
            guard let balance = data["balance"]?.objectValue,
                  let remaining = balance["remaining"]?.doubleValue else {
                throw ProviderError.unexpectedResponse("v0's billing answer has no data.balance.remaining.")
            }
            let total = balance["total"]?.doubleValue.flatMap { $0 > 0 ? Amount(value: $0, unit: .credits) : nil }
            readings.append(Reading(
                id: "credits",
                name: "Credits",
                value: .balance(Balance(
                    remaining: Amount(value: remaining, unit: .credits),
                    total: total,
                    resetsAt: DateParsing.epoch(data["billingCycle"]?["end"]?.doubleValue)
                )),
                meterLabel: "Credits"
            ))
            if let onDemand = data["onDemand"]?["balance"]?.doubleValue {
                readings.append(Reading(
                    id: "on_demand",
                    name: "On-demand credits",
                    value: .balance(Balance(remaining: Amount(value: onDemand, unit: .credits)))
                ))
            }
        case "legacy", nil:
            guard let limit = data["limit"]?.doubleValue else {
                throw ProviderError.unexpectedResponse("v0's billing answer has no data.limit.")
            }
            if let remaining = data["remaining"]?.doubleValue {
                readings.append(Reading(
                    id: "credits",
                    name: "Allowance",
                    value: .balance(Balance(
                        remaining: Amount(value: remaining, unit: .credits),
                        total: limit > 0 ? Amount(value: limit, unit: .credits) : nil,
                        resetsAt: DateParsing.epoch(data["reset"]?.doubleValue)
                    )),
                    meterLabel: "Allowance"
                ))
            }
        default:
            throw ProviderError.unexpectedResponse("v0 answered with an unknown billing type.")
        }

        if let daily = rateLimits?["dailyLimit"]?.objectValue,
           let limit = daily["limit"]?.doubleValue, limit > 0,
           let left = daily["remaining"]?.doubleValue {
            let used = max(0, limit - left)
            let grace = daily["isWithinGracePeriod"]?.boolValue == true
            readings.append(Reading(
                id: "daily_messages",
                name: "Daily messages",
                value: .window(QuotaWindow(
                    usedPercent: max(0, min(100, Int((used / limit * 100).rounded()))),
                    period: .named("daily"),
                    resetsAt: DateParsing.epoch(daily["reset"]?.doubleValue),
                    used: Amount(value: used, unit: .custom("messages")),
                    limit: Amount(value: limit, unit: .custom("messages"))
                )),
                meterLabel: "Today",
                detail: grace ? "New-account grace period · messages aren't counted yet" : nil
            ))
        }

        return ProviderSnapshot(
            readings: readings,
            plan: plan.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            note: readings.isEmpty ? "v0 reported no balance for this key." : nil,
            primaryHint: readings.contains { $0.id == "credits" } ? "credits" : nil,
            historyReadingID: readings.contains { $0.id == "credits" } ? "credits" : nil,
            fetchedAt: now
        )
    }
}
