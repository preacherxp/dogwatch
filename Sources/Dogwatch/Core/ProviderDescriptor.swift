import SwiftUI

/// A provider's stable id: lowercase letters, digits and hyphens, such as `codex` or `openrouter`.
/// It names the provider in `config.json`, the history database and its Keychain item.
struct ProviderID: Hashable, Comparable, Codable, Identifiable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }
    var description: String { rawValue }
    static func < (lhs: ProviderID, rhs: ProviderID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Valid ids are 2 to 40 characters of `a-z`, `0-9` and `-`, starting with a letter.
    var isValid: Bool {
        rawValue.range(of: #"^[a-z][a-z0-9-]{1,39}$"#, options: .regularExpression) != nil
    }

    static let codex: ProviderID = "codex"
    static let claude: ProviderID = "claude"
    static let grok: ProviderID = "grok"
}

/// A subscription tool you run (Codex, Claude Code), or an account billed through an API.
enum ProviderCategory: String, Codable, CaseIterable {
    case subscription
    case api

    var title: String { self == .subscription ? "Subscription tools" : "API accounts" }
}

/// How far a provider's numbers can be trusted. Shown in settings and the README table.
enum ProviderStability: String, Codable, CaseIterable {
    /// A public, documented API.
    case documented
    /// What the provider's own tool uses. It works today and can change without notice.
    case undocumented
    /// Built from documentation and never checked against a real account.
    case unverified

    var title: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .documented: return "Uses the provider's public, documented API."
        case .undocumented: return "Uses what the provider's own tool uses. It can change without notice."
        case .unverified: return "Built from documentation and not yet checked against a real account."
        }
    }
}

/// What a provider needs before it can read anything. Declared as data, so settings can show
/// the right controls and say exactly what will be read.
enum CredentialRequirement: Equatable {
    /// Nothing: public data or a local tool that needs no sign-in.
    case none
    /// Read-only access to another tool's own store. Dogwatch never writes, refreshes or copies it.
    case toolStore(ToolStore)
    /// A key the user pastes into settings. Kept in the login Keychain under Dogwatch's service.
    case pastedKey(KeySpec)

    var needsPastedKey: Bool {
        if case .pastedKey = self { return true }
        return false
    }
}

struct ToolStore: Equatable {
    enum Kind: String, Equatable {
        case file, keychain, localServer, command
    }

    /// Dogwatch only ever reads another tool's store. `readWrite` exists so the contract tests
    /// can reject a provider that declares it.
    enum Access: String, Equatable {
        case readOnly, readWrite
    }

    let kind: Kind
    /// The exact item, path or command, as shown to the user: `~/.grok/logs/unified.jsonl`.
    let location: String
    var access: Access = .readOnly
    /// Reading it can show a macOS Keychain prompt (Electron "Safe Storage", another app's item).
    var mayPrompt: Bool = false
    /// The id of a toggle field it is read behind, when it is only read with that setting on.
    var onlyWhen: String? = nil
}

/// What the user pastes. Kept in the login Keychain under Dogwatch's own service, one item per
/// provider; never in `config.json`, history, errors or logs.
struct KeySpec: Equatable {
    enum Kind: String, Equatable {
        case apiKey, adminKey, token, cookie

        var title: String {
            switch self {
            case .apiKey: return "API key"
            case .adminKey: return "Admin key"
            case .token: return "Token"
            case .cookie: return "Cookie"
            }
        }
    }

    var kind: Kind = .apiKey
    /// What the provider calls it: "API key", "Management key".
    let label: String
    /// A harmless example of the shape, such as `sk-or-v1-…`. Never a real key.
    let placeholder: String
    /// Where the user creates one.
    let helpURL: URL?
    /// Set when the key can do more than read usage (create keys, top up, change limits).
    /// Settings shows it next to the key field.
    var warning: String? = nil
    /// The narrower key to prefer when the provider offers one.
    var advice: String? = nil

    var isPowerful: Bool { warning != nil || kind == .adminKey }
}

/// A non-secret setting a provider needs, such as a team or project id. Stored in `config.json`.
struct SettingField: Equatable, Identifiable {
    enum Kind: Equatable {
        case text
        /// An on/off switch, stored as "true" or "false". Use it for an extra source the user
        /// must turn on, such as reading another tool's stored key; default off.
        case toggle
    }

    let id: String
    let label: String
    var placeholder: String = ""
    var help: String? = nil
    var isRequired: Bool = true
    var kind: Kind = .text
}

/// A program a provider is allowed to start. The shared runner refuses anything not declared.
/// Starting another tool is the last resort: prefer reading its file, then a read-only HTTPS
/// call with its unexpired stored token.
struct DeclaredCommand: Equatable {
    /// The program's name, looked up in `PATH` and the usual install folders.
    let executable: String
    /// The exact arguments; nothing else may be passed.
    let arguments: [String]
    /// Why it is run, shown in settings: "Reads rate limits from Codex's own app server."
    let reason: String
    /// Extra environment, such as `BROWSER=/usr/bin/false` so a signed-out tool can't open a browser.
    var environment: [String: String] = [:]
    /// True only when the tool's own documentation says this command is read-only and does not
    /// touch credentials or create sessions. Without it, the provider is at best `undocumented`.
    var documentedReadOnly: Bool = false
    /// The id of a toggle field the command runs behind, when it only runs with that setting
    /// on. Settings then says "with … on" instead of "turning this provider on runs …".
    var onlyWhen: String? = nil
}

/// A base URL the user can pick for providers with regional or compatible endpoints.
struct BaseURLOption: Equatable {
    let label: String
    let url: URL
}

/// The SF Symbols used for the provider in the app's own UI. Rendered at run time; never part
/// of the app icon. `themed` overrides the symbol in a given dashboard design.
struct ProviderGlyph: Equatable {
    let symbol: String
    var themed: [DashboardDesign: String] = [:]

    func symbol(for design: DashboardDesign) -> String { themed[design] ?? symbol }
}

/// Everything the app needs to show, configure and explain a provider without fetching.
struct ProviderDescriptor {
    let id: ProviderID
    let name: String
    let glyph: ProviderGlyph
    let tint: Color
    let category: ProviderCategory
    let stability: ProviderStability
    let credential: CredentialRequirement
    /// One line for the settings list: "ChatGPT allowance, tokens, and credits".
    let summary: String
    /// Plain sentences saying exactly what is read and where it goes. Shown in settings.
    let reads: String
    /// Short source for the README table: "Codex app server (local)".
    let source: String
    /// The only hosts the provider may call. Plain `http` is allowed for `localhost` and
    /// `127.0.0.1` only.
    var allowedHosts: [String] = []
    /// The provider is never fetched more often than this, whatever the configuration says.
    var minimumRefreshInterval: TimeInterval = 60
    var defaultRefreshInterval: TimeInterval = 300
    /// Regional or compatible endpoints; the first is the default.
    var baseURLs: [BaseURLOption] = []
    /// The user may enter any base URL (a self-hosted gateway); its host is then allowed.
    var acceptsCustomBaseURL = false
    /// The small label shown before there is any reading: "Open Claude Code".
    var idleLabel: String? = nil
    /// The provider's own reference for the numbers it reads.
    var documentation: URL? = nil
    /// How long one fetch may take before it fails with `.timedOut`.
    var timeout: TimeInterval = 40
    /// Non-secret settings the provider needs: team id, project id, account id.
    var fields: [SettingField] = []
    /// A key the user may paste instead of the tool's own sign-in (Kimi, Factory). Settings
    /// shows the key field for it; the provider decides which to use.
    var optionalKey: KeySpec? = nil
    /// Other local files or items it reads, besides the credential.
    var localSources: [ToolStore] = []
    /// Programs it starts. Settings tells the user that enabling the provider runs them.
    var commands: [DeclaredCommand] = []
}

extension ProviderDescriptor {
    var title: String { name }
    var logbookName: String { name.uppercased() }
}
