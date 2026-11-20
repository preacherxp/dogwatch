import SwiftUI

// Grok: the newest "billing: fetched credits config" line in Grok's own log. Grok writes it when
// you run /usage. This is a passive read of a local file and must stay that way: starting the
// Grok CLI to ask for billing can make it refresh an expired login and, when that fails, delete
// ~/.grok/auth.json. Dogwatch never starts Grok and never calls Grok's servers.
//
// The line's `ctx.config` carries `creditUsagePercent`, `currentPeriod {type, start, end}` and
// `prepaidBalance {val}` in cents (structure checked on this Mac's log, 2026-11-19; Grok
// documents none of it, see `grok --help`). The prepaid balance is its own balance reading.

struct GrokProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: .grok,
        name: "Grok",
        glyph: ProviderGlyph(symbol: "bolt.fill", themed: [.ledger: "bolt", .cyber: "bolt.horizontal.fill"]),
        tint: Bridge.sky,
        category: .subscription,
        stability: .undocumented,
        credential: .none,
        summary: "Grok Build weekly credits and prepaid balance",
        reads: "The last 1 MB of ~/.grok/logs/unified.jsonl (or $GROK_HOME/logs/unified.jsonl), for the newest “billing: fetched credits config” line. Nothing is sent anywhere, and Grok is never started.",
        source: "Grok's local log (written when you run /usage)",
        minimumRefreshInterval: 30,
        idleLabel: "Open Grok",
        localSources: [ToolStore(kind: .file, location: "~/.grok/logs/unified.jsonl")]
    )

    func logURL(in context: ProviderContext) -> URL {
        let home: URL
        if let grokHome = context.local.environment["GROK_HOME"], !grokHome.isEmpty {
            home = URL(fileURLWithPath: grokHome, isDirectory: true)
        } else {
            home = context.home.appendingPathComponent(".grok")
        }
        return home.appendingPathComponent("logs/unified.jsonl")
    }

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.fileExists(logURL(in: context)) ? .available : .unavailable("Grok is not installed, or /usage was never run")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        do {
            return Self.snapshot(from: try GrokUsageClient(logURL: logURL(in: context)).fetch())
        } catch GrokUsageError.cacheNotFound {
            throw ProviderError.notSignedIn(GrokUsageError.cacheNotFound.localizedDescription)
        } catch {
            throw ProviderError.unexpectedResponse(GrokUsageError.unreadableCache.localizedDescription)
        }
    }

    /// Readings: `credits`, the plan's credit window (primary), and `prepaid`, the prepaid
    /// balance in dollars when the log reports one.
    static func snapshot(from grok: GrokUsageSnapshot) -> ProviderSnapshot {
        var readings = [Reading(
            id: "credits",
            name: grok.periodLabel,
            value: .window(QuotaWindow(usedPercent: grok.usedPercent, period: .named(grok.periodLabel), resetsAt: grok.resetDate)),
            detail: grok.isWindowExpired ? "Window ended · run /usage" : nil
        )]
        if let dollars = grok.prepaidDollars {
            readings.append(Reading(
                id: "prepaid",
                name: "Prepaid balance",
                value: .balance(Balance(remaining: Amount(value: dollars, unit: .currency("USD"))))
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            plan: grok.planName,
            label: grok.isWindowExpired ? "Refresh needed" : grok.planName,
            primaryHint: "credits",
            historyReadingID: "credits",
            fetchedAt: grok.fetchedAt
        )
    }
}

struct GrokUsageSnapshot: Equatable {
    let usedPercent: Int
    let resetDate: Date?
    let periodLabel: String
    let planName: String
    let prepaidBalance: String?
    let fetchedAt: Date
    /// The prepaid balance in dollars, from the same cents as `prepaidBalance`.
    var prepaidDollars: Double? = nil

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var isWindowExpired: Bool {
        guard let resetDate else { return false }
        return resetDate <= Date()
    }
}

enum GrokUsageError: LocalizedError {
    case cacheNotFound
    case unreadableCache

    var errorDescription: String? {
        switch self {
        case .cacheNotFound:
            return "Open Grok and run /usage to publish credits."
        case .unreadableCache:
            return "Grok usage log could not be read."
        }
    }
}

final class GrokUsageClient {
    private let logURL: URL

    init(logURL: URL? = nil) {
        if let logURL {
            self.logURL = logURL
        } else {
            let home: URL
            if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
                home = URL(fileURLWithPath: grokHome, isDirectory: true)
            } else {
                home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
            }
            self.logURL = home.appendingPathComponent("logs/unified.jsonl")
        }
    }

    func fetch() throws -> GrokUsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: logURL.path) else {
            throw GrokUsageError.cacheNotFound
        }

        do {
            guard let record = try Self.lastBillingRecord(in: logURL) else {
                throw GrokUsageError.cacheNotFound
            }
            let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
            let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
            return try Self.parse(context: record.context, fetchedAt: record.timestamp ?? modifiedAt)
        } catch let error as GrokUsageError {
            throw error
        } catch {
            throw GrokUsageError.unreadableCache
        }
    }

    static func parse(context: [String: Any], fetchedAt: Date = Date()) throws -> GrokUsageSnapshot {
        let config = context["config"] as? [String: Any] ?? context
        let usedPercent = usedPercent(in: config)
        guard let usedPercent else {
            throw GrokUsageError.unreadableCache
        }

        let period = config["currentPeriod"] as? [String: Any]
        let resetRaw = (period?["end"] as? String)
            ?? (config["billingPeriodEnd"] as? String)
        let periodType = period?["type"] as? String
        let plan = (context["subscriptionTier"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Grok"

        return GrokUsageSnapshot(
            usedPercent: max(0, min(100, usedPercent)),
            resetDate: parseDate(resetRaw),
            periodLabel: periodLabel(from: periodType),
            planName: plan,
            prepaidBalance: prepaidBalance(in: config),
            fetchedAt: fetchedAt,
            prepaidDollars: cent(config["prepaidBalance"]).map { Double($0) / 100 }
        )
    }

    static func lastBillingRecord(in url: URL) throws -> (context: [String: Any], timestamp: Date?)? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }

        let window = min(size, 1_048_576)
        try handle.seek(toOffset: size - window)
        let data = handle.readDataToEndOfFile()
        return lastBillingRecord(in: data)
    }

    static func lastBillingRecord(in data: Data) -> (context: [String: Any], timestamp: Date?)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("billing: fetched credits config"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["msg"] as? String == "billing: fetched credits config",
                  let context = object["ctx"] as? [String: Any]
            else { continue }
            return (context, parseDate(object["ts"] as? String))
        }
        return nil
    }

    private static func usedPercent(in config: [String: Any]) -> Int? {
        if let value = number(config["creditUsagePercent"]) {
            return Int(value.rounded())
        }

        if let used = cent(config["used"]), let limit = cent(config["monthlyLimit"]), limit > 0 {
            return Int((Double(used) / Double(limit) * 100).rounded())
        }

        if let used = cent(config["onDemandUsed"]), let limit = cent(config["onDemandCap"]), limit > 0 {
            return Int((Double(used) / Double(limit) * 100).rounded())
        }

        return nil
    }

    private static func prepaidBalance(in config: [String: Any]) -> String? {
        guard let cents = cent(config["prepaidBalance"]) else { return nil }
        return String(format: "$%.2f", Double(cents) / 100)
    }

    private static func periodLabel(from type: String?) -> String {
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": return "weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "monthly"
        default: return "credits"
        }
    }

    private static func cent(_ value: Any?) -> Int64? {
        if let value = number(value) { return Int64(value.rounded()) }
        guard let object = value as? [String: Any] else { return nil }
        return number(object["val"]).map { Int64($0.rounded()) }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }

        return formatter.date(from: raw.replacingOccurrences(of: "+00:00", with: "Z"))
    }
}
