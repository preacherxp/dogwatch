import SwiftUI

// Devin (Devin Desktop, formerly Windsurf): the plan information Devin Desktop caches in its own
// settings database. A local, read-only file: no network, no sign-in, no Keychain prompt.
//
// Sources, read 2026-11-19:
// - Quotas: https://docs.devin.ai/desktop/accounts/quota (since March 2026 a daily and a weekly
//   allowance, reset on calendar dates; extra usage is billed separately).
// - Cache location and fields (undocumented): the open source CodexBar,
//   https://github.com/steipete/CodexBar/blob/main/docs/windsurf.md and
//   `Sources/CodexBarCore/Providers/Windsurf/WindsurfStatusProbe.swift`:
//   `ItemTable` key `windsurf.settings.cachedPlanInfo` in `User/globalStorage/state.vscdb`, JSON
//   `{planName, quotaUsage {dailyRemainingPercent, weeklyRemainingPercent, dailyResetAtUnix,
//   weeklyResetAtUnix}}` (percent 0–100, resets in Unix seconds).
//   CodexBar reads it from the Windsurf folder; Devin Desktop's folder is
//   `~/Library/Application Support/Devin` (CodexBar `DevinAppSessionImporter.swift`). Whether the
//   renamed app keeps the same key there is not confirmed, so both folders are read.
//
// Not used: Devin's web endpoint (`app.devin.ai/api/<org>/billing/quota/usage`) needs a browser
// session token pasted by the user, and its percentage scale is not established; Devin Desktop's
// encrypted session would need a Keychain prompt. The cache is only as fresh as Devin Desktop's
// last update; changes it hasn't checkpointed yet are read too (`queryReadOnly`).
// Not verified against a real account.

struct DevinProvider: UsageProvider {
    static let databases = [
        "Library/Application Support/Devin/User/globalStorage/state.vscdb",
        "Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
    ]
    static let planKey = "windsurf.settings.cachedPlanInfo"

    let descriptor = ProviderDescriptor(
        id: "devin",
        name: "Devin",
        glyph: ProviderGlyph(symbol: "water.waves"),
        tint: Color(red: 0.35, green: 0.78, blue: 0.7),
        category: .subscription,
        stability: .unverified,
        credential: .none,
        summary: "Devin Desktop daily and weekly quota",
        reads: "The plan information Devin Desktop (formerly Windsurf) caches in ~/Library/Application Support/Devin/User/globalStorage/state.vscdb, or the Windsurf folder for older installs: the key windsurf.settings.cachedPlanInfo, read-only. Nothing is sent anywhere and no sign-in is read. The numbers are as fresh as Devin Desktop's last update.",
        source: "Devin Desktop's local plan cache",
        minimumRefreshInterval: 60,
        idleLabel: "Open Devin Desktop",
        documentation: URL(string: "https://docs.devin.ai/desktop/accounts/quota"),
        localSources: DevinProvider.databases.map { ToolStore(kind: .file, location: "~/\($0)") }
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        existingDatabases(in: context).isEmpty ? .unavailable("Devin Desktop is not installed") : .available
    }

    /// The installed databases, most recently written first.
    private func existingDatabases(in context: ProviderContext) -> [URL] {
        Self.databases.map { context.home.appendingPathComponent($0) }
            .filter { context.local.fileExists($0) }
            .sorted { lastWrite($0, context) > lastWrite($1, context) }
    }

    private func lastWrite(_ database: URL, _ context: ProviderContext) -> Date {
        let wal = URL(fileURLWithPath: database.path + "-wal")
        return [context.local.modificationDate(of: database), context.local.modificationDate(of: wal)].compactMap { $0 }.max() ?? .distantPast
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let databases = existingDatabases(in: context)
        guard !databases.isEmpty else { throw ProviderError.notInstalled("Devin Desktop is not installed") }
        for database in databases {
            guard let text = try context.local.vscodeStateValue(database, key: Self.planKey) else { continue }
            guard let json = try? JSONValue(data: Data(text.utf8)) else {
                throw ProviderError.unexpectedResponse("Devin Desktop's cached plan isn't JSON.")
            }
            return try Self.snapshot(from: json, savedAt: lastWrite(database, context), now: context.now())
        }
        throw ProviderError.notSignedIn("Devin Desktop hasn't saved any plan information. Open Devin Desktop and sign in.")
    }

    /// `daily` and `weekly` windows from the cached plan. A window whose reset has passed since
    /// Devin Desktop saved it is shown as a fresh one, with a detail saying so.
    static func snapshot(from json: JSONValue, savedAt: Date, now: Date) throws -> ProviderSnapshot {
        guard let quota = json["quotaUsage"]?.objectValue else {
            throw ProviderError.unexpectedResponse("Devin Desktop's cached plan has no quotaUsage. Open Devin Desktop to update it.")
        }
        var readings: [Reading] = []
        for (id, name, label, prefix) in [("daily", "Daily quota", "Day", "daily"), ("weekly", "Weekly quota", "Week", "weekly")] {
            guard let remaining = quota["\(prefix)RemainingPercent"]?.doubleValue else { continue }
            let reset = DateParsing.epoch(quota["\(prefix)ResetAtUnix"]?.doubleValue)
            let hasReset = reset.map { $0 <= now } ?? false
            readings.append(Reading(
                id: id, name: name,
                value: .window(QuotaWindow(
                    usedPercent: hasReset ? 0 : max(0, min(100, Int((100 - remaining).rounded()))),
                    period: .named(prefix),
                    resetsAt: hasReset ? nil : reset
                )),
                meterLabel: label,
                detail: hasReset ? "New \(prefix) quota since Devin Desktop last updated" : nil,
                freshness: "As of Devin Desktop's update \(savedAt.formatted(.relative(presentation: .named)))"
            ))
        }
        guard !readings.isEmpty else {
            throw ProviderError.unexpectedResponse("Devin Desktop's cached plan has no daily or weekly quota.")
        }
        let plan = json["planName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            readings: readings,
            plan: plan,
            menuBar: .tightest,
            historyReadingID: readings.contains { $0.id == "weekly" } ? "weekly" : "daily",
            fetchedAt: savedAt == .distantPast ? now : min(savedAt, now)
        )
    }
}
