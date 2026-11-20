import Foundation

/// The providers the user showed or hid, as the app stored it in its preferences before
/// `config.json` existed. Read once to migrate those choices; never written by the app now.
struct HarnessVisibility: Equatable {
    /// The three providers the app had before providers became pluggable, in their old order.
    static let legacyProviders: [ProviderID] = [.codex, .claude, .grok]

    static let storageKey = "visibleHarnesses"
    static let knownKey = "knownHarnesses"

    private(set) var visible: Set<ProviderID>

    init(visible: Set<ProviderID> = Set(HarnessVisibility.legacyProviders)) {
        self.visible = visible.isEmpty ? Set(Self.legacyProviders) : visible
    }

    static func load(from defaults: UserDefaults) -> HarnessVisibility {
        guard let raw = defaults.string(forKey: storageKey), !raw.isEmpty else {
            return HarnessVisibility()
        }

        let parsed = decode(raw)
        if parsed.isEmpty {
            return HarnessVisibility()
        }

        let known = defaults.string(forKey: knownKey).map(decode) ?? [.codex, .claude]
        let newcomers = Set(Self.legacyProviders).subtracting(known)
        return HarnessVisibility(visible: parsed.union(newcomers))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(encode(visible), forKey: Self.storageKey)
        defaults.set(encode(Set(Self.legacyProviders)), forKey: Self.knownKey)
    }

    private static func decode(_ raw: String) -> Set<ProviderID> {
        Set(
            raw.split(separator: ",").map { ProviderID(String($0)) }
        )
    }

    private func encode(_ harnesses: Set<ProviderID>) -> String {
        Self.legacyProviders
            .filter { harnesses.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    func isVisible(_ harness: ProviderID) -> Bool {
        visible.contains(harness)
    }

    func canHide(_ harness: ProviderID) -> Bool {
        isVisible(harness) && visible.count > 1
    }

    mutating func set(_ harness: ProviderID, visible isVisible: Bool) {
        if isVisible {
            visible.insert(harness)
        } else if visible.count > 1 {
            visible.remove(harness)
        }
    }

    var logbookSubtitle: String {
        let names = Self.legacyProviders.filter { visible.contains($0) }.map(\.logbookName)
        return names.joined(separator: " + ") + " LOGBOOK"
    }

    var joinedTitles: String {
        Self.legacyProviders.filter { visible.contains($0) }.map(\.title).joined(separator: " + ")
    }
}

struct UsageSnapshot: Equatable {
    let planName: String
    let usedPercent: Int
    let resetDate: Date?
    let windowMinutes: Int?
    let lifetimeTokens: Int64?
    let dailyUsage: [DailyUsage]
    let creditBalance: String?
    var weeklyUsedPercent: Int? = nil

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var weeklyRemainingPercent: Int? {
        weeklyUsedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var windowLabel: String {
        // Named from the reported duration; no duration means no assumption about it.
        guard let windowMinutes else { return "current window" }
        if windowMinutes >= 10_080 { return "weekly" }
        if windowMinutes < 60 { return "\(windowMinutes)m" }
        return "\(windowMinutes / 60)h"
    }

    var tokensToday: Int64 {
        guard let today = dailyUsage.last(where: { Calendar.current.isDateInToday($0.date) }) else {
            return 0
        }
        return today.tokens
    }

    var lastSevenDays: [DailyUsage] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())

        return (0..<7).reversed().compactMap { offset -> DailyUsage? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            let tokens = dailyUsage.first(where: { calendar.isDate($0.date, inSameDayAs: date) })?.tokens ?? 0
            return DailyUsage(date: date, tokens: tokens)
        }
    }
}

extension UsageSnapshot {
    /// Codex's token figures as the token card shows them.
    var activity: TokenActivity {
        TokenActivity(dailyUsage: dailyUsage, lifetimeTokens: lifetimeTokens, credits: creditBalance)
    }
}

struct DailyUsage: Equatable, Identifiable {
    let date: Date
    let tokens: Int64

    var id: Date { date }
}

struct UsageHistoryEntry: Equatable, Identifiable {
    let date: Date
    let provider: ProviderID
    let tokens: Int64?
    let usedPercent: Int?

    var id: String {
        "\(date.timeIntervalSince1970)-\(provider.rawValue)"
    }
}

enum UsageHistoryRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var compactTitle: String {
        "\(rawValue)D"
    }
}

/// How amounts are written: `compact` ($12.4k, 1.5k credits) or `full` ($12,400.00, 1,500 credits).
enum AmountStyle: String, Codable, CaseIterable {
    case compact, full
}

enum UsageFormatters {
    private static let currencySymbols = ["USD": "$", "EUR": "€", "GBP": "£", "CNY": "¥", "JPY": "¥", "INR": "₹"]

    /// An amount with its unit: `$12.40`, `¥110.00`, `1,500 credits`, `12.4k tokens`.
    static func amount(_ amount: Amount, style: AmountStyle = .full) -> String {
        let number = style == .compact ? compactNumber(amount.value, currency: amount.unit.isCurrency) : fullNumber(amount.value, currency: amount.unit.isCurrency)
        switch amount.unit {
        case .currency(let code):
            if let symbol = currencySymbols[code.uppercased()] {
                return amount.value < 0 ? "-\(symbol)\(number.dropFirst())" : "\(symbol)\(number)"
            }
            return "\(number) \(code.uppercased())"
        default:
            return "\(number) \(amount.unit.code)"
        }
    }

    /// The menu bar's shortest form: `$12.40`, `$1.2k`, `1.5k`. Units other than money are left
    /// out to keep the row narrow; the panel and the spoken text say them.
    static func menuAmount(_ amount: Amount) -> String {
        let number = compactNumber(amount.value, currency: amount.unit.isCurrency)
        if case .currency(let code) = amount.unit, let symbol = currencySymbols[code.uppercased()] {
            return "\(symbol)\(number)"
        }
        return number
    }

    private static func compactNumber(_ value: Double, currency: Bool) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 10_000...: return String(format: "%.0fk", value / 1_000)
        case 1_000...: return String(format: "%.1fk", value / 1_000)
        default:
            if currency { return String(format: "%.2f", value) }
            return value.rounded() == value ? String(Int64(value)) : String(format: "%.1f", value)
        }
    }

    private static func fullNumber(_ value: Double, currency: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = currency ? 2 : 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func tokens(_ count: Int64?) -> String {
        guard let count else { return "—" }

        switch count {
        case 1_000_000_000...:
            return String(format: "%.2fB", Double(count) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(count) / 1_000)
        default:
            return count.formatted()
        }
    }

    static func plan(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Codex" }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "Reset time unavailable" }
        return "Resets \(date.formatted(.relative(presentation: .named))) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func resetCompact(_ date: Date?) -> String {
        guard let date else { return "Reset —" }
        if date <= Date() { return "Refresh needed" }
        return date.formatted(.relative(presentation: .named))
    }

    static func credits(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned) else { return raw }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = abs(value - value.rounded()) < 0.005 ? 0 : 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? raw
    }
}
