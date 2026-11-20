import SwiftUI

// Mistral API: the organisation's usage this month against its monthly spend limit, from the Admin API.
// Enterprise plans only: other plans can't create an Admin API key.
//
// API reference, read 2026-11-19:
// - https://docs.mistral.ai/openapi.yaml, `GET /v1/admin/spend-limit` (tag `beta.admin.billing`, security
//   `AdminApiKey`, header `x-api-key`): `LimitsOUT {limits: LimitsContext}` where `LimitsContext` has
//   `currency` ("Currency used for usage and limit amounts") and `completion: UsageLimits` with
//   `usage_limit` (current limit), `total_usage` ("Total current usage counted against the limit"),
//   `usage`, `vibe_usage`, `no_monthly_limit` and `monthly_limit_reached`; numbers may be null.
// - https://docs.mistral.ai/admin/admin-api/usage-metrics: the monthly limit is "a whole number in your
//   Organization's billing currency (500 means 500, not 500 cents)"; usage is in the same currency.
// - https://docs.mistral.ai/admin/admin-api/authentication: Admin API keys are created in the Admin Panel
//   for one organisation, optionally with an expiration date; there is no narrower admin key.
// `GET /v1/admin/usage` was not used: its per-model rows are untyped and carry no cost total.
// Mistral doesn't state the limit's time zone or how quickly usage is counted.

struct MistralAPIProvider: UsageProvider {
    static let freshness = "Mistral doesn't say how soon usage is counted"

    let descriptor = ProviderDescriptor(
        id: "mistral-api",
        name: "Mistral API",
        glyph: ProviderGlyph(symbol: "wind"),
        tint: Color(red: 0.98, green: 0.55, blue: 0.2),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .adminKey,
            label: "Admin API key",
            placeholder: "",
            helpURL: URL(string: "https://admin.mistral.ai/"),
            warning: "A Mistral Admin API key can manage your whole organization: users, workspaces, API keys and the spend limit. Dogwatch only reads the spend limit with it.",
            advice: "Mistral has no read-only Admin API key (Enterprise plans only). Create one only for Dogwatch with an expiration date."
        )),
        summary: "Usage this month against the spend limit (Enterprise)",
        reads: "One GET to https://api.mistral.ai/v1/admin/spend-limit, with your Admin API key from the Keychain in the x-api-key header: the organization's monthly spend limit and the usage counted against it.",
        source: "Mistral Admin API `GET /v1/admin/spend-limit` (beta)",
        allowedHosts: ["api.mistral.ai"],
        minimumRefreshInterval: 300,
        defaultRefreshInterval: 900,
        idleLabel: "Add an Admin API key",
        documentation: URL(string: "https://docs.mistral.ai/admin/admin-api/usage-metrics"),
        timeout: 20
    )

    static let limitURL = URL(string: "https://api.mistral.ai/v1/admin/spend-limit")!

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Mistral Admin API key set. Add one in settings.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.limitURL, headers: ["x-api-key": key])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Mistral rejected the key (HTTP 401). This needs an Admin API key (Enterprise plans), not a standard API key.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Mistral refused access (HTTP 403). This needs an Admin API key (Enterprise plans), not a standard API key.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let limits = json["limits"], let completion = limits["completion"]?.objectValue else {
            throw ProviderError.unexpectedResponse("Mistral's answer has no limits.completion.")
        }
        guard let currency = limits["currency"]?.stringValue, !currency.isEmpty else {
            throw ProviderError.unexpectedResponse("Mistral's answer has no limits.currency.")
        }
        guard let used = completion["total_usage"]?.doubleValue ?? completion["usage"]?.doubleValue else {
            throw ProviderError.unexpectedResponse("Mistral's answer has no limits.completion.total_usage.")
        }
        let unit = AmountUnit.currency(currency.uppercased())
        let uncapped = completion["no_monthly_limit"]?.boolValue == true
        let budget = uncapped ? nil : completion["usage_limit"]?.doubleValue.flatMap { $0 > 0 ? Amount(value: $0, unit: unit) : nil }
        var reading = Reading.spendReading(
            id: "spend_month", name: "This month", amount: Amount(value: used, unit: unit),
            period: "this month", budget: budget, freshness: freshness
        )
        if completion["monthly_limit_reached"]?.boolValue == true {
            reading.detail = "Monthly spend limit reached"
            reading.isBinding = true
        }
        return ProviderSnapshot(
            readings: [reading],
            label: budget == nil ? "No monthly limit" : nil,
            primaryHint: "spend_month",
            historyReadingID: "spend_month",
            fetchedAt: now
        )
    }
}
