import Foundation

/// Show the percentage left or used.
enum PercentageMode: String, Codable, CaseIterable {
    case left, used
}

/// Which providers the menu bar shows.
enum MenuBarMode: String, Codable, CaseIterable {
    /// Every provider set to appear in the menu bar, up to `maxItems`.
    case all
    /// Only the one with the least left.
    case lowest
}

/// One provider's settings. Everything is optional except the id; missing values use defaults.
struct ProviderConfig: Equatable {
    var id: ProviderID
    var enabled = true
    var inMenuBar = true
    /// The reading id to show on the gauge, instead of the default (the one that runs out first).
    var primary: String? = nil
    var percentage: PercentageMode? = nil
    /// Replaces the small label next to the provider's name.
    var label: String? = nil
    /// Turn the reading red at or below this percentage left. Default 20.
    var warnAt: Int? = nil
    /// Seconds between fetches; never below the provider's minimum.
    var refreshInterval: TimeInterval? = nil
    var baseURL: String? = nil
    /// Values for the provider's extra fields: team id, project id. Not secrets.
    var settings: [String: String] = [:]
    /// Totals the user typed for readings the provider gives no total for, by reading id.
    var limits: [String: Double] = [:]
    /// Keys this version doesn't know, kept as they were.
    var unknown: [String: JSONValue] = [:]
}

/// Everything in `config.json`. See the README's Configuration section for the file format.
struct DogwatchConfig: Equatable {
    static let currentVersion = 1

    var version = DogwatchConfig.currentVersion
    /// Seconds between background refreshes, for providers without their own interval.
    var refreshInterval: TimeInterval = 300
    var theme: DashboardDesign = .nautical
    var percentage: PercentageMode = .left
    var amounts: AmountStyle = .compact
    var launchAtLogin = false
    var menuBarMode: MenuBarMode = .all
    var menuBarMaxItems: Int? = nil
    /// In display order. Providers missing from the list are off.
    var providers: [ProviderConfig] = []
    /// The user's own providers, as written in the file. Parsed by `CustomProviderSpec`.
    var customProviders: [JSONValue] = []
    var unknown: [String: JSONValue] = [:]

    /// The settings a new user starts with: the given providers on, in order.
    static func defaults(enabled: [ProviderID]) -> DogwatchConfig {
        var config = DogwatchConfig()
        config.providers = enabled.map { ProviderConfig(id: $0) }
        return config
    }

    func provider(_ id: ProviderID) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    var enabledProviders: [ProviderID] {
        providers.filter(\.enabled).map(\.id)
    }

    mutating func update(_ id: ProviderID, _ change: (inout ProviderConfig) -> Void) {
        if let index = providers.firstIndex(where: { $0.id == id }) {
            change(&providers[index])
        } else {
            var config = ProviderConfig(id: id, enabled: false)
            change(&config)
            providers.append(config)
        }
    }
}

// MARK: - JSON

extension DogwatchConfig {
    private static let knownKeys: Set<String> = [
        "version", "refreshMinutes", "theme", "percentage", "amounts", "launchAtLogin", "menuBar", "providers", "customProviders",
    ]
    private static let knownProviderKeys: Set<String> = [
        "id", "enabled", "menuBar", "primary", "percentage", "label", "warnAt", "refreshMinutes", "baseURL", "settings", "limits",
    ]

    /// Reads a parsed file. Invalid values are replaced by defaults and described in `problems`,
    /// so one typo never loses the rest of the file.
    init(json: JSONValue, problems: inout [String]) {
        self.init()
        guard let root = json.objectValue else {
            problems.append("The file is not a JSON object.")
            return
        }
        if let version = root["version"]?.doubleValue, Int(version) > Self.currentVersion {
            problems.append("The file is from a newer Dogwatch (version \(Int(version))). Unknown settings are kept.")
        }
        if let minutes = root["refreshMinutes"] {
            if let value = minutes.doubleValue, value >= 1, value <= 1_440 { refreshInterval = value * 60 }
            else { problems.append("refreshMinutes must be a number from 1 to 1440.") }
        }
        if let theme = root["theme"] {
            if let value = theme.stringValue.flatMap(DashboardDesign.init(rawValue:)) { self.theme = value }
            else { problems.append("theme must be one of \(DashboardDesign.allCases.map(\.rawValue).joined(separator: ", ")).") }
        }
        if let percentage = root["percentage"] {
            if let value = percentage.stringValue.flatMap(PercentageMode.init(rawValue:)) { self.percentage = value }
            else { problems.append("percentage must be \"left\" or \"used\".") }
        }
        if let amounts = root["amounts"] {
            if let value = amounts.stringValue.flatMap(AmountStyle.init(rawValue:)) { self.amounts = value }
            else { problems.append("amounts must be \"compact\" or \"full\".") }
        }
        if let launch = root["launchAtLogin"] {
            if let value = launch.boolValue { launchAtLogin = value } else { problems.append("launchAtLogin must be true or false.") }
        }
        if let menuBar = root["menuBar"]?.objectValue {
            if let show = menuBar["show"] {
                if let value = show.stringValue.flatMap(MenuBarMode.init(rawValue:)) { menuBarMode = value }
                else { problems.append("menuBar.show must be \"all\" or \"lowest\".") }
            }
            if let max = menuBar["maxItems"], !max.isNull {
                if let value = max.doubleValue, value >= 1 { menuBarMaxItems = Int(value) }
                else { problems.append("menuBar.maxItems must be 1 or more.") }
            }
        }
        var seen = Set<ProviderID>()
        for (index, entry) in (root["providers"]?.arrayValue ?? []).enumerated() {
            guard let object = entry.objectValue, let rawID = object["id"]?.stringValue else {
                problems.append("providers[\(index)] needs an \"id\".")
                continue
            }
            let id = ProviderID(rawID)
            guard id.isValid else { problems.append("providers[\(index)]: \"\(rawID)\" is not a valid id."); continue }
            guard seen.insert(id).inserted else { problems.append("\(rawID) is listed twice; the first entry is used."); continue }
            providers.append(Self.provider(id, object, problems: &problems))
        }
        customProviders = root["customProviders"]?.arrayValue ?? []
        unknown = root.filter { !Self.knownKeys.contains($0.key) }
    }

    private static func provider(_ id: ProviderID, _ object: [String: JSONValue], problems: inout [String]) -> ProviderConfig {
        var config = ProviderConfig(id: id)
        let name = id.rawValue
        if let enabled = object["enabled"] { config.enabled = enabled.boolValue ?? { problems.append("\(name).enabled must be true or false."); return true }() }
        if let menuBar = object["menuBar"] { config.inMenuBar = menuBar.boolValue ?? { problems.append("\(name).menuBar must be true or false."); return true }() }
        config.primary = object["primary"]?.stringValue
        if let percentage = object["percentage"] {
            config.percentage = percentage.stringValue.flatMap(PercentageMode.init(rawValue:))
            if config.percentage == nil { problems.append("\(name).percentage must be \"left\" or \"used\".") }
        }
        config.label = object["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let warnAt = object["warnAt"] {
            if let value = warnAt.doubleValue, (0...100).contains(value) { config.warnAt = Int(value) }
            else { problems.append("\(name).warnAt must be a number from 0 to 100.") }
        }
        if let minutes = object["refreshMinutes"] {
            if let value = minutes.doubleValue, value >= 1, value <= 1_440 { config.refreshInterval = value * 60 }
            else { problems.append("\(name).refreshMinutes must be a number from 1 to 1440.") }
        }
        if let base = object["baseURL"]?.stringValue {
            if let url = URL(string: base), let scheme = url.scheme?.lowercased(), url.host != nil,
               scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host?.lowercased() ?? "")) {
                config.baseURL = base
            } else {
                problems.append("\(name).baseURL must be an https URL, or http on localhost.")
            }
        }
        for (key, value) in object["settings"]?.objectValue ?? [:] {
            if let text = value.stringValue { config.settings[key] = text }
        }
        for (key, value) in object["limits"]?.objectValue ?? [:] {
            if let number = value.doubleValue, number > 0 { config.limits[key] = number }
            else { problems.append("\(name).limits.\(key) must be a number above 0.") }
        }
        config.unknown = object.filter { !knownProviderKeys.contains($0.key) }
        return config
    }

    /// The file's JSON: known settings written out, unknown keys put back as they were.
    var json: JSONValue {
        var root = unknown
        root["version"] = .number(Double(Self.currentVersion))
        root["refreshMinutes"] = .number(refreshInterval / 60)
        root["theme"] = .string(theme.rawValue)
        root["percentage"] = .string(percentage.rawValue)
        root["amounts"] = .string(amounts.rawValue)
        root["launchAtLogin"] = .bool(launchAtLogin)
        var menuBar: [String: JSONValue] = ["show": .string(menuBarMode.rawValue)]
        if let menuBarMaxItems { menuBar["maxItems"] = .number(Double(menuBarMaxItems)) }
        root["menuBar"] = .object(menuBar)
        root["providers"] = .array(providers.map(\.json))
        root["customProviders"] = .array(customProviders)
        return .object(root)
    }
}

extension ProviderConfig {
    var json: JSONValue {
        var object = unknown
        object["id"] = .string(id.rawValue)
        object["enabled"] = .bool(enabled)
        object["menuBar"] = .bool(inMenuBar)
        if let primary { object["primary"] = .string(primary) }
        if let percentage { object["percentage"] = .string(percentage.rawValue) }
        if let label { object["label"] = .string(label) }
        if let warnAt { object["warnAt"] = .number(Double(warnAt)) }
        if let refreshInterval { object["refreshMinutes"] = .number(refreshInterval / 60) }
        if let baseURL { object["baseURL"] = .string(baseURL) }
        if !settings.isEmpty { object["settings"] = .object(settings.mapValues(JSONValue.string)) }
        if !limits.isEmpty { object["limits"] = .object(limits.mapValues(JSONValue.number)) }
        return .object(object)
    }
}

extension JSONValue {
    /// Pretty, sorted, human-editable JSON.
    func encodedForFile() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
