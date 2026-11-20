import SwiftUI

// Factory (Droid): the rolling rate limits Factory's own web app shows, with a Factory API key
// the user pastes.
//
// Sources, read 2026-11-19:
// - Plans: https://docs.factory.ai/pricing/individuals (Pro, Plus and Max: three independent
//   rolling windows, 5-hour, 7-day and 30-day; Droid Core models have their own windows after
//   Standard Usage runs out; Extra Usage is prepaid credit that never expires; Free is BYOK).
// - Endpoint and fields (undocumented): the open source CodexBar,
//   https://github.com/steipete/CodexBar/blob/main/docs/factory.md and
//   `Sources/CodexBarCore/Providers/Factory/FactoryStatusProbe.swift`:
//   `GET https://api.factory.ai/api/billing/limits` with `Authorization: Bearer <key>` →
//   `{usesTokenRateLimitsBilling, limits {standard, core} with {fiveHour, weekly, monthly}
//   each {usedPercent (0–100), windowEnd, secondsRemaining}, extraUsageBalanceCents,
//   extraUsageAllowed}`. "weekly" and "monthly" are the documented 7-day and 30-day windows.
//   CodexBar also sends web-app headers (`x-factory-client`, `Origin`); Dogwatch sends only the key.
// Not verified against a real account.

struct FactoryProvider: UsageProvider {
    static let limitsURL = URL(string: "https://api.factory.ai/api/billing/limits")!

    let descriptor = ProviderDescriptor(
        id: "factory",
        name: "Droid",
        glyph: ProviderGlyph(symbol: "gearshape.2"),
        tint: Color(red: 0.95, green: 0.55, blue: 0.3),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "Factory API key",
            placeholder: "fk-…",
            helpURL: URL(string: "https://app.factory.ai/settings/api-keys"),
            warning: "A Factory API key can run Droid on your account and use your plan, not only read usage.",
            advice: "Factory has no read-only key. Create one just for Dogwatch so you can revoke it on its own."
        )),
        summary: "Rolling 5-hour, 7-day and 30-day limits, and Extra Usage balance",
        reads: "One GET to https://api.factory.ai/api/billing/limits, the endpoint Factory's web app uses, with your API key from the Keychain in the Authorization header: the used share of each rolling window and your Extra Usage balance.",
        source: "Factory web app endpoint `GET /api/billing/limits`",
        allowedHosts: ["api.factory.ai"],
        minimumRefreshInterval: 120,
        defaultRefreshInterval: 600,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://docs.factory.ai/pricing/individuals"),
        timeout: 20
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Factory API key set. Add one in settings.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.limitsURL, headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Factory rejected the API key (HTTP 401). Check it in settings.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// Readings: `five_hour`, `seven_day`, `thirty_day` for Standard Usage, `core_*` for Droid Core
    /// when Factory reports it, and `extra_usage` as a balance in USD.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard json.objectValue != nil else {
            throw ProviderError.unexpectedResponse("Factory's answer isn't a JSON object.")
        }
        var readings: [Reading] = []
        let windows: [(key: String, id: String, name: String, period: WindowPeriod, meter: String)] = [
            ("fiveHour", "five_hour", "5h window", .duration(5 * 3_600), "5h"),
            ("weekly", "seven_day", "7-day window", .named("7-day"), "7d"),
            ("monthly", "thirty_day", "30-day window", .named("30-day"), "30d"),
        ]
        if json["usesTokenRateLimitsBilling"]?.boolValue == true, let limits = json["limits"] {
            for (pool, prefix, label) in [("standard", "", ""), ("core", "core_", "Droid Core ")] {
                guard let poolValue = limits[pool], poolValue.objectValue != nil else { continue }
                for window in windows {
                    guard let value = poolValue[window.key], let used = value["usedPercent"]?.doubleValue else { continue }
                    let reset = resetDate(value, now: now)
                    let ended = reset == nil && value["windowEnd"] != nil && value["windowEnd"]?.isNull == false
                    if pool == "core", used == 0, reset == nil { continue }
                    readings.append(Reading(
                        id: prefix + window.id,
                        name: label + window.name,
                        value: .window(QuotaWindow(
                            usedPercent: ended ? 0 : max(0, min(100, Int(used.rounded()))),
                            period: window.period,
                            resetsAt: reset
                        )),
                        meterLabel: label.isEmpty ? window.meter : "Core \(window.meter)"
                    ))
                }
            }
            if readings.isEmpty {
                throw ProviderError.unexpectedResponse("Factory's answer has no limits.standard windows.")
            }
        }
        if let cents = json["extraUsageBalanceCents"]?.doubleValue,
           cents > 0 || json["extraUsageAllowed"]?.boolValue == true {
            readings.append(Reading(
                id: "extra_usage", name: "Extra Usage",
                value: .balance(Balance(remaining: Amount(value: cents / 100, unit: .currency("USD"))))
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "Factory reports no rolling limits for this account (Free and BYOK plans have none)." : nil,
            menuBar: .tightest,
            historyReadingID: readings.contains { $0.id == "seven_day" } ? "seven_day" : nil,
            fetchedAt: now
        )
    }

    /// A window's reset: `secondsRemaining` from now, else `windowEnd` if it is still ahead.
    private static func resetDate(_ window: JSONValue, now: Date) -> Date? {
        if let seconds = window["secondsRemaining"]?.doubleValue, seconds > 0 { return now.addingTimeInterval(seconds) }
        guard let end = DateParsing.date(window["windowEnd"]), end > now else { return nil }
        return end
    }
}
