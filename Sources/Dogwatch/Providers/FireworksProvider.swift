import SwiftUI

// Fireworks AI: the account's rated spend this month from the billing summary. The credit balance
// isn't exposed by the API, so this shows spend.
//
// API reference, read 2026-11-19:
// - https://docs.fireworks.ai/api-reference/get-billing-summary.md
//   `GET https://api.fireworks.ai/v1/accounts/{account_id}/billing/summary?startTime=<RFC 3339>&endTime=<RFC 3339>&granularity=DAILY`,
//   bearer key. Only the date part of each time counts; `endTime` is exclusive. Answers
//   `{lineItems: [{totalCost: {currencyCode, units, nanos}}], usageBuckets: [{startTime, endTime, lineItems}]}`
//   where money is `units` (whole units, int64 as a string) plus `nanos` (10^-9 units). No paging.
// - https://docs.fireworks.ai/accounts/exporting-usage-and-costs.md: "Any key on the target account works";
//   rated costs can lag live traffic by a day or more and may differ from the invoice once credits or
//   adjustments are applied. Usage days default to UTC; the dates sent here are UTC dates.

struct FireworksProvider: UsageProvider {
    static let freshness = "Rated costs before credits; can lag live traffic by a day or more"

    let descriptor = ProviderDescriptor(
        id: "fireworks",
        name: "Fireworks AI",
        glyph: ProviderGlyph(symbol: "flame"),
        tint: Color(red: 0.6, green: 0.4, blue: 0.95),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "API key",
            placeholder: "",
            helpURL: URL(string: "https://app.fireworks.ai/settings/users/api-keys"),
            advice: "Fireworks has no read-only key; any key on the account can read its billing summary."
        )),
        summary: "Account spend this month and today",
        reads: "One GET to https://api.fireworks.ai/v1/accounts/<account id>/billing/summary for this month's rated costs by day, with your key from the Keychain in the Authorization header.",
        source: "Fireworks API `GET /v1/accounts/{id}/billing/summary`",
        allowedHosts: ["api.fireworks.ai"],
        minimumRefreshInterval: 1_800,
        defaultRefreshInterval: 3_600,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://docs.fireworks.ai/api-reference/get-billing-summary"),
        timeout: 30,
        fields: [SettingField(
            id: "account_id",
            label: "Account id",
            placeholder: "my-account",
            help: "Your Fireworks account id, as in the console's URLs and API paths."
        )]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        guard context.settings.value("account_id") != nil else { return .unavailable("No account id set") }
        return keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Fireworks API key set. Add one in settings.")
        }
        let account = try PathIdentifier.validated(context.settings.value("account_id"), field: "account id", provider: "Fireworks")
        let now = context.now()
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.summaryURL(account: account, now: now), headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Fireworks rejected the key (HTTP 401). Check it in settings.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Fireworks refused access (HTTP 403). Check that the key belongs to this account id.")
        } catch ProviderError.notFound {
            throw ProviderError.notConfigured("Fireworks doesn't know this account id (HTTP 404). Check it in settings.")
        }
        return try Self.snapshot(from: json, now: now)
    }

    /// This UTC month's first day through today, inclusive: `endTime` is tomorrow's date (exclusive).
    static func summaryURL(account: String, now: Date) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.fireworks.ai"
        components.path = "/v1/accounts/\(account)/billing/summary"
        components.queryItems = [
            URLQueryItem(name: "startTime", value: SpendPeriod.iso(SpendPeriod.month(containing: now).start)),
            URLQueryItem(name: "endTime", value: SpendPeriod.iso(SpendPeriod.day(containing: now).end)),
            URLQueryItem(name: "granularity", value: "DAILY"),
        ]
        return components.url!
    }

    /// `spend_month` is the sum of the top-level line items (or, if Fireworks sent only buckets, of
    /// every bucket); `spend_today` is today's UTC bucket when there is one.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        let month = SpendPeriod.month(containing: now)
        let today = SpendPeriod.day(containing: now)
        guard json.objectValue != nil else {
            throw ProviderError.unexpectedResponse("Fireworks' billing summary isn't an object.")
        }
        let buckets = json["usageBuckets"]?.arrayValue ?? []
        var monthTotal = MoneyTotal()
        if let items = json["lineItems"]?.arrayValue {
            try add(items, to: &monthTotal)
        } else if json["usageBuckets"] != nil {
            for bucket in buckets { try add(bucket["lineItems"]?.arrayValue ?? [], to: &monthTotal) }
        } else if json.objectValue?.isEmpty == false {
            throw ProviderError.unexpectedResponse("Fireworks' billing summary has no lineItems.")
        }
        // An empty object is a month with no billable usage yet.
        var readings = [Reading.spendReading(
            id: "spend_month", name: "This month", amount: monthTotal.amount(),
            period: "this month (UTC)", resetsAt: month.end, freshness: freshness
        )]
        if let bucket = buckets.first(where: { DateParsing.iso8601($0["startTime"]?.stringValue) == today.start }) {
            var todayTotal = MoneyTotal(currency: monthTotal.currency)
            try add(bucket["lineItems"]?.arrayValue ?? [], to: &todayTotal)
            readings.append(Reading.spendReading(
                id: "spend_today", name: "Today", amount: todayTotal.amount(fallback: monthTotal.currency ?? "USD"),
                period: "today (UTC)", resetsAt: today.end, freshness: freshness
            ))
        }
        return ProviderSnapshot(readings: readings, primaryHint: "spend_month", historyReadingID: "spend_month", fetchedAt: now)
    }

    private static func add(_ items: [JSONValue], to total: inout MoneyTotal) throws {
        for item in items {
            guard let cost = item["totalCost"], !cost.isNull else { continue }
            guard let value = Money.fromUnitsAndNanos(cost) else {
                throw ProviderError.unexpectedResponse("A Fireworks line item's totalCost has no units or nanos.")
            }
            try total.add(value, currency: cost["currencyCode"]?.stringValue, provider: "Fireworks")
        }
    }
}
