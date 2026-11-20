import SwiftUI

// Cline: the pay-as-you-go Cline credit balance, personal or an organisation's, with a pasted
// Cline API key.
//
// Sources, read 2026-11-19:
// - https://docs.cline.bot/api/authentication.md: API keys from app.cline.bot Settings > API Keys,
//   sent as `Authorization: Bearer <key>`.
// - https://docs.cline.bot/enterprise-solutions/api-reference.md: `GET /api/v1/users/me`,
//   `GET /api/v1/users/{id}/balance`, `GET /api/v1/organizations/{orgId}/balance`. The same
//   reference lists key management, credit purchases and account deletion for the same key.
// - The answer's shape and unit, from Cline's own clients (https://github.com/cline/cline:
//   sdk/packages/core/src/account/cline-account-service.ts, apps/cli/src/utils/output.ts):
//   answers may be wrapped as `{success, data, error}`; `/users/me` has `id`; a balance is
//   `{balance, userId | organizationId}` in millionths of a dollar (the CLI shows
//   `balance / 1_000_000` as dollars).
// ClinePass's 5-hour, weekly and monthly windows are shown only on Cline's dashboard; no
// documented endpoint or Cline client reads them, so they aren't shown.

struct ClineProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "cline",
        name: "Cline",
        glyph: ProviderGlyph(symbol: "chevron.left.forwardslash.chevron.right"),
        tint: Color(red: 0.6, green: 0.8, blue: 0.75),
        category: .subscription,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "Cline API key",
            placeholder: "Paste your Cline API key",
            helpURL: URL(string: "https://app.cline.bot"),
            warning: "A Cline API key can run models on your balance, buy credits with your saved payment method, manage keys and delete the account.",
            advice: "Cline has no read-only key. Create one just for Dogwatch so you can revoke it on its own."
        )),
        summary: "Cline credit balance (pay-as-you-go), personal or an organisation's",
        reads: "With your key from the Keychain in the Authorization header: one GET to https://api.cline.bot/api/v1/users/me for your user id, then one GET to /api/v1/users/<id>/balance. With an organisation id in settings, one GET to /api/v1/organizations/<id>/balance instead.",
        source: "Cline API `GET /api/v1/users/{id}/balance`",
        allowedHosts: ["api.cline.bot"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://docs.cline.bot/enterprise-solutions/api-reference"),
        timeout: 20,
        fields: [SettingField(
            id: "organization", label: "Organization ID", placeholder: "org id",
            help: "Optional. Shows the organisation's shared balance instead of your personal one.",
            isRequired: false
        )]
    )

    static let base = "https://api.cline.bot/api/v1"

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Cline API key set. Add one in settings.")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        do {
            if let organization = context.settings.value("organization") {
                let json = try await context.http.getJSON(try Self.url("/organizations/\(organization)/balance"), headers: headers)
                return try Self.snapshot(balance: try Self.unwrap(json), organization: true, now: context.now())
            }
            let me = try Self.unwrap(try await context.http.getJSON(try Self.url("/users/me"), headers: headers))
            guard let id = me["id"]?.stringValue, !id.isEmpty else {
                throw ProviderError.unexpectedResponse("Cline's /users/me answer has no id.")
            }
            let json = try await context.http.getJSON(try Self.url("/users/\(id)/balance"), headers: headers)
            return try Self.snapshot(balance: try Self.unwrap(json), organization: false, now: context.now())
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Cline rejected the key (HTTP 401). Check it in settings.")
        }
    }

    private static func url(_ path: String) throws -> URL {
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: base + encoded) else { throw ProviderError.notConfigured("Cline: \(path) is not a valid path.") }
        return url
    }

    /// Cline's API may wrap an answer as `{success, data, error}`; its clients unwrap it the same way.
    static func unwrap(_ json: JSONValue) throws -> JSONValue {
        guard let success = json["success"]?.boolValue else { return json }
        guard success else {
            let message = json["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            throw ProviderError.unexpectedResponse("Cline reported an error\(message.map { ": \($0)" } ?? ".")")
        }
        return json["data"] ?? .null
    }

    /// One reading, `balance`: dollars left, converted from millionths of a dollar.
    static func snapshot(balance json: JSONValue, organization: Bool, now: Date) throws -> ProviderSnapshot {
        guard let micro = json["balance"]?.doubleValue else {
            throw ProviderError.unexpectedResponse("Cline's balance answer has no balance.")
        }
        return ProviderSnapshot(
            readings: [Reading(
                id: "balance",
                name: organization ? "Organisation balance" : "Balance",
                value: .balance(Balance(remaining: Amount(value: micro / 1_000_000, unit: .currency("USD"))))
            )],
            fetchedAt: now
        )
    }
}
