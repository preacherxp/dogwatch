import SwiftUI

// Kimi Code (membership): the quota windows of a Kimi Code subscription, with a pasted Kimi Code key.
//
// Sources, read 2026-11-19:
// - https://www.kimi.com/code/docs/en/kimi-code/faq.html: Kimi Code base URLs (China
//   https://api.kimi.com/coding/, overseas https://api.kimi.ai/coding/), keys from the Kimi Code
//   Console, and "use the /usage command to check your current quota".
// - What `/usage` calls, from Moonshot's own Kimi Code CLI
//   (https://github.com/MoonshotAI/kimi-cli, src/kimi_cli/ui/shell/usage.py): `GET
//   {base}/coding/v1/usages` with `Authorization: Bearer <key>`. It reads `usage` (a summary row,
//   "Weekly limit" when unnamed) and `limits[]`, each with `detail` (or the item itself) holding
//   `limit` and `used` (or `remaining`), an optional `name`/`title`, a reset as
//   `reset_at`/`resetAt`/`reset_time`/`resetTime` (ISO 8601) or `reset_in`/`resetIn`/`ttl`
//   (seconds), and `window {duration, timeUnit}` (`TIME_UNIT_MINUTE`, `…HOUR`, `…DAY`).
// This provider reads the same fields the same way. The response isn't documented, and no
// account was available to check it, so it shows percentages only (the counts' unit isn't stated).
// It never reads the Kimi CLI's own sign-in: Kimi rotates refresh tokens, and reusing them could
// sign the CLI out.

struct KimiProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "kimi",
        name: "Kimi Code",
        glyph: ProviderGlyph(symbol: "k.square"),
        tint: Color(red: 0.55, green: 0.75, blue: 1.0),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "Kimi Code API key",
            placeholder: "Paste your Kimi Code key",
            helpURL: URL(string: "https://www.kimi.com/code/console"),
            warning: "A Kimi Code key can also run models against your membership quota.",
            advice: "Kimi has no read-only key. A Kimi Open Platform (Moonshot) key won't work here; use a Kimi Code key from the region you chose."
        )),
        summary: "Kimi Code membership quota windows",
        reads: "One GET to /coding/v1/usages on the region you choose (api.kimi.com or api.kimi.ai), with your Kimi Code key from the Keychain in the Authorization header. It is what the Kimi Code CLI's /usage command reads. The Kimi CLI's own sign-in is never read.",
        source: "Kimi Code `GET /coding/v1/usages` (what the Kimi Code CLI's /usage reads)",
        allowedHosts: ["api.kimi.com", "api.kimi.ai"],
        minimumRefreshInterval: 120,
        defaultRefreshInterval: 900,
        baseURLs: [
            BaseURLOption(label: "China (kimi.com)", url: URL(string: "https://api.kimi.com")!),
            BaseURLOption(label: "Overseas (kimi.ai)", url: URL(string: "https://api.kimi.ai")!),
        ],
        idleLabel: "Add a Kimi Code key",
        documentation: URL(string: "https://www.kimi.com/code/docs/en/kimi-code/faq.html"),
        timeout: 20
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Kimi Code key set. Add one in settings.")
        }
        var base = (context.settings.baseURL ?? descriptor.baseURLs[0].url).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/coding/v1/usages") else {
            throw ProviderError.notConfigured("Kimi Code's base URL is not valid.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(url, headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Kimi rejected the key (HTTP 401). Check it in settings, and use a key from the region you chose.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// Readings: `summary` for the `usage` row, and one per `limits[]` entry, named by its window
    /// (`window_300m` for a 5-hour window) or its position (`limit_2`).
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard json.objectValue != nil, json["usage"] != nil || json["limits"] != nil else {
            throw ProviderError.unexpectedResponse("Kimi's answer has no \"usage\" or \"limits\".")
        }
        var readings: [Reading] = []
        if let usage = json["usage"], usage.objectValue != nil,
           let window = row(usage, now: now) {
            let name = label(usage) ?? "Weekly limit"
            readings.append(Reading(
                id: "summary",
                name: name,
                value: .window(QuotaWindow(usedPercent: window.percent, period: .named(label(usage) == nil ? "weekly" : name), resetsAt: window.reset)),
                meterLabel: label(usage) == nil ? "Week" : name
            ))
        }
        var seen = Set(readings.map(\.id))
        for (index, item) in (json["limits"]?.arrayValue ?? []).enumerated() {
            guard item.objectValue != nil else { continue }
            let detail = item["detail"]?.objectValue != nil ? item["detail"]! : item
            guard let window = row(detail, now: now) else { continue }
            let span = duration(item["window"] ?? .null, item: item, detail: detail)
            var id = span.map { "window_\(Int($0 / 60))m" } ?? "limit_\(index + 1)"
            if seen.contains(id) { id += "_\(index + 1)" }
            seen.insert(id)
            let name = label(item) ?? label(detail) ?? span.map { "\(WindowPeriod.duration($0).label) limit" } ?? "Limit \(index + 1)"
            readings.append(Reading(
                id: id,
                name: name,
                value: .window(QuotaWindow(usedPercent: window.percent, period: span.map { .duration($0) } ?? .named(name), resetsAt: window.reset)),
                meterLabel: span.map { WindowPeriod.duration($0).label } ?? name
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "Kimi reported no quota for this key." : nil,
            fetchedAt: now
        )
    }

    private static func label(_ value: JSONValue) -> String? {
        for key in ["name", "title", "scope"] {
            if let text = value[key]?.stringValue, !text.isEmpty { return text }
        }
        return nil
    }

    /// The used percentage and reset of one row, or nil when it has no limit.
    private static func row(_ value: JSONValue, now: Date) -> (percent: Int, reset: Date?)? {
        guard let limit = value["limit"]?.doubleValue, limit > 0 else { return nil }
        let used: Double
        if let reported = value["used"]?.doubleValue {
            used = reported
        } else if let remaining = value["remaining"]?.doubleValue {
            used = limit - remaining
        } else {
            return nil
        }
        var reset: Date?
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let date = DateParsing.date(value[key]) { reset = date; break }
        }
        if reset == nil {
            for key in ["reset_in", "resetIn", "ttl"] {
                if let seconds = value[key]?.doubleValue, seconds > 0 { reset = now.addingTimeInterval(seconds); break }
            }
        }
        return (max(0, min(100, Int((used / limit * 100).rounded()))), reset)
    }

    /// A window's length in seconds from `duration` and `timeUnit`, looked up in the window, the
    /// item, then the detail, as the Kimi CLI does.
    private static func duration(_ window: JSONValue, item: JSONValue, detail: JSONValue) -> TimeInterval? {
        let amount = (window["duration"] ?? item["duration"] ?? detail["duration"])?.doubleValue
        let unit = (window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"])?.stringValue ?? ""
        guard let amount, amount > 0 else { return nil }
        if unit.contains("MINUTE") { return amount * 60 }
        if unit.contains("HOUR") { return amount * 3_600 }
        if unit.contains("DAY") { return amount * 86_400 }
        return nil
    }
}
