import Foundation

/// Why a fetch failed. Each case has a message the panel shows as it is.
enum ProviderError: LocalizedError, Equatable {
    /// The tool isn't on this Mac: "Cursor is not installed".
    case notInstalled(String)
    /// The tool is installed but not signed in, or no key is set.
    case notSignedIn(String)
    /// The sign-in or key has expired or been revoked.
    case expired(String)
    case rateLimited(retryAfter: TimeInterval?)
    /// The provider answered, but not with what was expected. The message names what was missing.
    case unexpectedResponse(String)
    case network(String)
    case timedOut
    /// A provider tried to call a host it didn't declare.
    case hostNotAllowed(String)
    /// Settings are missing or invalid: a custom provider without a URL, a bad JSON path.
    case notConfigured(String)
    /// The user denied a Keychain prompt. Never retried on a timer, only when the user asks.
    case accessDenied(String)
    /// HTTP 402: the account is out of credit, or its plan doesn't include this (Lovable below
    /// Business, an empty Kilo balance).
    case paymentRequired(String)
    /// HTTP 404: the provider doesn't know the account, organization or project in the request,
    /// or the feature isn't enabled for it (Together's beta report).
    case notFound(String)
    /// The provider tried to start a program it didn't declare.
    case commandNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let message), .notSignedIn(let message), .expired(let message),
             .unexpectedResponse(let message), .notConfigured(let message), .accessDenied(let message),
             .paymentRequired(let message), .notFound(let message):
            return message
        case .commandNotAllowed(let command):
            return "Refused to run \(command): not one of this provider's declared commands."
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Rate limited. Trying again later." }
            return "Rate limited. Trying again in \(Int(retryAfter.rounded(.up))) seconds."
        case .network(let message):
            return "Network error: \(message)"
        case .timedOut:
            return "No answer in time."
        case .hostNotAllowed(let host):
            return "Refused to contact \(host): not one of this provider's hosts."
        }
    }

    /// A short name for the kind of failure, for tests and the connection test in settings.
    var kind: String {
        switch self {
        case .notInstalled: return "notInstalled"
        case .notSignedIn: return "notSignedIn"
        case .expired: return "expired"
        case .rateLimited: return "rateLimited"
        case .unexpectedResponse: return "unexpectedResponse"
        case .network: return "network"
        case .timedOut: return "timedOut"
        case .hostNotAllowed: return "hostNotAllowed"
        case .notConfigured: return "notConfigured"
        case .accessDenied: return "accessDenied"
        case .paymentRequired: return "paymentRequired"
        case .notFound: return "notFound"
        case .commandNotAllowed: return "commandNotAllowed"
        }
    }

    /// Errors the store doesn't retry on its timer: retrying can't help, or would prompt again.
    var waitsForUser: Bool {
        switch self {
        case .accessDenied, .notConfigured, .commandNotAllowed, .hostNotAllowed: return true
        default: return false
        }
    }
}

/// Whether a provider can be read on this Mac right now, and if not, why.
enum ProviderAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
    var reason: String? { if case .unavailable(let reason) = self { return reason } else { return nil } }
}

/// The user's settings for one provider that a fetch may need.
struct ProviderSettings: Equatable {
    /// The chosen base URL, for providers with regional or compatible endpoints.
    var baseURL: URL? = nil
    /// Values of the descriptor's `fields`, by field id: a team id, a project id.
    var values: [String: String] = [:]

    func value(_ field: String) -> String? {
        values[field].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// A toggle field; off unless the user turned it on.
    func isOn(_ field: String) -> Bool {
        values[field] == "true"
    }
}

/// What a provider gets to work with. Everything that touches the outside world goes through
/// it, so tests can replace it and providers can't reach anything they didn't declare.
struct ProviderContext {
    /// Calls only the provider's declared hosts.
    let http: HTTPClient
    /// The provider's pasted key from the Keychain, or nil. Pass it straight into a request
    /// header; never log, store or put it in an error.
    let key: () -> String?
    let settings: ProviderSettings
    /// Local files, commands and logs.
    let local: LocalTools
    let now: () -> Date

    var home: URL { local.home }
}

/// One source of usage. A provider is a small value: its descriptor, a check for whether it
/// applies on this Mac, and a fetch that turns the provider's answer into readings.
protocol UsageProvider {
    var descriptor: ProviderDescriptor { get }

    /// Cheap and local: is the tool installed, is a key set? No network.
    func availability(in context: ProviderContext) -> ProviderAvailability

    /// Reads usage. Throws `ProviderError`. The store adds the timeout and cancellation.
    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot
}

extension UsageProvider {
    var id: ProviderID { descriptor.id }

    /// The default for pasted-key providers: available once a key is set.
    func keyAvailability(in context: ProviderContext) -> ProviderAvailability {
        context.key().map { $0.isEmpty ? .unavailable("No key set") : .available } ?? .unavailable("No key set")
    }
}

/// Runs `operation` with a time limit, cancelling it when the limit passes.
func withTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProviderError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ProviderError.timedOut }
        return result
    }
}
