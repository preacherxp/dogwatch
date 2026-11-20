import SwiftUI

// Gemini CLI: the per-model request quota Gemini CLI itself reads, with Gemini CLI's stored
// Google sign-in. Since 2026-06-18 Gemini CLI serves Google Workspace accounts (Gemini Code Assist
// Standard and Enterprise, Workspace AI Ultra); personal accounts moved to Antigravity.
//
// Sources, read 2026-11-19:
// - Quotas: https://geminicli.com/docs/resources/quota-and-pricing (Standard 1,500 and
//   Enterprise 2,000 model requests per user per day).
// - Endpoints and fields: Gemini CLI's own open source code,
//   https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts
//   and `types.ts`: `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
//   (`currentTier`, `paidTier`, `cloudaicompanionProject`, `ineligibleTiers[].reasonCode`) and
//   `POST …/v1internal:retrieveUserQuota` with `{project}` → `buckets[] {modelId,
//   remainingFraction, resetTime, tokenType, remainingAmount}`. Both are lookups; neither
//   changes the account. The API is internal to Gemini CLI and undocumented.
// - Credential: `~/.gemini/oauth_creds.json` (`access_token`, `expiry_date` in ms), Gemini CLI's
//   default store (`oauth2.ts`). The access token lasts about an hour and only Gemini CLI
//   refreshes it, so between Gemini CLI sessions this provider says "open Gemini CLI".
// Not verified against a real account.

struct GeminiCLIProvider: UsageProvider {
    static let credentialsPath = ".gemini/oauth_creds.json"
    static let projectField = "project"
    static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    let descriptor = ProviderDescriptor(
        id: "gemini-cli",
        name: "Gemini CLI",
        glyph: ProviderGlyph(symbol: "sparkle"),
        tint: Color(red: 0.45, green: 0.55, blue: 0.95),
        category: .subscription,
        stability: .unverified,
        credential: .toolStore(ToolStore(kind: .file, location: "~/.gemini/oauth_creds.json")),
        summary: "Daily request quota per model (Workspace and Code Assist accounts)",
        reads: "The access token Gemini CLI keeps in ~/.gemini/oauth_creds.json, read as stored. If it has expired, Dogwatch asks you to open Gemini CLI and never refreshes it. Otherwise it is sent only in the Authorization header of two lookups Gemini CLI itself makes: POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist (your tier and project) and POST …/v1internal:retrieveUserQuota (what is left per model). Personal Google accounts are no longer served by Gemini CLI; use Antigravity for those.",
        source: "Gemini CLI's quota lookup, with Gemini CLI's stored sign-in",
        allowedHosts: ["cloudcode-pa.googleapis.com"],
        minimumRefreshInterval: 120,
        defaultRefreshInterval: 900,
        idleLabel: "Open Gemini CLI",
        documentation: URL(string: "https://geminicli.com/docs/resources/quota-and-pricing"),
        timeout: 30,
        fields: [SettingField(
            id: GeminiCLIProvider.projectField,
            label: "Google Cloud project id",
            placeholder: "my-project-123",
            help: "Only if your account needs one (GOOGLE_CLOUD_PROJECT for Gemini CLI). Usually Google provides it.",
            isRequired: false
        )]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.fileExists(context.home.appendingPathComponent(Self.credentialsPath))
            ? .available : .unavailable("Gemini CLI is not signed in")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let token = try StoredCredential.token(
            file: context.home.appendingPathComponent(Self.credentialsPath), local: context.local,
            tokenPath: "access_token", expiryPath: "expiry_date", tool: "Gemini CLI", now: context.now()
        )
        let configured = context.settings.value(Self.projectField)
        var metadata: [String: Any] = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
        var loadBody: [String: Any] = [:]
        if let configured {
            metadata["duetProject"] = configured
            loadBody["cloudaicompanionProject"] = configured
        }
        loadBody["metadata"] = metadata
        let load = try await post(Self.loadURL, body: loadBody, token: token, context: context)

        if load["currentTier"] == nil || load["currentTier"]?.isNull == true,
           load["ineligibleTiers"]?.arrayValue?.contains(where: { $0["reasonCode"]?.stringValue == "UNSUPPORTED_CLIENT" }) == true,
           load["paidTier"]?["name"]?.stringValue == nil {
            throw ProviderError.notConfigured("Gemini CLI no longer serves this Google account. Use the Antigravity provider instead.")
        }
        guard let project = load["cloudaicompanionProject"]?.stringValue ?? configured else {
            throw ProviderError.notConfigured("Gemini CLI needs your Google Cloud project id in settings.")
        }
        let quota = try await post(Self.quotaURL, body: ["project": project], token: token, context: context)
        let plan = load["paidTier"]?["name"]?.stringValue ?? load["currentTier"]?["name"]?.stringValue
        return try Self.snapshot(quota: quota, plan: plan, now: context.now())
    }

    private func post(_ url: URL, body: [String: Any], token: String, context: ProviderContext) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await context.http.send(request)
        } catch ProviderError.notSignedIn {
            throw ProviderError.expired("Gemini CLI's sign-in was rejected. Open Gemini CLI to sign in again.")
        } catch ProviderError.expired {
            throw ProviderError.expired("Google refused Gemini CLI's sign-in (HTTP 403). Your account may need a Gemini Code Assist licence, or open Gemini CLI to sign in again.")
        }
        guard let json = try? JSONValue(data: data), json.objectValue != nil else {
            throw ProviderError.unexpectedResponse("Gemini CLI's quota service did not answer with JSON.")
        }
        return json
    }

    /// One window per model, from its lowest `remainingFraction` bucket, keyed `model:<id>`.
    static func snapshot(quota: JSONValue, plan: String?, now: Date) throws -> ProviderSnapshot {
        guard let buckets = quota["buckets"]?.arrayValue else {
            throw ProviderError.unexpectedResponse("Gemini CLI's quota answer has no buckets.")
        }
        var lowest: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"]?.stringValue, !model.isEmpty,
                  let fraction = bucket["remainingFraction"]?.doubleValue else { continue }
            let reset = DateParsing.date(bucket["resetTime"])
            if let current = lowest[model], current.fraction <= fraction { continue }
            lowest[model] = (fraction, reset)
        }
        let readings = lowest.keys.sorted().map { model -> Reading in
            let entry = lowest[model]!
            return Reading(
                id: "model:\(model)", name: model,
                value: .window(QuotaWindow(
                    usedPercent: max(0, min(100, Int(((1 - entry.fraction) * 100).rounded()))),
                    period: .named("daily"),
                    resetsAt: entry.reset.flatMap { $0 > now ? $0 : nil }
                )),
                meterLabel: model
            )
        }
        return ProviderSnapshot(
            readings: readings,
            plan: plan,
            note: readings.isEmpty ? "Gemini CLI reported no quota for this account (API keys and Vertex AI have none)." : nil,
            menuBar: .tightest,
            fetchedAt: now
        )
    }
}
