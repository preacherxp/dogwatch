import SwiftUI

// OpenRouter: the reference provider for the "pasted key, balance in a currency" kind.
//
// API reference, read 2026-11-19: https://openrouter.ai/docs/api_reference/limits.md
// `GET https://openrouter.ai/api/v1/key` with `Authorization: Bearer <key>` returns, for the key:
// - `limit`, `limit_remaining`, `limit_reset`: the key's own credit cap in USD (null = no cap);
// - `budgets[]` and `effective_budget`: org budgets and the one that blocks first, each with
//   `limit_usd`, `spend_usd`, `remaining_usd`, `reset_interval` and `resets_at` (ISO 8601 UTC);
// - `usage`, `usage_daily`, `usage_weekly`, `usage_monthly`: spend in USD (UTC windows);
// - `free_model_daily_requests {used, limit, remaining}` and `is_free_tier`.
// The account's total balance (`/api/v1/credits`) needs a management key, so it isn't read.
// The live response has fields the reference doesn't list; unknown fields are ignored.

struct OpenRouterProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "openrouter",
        name: "OpenRouter",
        glyph: ProviderGlyph(symbol: "arrow.triangle.branch"),
        tint: Color(red: 0.55, green: 0.6, blue: 1.0),
        category: .api,
        stability: .documented,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "API key",
            placeholder: "sk-or-v1-…",
            helpURL: URL(string: "https://openrouter.ai/settings/keys"),
            advice: "OpenRouter has no read-only key. A key with a credit limit limits the damage if it leaks."
        )),
        summary: "Key credit limit, budgets and spend",
        reads: "One GET to https://openrouter.ai/api/v1/key, with your key from the Keychain in the Authorization header: the key's credit limit, any budgets on it, and what it spent today and this month.",
        source: "OpenRouter API `GET /api/v1/key`",
        allowedHosts: ["openrouter.ai"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://openrouter.ai/docs/api_reference/limits"),
        timeout: 20
    )

    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No OpenRouter key set. Add one in settings.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.keyURL, headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("OpenRouter rejected the key (HTTP 401). Check it in settings.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// Readings from the `/api/v1/key` answer:
    /// - `budget`: the effective budget (the one that blocks first), as a balance out of its limit;
    /// - `key_limit`: the key's own cap, when it isn't already the effective budget;
    /// - `spend_month` and `spend_today`: spend in USD;
    /// - `free_requests`: free-model requests today, for free-tier accounts.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let data = json["data"]?.objectValue else {
            throw ProviderError.unexpectedResponse("OpenRouter's answer has no \"data\" object.")
        }
        var readings: [Reading] = []
        let effective = data["effective_budget"]?.objectValue
        if let effective, let limit = effective["limit_usd"]?.doubleValue, let remaining = effective["remaining_usd"]?.doubleValue {
            let scope = effective["scope"]?.stringValue ?? "budget"
            readings.append(Reading(
                id: "budget",
                name: scopeName(scope),
                value: .balance(Balance(
                    remaining: Amount(value: remaining, unit: .currency("USD")),
                    total: Amount(value: limit, unit: .currency("USD")),
                    resetsAt: DateParsing.iso8601(effective["resets_at"]?.stringValue)
                )),
                meterLabel: scopeName(scope),
                isBinding: true
            ))
        }
        if effective?["scope"]?.stringValue != "key_limit",
           let limit = data["limit"]?.doubleValue, let remaining = data["limit_remaining"]?.doubleValue {
            readings.append(Reading(
                id: "key_limit",
                name: "Key limit",
                value: .balance(Balance(
                    remaining: Amount(value: remaining, unit: .currency("USD")),
                    total: Amount(value: limit, unit: .currency("USD"))
                )),
                meterLabel: "Key limit"
            ))
        }
        guard let monthly = data["usage_monthly"]?.doubleValue else {
            throw ProviderError.unexpectedResponse("OpenRouter's answer has no usage_monthly.")
        }
        readings.append(Reading(
            id: "spend_month",
            name: "This month",
            value: .spend(Spend(amount: Amount(value: monthly, unit: .currency("USD")), period: "this month"))
        ))
        if let daily = data["usage_daily"]?.doubleValue {
            readings.append(Reading(
                id: "spend_today",
                name: "Today",
                value: .spend(Spend(amount: Amount(value: daily, unit: .currency("USD")), period: "today"))
            ))
        }
        if data["is_free_tier"]?.boolValue == true, let free = data["free_model_daily_requests"]?.objectValue,
           let used = free["used"]?.doubleValue, let limit = free["limit"]?.doubleValue, limit > 0 {
            readings.append(Reading(
                id: "free_requests",
                name: "Free requests today",
                value: .window(QuotaWindow(
                    usedPercent: Int((used / limit * 100).rounded()),
                    period: .named("today"),
                    resetsAt: Calendar.utc.nextMidnight(after: now),
                    used: Amount(value: used, unit: .requests),
                    limit: Amount(value: limit, unit: .requests)
                )),
                meterLabel: "Free today"
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            label: readings.first?.id == "spend_month" ? "No credit limit" : nil,
            primaryHint: readings.first { $0.id == "budget" || $0.id == "key_limit" }?.id ?? "spend_month",
            historyReadingID: readings.first { $0.id == "budget" || $0.id == "key_limit" }?.id ?? "spend_month",
            fetchedAt: now
        )
    }

    private static func scopeName(_ scope: String) -> String {
        switch scope {
        case "key_limit", "api_key": return "Key limit"
        case "workspace": return "Workspace budget"
        case "member", "workspace_default_member": return "Member budget"
        case "workspace_default_key": return "Key budget"
        default: return "Budget"
        }
    }
}

extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func nextMidnight(after date: Date) -> Date? {
        self.date(byAdding: .day, value: 1, to: startOfDay(for: date))
    }
}
