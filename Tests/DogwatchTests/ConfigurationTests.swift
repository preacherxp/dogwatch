import Foundation
import XCTest
@testable import Dogwatch

/// `config.json`: parsing, validation, unknown keys, broken files, migration and reloads.
final class ConfigurationTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsEverySetting() throws {
        let json = try JSONValue(data: Data("""
        {"version": 1, "refreshMinutes": 10, "theme": "ledger", "percentage": "used", "amounts": "full", "launchAtLogin": true,
         "menuBar": {"show": "lowest", "maxItems": 2},
         "providers": [
           {"id": "claude", "enabled": true, "menuBar": false, "primary": "seven_day", "percentage": "left", "label": "Work",
            "warnAt": 15, "refreshMinutes": 3},
           {"id": "copilot", "enabled": true, "limits": {"credits": 1500}},
           {"id": "xai-api", "enabled": false, "settings": {"teamId": "team-123"}, "baseURL": "https://management-api.x.ai"}
         ],
         "customProviders": [{"id": "custom-a", "name": "A", "url": "https://a.example.com", "readings": [{"kind": "balance", "remaining": "x"}]}]}
        """.utf8))
        var problems: [String] = []
        let config = DogwatchConfig(json: json, problems: &problems)

        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.refreshInterval, 600)
        XCTAssertEqual(config.theme, .ledger)
        XCTAssertEqual(config.percentage, .used)
        XCTAssertEqual(config.amounts, .full)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.menuBarMode, .lowest)
        XCTAssertEqual(config.menuBarMaxItems, 2)
        XCTAssertEqual(config.enabledProviders, ["claude", "copilot"])
        let claude = try XCTUnwrap(config.provider("claude"))
        XCTAssertFalse(claude.inMenuBar)
        XCTAssertEqual(claude.primary, "seven_day")
        XCTAssertEqual(claude.label, "Work")
        XCTAssertEqual(claude.warnAt, 15)
        XCTAssertEqual(claude.refreshInterval, 180)
        XCTAssertEqual(config.provider("copilot")?.limits, ["credits": 1500])
        XCTAssertEqual(config.provider("xai-api")?.settings, ["teamId": "team-123"])
        XCTAssertEqual(config.customProviders.count, 1)
    }

    func testInvalidValuesFallBackAndSayWhy() throws {
        let json = try JSONValue(data: Data("""
        {"refreshMinutes": 0, "theme": "neon", "percentage": "half", "menuBar": {"show": "some", "maxItems": 0},
         "providers": [{"id": "Claude Code"}, {"enabled": true}, {"id": "codex", "warnAt": 150, "baseURL": "http://example.com"},
                       {"id": "codex"}]}
        """.utf8))
        var problems: [String] = []
        let config = DogwatchConfig(json: json, problems: &problems)

        XCTAssertEqual(config.refreshInterval, 300)
        XCTAssertEqual(config.theme, .nautical)
        XCTAssertEqual(config.percentage, .left)
        XCTAssertNil(config.menuBarMaxItems)
        XCTAssertEqual(config.providers.map(\.id), ["codex"])
        XCTAssertNil(config.provider("codex")?.warnAt)
        XCTAssertNil(config.provider("codex")?.baseURL)
        XCTAssertEqual(problems.count, 10, problems.joined(separator: "\n"))
    }

    func testUnknownKeysSurviveARewrite() throws {
        try Data("""
        {"version": 1, "theme": "cyber", "futureSetting": {"x": 1},
         "providers": [{"id": "codex", "enabled": true, "futureProviderSetting": "kept"}]}
        """.utf8).write(to: url)
        let store = ConfigStore(url: url, fallback: DogwatchConfig())
        var config = store.config
        config.theme = .ledger
        try store.save(config)

        let saved = try JSONValue(data: Data(contentsOf: url))
        XCTAssertEqual(saved["futureSetting"], .object(["x": .number(1)]))
        XCTAssertEqual(saved["providers"]?[0]?["futureProviderSetting"], .string("kept"))
        XCTAssertEqual(saved["theme"], .string("ledger"))
    }

    func testABrokenFileFallsBackAndIsBackedUpBeforeSaving() throws {
        try Data("{ not json".utf8).write(to: url)
        let fallback = DogwatchConfig.defaults(enabled: [.codex])
        let store = ConfigStore(url: url, fallback: fallback)

        XCTAssertTrue(store.isBroken)
        XCTAssertNotNil(store.message)
        XCTAssertEqual(store.config, fallback)
        try store.save(store.config)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("config.broken.json")), "{ not json")
        XCTAssertNoThrow(try JSONValue(data: Data(contentsOf: url)))
    }

    func testFirstLaunchMigratesTheOldPreferencesOnce() throws {
        let defaults = InMemoryDefaults()
        defaults.set("codex,grok", forKey: HarnessVisibility.storageKey)
        defaults.set("codex,claude,grok", forKey: HarnessVisibility.knownKey)
        defaults.set("ledger", forKey: "dashboardDesign")

        let store = ConfigStore.live(url: url, legacyDefaults: defaults)
        XCTAssertEqual(store.config.enabledProviders, [.codex, .grok])
        XCTAssertEqual(store.config.providers.map(\.id), [.codex, .claude, .grok])
        XCTAssertEqual(store.config.theme, .ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        defaults.set("claude", forKey: HarnessVisibility.storageKey)
        XCTAssertEqual(ConfigStore.live(url: url, legacyDefaults: defaults).config.enabledProviders, [.codex, .grok],
                       "Once the file exists, preferences are never read again.")
    }

    func testReloadsWhenTheFileChanges() throws {
        let store = ConfigStore(url: url, fallback: DogwatchConfig())
        try store.save(DogwatchConfig.defaults(enabled: [.codex]))
        XCTAssertFalse(store.reloadIfChanged())
        Thread.sleep(forTimeInterval: 1.1)
        try Data(#"{"providers": [{"id": "claude"}], "theme": "cyber"}"#.utf8).write(to: url)
        XCTAssertTrue(store.reloadIfChanged())
        XCTAssertEqual(store.config.enabledProviders, [.claude])
        XCTAssertEqual(store.config.theme, .cyber)
    }

    func testTheFileIsReadable() throws {
        let data = try DogwatchConfig.defaults(enabled: [.codex, .claude]).json.encodedForFile()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n  \"providers\""), "Pretty-printed for people")
        XCTAssertTrue(text.contains("\"refreshMinutes\" : 5"))
    }
}
