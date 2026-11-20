import Foundation

/// UserDefaults that keeps values in memory only. A real suite, even after
/// removePersistentDomain(forName:), leaves an empty plist in ~/Library/Preferences.
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() {
        // nil reads the app's search list but is never written to; every write lands below.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
