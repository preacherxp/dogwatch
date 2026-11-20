import SwiftUI

// DeepInfra: spend this month, the tightest per-key monthly limit, and the account spending limit.
// No prepaid balance is exposed, so the main figure is spend.
//
// API reference, read 2026-11-19 (all `GET https://api.deepinfra.com/…`, `Authorization: Bearer <key>`,
// keys need the `billing:read` scope):
// - https://docs.deepinfra.com/api-reference/billing/usage.md
//   `/payment/usage?from=current` → `{months: [{period: "YYYY.MM", interval: {fr, to}, items: [...],
//   total_cost, invoice_id}]}`. `total_cost` is an integer in **cents**; `from` and the interval are UTC.
// - https://docs.deepinfra.com/api-reference/billing/get-key-limits.md
//   `/payment/key-limits` → `[{token_id, name, limit, spend}]`: monthly limit and spend this month in
//   **USD**, either null when not set or not yet computed. Key names are never shown.
// - https://docs.deepinfra.com/api-reference/billing/get-config.md
//   `/payment/config` → `{limit}`: the account spending limit in **USD**, negative for none. Its
//   period isn't stated, so it is shown as a note rather than a budget for this month's spend.
// - https://docs.deepinfra.com/account/authentication.md: the `billing:read` scope reads usage, invoices,
//   key spending limits and request costs, and nothing else.
// DeepInfra documents no delay for usage and no rate limit for these endpoints.

struct DeepInfraProvider: UsageProvider {
    static let freshness = "DeepInfra doesn't say how soon usage appears"

    let descriptor = ProviderDescriptor(
        id: "deepinfra",
        name: "DeepInfra",
        glyph: ProviderGlyph(symbol: "cpu"),
        tint: Color(red: 0.3, green: 0.7, blue: 0.85),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "API key",
            placeholder: "",
            helpURL: URL(string: "https://deepinfra.com/dash/keys"),
            advice: "Create a key with only the billing:read scope: it reads usage and limits and can't run models. An unrestricted key works too but can do much more."
        )),
        summary: "Spend this month, key limits and account limit",
        reads: "GETs to https://api.deepinfra.com/payment/usage (this month's spend), /payment/key-limits (each key's monthly limit and spend) and /payment/config (the account spending limit), with your key from the Keychain in the Authorization header. Key names are not shown.",
        source: "DeepInfra API `GET /payment/usage`, `/payment/key-limits`, `/payment/config`",
        allowedHosts: ["api.deepinfra.com"],
        minimumRefreshInterval: 300,
        defaultRefreshInterval: 900,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://docs.deepinfra.com/api-reference/billing/usage"),
        timeout: 30
    )

    static let usageURL = URL(string: "https://api.deepinfra.com/payment/usage?from=current")!
    static let keyLimitsURL = URL(string: "https://api.deepinfra.com/payment/key-limits")!
    static let configURL = URL(string: "https://api.deepinfra.com/payment/config")!

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No DeepInfra key set. Add one in settings.")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        let usage: JSONValue
        do {
            usage = try await context.http.getJSON(Self.usageURL, headers: headers)
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("DeepInfra rejected the key (HTTP 401). Check it in settings.")
        } catch ProviderError.expired {
            throw ProviderError.expired("DeepInfra refused the usage report (HTTP 403). The key needs the billing:read scope.")
        }
        // The other two are extras: if either fails, the spend still shows.
        // `/payment/key-limits` answers with a top-level array, which `getJSON` parses as well.
        let keyLimits = try? await context.http.getJSON(Self.keyLimitsURL, headers: headers)
        try Task.checkCancellation()
        let config = try? await context.http.getJSON(Self.configURL, headers: headers)
        try Task.checkCancellation()
        return try Self.snapshot(usage: usage, keyLimits: keyLimits, config: config, now: context.now())
    }

    static func snapshot(usage: JSONValue, keyLimits: JSONValue?, config: JSONValue?, now: Date) throws -> ProviderSnapshot {
        guard let months = usage["months"]?.arrayValue else {
            throw ProviderError.unexpectedResponse("DeepInfra's usage answer has no \"months\" list.")
        }
        let thisMonth = SpendPeriod.yearMonth(now, separator: ".")
        // `from=current` returns one month; pick it by period so another month is never shown as this one.
        let entry = months.first { $0["period"]?.stringValue == thisMonth } ?? (months.count == 1 ? months[0] : nil)
        var readings: [Reading] = []
        if let entry {
            guard let dollars = Money.fromCents(entry["total_cost"]) else {
                throw ProviderError.unexpectedResponse("DeepInfra's usage answer has no total_cost.")
            }
            let period = entry["period"]?.stringValue ?? thisMonth
            let isThisMonth = period == thisMonth
            readings.append(Reading.spendReading(
                id: "spend_month", name: isThisMonth ? "This month" : "Month \(period)",
                amount: Amount(value: dollars, unit: .currency("USD")),
                period: isThisMonth ? "this month (UTC)" : "\(period) (UTC)",
                resetsAt: isThisMonth ? SpendPeriod.month(containing: now).end : nil,
                freshness: freshness
            ))
        } else if months.isEmpty {
            readings.append(Reading.spendReading(
                id: "spend_month", name: "This month", amount: Amount(value: 0, unit: .currency("USD")),
                period: "this month (UTC)", resetsAt: SpendPeriod.month(containing: now).end, freshness: freshness
            ))
        } else {
            throw ProviderError.unexpectedResponse("DeepInfra's usage answer has no entry for \(thisMonth).")
        }
        if let tightest = tightestKeyLimit(keyLimits) {
            readings.append(Reading(
                id: "key_limit",
                name: "Tightest key limit",
                value: .balance(Balance(
                    remaining: Amount(value: tightest.limit - tightest.spend, unit: .currency("USD")),
                    total: Amount(value: tightest.limit, unit: .currency("USD"))
                )),
                meterLabel: "Key limit"
            ))
        }
        var note: String?
        if let limit = config?["limit"]?.doubleValue, limit >= 0 {
            note = "Account spending limit \(UsageFormatters.amount(Amount(value: limit, unit: .currency("USD"))))."
        }
        return ProviderSnapshot(readings: readings, note: note, primaryHint: "spend_month", historyReadingID: "spend_month", fetchedAt: now)
    }

    /// The key with the smallest share of its monthly limit left, among keys with both a limit and a
    /// computed spend. Names are dropped: only the numbers are kept.
    static func tightestKeyLimit(_ json: JSONValue?) -> (limit: Double, spend: Double)? {
        let keys = json?.arrayValue ?? []
        let limited: [(limit: Double, spend: Double)] = keys.compactMap { key in
            guard let limit = key["limit"]?.doubleValue, limit > 0, let spend = key["spend"]?.doubleValue else { return nil }
            return (limit, spend)
        }
        return limited.min { ($0.limit - $0.spend) / $0.limit < ($1.limit - $1.spend) / $1.limit }
    }
}
