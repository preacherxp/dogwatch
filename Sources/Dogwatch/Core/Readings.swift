import Foundation

/// What an amount is counted in.
enum AmountUnit: Equatable, Hashable, Codable {
    /// An ISO 4217 code such as `USD`.
    case currency(String)
    case credits
    case tokens
    case requests
    /// Anything else, named as the provider names it: "messages", "minutes".
    case custom(String)

    /// Parses `USD`, `credits`, `tokens`, `requests`, or any other word as a custom unit.
    init(_ text: String) {
        switch text.lowercased() {
        case "credits": self = .credits
        case "tokens": self = .tokens
        case "requests": self = .requests
        default:
            if text.count == 3, text.uppercased() == text, text.allSatisfy(\.isLetter) {
                self = .currency(text)
            } else {
                self = .custom(text)
            }
        }
    }

    var isCurrency: Bool { if case .currency = self { return true } else { return false } }

    var code: String {
        switch self {
        case .currency(let code): return code
        case .credits: return "credits"
        case .tokens: return "tokens"
        case .requests: return "requests"
        case .custom(let name): return name
        }
    }

    init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

struct Amount: Equatable {
    var value: Double
    var unit: AmountUnit
}

/// The span a quota window covers, as the provider defines it.
enum WindowPeriod: Equatable {
    case duration(TimeInterval)
    /// A period the provider names rather than measures: "weekly", "billing period", "Fable weekly".
    case named(String)

    var label: String {
        switch self {
        case .named(let name): return name
        case .duration(let seconds):
            let minutes = Int(seconds / 60)
            if minutes >= 10_080 { return "weekly" }
            if minutes < 60 { return "\(minutes)m" }
            return "\(minutes / 60)h"
        }
    }
}

/// A limit that resets: a share of it is used, the rest is left until `resetsAt`.
struct QuotaWindow: Equatable {
    /// Whole percent used, as the provider reports it or computed from `used` and `limit`.
    var usedPercent: Int
    var period: WindowPeriod
    var resetsAt: Date?
    var used: Amount? = nil
    var limit: Amount? = nil
    /// False for a window the provider counts but gives no total for (Copilot's monthly AI
    /// credits): `used` is known, `usedPercent` is meaningless and ignored, and the window has a
    /// percentage only once the user types a total for it.
    var isMetered = true

    /// A window with a known amount used and no published total. Shown as the amount used until
    /// the user types a total.
    static func unmetered(used: Amount, period: WindowPeriod, resetsAt: Date?) -> QuotaWindow {
        QuotaWindow(usedPercent: 0, period: period, resetsAt: resetsAt, used: used, limit: nil, isMetered: false)
    }
}

/// Money or credits left: prepaid credit, a key's remaining limit.
struct Balance: Equatable {
    var remaining: Amount
    /// What the balance is out of. With it, the balance is also a percentage; without it, only an amount.
    var total: Amount? = nil
    /// When it refills, for budgets that reset (a weekly key limit).
    var resetsAt: Date? = nil
}

/// Money spent over a period, optionally against a budget.
struct Spend: Equatable {
    var amount: Amount
    /// "this month", "today", "billing period".
    var period: String? = nil
    var budget: Amount? = nil
    var resetsAt: Date? = nil
}

/// One number a provider reports. A snapshot usually carries several.
struct Reading: Identifiable, Equatable {
    enum Value: Equatable {
        case window(QuotaWindow)
        case balance(Balance)
        case spend(Spend)
    }

    /// Stable within the provider, so configuration and history can refer to it: `five_hour`,
    /// `seven_day`, `credits`, `model:fable`.
    let id: String
    /// What the reading is, shown as the card's label when it is the primary: "5h session".
    var name: String
    var value: Value
    /// The short label used when the reading is shown as a second meter: "Week".
    var meterLabel: String? = nil
    /// Replaces the generated detail line, for states the numbers alone don't explain:
    /// "New 5h window · starts with your next message".
    var detail: String? = nil
    /// The provider says this is the limit the user is hitting now, such as Claude's
    /// `limits[].is_active`. A binding reading is the default primary.
    var isBinding: Bool = false
    /// How fresh the data is when the provider lags: "Complete through yesterday".
    var freshness: String? = nil
    /// False for a reading that must never be the headline number: not the default primary and
    /// not counted by `menuBar: .tightest` or the menu bar's "lowest". Use it for a cap that isn't
    /// the plan's own limit, such as Claude's optional extra-usage spend. The user can still pick
    /// it as the primary.
    var canHeadline = true
    /// The total is known to be short, such as a spend report cut off after its last page. An
    /// incomplete reading never becomes a percentage, whatever budget it has.
    var isIncomplete = false

    var window: QuotaWindow? { if case .window(let window) = value { return window } else { return nil } }
    var balance: Balance? { if case .balance(let balance) = value { return balance } else { return nil } }
    var spend: Spend? { if case .spend(let spend) = value { return spend } else { return nil } }

    /// Percentage left, only when it can be computed from real numbers: a window's used
    /// percentage, a balance out of a known total, or spend against a budget. Never guessed.
    var remainingPercent: Int? {
        if isIncomplete { return nil }
        switch value {
        case .window(let window):
            guard window.isMetered else { return nil }
            return max(0, min(100, 100 - window.usedPercent))
        case .balance(let balance):
            guard let total = balance.total, total.value > 0, total.unit == balance.remaining.unit else { return nil }
            return max(0, min(100, Int((balance.remaining.value / total.value * 100).rounded())))
        case .spend(let spend):
            guard let budget = spend.budget, budget.value > 0, budget.unit == spend.amount.unit else { return nil }
            return max(0, min(100, Int(((budget.value - spend.amount.value) / budget.value * 100).rounded())))
        }
    }

    var resetsAt: Date? {
        switch value {
        case .window(let window): return window.resetsAt
        case .balance(let balance): return balance.resetsAt
        case .spend(let spend): return spend.resetsAt
        }
    }

    /// The amount to show when there is no percentage: a balance left, or money spent.
    var amount: Amount? {
        switch value {
        case .window(let window): return window.isMetered ? nil : window.used
        case .balance(let balance): return balance.remaining
        case .spend(let spend): return spend.amount
        }
    }

    /// The detail line under the provider's name when this reading is the primary.
    var detailText: String {
        if let detail { return detail }
        switch value {
        case .window(let window):
            guard window.isMetered else {
                return "\(window.used.map { UsageFormatters.amount($0) } ?? "Some") used · \(window.period.label)"
            }
            return "\(window.usedPercent)% used · \(window.period.label)"
        case .balance(let balance):
            let left = UsageFormatters.amount(balance.remaining)
            if let total = balance.total { return "\(left) of \(UsageFormatters.amount(total)) left" }
            return "\(left) left"
        case .spend(let spend):
            let spent = UsageFormatters.amount(spend.amount)
            let period = spend.period.map { " · \($0)" } ?? ""
            if let budget = spend.budget, !isIncomplete { return "\(spent) of \(UsageFormatters.amount(budget)) spent\(period)" }
            return "\(spent) spent\(period)"
        }
    }
}

/// Exact token counts for providers that report them, shown as the token card and recorded
/// in history.
struct TokenActivity: Equatable {
    var dailyUsage: [DailyUsage]
    var lifetimeTokens: Int64?
    /// A credit balance the provider reports as text, shown as reported.
    var credits: String?

    var tokensToday: Int64 {
        dailyUsage.last(where: { Calendar.current.isDateInToday($0.date) })?.tokens ?? 0
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

/// What the menu bar shows for a provider.
enum MenuBarPick: String, Codable, Equatable {
    /// The primary reading.
    case primary
    /// The lowest percentage left among the provider's readings: never overstates.
    case tightest
}

/// Everything one fetch returned.
struct ProviderSnapshot: Equatable {
    var readings: [Reading]
    /// The plan as the provider names it: "Plus", "X Premium+".
    var plan: String? = nil
    /// Replaces the small label next to the provider's name. Defaults to the plan, then the
    /// primary reading's name.
    var label: String? = nil
    /// A line shown when there are no readings, or under them.
    var note: String? = nil
    /// The reading the provider shows by default. Without it, the one that runs out first.
    var primaryHint: String? = nil
    var menuBar: MenuBarPick = .primary
    var activity: TokenActivity? = nil
    /// The reading recorded as the provider's line in the history chart. Defaults to the primary.
    var historyReadingID: String? = nil
    var fetchedAt: Date = Date()

    /// The primary reading: the configured one if it exists, else the provider's hint, else a
    /// binding reading, else the window with the least left, else the first balance, else the
    /// first spend.
    func primary(override: String? = nil) -> Reading? {
        if let override, let reading = readings.first(where: { $0.id == override }) { return reading }
        if let primaryHint, let reading = readings.first(where: { $0.id == primaryHint }) { return reading }
        let eligible = readings.filter(\.canHeadline)
        if let binding = eligible.filter(\.isBinding).min(by: Self.lessLeft) { return binding }
        if let window = eligible.filter({ $0.window != nil }).min(by: Self.lessLeft) { return window }
        return eligible.first(where: { $0.balance != nil }) ?? eligible.first(where: { $0.spend != nil }) ?? readings.first
    }

    /// The lowest percentage left among readings that have one.
    var tightestRemainingPercent: Int? {
        readings.filter(\.canHeadline).compactMap(\.remainingPercent).min()
    }

    /// Applies totals the user typed in settings, for readings whose provider publishes none
    /// (Copilot's monthly credits, a budget for API spend). A user total turns an unmetered
    /// window, a bare balance or spend into a percentage; it never replaces a total the provider
    /// reported, and never makes an incomplete reading a percentage.
    func applying(userLimits: [String: Double]) -> ProviderSnapshot {
        guard !userLimits.isEmpty else { return self }
        var copy = self
        copy.readings = readings.map { reading in
            guard let limit = userLimits[reading.id], limit > 0 else { return reading }
            var reading = reading
            switch reading.value {
            case .window(var window) where !window.isMetered:
                guard let used = window.used else { break }
                window.limit = Amount(value: limit, unit: used.unit)
                window.usedPercent = max(0, min(100, Int((used.value / limit * 100).rounded())))
                window.isMetered = true
                reading.value = .window(window)
            case .balance(var balance) where balance.total == nil:
                balance.total = Amount(value: limit, unit: balance.remaining.unit)
                reading.value = .balance(balance)
            case .spend(var spend) where spend.budget == nil:
                spend.budget = Amount(value: limit, unit: spend.amount.unit)
                reading.value = .spend(spend)
            default:
                break
            }
            return reading
        }
        return copy
    }

    /// Readings other than the primary, in the provider's order.
    func secondary(override: String? = nil) -> [Reading] {
        let primary = primary(override: override)
        return readings.filter { $0.id != primary?.id }
    }

    private static func lessLeft(_ lhs: Reading, _ rhs: Reading) -> Bool {
        (lhs.remainingPercent ?? 101) < (rhs.remainingPercent ?? 101)
    }
}
