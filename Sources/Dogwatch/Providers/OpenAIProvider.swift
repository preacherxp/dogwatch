import SwiftUI

// OpenAI API: the organisation's spend from the Costs report, read with an Admin API key.
// There is no prepaid balance or credit endpoint, so this shows spend, not what is left.
//
// API reference, read 2026-11-19:
// - https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs.md
//   `GET https://api.openai.com/v1/organization/costs?start_time=<unix>&bucket_width=1d&limit=<1-180>`
//   with optional `project_ids[]`; answers `{data: [{start_time, end_time, results: [{amount: {value, currency}}]}],
//   has_more, next_page}`. `value` is a number in whole units of `currency` (lowercase ISO, "usd").
//   Buckets are UTC days in Unix seconds; `page=<next_page>` continues.
// - https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/spend_limit.md
//   `GET /v1/organization/spend_limit`: `threshold_amount` in cents, `interval: "month"`,
//   `enforcement.status`. Its answer also lists notification email recipients; they are never read.
//   OpenAI doesn't state which time zone its monthly cycle uses, so the limit is shown as a note,
//   not turned into a percentage against the UTC calendar month.
// - https://developers.openai.com/api/docs/guides/admin-apis.md: admin keys have no read-only variant.
// OpenAI publishes no delay for the costs report and no rate limit for admin endpoints.

struct OpenAIProvider: UsageProvider {
    static let freshness = "Daily UTC buckets; OpenAI doesn't say how soon costs appear"

    let descriptor = ProviderDescriptor(
        id: "openai",
        name: "OpenAI API",
        glyph: ProviderGlyph(symbol: "dollarsign.circle"),
        tint: Color(red: 0.45, green: 0.75, blue: 0.65),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .adminKey,
            label: "Admin key",
            placeholder: "sk-admin-…",
            helpURL: URL(string: "https://platform.openai.com/settings/organization/admin-keys"),
            warning: "An OpenAI Admin key can manage the whole organization: invite and remove members, create and revoke API keys, change projects and spend limits. Dogwatch only reads costs and the spend limit with it.",
            advice: "OpenAI has no read-only Admin key. Create one only for Dogwatch, with an expiry, and revoke it when you stop using it."
        )),
        summary: "Organization spend this month and today",
        reads: "GETs to https://api.openai.com/v1/organization/costs (this month's daily cost buckets, optionally for one project) and /v1/organization/spend_limit (the organization's monthly hard limit), with your Admin key from the Keychain in the Authorization header.",
        source: "OpenAI Admin API `GET /v1/organization/costs`",
        allowedHosts: ["api.openai.com"],
        minimumRefreshInterval: 900,
        defaultRefreshInterval: 1_800,
        idleLabel: "Add an Admin key",
        documentation: URL(string: "https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs"),
        timeout: 40,
        fields: [SettingField(
            id: "project_id",
            label: "Project id",
            placeholder: "proj_…",
            help: "Only count this project's costs. Leave empty for the whole organization.",
            isRequired: false
        )]
    )

    static let costsURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    static let spendLimitURL = URL(string: "https://api.openai.com/v1/organization/spend_limit")!
    static let maxPages = 5

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No OpenAI Admin key set. Add one in settings.")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        let now = context.now()
        let project = context.settings.value("project_id")
        let report: PagedReport
        do {
            report = try await PagedReport.collect(
                first: Self.firstURL(now: now, project: project),
                maxPages: Self.maxPages,
                fetch: { try await context.http.getJSON($0, headers: headers) },
                next: { page in
                    guard page["has_more"]?.boolValue == true, let cursor = page["next_page"]?.stringValue else { return nil }
                    return PagedReport.url(Self.firstURL(now: now, project: project), setting: "page", to: cursor)
                }
            )
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("OpenAI rejected the key (HTTP 401). The costs report needs an Admin key, not a project key.")
        } catch ProviderError.expired {
            throw ProviderError.expired("OpenAI refused the costs report (HTTP 403). It needs an Admin key from an organization owner.")
        }
        var limit: JSONValue?
        if project == nil {
            // Optional: the org-wide limit. Any failure (none set, no permission) just leaves it out.
            limit = try? await context.http.getJSON(Self.spendLimitURL, headers: headers)
            try Task.checkCancellation()
        }
        return try Self.snapshot(from: report, spendLimit: limit, project: project, now: now)
    }

    static func firstURL(now: Date, project: String?) -> URL {
        var components = URLComponents(url: costsURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "start_time", value: SpendPeriod.unix(SpendPeriod.month(containing: now).start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        if let project { items.append(URLQueryItem(name: "project_ids[]", value: project)) }
        components.queryItems = items
        return components.url!
    }

    /// Sums every result in every bucket of this UTC month into `spend_month`, and today's UTC
    /// bucket into `spend_today`. Buckets outside the month (there should be none) are ignored.
    static func snapshot(from report: PagedReport, spendLimit: JSONValue?, project: String?, now: Date) throws -> ProviderSnapshot {
        let month = SpendPeriod.month(containing: now)
        let today = SpendPeriod.day(containing: now)
        var monthTotal = MoneyTotal()
        var todayTotal = MoneyTotal()
        var sawToday = false
        for page in report.pages {
            guard let buckets = page["data"]?.arrayValue else {
                throw ProviderError.unexpectedResponse("OpenAI's costs answer has no \"data\" list.")
            }
            for bucket in buckets {
                guard let startSeconds = bucket["start_time"]?.doubleValue else {
                    throw ProviderError.unexpectedResponse("An OpenAI cost bucket has no start_time.")
                }
                let start = Date(timeIntervalSince1970: startSeconds)
                guard month.contains(start), start < month.end else { continue }
                let isToday = start == today.start
                if isToday { sawToday = true }
                for result in bucket["results"]?.arrayValue ?? [] {
                    guard let amount = result["amount"], !amount.isNull else { continue }
                    guard let value = amount["value"]?.doubleValue else {
                        throw ProviderError.unexpectedResponse("An OpenAI cost result has no amount.value.")
                    }
                    let currency = amount["currency"]?.stringValue
                    try monthTotal.add(value, currency: currency, provider: "OpenAI")
                    if isToday { try todayTotal.add(value, currency: currency, provider: "OpenAI") }
                }
            }
        }
        let currency = monthTotal.currency ?? "USD"
        var readings = [Reading.spendReading(
            id: "spend_month", name: project == nil ? "This month" : "Project this month",
            amount: monthTotal.amount(fallback: currency), period: "this month (UTC)",
            resetsAt: month.end, freshness: freshness, truncated: report.truncated
        )]
        if sawToday {
            readings.append(Reading.spendReading(
                id: "spend_today", name: "Today",
                amount: todayTotal.amount(fallback: currency), period: "today (UTC)",
                resetsAt: today.end, freshness: freshness, truncated: report.truncated
            ))
        }
        var notes: [String] = []
        if report.truncated { notes.append("OpenAI's report had more than \(maxPages) pages; the total shown is incomplete.") }
        if let line = limitNote(spendLimit) { notes.append(line) }
        return ProviderSnapshot(
            readings: readings,
            label: project == nil ? "Organization" : "One project",
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            primaryHint: "spend_month",
            historyReadingID: "spend_month",
            fetchedAt: now
        )
    }

    /// "Organization hard limit $100.00 a month (enforcing)", from `threshold_amount` in cents.
    static func limitNote(_ json: JSONValue?) -> String? {
        guard let json, json["object"]?.stringValue == "organization.spend_limit",
              let dollars = Money.fromCents(json["threshold_amount"]) else { return nil }
        let currency = json["currency"]?.stringValue?.uppercased() ?? "USD"
        let interval = json["interval"]?.stringValue == "month" ? " a month" : ""
        let status = json.value(at: "enforcement.status")?.stringValue.map { " (\($0))" } ?? ""
        return "Organization hard limit \(UsageFormatters.amount(Amount(value: dollars, unit: .currency(currency))))\(interval)\(status)."
    }
}
