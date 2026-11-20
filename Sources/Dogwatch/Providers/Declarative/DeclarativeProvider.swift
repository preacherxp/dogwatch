import SwiftUI

/// A provider described as data: one HTTPS GET with the key in a header, and JSON paths to the
/// numbers. The user's custom providers use it, and so can built-in providers whose API is one
/// flat JSON answer (`DeclarativeProviders`). Anything that needs several requests, sums over
/// arrays or pages, or a sign or shape decision is a Swift provider instead.
///
/// The format, as written in `config.json` under `customProviders`:
///
/// ```json
/// {
///   "id": "custom-novita",
///   "name": "Novita AI",
///   "url": "https://api.novita.ai/openapi/v1/billing/balance/detail",
///   "headers": { "Authorization": "Bearer {key}" },
///   "okWhen": { "path": "base_resp.status_code", "equals": 0 },
///   "errorMessage": "base_resp.status_msg",
///   "readings": [
///     { "id": "balance", "name": "Balance", "kind": "balance",
///       "remaining": "availableBalance", "unit": "USD", "scale": 0.0001 }
///   ],
///   "refreshMinutes": 5
/// }
/// ```
struct CustomProviderSpec: Equatable {
    enum Kind: String { case window, balance, spend }
    enum DateFormat: String { case auto, iso8601, unixSeconds, unixMs }

    struct ReadingSpec: Equatable {
        var id: String
        var name: String
        var kind: Kind
        /// Window: a used percentage (0–100, or a 0–1 fraction with `fraction: true`)…
        var usedPercent: String?
        /// …or a remaining percentage (0–100, or a fraction with `fraction: true`)…
        var remainingPercent: String?
        var fraction = false
        /// …or used and limit, or remaining and total, as amounts.
        var used: String?
        var limit: String?
        /// Balance: what is left, optionally of a total. Window: what is left of `total`.
        var remaining: String?
        var total: String?
        /// Spend: the amount spent, optionally against a budget.
        var amount: String?
        var budget: String?
        /// A unit (`USD`, `credits`, `points`), a JSON path to one (`$.currency`), or
        /// `{baseURL.unit}` for the unit of the chosen `baseURLs` entry.
        var unit: String = "USD"
        /// Multiplies every amount: 0.01 for cents, 0.0001 for 1/10,000 of a dollar.
        var scale: Double = 1
        /// Negates amounts, for APIs that count credit as negative.
        var flipSign = false
        var period: String?
        var reset: String?
        var resetFormat: DateFormat = .auto
        /// A value missing from the answer leaves this reading out instead of failing the fetch,
        /// for parts of an answer that come and go (a pass only some teams have, one of two shapes).
        var optional = false
        /// `null` counts as 0 instead of "none", for APIs that document "null when zero".
        var nullIsZero = false
        /// The short label when the reading is a second meter: "Week".
        var meterLabel: String?
    }

    /// Picks the primary reading from a value in the answer, such as the currency an account
    /// is currently spending: `{"path": "consumptionCurrency", "readings": {"USD": "usd"}}`.
    struct PrimaryFrom: Equatable {
        var path: String
        var readings: [String: String]
    }

    var id: ProviderID
    var name: String
    var url: String
    var headers: [String: String] = [:]
    var okWhen: (path: String, equals: JSONValue)?
    var errorMessagePath: String?
    var readings: [ReadingSpec]
    var primary: String?
    var primaryFrom: PrimaryFrom?
    var refreshMinutes: Double = 5
    /// Never fetched more often than this; at least 0.5 (30 seconds). Default 1.
    var minimumRefreshMinutes: Double = 1
    var keyLabel = "API key"
    var keyHelpURL: URL?
    var keyWarning: String?
    var keyAdvice: String?
    var keyPlaceholder = ""
    /// What the user pastes: `apiKey` (default), `adminKey`, `token` or `cookie`.
    var keyKind: KeySpec.Kind = .apiKey
    /// The provider's colour, `#RRGGBB`. Without it, one is picked from the id.
    var tint: (red: Double, green: Double, blue: Double)?
    var baseURLs: [BaseURLOption] = []
    /// The unit of each `baseURLs` entry that names one, keyed by the entry's host.
    var baseURLUnits: [String: String] = [:]
    /// The user may enter any base URL (a self-hosted gateway). `{baseURL}` then needs no
    /// `baseURLs`; the user's URL is used, or the first offered one.
    var customBaseURL = false
    var fields: [SettingField] = []
    var stability: ProviderStability = .unverified
    var category: ProviderCategory = .api
    var glyph = "gauge.with.dots.needle.33percent"
    var summary: String?
    var source: String?
    var documentation: URL?

    static func == (lhs: CustomProviderSpec, rhs: CustomProviderSpec) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.headers == rhs.headers && lhs.readings == rhs.readings
            && lhs.okWhen?.path == rhs.okWhen?.path && lhs.okWhen?.equals == rhs.okWhen?.equals
    }

    /// Whether the request needs a pasted key.
    var usesKey: Bool { headers.values.contains { $0.contains("{key}") } }

    /// Every host the URL can point at, with each offered base URL.
    var hosts: [String] {
        candidateURLs.compactMap { URL(string: Self.stripPlaceholders($0))?.host?.lowercased() }
    }

    /// The URL with each offered base URL filled in; none when only a user-entered base URL can fill it.
    var candidateURLs: [String] {
        if !baseURLs.isEmpty { return baseURLs.map { url.replacingOccurrences(of: "{baseURL}", with: $0.url.absoluteString) } }
        return url.contains("{baseURL}") ? [] : [url]
    }

    static let baseURLUnit = "{baseURL.unit}"

    private static func stripPlaceholders(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{field:[A-Za-z0-9_]+\}"#, with: "x", options: .regularExpression)
    }
}

enum CustomProviderError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message } else { return nil } }
}

extension CustomProviderSpec {
    /// Parses and validates a definition. Every problem is a readable error; nothing traps.
    init(json: JSONValue) throws {
        guard let object = json.objectValue else { throw CustomProviderError.invalid("A custom provider must be a JSON object.") }
        func string(_ key: String) -> String? { object[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

        guard let rawID = string("id") else { throw CustomProviderError.invalid("Needs an \"id\".") }
        let id = ProviderID(rawID)
        guard id.isValid else { throw CustomProviderError.invalid("\"\(rawID)\" is not a valid id: use a-z, 0-9 and -, starting with a letter.") }
        guard let name = string("name") else { throw CustomProviderError.invalid("\(rawID) needs a \"name\".") }
        guard let url = string("url") else { throw CustomProviderError.invalid("\(rawID) needs a \"url\".") }

        var headers: [String: String] = [:]
        for (key, value) in object["headers"]?.objectValue ?? [:] {
            guard let text = value.stringValue else { throw CustomProviderError.invalid("\(rawID): header \(key) must be text.") }
            headers[key] = text
        }

        var readings: [ReadingSpec] = []
        for (index, entry) in (object["readings"]?.arrayValue ?? []).enumerated() {
            readings.append(try ReadingSpec(json: entry, index: index, provider: rawID))
        }
        guard !readings.isEmpty else { throw CustomProviderError.invalid("\(rawID) needs at least one entry in \"readings\".") }
        guard Set(readings.map(\.id)).count == readings.count else { throw CustomProviderError.invalid("\(rawID): reading ids must be different.") }

        self.init(id: id, name: name, url: url, headers: headers, readings: readings)
        if let okWhen = object["okWhen"]?.objectValue {
            guard let path = okWhen["path"]?.stringValue, DeclarativePath.isValid(path), let equals = okWhen["equals"] else {
                throw CustomProviderError.invalid("\(rawID): okWhen needs a valid \"path\" and an \"equals\" value.")
            }
            self.okWhen = (path, equals)
        }
        if let path = string("errorMessage") {
            guard DeclarativePath.isValid(path) else { throw CustomProviderError.invalid("\(rawID): errorMessage is not a valid path.") }
            errorMessagePath = path
        }
        primary = string("primary")
        if let entry = object["primaryFrom"] {
            guard let path = entry["path"]?.stringValue, DeclarativePath.isValid(path), let map = entry["readings"]?.objectValue,
                  map.values.allSatisfy({ $0.stringValue != nil })
            else { throw CustomProviderError.invalid("\(rawID): primaryFrom needs a valid \"path\" and \"readings\" mapping values to reading ids.") }
            primaryFrom = PrimaryFrom(path: path, readings: map.compactMapValues(\.stringValue))
        }
        if let minutes = object["refreshMinutes"]?.doubleValue {
            guard minutes >= 1 else { throw CustomProviderError.invalid("\(rawID): refreshMinutes must be 1 or more.") }
            refreshMinutes = minutes
        }
        if let value = object["minimumRefreshMinutes"] {
            guard let minutes = value.doubleValue, minutes >= 0.5 else {
                throw CustomProviderError.invalid("\(rawID): minimumRefreshMinutes must be 0.5 or more.")
            }
            minimumRefreshMinutes = minutes
        }
        keyLabel = string("keyLabel") ?? keyLabel
        keyHelpURL = string("keyHelpURL").flatMap(URL.init(string:))
        keyWarning = string("keyWarning")
        keyAdvice = string("keyAdvice")
        keyPlaceholder = string("keyPlaceholder") ?? keyPlaceholder
        if let kind = string("keyKind") {
            guard let value = KeySpec.Kind(rawValue: kind) else {
                throw CustomProviderError.invalid("\(rawID): keyKind must be apiKey, adminKey, token or cookie.")
            }
            keyKind = value
        }
        if let hex = string("tint") {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
                throw CustomProviderError.invalid("\(rawID): tint must be a colour such as #3FA7D6.")
            }
            tint = (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        customBaseURL = object["customBaseURL"]?.boolValue ?? false
        summary = string("summary")
        source = string("source")
        documentation = string("documentation").flatMap(URL.init(string:))
        if let glyph = string("glyph") { self.glyph = glyph }
        if let stability = string("stability").flatMap(ProviderStability.init(rawValue:)) { self.stability = stability }
        if let category = string("category").flatMap(ProviderCategory.init(rawValue:)) { self.category = category }
        for entry in object["baseURLs"]?.arrayValue ?? [] {
            guard let label = entry["label"]?.stringValue, let raw = entry["url"]?.stringValue, let base = URL(string: raw) else {
                throw CustomProviderError.invalid("\(rawID): each baseURLs entry needs a \"label\" and a \"url\".")
            }
            baseURLs.append(BaseURLOption(label: label, url: base))
            if let unit = entry["unit"]?.stringValue, let host = base.host?.lowercased() { baseURLUnits[host] = unit }
        }
        for entry in object["fields"]?.arrayValue ?? [] {
            guard let fieldID = entry["id"]?.stringValue, let label = entry["label"]?.stringValue else {
                throw CustomProviderError.invalid("\(rawID): each fields entry needs an \"id\" and a \"label\".")
            }
            fields.append(SettingField(id: fieldID, label: label, placeholder: entry["placeholder"]?.stringValue ?? "", help: entry["help"]?.stringValue))
        }
        try validate()
    }

    private func validate() throws {
        let name = id.rawValue
        guard !url.contains("{key}") else {
            throw CustomProviderError.invalid("\(name): {key} may only appear in a header, never in the URL.")
        }
        guard url.contains("{baseURL}") == (!baseURLs.isEmpty || customBaseURL) else {
            throw CustomProviderError.invalid("\(name): use {baseURL} in the url exactly when baseURLs or customBaseURL is set.")
        }
        if customBaseURL, !url.hasPrefix("{baseURL}") {
            throw CustomProviderError.invalid("\(name): with customBaseURL the url must start with {baseURL}.")
        }
        for candidate in candidateURLs {
            guard let parsed = URL(string: Self.stripPlaceholders(candidate)), let host = parsed.host?.lowercased(), let scheme = parsed.scheme?.lowercased() else {
                throw CustomProviderError.invalid("\(name): \(candidate) is not a valid URL.")
            }
            guard scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else {
                throw CustomProviderError.invalid("\(name): the URL must use https (http only on localhost).")
            }
        }
        if let primary, !readings.contains(where: { $0.id == primary }) {
            throw CustomProviderError.invalid("\(name): primary \"\(primary)\" is not one of its readings.")
        }
        for target in primaryFrom?.readings.values.sorted() ?? [] where !readings.contains(where: { $0.id == target }) {
            throw CustomProviderError.invalid("\(name): primaryFrom names \"\(target)\", which is not one of its readings.")
        }
        for reading in readings where reading.unit == Self.baseURLUnit {
            guard !baseURLs.isEmpty, baseURLs.allSatisfy({ $0.url.host.map { baseURLUnits[$0.lowercased()] != nil } ?? false }) else {
                throw CustomProviderError.invalid("\(name): \(reading.id) uses {baseURL.unit}, so every baseURLs entry needs a \"unit\".")
            }
        }
        for template in [url] + Array(headers.values) {
            for field in template.matches(of: #/\{field:([A-Za-z0-9_]+)\}/#) where !fields.contains(where: { $0.id == String(field.1) }) {
                throw CustomProviderError.invalid("\(name): {field:\(field.1)} needs an entry in \"fields\".")
            }
        }
        for (header, template) in headers where template.contains("{key}") && template.contains("{field:") {
            throw CustomProviderError.invalid("\(name): header \(header) can't mix {key} and a setting.")
        }
    }
}

extension CustomProviderSpec.ReadingSpec {
    init(json: JSONValue, index: Int, provider: String) throws {
        let label = "\(provider) readings[\(index)]"
        guard let object = json.objectValue else { throw CustomProviderError.invalid("\(label) must be an object.") }
        func path(_ key: String) throws -> String? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let text = value.stringValue, DeclarativePath.isValid(text) else {
                throw CustomProviderError.invalid("\(label).\(key) is not a valid JSON path.")
            }
            return text
        }
        guard let kind = object["kind"]?.stringValue.flatMap(CustomProviderSpec.Kind.init(rawValue:)) else {
            throw CustomProviderError.invalid("\(label).kind must be \"window\", \"balance\" or \"spend\".")
        }
        self.init(
            id: object["id"]?.stringValue ?? "reading\(index)",
            name: object["name"]?.stringValue ?? kind.rawValue.capitalized,
            kind: kind
        )
        usedPercent = try path("usedPercent")
        remainingPercent = try path("remainingPercent")
        fraction = object["fraction"]?.boolValue ?? false
        used = try path("used")
        limit = try path("limit")
        remaining = try path("remaining")
        total = try path("total")
        amount = try path("amount")
        budget = try path("budget")
        unit = object["unit"]?.stringValue ?? unit
        if let scale = object["scale"] {
            guard let value = scale.doubleValue, value != 0 else { throw CustomProviderError.invalid("\(label).scale must be a number other than 0.") }
            self.scale = value
        }
        flipSign = object["flipSign"]?.boolValue ?? false
        optional = object["optional"]?.boolValue ?? false
        nullIsZero = object["nullIsZero"]?.boolValue ?? false
        meterLabel = object["meterLabel"]?.stringValue
        period = object["period"]?.stringValue
        if let period, period.hasPrefix("$"), !DeclarativePath.isValid(period) {
            throw CustomProviderError.invalid("\(label).period is not a valid JSON path.")
        }
        reset = try path("reset")
        if let format = object["resetFormat"]?.stringValue {
            guard let value = CustomProviderSpec.DateFormat(rawValue: format) else {
                throw CustomProviderError.invalid("\(label).resetFormat must be auto, iso8601, unixSeconds or unixMs.")
            }
            resetFormat = value
        }

        switch kind {
        case .window:
            guard usedPercent != nil || remainingPercent != nil || (used != nil && limit != nil) || (remaining != nil && total != nil) else {
                throw CustomProviderError.invalid("\(label): a window needs usedPercent, remainingPercent, or used and limit, or remaining and total.")
            }
        case .balance:
            guard remaining != nil else { throw CustomProviderError.invalid("\(label): a balance needs remaining.") }
        case .spend:
            guard amount != nil else { throw CustomProviderError.invalid("\(label): a spend needs amount.") }
        }
    }
}

/// Runs a `CustomProviderSpec`.
struct DeclarativeProvider: UsageProvider {
    let spec: CustomProviderSpec?
    let descriptor: ProviderDescriptor
    private let problem: String?

    init(spec: CustomProviderSpec) {
        self.spec = spec
        self.problem = nil
        let key: CredentialRequirement = spec.usesKey
            ? .pastedKey(KeySpec(kind: spec.keyKind, label: spec.keyLabel, placeholder: spec.keyPlaceholder, helpURL: spec.keyHelpURL, warning: spec.keyWarning, advice: spec.keyAdvice))
            : .none
        descriptor = ProviderDescriptor(
            id: spec.id,
            name: spec.name,
            glyph: ProviderGlyph(symbol: spec.glyph),
            tint: spec.tint.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Self.tint(for: spec.id),
            category: spec.category,
            stability: spec.stability,
            credential: key,
            summary: spec.summary ?? "Custom: \(spec.readings.map(\.name).joined(separator: ", "))",
            reads: "One GET to \(spec.url)\(spec.usesKey ? ", with your key from the Keychain in the \(spec.headers.first { $0.value.contains("{key}") }?.key ?? "request") header" : ""). Nothing else is sent.",
            source: spec.source ?? "Declarative definition",
            allowedHosts: spec.hosts,
            minimumRefreshInterval: spec.minimumRefreshMinutes * 60,
            defaultRefreshInterval: max(spec.refreshMinutes, spec.minimumRefreshMinutes) * 60,
            baseURLs: spec.baseURLs,
            acceptsCustomBaseURL: spec.customBaseURL,
            documentation: spec.documentation,
            timeout: 20,
            fields: spec.fields
        )
    }

    /// A built-in declarative definition, written as the same JSON a user would write.
    /// An invalid definition becomes a provider that reports the problem instead of crashing.
    init(definition: String) {
        do {
            self.init(spec: try CustomProviderSpec(json: try JSONValue(data: Data(definition.utf8))))
        } catch {
            let message = (error as? CustomProviderError)?.errorDescription ?? "The definition is not valid JSON."
            let rawID = (try? JSONValue(data: Data(definition.utf8)))?["id"]?.stringValue ?? "invalid-definition"
            self.init(invalid: ProviderID(rawID), problem: message)
        }
    }

    private init(invalid id: ProviderID, problem: String) {
        spec = nil
        self.problem = problem
        descriptor = ProviderDescriptor(
            id: id, name: id.rawValue, glyph: ProviderGlyph(symbol: "exclamationmark.triangle"), tint: Bridge.muted,
            category: .api, stability: .unverified, credential: .none, summary: problem, reads: "Nothing: the definition is invalid.",
            source: "Invalid definition"
        )
    }

    /// A stable colour for a provider without its own.
    static func tint(for id: ProviderID) -> Color {
        let palette = [Bridge.seafoam, Bridge.amber, Bridge.sky, Color(red: 0.75, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.5, blue: 0.7), Color(red: 0.6, green: 0.85, blue: 0.4)]
        let hash = id.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    func availability(in context: ProviderContext) -> ProviderAvailability {
        guard spec != nil else { return .unavailable(problem ?? "Invalid definition") }
        if spec?.usesKey == true { return keyAvailability(in: context) }
        return .available
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let spec else { throw ProviderError.notConfigured(problem ?? "Invalid definition") }
        var headers: [String: String] = [:]
        for (name, template) in spec.headers {
            if template.contains("{key}") {
                guard let key = context.key(), !key.isEmpty else { throw ProviderError.notSignedIn("No key set. Add one in settings.") }
                headers[name] = template.replacingOccurrences(of: "{key}", with: key)
            } else if template.contains("{field:") {
                // A setting such as an organisation id, for providers that take it in a header.
                // Only filled when set; a header whose setting is empty is left out.
                var value = template
                var complete = true
                for field in spec.fields where value.contains("{field:\(field.id)}") {
                    guard let setting = context.settings.value(field.id) else { complete = false; break }
                    guard !setting.contains(where: { $0.isNewline }) else {
                        throw ProviderError.notConfigured("\(spec.name): \(field.label) can't contain a line break.")
                    }
                    value = value.replacingOccurrences(of: "{field:\(field.id)}", with: setting)
                }
                if complete { headers[name] = value }
            } else {
                headers[name] = template
            }
        }
        let base = try baseURL(spec, context)
        let url = try requestURL(spec, context, base: base)
        let json = try await context.http.getJSON(url, headers: headers)
        return try Self.snapshot(from: json, spec: spec, now: context.now(), baseURL: base)
    }

    /// The base URL in use: the user's choice, else the first offered one; nil when the url has none.
    private func baseURL(_ spec: CustomProviderSpec, _ context: ProviderContext) throws -> URL? {
        guard spec.url.contains("{baseURL}") else { return nil }
        guard let base = context.settings.baseURL ?? spec.baseURLs.first?.url else {
            throw ProviderError.notConfigured("\(spec.name) needs a base URL in its settings.")
        }
        return base
    }

    private func requestURL(_ spec: CustomProviderSpec, _ context: ProviderContext, base: URL?) throws -> URL {
        var text = spec.url
        if let base {
            var baseText = base.absoluteString
            while baseText.hasSuffix("/") { baseText.removeLast() }
            text = text.replacingOccurrences(of: "{baseURL}", with: baseText)
        }
        for field in spec.fields {
            let placeholder = "{field:\(field.id)}"
            guard text.contains(placeholder) else { continue }
            guard let value = context.settings.value(field.id),
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
            else { throw ProviderError.notConfigured("\(spec.name) needs \(field.label) in its settings.") }
            text = text.replacingOccurrences(of: placeholder, with: encoded)
        }
        guard let url = URL(string: text) else { throw ProviderError.notConfigured("\(spec.name): \(text) is not a valid URL.") }
        return url
    }

    /// Turns the answer into readings. A missing required value is an `unexpectedResponse` that
    /// names the path; a `null` value means "none" and leaves that reading out.
    /// `baseURL` is the base URL the request went to, for `{baseURL.unit}`.
    static func snapshot(from json: JSONValue, spec: CustomProviderSpec, now: Date, baseURL: URL? = nil) throws -> ProviderSnapshot {
        if let okWhen = spec.okWhen, DeclarativePath.value(in: json, at: okWhen.path) != okWhen.equals {
            let message = spec.errorMessagePath.flatMap { DeclarativePath.value(in: json, at: $0)?.stringValue }
            throw ProviderError.unexpectedResponse("\(spec.name) reported an error\(message.map { ": \($0)" } ?? ".")")
        }
        var readings: [Reading] = []
        for reading in spec.readings {
            do {
                if let value = try Self.reading(reading, in: json, spec: spec, baseURL: baseURL) { readings.append(value) }
            } catch let missing as MissingValue {
                if !reading.optional { throw ProviderError.unexpectedResponse("\(spec.name): \(missing.message)") }
            }
        }
        var hint = spec.primary
        if let from = spec.primaryFrom, let key = DeclarativePath.value(in: json, at: from.path)?.stringValue,
           let target = from.readings[key], readings.contains(where: { $0.id == target }) {
            hint = target
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "\(spec.name) reported no limit or balance." : nil,
            primaryHint: hint,
            fetchedAt: now
        )
    }

    /// A value the reading needs is missing: fails the fetch, or leaves an optional reading out.
    private struct MissingValue: Error {
        let message: String
    }

    private static func reading(_ reading: CustomProviderSpec.ReadingSpec, in json: JSONValue, spec: CustomProviderSpec, baseURL: URL?) throws -> Reading? {
        func number(_ path: String?) throws -> Double?? {
            guard let path else { return .none }
            guard let value = DeclarativePath.value(in: json, at: path) else {
                throw MissingValue(message: "no value at \(path).")
            }
            if value.isNull { return .some(reading.nullIsZero ? 0 : nil) }
            guard let number = value.doubleValue else {
                throw ProviderError.unexpectedResponse("\(spec.name): the value at \(path) is not a number.")
            }
            return .some(number)
        }
        func amount(_ raw: Double) -> Double { (reading.flipSign ? -raw : raw) * reading.scale }

        let unit: AmountUnit
        if reading.unit == CustomProviderSpec.baseURLUnit {
            guard let host = baseURL?.host?.lowercased(), let text = spec.baseURLUnits[host] else {
                throw ProviderError.notConfigured("\(spec.name): the unit for this base URL is not known. Pick one of the offered regions.")
            }
            unit = AmountUnit(text)
        } else if reading.unit.hasPrefix("$") {
            guard let text = DeclarativePath.value(in: json, at: reading.unit)?.stringValue else {
                throw MissingValue(message: "no unit at \(reading.unit).")
            }
            unit = AmountUnit(text.count == 3 ? text.uppercased() : text)
        } else {
            unit = AmountUnit(reading.unit)
        }
        let resetsAt: Date? = try reading.reset.flatMap { path -> Date? in
            guard let value = DeclarativePath.value(in: json, at: path) else { throw MissingValue(message: "no value at \(path).") }
            switch reading.resetFormat {
            case .auto: return DateParsing.date(value)
            case .iso8601: return DateParsing.iso8601(value.stringValue)
            case .unixSeconds: return value.doubleValue.map(Date.init(timeIntervalSince1970:))
            case .unixMs: return value.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
            }
        }
        // A period starting with `$` is a path into the answer ("monthly", "billing period").
        let period: String
        if let raw = reading.period, raw.hasPrefix("$") {
            guard let text = DeclarativePath.value(in: json, at: raw)?.stringValue, !text.isEmpty else {
                throw MissingValue(message: "no period at \(raw).")
            }
            period = text
        } else {
            period = reading.period ?? reading.name
        }

        switch reading.kind {
        case .window:
            if let percentPath = reading.usedPercent ?? reading.remainingPercent {
                guard let raw = try number(percentPath), let value = raw else { return nil }
                let percent = reading.fraction ? value * 100 : value
                let used = reading.usedPercent != nil ? percent : 100 - percent
                return Reading(id: reading.id, name: reading.name, value: .window(QuotaWindow(
                    usedPercent: max(0, min(100, Int(used.rounded()))), period: .named(period), resetsAt: resetsAt)),
                    meterLabel: reading.meterLabel)
            }
            let used: Double
            let limit: Double
            if reading.used != nil {
                guard let rawUsed = try number(reading.used), let u = rawUsed, let rawLimit = try number(reading.limit), let l = rawLimit else { return nil }
                used = amount(u); limit = amount(l)
            } else {
                guard let rawLeft = try number(reading.remaining), let r = rawLeft, let rawTotal = try number(reading.total), let t = rawTotal else { return nil }
                used = amount(t) - amount(r); limit = amount(t)
            }
            guard limit > 0 else { return nil }
            return Reading(id: reading.id, name: reading.name, value: .window(QuotaWindow(
                usedPercent: max(0, min(100, Int((used / limit * 100).rounded()))),
                period: .named(period), resetsAt: resetsAt,
                used: Amount(value: used, unit: unit), limit: Amount(value: limit, unit: unit))),
                meterLabel: reading.meterLabel)
        case .balance:
            guard let raw = try number(reading.remaining), let remaining = raw else { return nil }
            let total = try number(reading.total).flatMap { $0 }.map { Amount(value: amount($0), unit: unit) }
            return Reading(id: reading.id, name: reading.name, value: .balance(Balance(
                remaining: Amount(value: amount(remaining), unit: unit), total: total, resetsAt: resetsAt)),
                meterLabel: reading.meterLabel)
        case .spend:
            guard let raw = try number(reading.amount), let spent = raw else { return nil }
            let budget = try number(reading.budget).flatMap { $0 }.map { Amount(value: amount($0), unit: unit) }
            return Reading(id: reading.id, name: reading.name, value: .spend(Spend(
                amount: Amount(value: amount(spent), unit: unit), period: reading.period == nil ? nil : period, budget: budget, resetsAt: resetsAt)),
                meterLabel: reading.meterLabel)
        }
    }
}
