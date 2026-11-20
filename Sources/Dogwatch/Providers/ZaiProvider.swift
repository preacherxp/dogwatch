import SwiftUI

// Z.ai GLM Coding Plan: the 5-hour and weekly quota windows, with a pasted Coding Plan key.
//
// Sources, read 2026-11-19:
// - Z.ai's own usage plugin for Claude Code, `glm-plan-usage`
//   (https://github.com/zai-org/zai-coding-plugins, skills/usage-query-skill/scripts/query-usage.mjs):
//   `GET {https://api.z.ai | https://open.bigmodel.cn}/api/monitor/usage/quota/limit` with the plan
//   key, answered with `{code, msg, success, data: {limits: [{type, percentage, currentValue,
//   usage, usageDetails, …}]}}`. It names `TOKENS_LIMIT` the 5-hour token quota and `TIME_LIMIT`
//   the monthly MCP quota (`currentValue` of `usage`).
// - Plan rules: https://docs.z.ai/devpack/faq and https://docs.z.ai/devpack/notice/usage-revision
//   (a 5-hour window and a weekly window). Keys: https://docs.z.ai/devpack/notice/api-key-management
//   (since 2026-10-16 Coding Plan keys are separate from standard API keys).
// The endpoint isn't in Z.ai's API reference. Checked on this Mac on 2026-11-19 with one GET: a
// key without a plan is answered with HTTP 200 and `{code: 500, msg, success: false}`, so the
// body's `success` decides, not the status. A populated answer was not seen. How a limit's
// `unit`/`number` give its duration (3 = hours, 6 = weeks) and `nextResetTime` (Unix ms) come
// from a third-party monitor (CodexBar's zai.js), so a limit with any other unit is shown under
// a neutral name instead of a guessed duration.

struct ZaiProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "zai",
        name: "Z.ai",
        glyph: ProviderGlyph(symbol: "z.square"),
        tint: Color(red: 0.35, green: 0.55, blue: 1.0),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "Coding Plan API key",
            placeholder: "Paste your GLM Coding Plan key",
            helpURL: URL(string: "https://z.ai/manage-apikey/apikey-list"),
            warning: "The Coding Plan key can also run models against your plan's quota.",
            advice: "Z.ai has no read-only key. A pay-as-you-go API key won't work here; use the Coding Plan key."
        )),
        summary: "GLM Coding Plan 5-hour and weekly quota, and MCP calls this month",
        reads: "One GET to /api/monitor/usage/quota/limit on the region you choose (api.z.ai or open.bigmodel.cn), with your Coding Plan key from the Keychain in the Authorization header. This is the endpoint Z.ai's own usage plugin calls; it isn't in Z.ai's API reference.",
        source: "Z.ai `GET /api/monitor/usage/quota/limit` (used by Z.ai's usage plugin)",
        allowedHosts: ["api.z.ai", "open.bigmodel.cn"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        baseURLs: [
            BaseURLOption(label: "Global (api.z.ai)", url: URL(string: "https://api.z.ai")!),
            BaseURLOption(label: "China (open.bigmodel.cn)", url: URL(string: "https://open.bigmodel.cn")!),
        ],
        idleLabel: "Add a Coding Plan key",
        documentation: URL(string: "https://docs.z.ai/devpack/faq"),
        timeout: 20
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Z.ai Coding Plan key set. Add one in settings.")
        }
        var base = (context.settings.baseURL ?? descriptor.baseURLs[0].url).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/monitor/usage/quota/limit") else {
            throw ProviderError.notConfigured("Z.ai's base URL is not valid.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(url, headers: ["Authorization": "Bearer \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Z.ai rejected the key (HTTP 401). Check it in settings.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// Readings: one window per Coding Plan limit (`five_hour`, `weekly`, or `limit_<unit>_<number>`
    /// when the duration isn't one we can name), and `mcp_monthly` for MCP tool calls.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        if json["success"]?.boolValue != true {
            let message = json["msg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if json["success"] == nil, json["data"] == nil {
                throw ProviderError.unexpectedResponse("Z.ai's answer has no \"success\" or \"data\".")
            }
            throw ProviderError.unexpectedResponse("Z.ai reported an error\(message.map { ": \($0)" } ?? ".")")
        }
        guard let data = json["data"]?.objectValue else {
            throw ProviderError.unexpectedResponse("Z.ai's answer has no \"data\" object.")
        }

        var plan: [Reading] = []
        var other: [Reading] = []
        for (index, entry) in (data["limits"]?.arrayValue ?? []).enumerated() {
            guard let type = entry["type"]?.stringValue,
                  let percent = entry["percentage"]?.doubleValue else { continue }
            let usedPercent = max(0, min(100, Int(percent.rounded())))
            let reset = DateParsing.epoch(entry["nextResetTime"]?.doubleValue)
            switch type {
            case "TOKENS_LIMIT", "CREDIT_LIMIT":
                let window = Self.window(unit: entry["unit"]?.doubleValue, number: entry["number"]?.doubleValue, index: index)
                plan.append(Reading(
                    id: window.id,
                    name: window.name,
                    value: .window(QuotaWindow(usedPercent: usedPercent, period: window.period, resetsAt: reset)),
                    meterLabel: window.meter
                ))
            case "TIME_LIMIT":
                let used = entry["currentValue"]?.doubleValue
                let limit = entry["usage"]?.doubleValue
                let counts = (used != nil && (limit ?? 0) > 0)
                other.append(Reading(
                    id: "mcp_monthly",
                    name: "MCP calls",
                    value: .window(QuotaWindow(
                        usedPercent: usedPercent,
                        period: .named("monthly"),
                        resetsAt: reset,
                        used: counts ? Amount(value: used!, unit: .custom("calls")) : nil,
                        limit: counts ? Amount(value: limit!, unit: .custom("calls")) : nil
                    )),
                    meterLabel: "MCP"
                ))
            default:
                continue
            }
        }
        // The Coding Plan window closest to running out is what limits the user; MCP calls are
        // a separate quota and never the default.
        let tightest = plan.max { ($0.window?.usedPercent ?? 0) < ($1.window?.usedPercent ?? 0) }
        let readings = plan + other
        let planName = (data["planName"] ?? data["plan"] ?? data["packageName"])?.stringValue
        return ProviderSnapshot(
            readings: readings,
            plan: planName,
            note: plan.isEmpty ? "Z.ai reported no Coding Plan quota for this key." : nil,
            primaryHint: tightest?.id,
            menuBar: .primary,
            historyReadingID: tightest?.id,
            fetchedAt: now
        )
    }

    private static func window(unit: Double?, number: Double?, index: Int) -> (id: String, name: String, meter: String, period: WindowPeriod) {
        guard let unit, let number, number > 0 else {
            return ("limit_\(index + 1)", "Coding Plan limit", "Limit", .named("Coding Plan window"))
        }
        let n = Int(number)
        switch Int(unit) {
        case 3 where n == 5: return ("five_hour", "5h window", "5h", .duration(5 * 3_600))
        case 3: return ("limit_\(n)h", "\(n)h window", "\(n)h", .duration(TimeInterval(n) * 3_600))
        case 6 where n == 1: return ("weekly", "Weekly", "Week", .duration(7 * 86_400))
        case 6: return ("limit_\(n)w", "\(n)-week window", "\(n)w", .duration(TimeInterval(n) * 7 * 86_400))
        case 1: return ("limit_\(n)d", "\(n)-day window", "\(n)d", .duration(TimeInterval(n) * 86_400))
        default: return ("limit_\(Int(unit))_\(n)", "Coding Plan limit", "Limit", .named("Coding Plan window"))
        }
    }
}
