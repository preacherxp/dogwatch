import SwiftUI

// Hugging Face: an organisation's Inference Providers spend this month. Enterprise organisations only;
// there is no API for a personal account's credits.
//
// API reference, read 2026-11-19:
// - https://huggingface.co/.well-known/openapi.json, `GET /api/organizations/{name}/billing/usage/inference`
//   (badges: Enterprise, Enterprise Plus, Academia Hub): query `startDate`, `endDate` (RFC 3339 UTC,
//   default the current month), `limit` (daily periods per page, 1–31, default 7). Answers an array of
//   `{period: <date-time>, usage: [{user, model, provider, requestCount, costCents, inputTokens,
//   outputTokens, cachedInputTokens}]}`; more pages via the `Link` header. "Requests are included up
//   to 2 hours after they are made."
// - https://huggingface.co/docs/inference-providers/en/pricing.md: costs are in cents, rounded to the
//   nearest cent per row, so the sum can differ slightly from the invoice; the token needs permission to
//   read the organisation's billing.
// A month has at most 31 daily periods, so one page at limit=31 holds the whole month and the `Link`
// header (which `HTTPClient` doesn't expose) is never needed. The per-member `user` field is dropped.

struct HuggingFaceProvider: UsageProvider {
    static let freshness = "Requests appear up to 2 hours late; costs are rounded per row"

    let descriptor = ProviderDescriptor(
        id: "huggingface",
        name: "Hugging Face",
        glyph: ProviderGlyph(symbol: "face.smiling"),
        tint: Color(red: 1.0, green: 0.8, blue: 0.2),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .token,
            label: "Access token",
            placeholder: "hf_…",
            helpURL: URL(string: "https://huggingface.co/settings/tokens"),
            advice: "Use a fine-grained token whose only permission is reading this organization's billing."
        )),
        summary: "Organization Inference Providers spend this month (Enterprise)",
        reads: "One GET to https://huggingface.co/api/organizations/<organization>/billing/usage/inference for this month's daily Inference Providers costs, with your token from the Keychain in the Authorization header. Per-member rows are added up; member names are not kept.",
        source: "Hugging Face Hub API `GET /api/organizations/{name}/billing/usage/inference`",
        allowedHosts: ["huggingface.co"],
        minimumRefreshInterval: 900,
        defaultRefreshInterval: 1_800,
        idleLabel: "Add an access token",
        documentation: URL(string: "https://huggingface.co/docs/inference-providers/en/pricing"),
        timeout: 30,
        fields: [SettingField(
            id: "organization",
            label: "Organization",
            placeholder: "my-org",
            help: "The organization's name as in its huggingface.co URL. Usage is available to Enterprise organizations."
        )]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        guard context.settings.value("organization") != nil else { return .unavailable("No organization set") }
        return keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Hugging Face token set. Add one in settings.")
        }
        let organization = try PathIdentifier.validated(context.settings.value("organization"), field: "organization", provider: "Hugging Face")
        let now = context.now()
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.usageURL(organization: organization, now: now), headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Hugging Face rejected the token (HTTP 401). Check it in settings.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Hugging Face refused access (HTTP 403). The token needs permission to read this organization's billing, and the organization must be on Enterprise.")
        } catch ProviderError.notFound {
            throw ProviderError.notConfigured("Hugging Face doesn't know this organization, or the token can't see it (HTTP 404).")
        }
        return try Self.snapshot(from: json, now: now)
    }

    static func usageURL(organization: String, now: Date) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/organizations/\(organization)/billing/usage/inference"
        components.queryItems = [
            URLQueryItem(name: "startDate", value: SpendPeriod.iso(SpendPeriod.month(containing: now).start)),
            URLQueryItem(name: "limit", value: "31"),
        ]
        return components.url!
    }

    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let periods = json.arrayValue else {
            throw ProviderError.unexpectedResponse("Hugging Face's usage answer isn't a list of daily periods.")
        }
        let month = SpendPeriod.month(containing: now)
        let today = SpendPeriod.day(containing: now)
        var monthCents = 0.0
        var todayCents = 0.0
        for period in periods {
            guard let start = DateParsing.iso8601(period["period"]?.stringValue) else {
                throw ProviderError.unexpectedResponse("A Hugging Face usage period has no date.")
            }
            guard start >= month.start, start < month.end else { continue }
            for row in period["usage"]?.arrayValue ?? [] {
                guard let cents = row["costCents"]?.doubleValue else {
                    throw ProviderError.unexpectedResponse("A Hugging Face usage row has no costCents.")
                }
                monthCents += cents
                if start >= today.start, start < today.end { todayCents += cents }
            }
        }
        let readings = [
            Reading.spendReading(
                id: "spend_month", name: "This month", amount: Amount(value: monthCents / 100, unit: .currency("USD")),
                period: "this month (UTC)", resetsAt: month.end, freshness: freshness
            ),
            Reading.spendReading(
                id: "spend_today", name: "Today", amount: Amount(value: todayCents / 100, unit: .currency("USD")),
                period: "today (UTC)", resetsAt: today.end, freshness: freshness
            ),
        ]
        return ProviderSnapshot(readings: readings, label: "Inference Providers", primaryHint: "spend_month", historyReadingID: "spend_month", fetchedAt: now)
    }
}
