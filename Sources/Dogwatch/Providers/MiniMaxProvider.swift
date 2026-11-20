import SwiftUI

// MiniMax M Plan (formerly Token Plan, Coding Plan): what is left of the 5-hour and weekly windows,
// with a pasted M Plan key.
//
// Sources, read 2026-11-19:
// - https://platform.minimax.io/docs/m-plan/faq.md ("How can I check M Plan usage?"): `GET
//   https://www.minimax.io/v1/token_plan/remains` with `Authorization: Bearer <M Plan API key>`;
//   the China platform (https://platform.minimax.cn/docs/m-plan/faq.md) uses www.minimax.cn.
//   Windows: 5 hours and 7 days, each starting at first use; image and video models have only
//   the weekly window.
// - The field names aren't documented. They come from MiniMax's own CLI, `mmx-cli` 1.0.29
//   (`QuotaResponse`, `QuotaModelRemain` in dist/index.d.ts, and `mmx quota show`):
//   `model_remains[] {model_name, start_time, end_time (Unix ms), current_interval_total_count,
//   current_interval_usage_count, current_interval_remaining_percent?, current_weekly_*,
//   weekly_end_time, weekly_boost_permille?, current_interval_status?, current_weekly_status?}`.
//   `mmx` shows the remaining percentage when the API gives one, and otherwise treats
//   `*_usage_count / *_total_count` as the share *remaining*; this provider does the same and
//   shows no counts, because the counts' meaning is ambiguous. A weekly boost (`weekly_boost_permille`)
//   scales the weekly share as `mmx` does. Status 3 on both windows with zero totals means the
//   model isn't in the plan; status 3 on the weekly window alone means it has no weekly cap.
// Errors come back as HTTP 200 with `base_resp.status_code` other than 0. Checked on this Mac on
// 2026-11-19 with one GET: a key without a plan answers `{model_remains: null, base_resp:
// {status_code: 2062, status_msg}}`. A populated answer was not seen.

struct MiniMaxProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "minimax",
        name: "MiniMax",
        glyph: ProviderGlyph(symbol: "m.square"),
        tint: Color(red: 0.95, green: 0.35, blue: 0.45),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "M Plan API key",
            placeholder: "sk-cp-…",
            helpURL: URL(string: "https://platform.minimax.io/console/plan"),
            warning: "The M Plan key can also run models against your plan's quota and Credits.",
            advice: "MiniMax has no read-only key. A pay-as-you-go key (sk-api-…) won't work here; use the M Plan key."
        )),
        summary: "M Plan 5-hour and weekly quota left, per model",
        reads: "One GET to /v1/token_plan/remains on the region you choose (www.minimax.io or www.minimax.cn), with your M Plan key from the Keychain in the Authorization header, as MiniMax's usage FAQ describes.",
        source: "MiniMax `GET /v1/token_plan/remains` (M Plan FAQ; fields from MiniMax's `mmx` CLI)",
        allowedHosts: ["www.minimax.io", "www.minimax.cn"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        baseURLs: [
            BaseURLOption(label: "Global (minimax.io)", url: URL(string: "https://www.minimax.io")!),
            BaseURLOption(label: "China (minimax.cn)", url: URL(string: "https://www.minimax.cn")!),
        ],
        idleLabel: "Add an M Plan key",
        documentation: URL(string: "https://platform.minimax.io/docs/m-plan/faq"),
        timeout: 20
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No MiniMax M Plan key set. Add one in settings.")
        }
        var base = (context.settings.baseURL ?? descriptor.baseURLs[0].url).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/token_plan/remains") else {
            throw ProviderError.notConfigured("MiniMax's base URL is not valid.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(url, headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("MiniMax rejected the key (HTTP 401). Check it in settings.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// Readings, per model in the plan: `five_hour:<model>` and `weekly:<model>`, as windows with
    /// only a percentage. The primary is the window with the least left.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let status = json["base_resp"]?["status_code"]?.doubleValue else {
            throw ProviderError.unexpectedResponse("MiniMax's answer has no base_resp.status_code.")
        }
        if status != 0 {
            let message = json["base_resp"]?["status_msg"]?.stringValue ?? "status \(Int(status))"
            switch Int(status) {
            case 2049:
                throw ProviderError.notSignedIn("MiniMax rejected the key (\(message)). Check it in settings, and use an M Plan key for the region you chose.")
            case 2062:
                throw ProviderError.unexpectedResponse("MiniMax: this key has no active M Plan subscription (\(message)).")
            default:
                throw ProviderError.unexpectedResponse("MiniMax reported an error: \(message).")
            }
        }

        var readings: [Reading] = []
        for entry in json["model_remains"]?.arrayValue ?? [] {
            guard let model = entry["model_name"]?.stringValue, !model.isEmpty else { continue }
            let intervalTotal = entry["current_interval_total_count"]?.doubleValue ?? 0
            let weeklyTotal = entry["current_weekly_total_count"]?.doubleValue ?? 0
            let intervalStatus = entry["current_interval_status"]?.doubleValue
            let weeklyStatus = entry["current_weekly_status"]?.doubleValue
            if intervalTotal == 0, weeklyTotal == 0, intervalStatus == 3, weeklyStatus == 3 { continue }

            if let left = remainingPercent(
                percent: entry["current_interval_remaining_percent"]?.doubleValue,
                count: entry["current_interval_usage_count"]?.doubleValue, total: intervalTotal, boostPermille: nil
            ) {
                let start = entry["start_time"]?.doubleValue
                let end = entry["end_time"]?.doubleValue
                let span = (start != nil && end != nil && end! > start!) ? (end! - start!) / 1000 : 5 * 3_600
                readings.append(Reading(
                    id: "five_hour:\(model)",
                    name: "\(model) · \(WindowPeriod.duration(span).label)",
                    value: .window(QuotaWindow(usedPercent: 100 - left, period: .duration(span), resetsAt: DateParsing.epoch(end))),
                    meterLabel: WindowPeriod.duration(span).label
                ))
            }
            if weeklyStatus != 3, let left = remainingPercent(
                percent: entry["current_weekly_remaining_percent"]?.doubleValue,
                count: entry["current_weekly_usage_count"]?.doubleValue, total: weeklyTotal,
                boostPermille: entry["weekly_boost_permille"]?.doubleValue
            ) {
                readings.append(Reading(
                    id: "weekly:\(model)",
                    name: "\(model) · weekly",
                    value: .window(QuotaWindow(usedPercent: 100 - left, period: .duration(7 * 86_400),
                                               resetsAt: DateParsing.epoch(entry["weekly_end_time"]?.doubleValue))),
                    meterLabel: "Week"
                ))
            }
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "MiniMax reported no M Plan quota for this key." : nil,
            fetchedAt: now
        )
    }

    /// Whole percent left, 0–100, the way `mmx quota show` computes it; nil when there is nothing to show.
    private static func remainingPercent(percent: Double?, count: Double?, total: Double, boostPermille: Double?) -> Int? {
        let boost = boostPermille.map { max(0, $0) / 1000 } ?? 1
        let raw: Double
        if let percent {
            raw = percent
        } else if let count, total > 0 {
            raw = count / total * 100
        } else {
            return nil
        }
        return max(0, min(100, Int((raw * boost).rounded())))
    }
}
