import Foundation

// Shared pieces for API providers whose figure is spend reported as daily rows: UTC periods,
// money conversion, a currency-safe total, capped cursor paging and the spend readings.
// Added by the spend-report batch (OpenAI, Anthropic API, Together, Fireworks, DeepInfra,
// Mistral API, Hugging Face). Nothing here touches the network itself; providers pass a fetch.

/// Calendar periods in UTC, which is how every spend report in this batch cuts its days and months.
enum SpendPeriod {
    /// The UTC calendar month containing `date`: its start, and the start of the next month.
    static func month(containing date: Date) -> DateInterval {
        let calendar = Calendar.utc
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }

    /// The UTC day containing `date`.
    static func day(containing date: Date) -> DateInterval {
        let start = Calendar.utc.startOfDay(for: date)
        return DateInterval(start: start, end: Calendar.utc.date(byAdding: .day, value: 1, to: start)!)
    }

    /// `2026-11-01T00:00:00Z`.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `2026-11-19`, the UTC date.
    static func ymd(_ date: Date) -> String {
        let components = Calendar.utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    /// `2026-11`, the UTC month.
    static func yearMonth(_ date: Date, separator: String = "-") -> String {
        let components = Calendar.utc.dateComponents([.year, .month], from: date)
        return String(format: "%04d%@%02d", components.year!, separator, components.month!)
    }

    /// Seconds since 1970, as a whole number for query strings.
    static func unix(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970)) }
}

/// Money as the providers send it, converted once into whole currency units.
enum Money {
    /// Minor units (cents) as a number or a decimal string, such as Anthropic's `"123.45"` = $1.2345.
    static func fromCents(_ value: JSONValue?) -> Double? {
        value?.doubleValue.map { $0 / 100 }
    }

    /// Google-style money: whole `units` (often a string) plus `nanos` (10^-9 units).
    /// `{"units": "12", "nanos": 340000000}` is 12.34. Missing parts count as zero only when the
    /// other part is present.
    static func fromUnitsAndNanos(_ object: JSONValue?) -> Double? {
        guard let object, object.objectValue != nil else { return nil }
        let units = object["units"]?.doubleValue
        let nanos = object["nanos"]?.doubleValue
        guard units != nil || nanos != nil else { return nil }
        return (units ?? 0) + (nanos ?? 0) / 1_000_000_000
    }
}

/// Adds amounts of one currency. Adding a second currency is an error rather than a wrong sum.
struct MoneyTotal: Equatable {
    private(set) var value: Double = 0
    private(set) var currency: String?
    private(set) var rows = 0

    init(currency: String? = nil) {
        self.currency = currency?.uppercased()
    }

    mutating func add(_ amount: Double, currency rowCurrency: String?, provider: String) throws {
        if let code = rowCurrency?.uppercased(), !code.isEmpty {
            if let currency, currency != code {
                throw ProviderError.unexpectedResponse("\(provider) reported costs in both \(currency) and \(code); Dogwatch won't add them together.")
            }
            currency = code
        }
        value += amount
        rows += 1
    }

    /// The total in its currency, or in `fallback` when no row named one.
    func amount(fallback: String = "USD") -> Amount {
        Amount(value: (value * 1_000_000).rounded() / 1_000_000, unit: .currency(currency ?? fallback))
    }
}

/// Pages of a report fetched by following a cursor, with a cap so a runaway cursor can't loop.
struct PagedReport {
    var pages: [JSONValue]
    /// More pages existed than the cap allowed: totals from these pages are incomplete.
    var truncated: Bool

    /// Fetches `first`, then whatever `next` returns for each page, until it returns nil or
    /// `maxPages` pages have been read.
    static func collect(
        first: URL,
        maxPages: Int,
        fetch: (URL) async throws -> JSONValue,
        next: (JSONValue) -> URL?
    ) async throws -> PagedReport {
        var pages: [JSONValue] = []
        var url: URL? = first
        while let current = url {
            if pages.count == maxPages { return PagedReport(pages: pages, truncated: true) }
            try Task.checkCancellation()
            let page = try await fetch(current)
            pages.append(page)
            url = next(page)
        }
        return PagedReport(pages: pages, truncated: false)
    }

    /// `base` with `name=value` set (replacing any earlier value), for cursor parameters.
    static func url(_ base: URL, setting name: String, to value: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url
    }
}

extension Reading {
    /// Spend over a named period. `truncated` marks a total read from a report that was cut off:
    /// the name and detail say so, so a partial sum is never shown as the whole.
    static func spendReading(
        id: String,
        name: String,
        amount: Amount,
        period: String,
        budget: Amount? = nil,
        resetsAt: Date? = nil,
        freshness: String? = nil,
        truncated: Bool = false
    ) -> Reading {
        Reading(
            id: id,
            name: truncated ? "\(name) (incomplete)" : name,
            value: .spend(Spend(amount: amount, period: period, budget: budget, resetsAt: resetsAt)),
            detail: truncated ? "At least \(UsageFormatters.amount(amount)) spent · \(period) · report cut off" : nil,
            freshness: freshness,
            // A cut-off total is never a percentage, even with a budget.
            isIncomplete: truncated
        )
    }
}

/// Validates a non-secret identifier that goes into a URL path (account id, organisation name),
/// so a stray slash or space can't change which endpoint is called.
enum PathIdentifier {
    static func validated(_ raw: String?, field: String, provider: String) throws -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ProviderError.notConfigured("Add your \(provider) \(field) in its settings.")
        }
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw ProviderError.notConfigured("The \(provider) \(field) may only contain letters, digits, dots, hyphens and underscores.")
        }
        return value
    }
}
