import SwiftUI

// Deepgram: a project's outstanding balances.
//
// API reference, read 2026-11-19: https://developers.deepgram.com/reference/manage/billing/list
// Key scopes, read 2026-11-19: https://developers.deepgram.com/guides/deep-dives/working-with-roles
// `GET https://api.deepgram.com/v1/projects/{project_id}/balances` with `Authorization: Token <key>`
// returns `{"balances": [{"balance_id", "amount", "units", "purchase_order_id"}]}`: a project can
// hold several balances (one per purchase), each with its own `units` ("USD"). Swift rather than a
// declarative definition because the balances have to be summed per unit. Reading a project's
// balances needs `billing:read`, which only owner and admin keys carry; member keys get 403.

struct DeepgramProvider: UsageProvider {
    static let projectField = "project_id"

    let descriptor = ProviderDescriptor(
        id: "deepgram",
        name: "Deepgram",
        glyph: ProviderGlyph(symbol: "mic"),
        tint: Color(red: 0.2, green: 0.85, blue: 0.6),
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(
            kind: .apiKey,
            label: "API key",
            placeholder: "",
            helpURL: URL(string: "https://developers.deepgram.com/guides/deep-dives/working-with-roles"),
            warning: "Reading balances needs billing:read, which only owner and admin keys have. Those keys can also manage the project's keys and members.",
            advice: "If you create keys through Deepgram's API, you can create one with only the billing:read scope and paste that instead."
        )),
        summary: "Project balance",
        reads: "One GET to https://api.deepgram.com/v1/projects/<your project id>/balances, with your key from the Keychain in the Authorization header: the project's outstanding balances, added up per unit.",
        source: "Deepgram API `GET /v1/projects/{id}/balances`",
        allowedHosts: ["api.deepgram.com"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 900,
        idleLabel: "Add an API key",
        documentation: URL(string: "https://developers.deepgram.com/reference/manage/billing/list"),
        timeout: 20,
        fields: [SettingField(id: DeepgramProvider.projectField, label: "Project ID", placeholder: "Project ID from the Deepgram console",
                              help: "Shown in the Deepgram console's project settings.")]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else {
            throw ProviderError.notSignedIn("No Deepgram key set. Add one in settings.")
        }
        guard let project = context.settings.value(Self.projectField),
              let encoded = project.trimmingCharacters(in: .whitespaces)
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))),
              let url = URL(string: "https://api.deepgram.com/v1/projects/\(encoded)/balances")
        else {
            throw ProviderError.notConfigured("Deepgram needs a project id in its settings.")
        }
        let json: JSONValue
        do {
            json = try await context.http.getJSON(url, headers: ["Authorization": "Token \(key)"])
        } catch ProviderError.notSignedIn {
            throw ProviderError.notSignedIn("Deepgram rejected the key (HTTP 401). Check it in settings.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Deepgram refused access (HTTP 403). The key needs billing:read on this project, which owner and admin keys have.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// One balance reading per unit, each the sum of the project's balances in that unit. A
    /// balance without a unit can't be labelled honestly, so it is left out.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let balances = json["balances"]?.arrayValue else {
            throw ProviderError.unexpectedResponse("Deepgram's answer has no balances.")
        }
        var order: [String] = []
        var totals: [String: Double] = [:]
        for balance in balances {
            guard let unit = balance["units"]?.stringValue?.trimmingCharacters(in: .whitespaces), !unit.isEmpty,
                  let amount = balance["amount"]?.doubleValue
            else { continue }
            let code = unit.count == 3 ? unit.uppercased() : unit
            if totals[code] == nil { order.append(code) }
            totals[code, default: 0] += amount
        }
        let readings = order.map { code in
            Reading(
                id: "balance_\(code.lowercased())",
                name: order.count == 1 ? "Balance" : "Balance (\(code))",
                value: .balance(Balance(remaining: Amount(value: totals[code] ?? 0, unit: AmountUnit(code))))
            )
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "Deepgram reports no outstanding balance for this project." : nil,
            primaryHint: totals["USD"] != nil ? "balance_usd" : nil,
            fetchedAt: now
        )
    }
}
