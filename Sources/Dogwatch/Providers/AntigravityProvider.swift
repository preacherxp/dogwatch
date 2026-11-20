import SwiftUI

// Antigravity: the quota buckets the Antigravity CLI (`agy`) hands to its status line command.
// A file written by the user's own status line command, read-only. Dogwatch never starts `agy`.
//
// Documentation, read 2026-11-19:
// - Status line payload: https://antigravity.google/docs/cli/statusline. `quota` maps bucket ids
//   (`gemini-weekly`, `gemini-5h`, `3p-weekly`, `3p-5h`, …) to `{remaining_fraction` or
//   `remaining_amount, reset_time, reset_in_seconds, disabled}`; `plan_tier` is the plan.
// - Quotas: https://antigravity.google/docs/cli/commands/usage. Each model group has a weekly
//   and a five-hour limit.
//
// Why not `agy -p "/usage" --output-format json`: its documentation says `/usage` refreshes the
// model configuration and quotas from the backend; it doesn't say starting `agy` leaves the
// sign-in untouched, and a signed-out `agy` may open a browser sign-in. A status line file needs
// no program at all.
//
// Setup (shown in settings): in ~/.gemini/antigravity-cli/settings.json,
//   "statusLine": {"type": "command", "stack_with_default": true,
//     "command": "f=\"$HOME/Library/Application Support/Dogwatch/antigravity-quota.json\"; jq -c '{quota, plan_tier}' > \"$f.tmp\" && mv \"$f.tmp\" \"$f\""}
// Only `quota` and `plan_tier` are kept; the payload's other fields (including the account
// email) never reach the file. Not verified against a real account.

struct AntigravityProvider: UsageProvider {
    static let filePath = "Library/Application Support/Dogwatch/antigravity-quota.json"

    let descriptor = ProviderDescriptor(
        id: "antigravity",
        name: "Antigravity",
        glyph: ProviderGlyph(symbol: "arrow.up.circle"),
        tint: Color(red: 0.4, green: 0.6, blue: 1.0),
        category: .subscription,
        stability: .unverified,
        credential: .none,
        summary: "Five-hour and weekly quota per model group",
        reads: "~/Library/Application Support/Dogwatch/antigravity-quota.json, which you create with Antigravity CLI's documented status line: in ~/.gemini/antigravity-cli/settings.json set \"statusLine\": {\"type\": \"command\", \"stack_with_default\": true, \"command\": \"f=\\\"$HOME/Library/Application Support/Dogwatch/antigravity-quota.json\\\"; jq -c '{quota, plan_tier}' > \\\"$f.tmp\\\" && mv \\\"$f.tmp\\\" \\\"$f\\\"\"} (needs jq). It keeps only the quota buckets and the plan name. Dogwatch reads the file and never starts agy or reads its sign-in; the numbers are as fresh as your last agy session.",
        source: "Antigravity CLI status line (`quota`), written to a file",
        minimumRefreshInterval: 30,
        idleLabel: "Set up the status line",
        documentation: URL(string: "https://antigravity.google/docs/cli/statusline"),
        localSources: [ToolStore(kind: .file, location: "~/\(AntigravityProvider.filePath)")]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.fileExists(context.home.appendingPathComponent(Self.filePath))
            ? .available : .unavailable("Set up Antigravity's status line (see What Dogwatch reads)")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let url = context.home.appendingPathComponent(Self.filePath)
        guard context.local.fileExists(url) else {
            throw ProviderError.notConfigured("No Antigravity status line file yet. Set up the status line, then use agy once.")
        }
        guard let json = try? JSONValue(data: context.local.read(url)) else {
            throw ProviderError.unexpectedResponse("antigravity-quota.json isn't JSON.")
        }
        let written = context.local.modificationDate(of: url) ?? context.now()
        return try Self.snapshot(from: json, writtenAt: written, now: context.now())
    }

    /// One window per enabled bucket with a `remaining_fraction`, keyed `bucket:<id>`. Buckets
    /// whose reset passed after the file was written are shown as fresh windows.
    static func snapshot(from json: JSONValue, writtenAt: Date, now: Date) throws -> ProviderSnapshot {
        guard let quota = json["quota"]?.objectValue else {
            throw ProviderError.unexpectedResponse("The Antigravity status line file has no quota object.")
        }
        var readings: [Reading] = []
        for id in quota.keys.sorted(by: bucketOrder) {
            guard let bucket = quota[id], bucket["disabled"]?.boolValue != true,
                  let fraction = bucket["remaining_fraction"]?.doubleValue
            else { continue }
            let reset = DateParsing.date(bucket["reset_time"])
                ?? bucket["reset_in_seconds"]?.doubleValue.map { writtenAt.addingTimeInterval($0) }
            let hasReset = reset.map { $0 <= now } ?? false
            let (name, period, meter) = describe(id)
            readings.append(Reading(
                id: "bucket:\(id)", name: name,
                value: .window(QuotaWindow(
                    usedPercent: hasReset ? 0 : max(0, min(100, Int(((1 - fraction) * 100).rounded()))),
                    period: period,
                    resetsAt: hasReset ? nil : reset
                )),
                meterLabel: meter,
                detail: hasReset ? "New window since agy last reported it" : nil,
                freshness: "From agy's status line \(writtenAt.formatted(.relative(presentation: .named)))"
            ))
        }
        let plan = json["plan_tier"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            readings: readings,
            plan: plan,
            note: readings.isEmpty ? "agy reported no quota buckets." : nil,
            menuBar: .tightest,
            historyReadingID: readings.first { $0.id.hasSuffix("weekly") }?.id,
            fetchedAt: min(writtenAt, now)
        )
    }

    /// "gemini-5h" → ("Gemini 5h", 5 hours, "Gemini 5h"); "3p-weekly" → ("Claude and GPT weekly", …).
    static func describe(_ id: String) -> (name: String, period: WindowPeriod, meter: String) {
        let lower = id.lowercased()
        let group: String
        var rest = lower
        if let dash = lower.lastIndex(of: "-") {
            group = String(lower[..<dash])
            rest = String(lower[lower.index(after: dash)...])
        } else {
            group = lower
        }
        let groupName: String
        switch group {
        case "gemini": groupName = "Gemini"
        case "3p": groupName = "Claude and GPT"
        default: groupName = group.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        switch rest {
        case "5h": return ("\(groupName) 5h", .duration(5 * 3_600), "\(groupName) 5h")
        case "weekly": return ("\(groupName) weekly", .named("weekly"), "\(groupName) week")
        default: return ("\(groupName) \(rest)", .named(rest), "\(groupName) \(rest)")
        }
    }

    /// Five-hour buckets first, then weekly, then by name, so the order is stable.
    private static func bucketOrder(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ id: String) -> Int { id.hasSuffix("-5h") ? 0 : id.hasSuffix("-weekly") ? 1 : 2 }
        return (rank(lhs), lhs) < (rank(rhs), rhs)
    }
}
