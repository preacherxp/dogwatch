import SwiftUI

// Anthropic API: the organisation's spend from the Admin API cost report. This is the pay-as-you-go
// Claude API account; the Claude Code subscription is the separate `claude` provider.
// There is no prepaid balance endpoint, so this shows spend, not what is left.
//
// API reference, read 2026-11-19:
// - https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve.md
//   `GET https://api.anthropic.com/v1/organizations/cost_report?starting_at=<RFC 3339>&bucket_width=1d&limit=<1-31>`,
//   headers `x-api-key: <Admin API key>` and `anthropic-version`. Answers
//   `{data: [{starting_at, ending_at, results: [{amount, currency, ...}]}], has_more, next_page}`, buckets
//   snapped to UTC days, one per day including days with no cost. `amount` is a decimal string in the
//   currency's lowest unit (cents): "123.45" in USD is $1.2345. `page=<next_page>` continues.
// - https://platform.claude.com/docs/en/manage-claude/usage-cost-api.md: this is the legacy Usage and Cost
//   API and "remains supported"; data typically appears within 5 minutes; polling once a minute is
//   supported; Priority Tier costs are not included. The newer analytics endpoint is in beta and
//   refreshes only every few hours, so the legacy report is used.
// - https://platform.claude.com/docs/en/manage-claude/admin-api-keys.md: Admin API keys; organizations only,
//   not individual Console accounts or claude.ai Team plans.

struct AnthropicAPIProvider: UsageProvider {
    static let freshness = "Daily UTC buckets, usually within 5 minutes; Priority Tier costs aren't included"
    static let apiVersion = "2026-10-21"

    let descriptor = ProviderDescriptor(
        id: "anthropic-api",
        name: "Anthropic API",
        glyph: ProviderGlyph(symbol: "dollarsign.square"),
        tint: Color(red: 0.85, green: 0.55, blue: 0.4),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .adminKey,
            label: "Admin API key",
            placeholder: "sk-ant-admin01-…",
            helpURL: URL(string: "https://platform.claude.com/settings/admin-keys"),
            warning: "An Anthropic Admin API key can manage your whole organization: members, invites, workspaces and API keys. Dogwatch only reads the cost report with it.",
            advice: "Anthropic has no read-only Admin API key for Console organizations. Create one only for Dogwatch with an expiration date."
        )),
        summary: "Organization spend this month and today",
        reads: "GETs to https://api.anthropic.com/v1/organizations/cost_report for this month's daily costs, with your Admin API key from the Keychain in the x-api-key header.",
        source: "Anthropic Admin API `GET /v1/organizations/cost_report`",
        allowedHosts: ["api.anthropic.com"],
        minimumRefreshInterval: 300,
        defaultRefreshInterval: 600,
        idleLabel: "Add an Admin API key",
        documentation: URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api"),
        timeout: 40
    )

    static let reportURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    static let maxPages = 5

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Anthropic Admin API key set. Add one in settings.")
        }
        let headers = ["x-api-key": key, "anthropic-version": Self.apiVersion]
        let now = context.now()
        let first = Self.firstURL(now: now)
        let report: PagedReport
        do {
            report = try await PagedReport.collect(
                first: first,
                maxPages: Self.maxPages,
                fetch: { try await context.http.getJSON($0, headers: headers) },
                next: { page in
                    guard page["has_more"]?.boolValue == true, let cursor = page["next_page"]?.stringValue else { return nil }
                    return PagedReport.url(first, setting: "page", to: cursor)
                }
            )
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Anthropic rejected the key (HTTP 401). The cost report needs an Admin API key, not a workspace key.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Anthropic refused the cost report (HTTP 403). It needs an Admin API key from an organization admin.")
        }
        return try Self.snapshot(from: report, now: now)
    }

    static func firstURL(now: Date) -> URL {
        var components = URLComponents(url: reportURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: SpendPeriod.iso(SpendPeriod.month(containing: now).start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        return components.url!
    }

    /// Sums every result of every bucket in this UTC month (cents → dollars) into `spend_month`,
    /// and today's UTC bucket into `spend_today`.
    static func snapshot(from report: PagedReport, now: Date) throws -> ProviderSnapshot {
        let month = SpendPeriod.month(containing: now)
        let today = SpendPeriod.day(containing: now)
        var monthTotal = MoneyTotal()
        var todayTotal = MoneyTotal()
        var sawToday = false
        for page in report.pages {
            guard let buckets = page["data"]?.arrayValue else {
                throw ProviderError.unexpectedResponse("Anthropic's cost report has no \"data\" list.")
            }
            for bucket in buckets {
                guard let start = DateParsing.iso8601(bucket["starting_at"]?.stringValue) else {
                    throw ProviderError.unexpectedResponse("An Anthropic cost bucket has no starting_at.")
                }
                guard start >= month.start, start < month.end else { continue }
                let isToday = start == today.start
                if isToday { sawToday = true }
                for result in bucket["results"]?.arrayValue ?? [] {
                    guard let dollars = Money.fromCents(result["amount"]) else {
                        throw ProviderError.unexpectedResponse("An Anthropic cost result has no amount.")
                    }
                    let currency = result["currency"]?.stringValue
                    try monthTotal.add(dollars, currency: currency, provider: "Anthropic")
                    if isToday { try todayTotal.add(dollars, currency: currency, provider: "Anthropic") }
                }
            }
        }
        let currency = monthTotal.currency ?? "USD"
        var readings = [Reading.spendReading(
            id: "spend_month", name: "This month", amount: monthTotal.amount(fallback: currency),
            period: "this month (UTC)", resetsAt: month.end, freshness: freshness, truncated: report.truncated
        )]
        if sawToday {
            readings.append(Reading.spendReading(
                id: "spend_today", name: "Today", amount: todayTotal.amount(fallback: currency),
                period: "today (UTC)", resetsAt: today.end, freshness: freshness, truncated: report.truncated
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            note: report.truncated ? "Anthropic's report had more than \(maxPages) pages; the total shown is incomplete." : nil,
            primaryHint: "spend_month",
            historyReadingID: "spend_month",
            fetchedAt: now
        )
    }
}
