import SwiftUI

// Together AI: the organisation's spend this month from the billing usage report. There is no
// balance endpoint (the balance is only in the dashboard), so this shows spend.
//
// API reference, read 2026-11-19: https://docs.together.ai/reference/billing-usage.md
// `GET https://api.together.ai/v1/billing/usage?month=YYYY-MM&granularity=hour&limit=<1-1000>`, bearer key.
// Answers `{billing_period, currency: "USD", data: [{date, start_time, end_time, line_items: [{cost, ...}]}],
// next_cursor}`; `cost` is USD as a decimal string; windows and `date` are UTC; `after=<next_cursor>`
// continues. Finalised windows run through the last completed hour (hourly granularity); this
// month's data can be up to 1 hour behind. The endpoint is in beta and enabled per organisation:
// others get 404. It reports the key's whole organisation, whichever project the key belongs to.
// Hourly windows are used so today's completed hours are included; a 31-day month is 744 windows,
// one page at limit=1000.

struct TogetherProvider: UsageProvider {
    static let freshness = "Through the last completed hour (UTC); up to an hour behind"

    let descriptor = ProviderDescriptor(
        id: "together",
        name: "Together AI",
        glyph: ProviderGlyph(symbol: "square.stack.3d.up"),
        tint: Color(red: 0.35, green: 0.55, blue: 0.95),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "API key",
            placeholder: "",
            helpURL: URL(string: "https://api.together.ai/settings/projects/~current/api-keys"),
            advice: "Together has no read-only key, and any project's key reads the whole organization's usage. A key from a project with a low spend limit limits the damage if it leaks."
        )),
        summary: "Organization spend this month and today",
        reads: "GETs to https://api.together.ai/v1/billing/usage for this month's hourly usage line items, with your key from the Keychain in the Authorization header. Together reports the key's whole organization.",
        source: "Together API `GET /v1/billing/usage` (beta)",
        allowedHosts: ["api.together.ai"],
        minimumRefreshInterval: 900,
        defaultRefreshInterval: 1_800,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://docs.together.ai/reference/billing-usage"),
        timeout: 40
    )

    static let usageURL = URL(string: "https://api.together.ai/v1/billing/usage")!
    static let maxPages = 5

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Together API key set. Add one in settings.")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        let now = context.now()
        let first = Self.firstURL(now: now)
        let report: PagedReport
        do {
            report = try await PagedReport.collect(
                first: first,
                maxPages: Self.maxPages,
                fetch: { try await context.http.getJSON($0, headers: headers) },
                next: { page in
                    guard let cursor = page["next_cursor"]?.stringValue, !cursor.isEmpty else { return nil }
                    return PagedReport.url(first, setting: "after", to: cursor)
                }
            )
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Together rejected the key (HTTP 401). Check it in settings.")
        } catch ProviderError.notFound {
            throw ProviderError.unexpectedResponse("Together's billing usage report isn't enabled for this organization yet (it's in beta). Together support can turn it on.")
        }
        return try Self.snapshot(from: report, now: now)
    }

    static func firstURL(now: Date) -> URL {
        var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: SpendPeriod.yearMonth(now)),
            URLQueryItem(name: "granularity", value: "hour"),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        return components.url!
    }

    /// Sums `cost` over every line item of every window into `spend_month`, and the windows whose
    /// UTC `date` is today into `spend_today`.
    static func snapshot(from report: PagedReport, now: Date) throws -> ProviderSnapshot {
        let month = SpendPeriod.month(containing: now)
        let today = SpendPeriod.day(containing: now)
        let todayDate = SpendPeriod.ymd(now)
        var monthTotal = MoneyTotal()
        var todayTotal = MoneyTotal()
        for page in report.pages {
            if let period = page["billing_period"]?.stringValue, period != SpendPeriod.yearMonth(now) {
                throw ProviderError.unexpectedResponse("Together answered for \(period), not this month.")
            }
            guard let windows = page["data"]?.arrayValue else {
                throw ProviderError.unexpectedResponse("Together's usage report has no \"data\" list.")
            }
            let currency = page["currency"]?.stringValue
            for window in windows {
                let isToday = window["date"]?.stringValue == todayDate
                for item in window["line_items"]?.arrayValue ?? [] {
                    guard let cost = item["cost"]?.doubleValue else {
                        throw ProviderError.unexpectedResponse("A Together usage line item has no cost.")
                    }
                    try monthTotal.add(cost, currency: currency, provider: "Together")
                    if isToday { try todayTotal.add(cost, currency: currency, provider: "Together") }
                }
            }
        }
        let readings = [
            Reading.spendReading(
                id: "spend_month", name: "This month", amount: monthTotal.amount(),
                period: "this month (UTC)", resetsAt: month.end, freshness: freshness, truncated: report.truncated
            ),
            Reading.spendReading(
                id: "spend_today", name: "Today", amount: todayTotal.amount(fallback: monthTotal.currency ?? "USD"),
                period: "today (UTC)", resetsAt: today.end, freshness: freshness, truncated: report.truncated
            ),
        ]
        return ProviderSnapshot(
            readings: readings,
            note: report.truncated ? "Together's report had more than \(maxPages) pages; the total shown is incomplete." : nil,
            primaryHint: "spend_month",
            historyReadingID: "spend_month",
            fetchedAt: now
        )
    }
}
