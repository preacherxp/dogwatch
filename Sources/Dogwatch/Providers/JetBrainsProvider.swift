import SwiftUI

// JetBrains AI (AI Assistant and Junie): the quota the IDE saves in
// `<config>/options/AIAssistantQuotaManager2.xml`, under
// ~/Library/Application Support/JetBrains/<IDE><version>/ (and .../Google/<Android Studio>/).
// A local file only: nothing is sent anywhere, and no IDE is started.
//
// Plans (https://www.jetbrains.com/help/ai-assistant/licensing-and-subscriptions.html, read
// 2026-11-19): AI credits per 30 days from first use (AI Free, Pro, Ultimate; 1 credit = $1),
// purchased top-up credits valid 12 months and spent only after the monthly quota is used up.
//
// File format: JetBrains doesn't document it. Two `<option name=… value=…/>` entries hold
// HTML-escaped JSON:
// - `quotaInfo`: `{type: "Available", current, maximum, until, tariffQuota {current, maximum,
//   available}, topUpQuota {current, maximum, available}}`, numbers as strings;
// - `nextRefill`: `{type: "Known", next (ISO 8601), tariff {amount, duration}}`.
// Units are 100,000 per AI credit. This shape and scale come from CodexBar's reader
// (https://github.com/steipete/CodexBar, docs/jetbrains.md and JetBrainsStatusProbe.swift, read
// 2026-11-19). On this Mac the file exists but the account has no AI licence
// (`quotaInfo.type` "Unknown", `nextRefill.type` "Error"), so the "Available" shape has never
// been checked here: the provider is labelled unverified.
// The IDE persists this file rarely; it can lag behind the IDE's own counter. The fresher
// `idea.log` records are not read.

struct JetBrainsProvider: UsageProvider {
    /// Quota units per AI credit.
    static let unitsPerCredit = 100_000.0
    static let fileName = "AIAssistantQuotaManager2.xml"
    static let vendorFolders = ["Library/Application Support/JetBrains", "Library/Application Support/Google"]

    let descriptor = ProviderDescriptor(
        id: "jetbrains",
        name: "JetBrains AI",
        glyph: ProviderGlyph(symbol: "sparkles.rectangle.stack"),
        tint: Color(red: 0.98, green: 0.35, blue: 0.55),
        category: .subscription,
        stability: .unverified,
        credential: .none,
        summary: "AI Assistant and Junie monthly AI credits and top-ups",
        reads: "The newest options/AIAssistantQuotaManager2.xml under ~/Library/Application Support/JetBrains/<IDE> or ~/Library/Application Support/Google/<Android Studio>, which the IDE writes. Only the quota and refill entries are read. Nothing is sent anywhere, and no IDE is started.",
        source: "The IDE's saved AI quota (local file)",
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        idleLabel: "Open a JetBrains IDE",
        documentation: URL(string: "https://www.jetbrains.com/help/ai-assistant/licensing-and-subscriptions.html"),
        timeout: 10,
        localSources: [ToolStore(kind: .file, location: "~/Library/Application Support/JetBrains/*/options/AIAssistantQuotaManager2.xml")]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        Self.newestQuotaFile(in: context) == nil ? .unavailable("No JetBrains IDE with AI Assistant found") : .available
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let file = Self.newestQuotaFile(in: context) else {
            throw ProviderError.notInstalled("No JetBrains IDE with AI Assistant found.")
        }
        guard let data = try? context.local.read(file.url), let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.unexpectedResponse("\(file.ide)'s AI quota file could not be read.")
        }
        var snapshot = try Self.snapshot(fromXML: text, now: context.now())
        let saved = file.modified.formatted(.relative(presentation: .named))
        snapshot.note = [snapshot.note, "Saved by \(file.ide) \(saved)"].compactMap { $0 }.joined(separator: " · ")
        return snapshot
    }

    /// The most recently modified quota file among the IDE configuration folders, with the
    /// folder's name ("IntelliJIdea2026.2") as the IDE.
    static func newestQuotaFile(in context: ProviderContext) -> (url: URL, ide: String, modified: Date)? {
        var newest: (url: URL, ide: String, modified: Date)?
        for vendor in vendorFolders {
            let root = context.home.appendingPathComponent(vendor, isDirectory: true)
            for folderURL in context.local.contents(of: root) {
                let folder = folderURL.lastPathComponent
                let url = folderURL.appendingPathComponent("options").appendingPathComponent(fileName)
                guard context.local.fileExists(url) else { continue }
                let modified = context.local.modificationDate(of: url) ?? .distantPast
                if newest.map({ modified > $0.modified }) ?? true { newest = (url, folder, modified) }
            }
        }
        return newest
    }

    /// The JSON in `<option name="…" value="…"/>`, unescaped.
    static func option(_ name: String, in xml: String) -> JSONValue? {
        let pattern = #"<option\s+name="\#(name)"\s+value="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        let raw = String(xml[range])
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return try? JSONValue(data: Data(raw.utf8))
    }

    /// Readings:
    /// - `monthly`: the subscription's AI credits for the current 30-day cycle, as a window;
    /// - `top_up`: purchased credits left, as a balance without a total (JetBrains spends them
    ///   only after the monthly quota, so a share of them would mean nothing).
    static func snapshot(fromXML xml: String, now: Date) throws -> ProviderSnapshot {
        guard let quota = option("quotaInfo", in: xml) else {
            throw ProviderError.unexpectedResponse("JetBrains' quota file has no quotaInfo.")
        }
        let type = quota["type"]?.stringValue
        if type == "Unknown" {
            throw ProviderError.notSignedIn("JetBrains AI has no quota on this Mac: no AI licence, or AI Assistant hasn't been used.")
        }
        guard type == "Available" else {
            throw ProviderError.unexpectedResponse("JetBrains' quota file says \(type.map { "“\($0)”" } ?? "nothing") instead of an available quota.")
        }

        // The monthly quota, never mixed with totals that include top-ups.
        let tariff = quota["tariffQuota"]
        let monthly: (used: Double, maximum: Double)?
        if let used = finite(tariff?["current"]), let maximum = finite(tariff?["maximum"]) {
            monthly = (used, maximum)
        } else if tariff == nil, let used = finite(quota["current"]), let maximum = finite(quota["maximum"]) {
            monthly = (used, maximum)
        } else {
            monthly = nil
        }
        guard let monthly, monthly.maximum > 0, monthly.used >= 0 else {
            throw ProviderError.unexpectedResponse("JetBrains' quota file has no monthly current and maximum.")
        }

        let refill = option("nextRefill", in: xml)
        let reset = refill?["type"]?.stringValue == "Known" ? DateParsing.date(refill?["next"]) : nil
        let usedPercent = Int((min(monthly.used, monthly.maximum) / monthly.maximum * 100).rounded())
        var readings = [Reading(
            id: "monthly",
            name: "Monthly credits",
            value: .window(QuotaWindow(
                usedPercent: usedPercent,
                period: .named("30 days"),
                resetsAt: reset.flatMap { $0 > now ? $0 : nil },
                used: Amount(value: monthly.used / unitsPerCredit, unit: .credits),
                limit: Amount(value: monthly.maximum / unitsPerCredit, unit: .credits)
            )),
            meterLabel: "Month"
        )]

        if let topUp = quota["topUpQuota"], let maximum = finite(topUp["maximum"]), maximum > 0,
           let available = finite(topUp["available"]), available >= 0 {
            readings.append(Reading(
                id: "top_up",
                name: "Top-up credits",
                value: .balance(Balance(remaining: Amount(value: min(available, maximum) / unitsPerCredit, unit: .credits)))
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            primaryHint: "monthly",
            historyReadingID: "monthly",
            fetchedAt: now
        )
    }

    private static func finite(_ value: JSONValue?) -> Double? {
        value?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }
}
