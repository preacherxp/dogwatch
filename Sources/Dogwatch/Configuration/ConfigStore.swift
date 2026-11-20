import Foundation

/// Reads and writes `config.json`, the one source of truth for settings. A missing file is
/// created from the app's old preferences once; a broken file falls back to defaults with a
/// visible message and is backed up before the app ever writes over it.
final class ConfigStore {
    /// nil keeps everything in memory (tests and previews).
    let url: URL?
    private(set) var config: DogwatchConfig
    private(set) var problems: [String] = []
    /// The file exists but couldn't be parsed; it is copied aside before the first save.
    private(set) var isBroken = false
    private var lastModified: Date?

    init(url: URL?, fallback: DogwatchConfig) {
        self.url = url
        self.config = fallback
        if url != nil { load(fallback: fallback) }
    }

    static func inMemory(_ config: DogwatchConfig) -> ConfigStore {
        ConfigStore(url: nil, fallback: config)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dogwatch/config.json")
    }

    /// The live file. When it doesn't exist yet, it is written once from the preferences the
    /// app used before (visible providers, theme); after that the preferences are never read.
    static func live(url: URL = defaultURL, legacyDefaults: UserDefaults = .standard) -> ConfigStore {
        let migrated = migratedConfig(from: legacyDefaults)
        let store = ConfigStore(url: url, fallback: migrated)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? store.save(migrated)
        }
        return store
    }

    /// Settings from the app's old preferences: which of the three original providers were
    /// visible, and the theme.
    static func migratedConfig(from defaults: UserDefaults) -> DogwatchConfig {
        let visibility = HarnessVisibility.load(from: defaults)
        var config = DogwatchConfig()
        config.providers = HarnessVisibility.legacyProviders.map { ProviderConfig(id: $0, enabled: visibility.isVisible($0)) }
        if let theme = defaults.string(forKey: "dashboardDesign").flatMap(DashboardDesign.init(rawValue:)) {
            config.theme = theme
        }
        return config
    }

    var message: String? {
        problems.isEmpty ? nil : "config.json: " + problems.joined(separator: " ")
    }

    private func load(fallback: DogwatchConfig) {
        guard let url else { return }
        lastModified = Self.modificationDate(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = fallback
            problems = []
            isBroken = false
            return
        }
        do {
            let json = try JSONValue(data: Data(contentsOf: url))
            var found: [String] = []
            config = DogwatchConfig(json: json, problems: &found)
            problems = found
            isBroken = false
        } catch {
            config = fallback
            problems = ["The file is not valid JSON, so defaults are in use. Fix it or delete it; Dogwatch keeps a copy before saving over it."]
            isBroken = true
        }
    }

    /// Re-reads the file when it changed on disk. Returns true when it did.
    @discardableResult
    func reloadIfChanged() -> Bool {
        guard let url else { return false }
        let modified = Self.modificationDate(url)
        guard modified != lastModified else { return false }
        load(fallback: config)
        return true
    }

    /// Writes the configuration, keeping unknown keys. A broken file is first copied to
    /// `config.broken.json` so nothing the user wrote is lost.
    func save(_ newConfig: DogwatchConfig) throws {
        config = newConfig
        guard let url else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isBroken, fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("config.broken.json")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: url, to: backup)
            isBroken = false
        }
        try newConfig.json.encodedForFile().write(to: url, options: .atomic)
        problems = []
        lastModified = Self.modificationDate(url)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
