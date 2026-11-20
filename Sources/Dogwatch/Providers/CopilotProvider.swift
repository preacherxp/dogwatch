import SwiftUI

// GitHub Copilot: the endpoint every official Copilot editor plugin calls to show its quota,
// `GET https://api.github.com/copilot_internal/user`, with the GitHub sign-in the Copilot
// plugins (JetBrains, Neovim, Xcode) keep in plain JSON under ~/.config/github-copilot.
// The endpoint is not in GitHub's REST documentation; it is what Copilot's own clients use.
//
// What it returns (shape checked live on this Mac on 2026-11-19, Free plan):
// - `quota_snapshots.{chat, completions, premium_interactions}`, each with `entitlement`,
//   `remaining`, `percent_remaining`, `unlimited`, `has_quota`, `token_based_billing`,
//   `credits_used`, `overage_count`, `quota_reset_at`;
// - `quota_reset_date_utc` (ISO 8601) and `quota_reset_date` (a date), `copilot_plan`,
//   `access_type_sku`, plus personal fields (`login`, `id`, `analytics_tracking_id`) that are
//   never read.
// Since June 2026 every plan is billed in GitHub AI Credits, and GitHub does not publish the
// included credits on this or any other endpoint. So AI credits are shown as credits used
// (`premium_interactions.credits_used`, not summed with other snapshots, which can repeat the
// same pool) and become a percentage only when the user types their allowance in
// `config.json` `limits` (`"ai_credits": 1500`). Quotas the endpoint does give a total for
// (`has_quota`, not `unlimited`, `entitlement > 0`, e.g. Free plan chat and completions) are
// windows from GitHub's own `percent_remaining`. Quotas reset at 00:00 UTC on the 1st.
//
// References, read 2026-11-19:
// - https://docs.github.com/en/copilot/concepts/billing/individual-plans (AI credits per plan)
// - https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing
// - Endpoint and headers: CodexBar docs/copilot.md (https://github.com/steipete/CodexBar)
// - Token file: written by the Copilot plugins; `hosts.json` is the older name of `apps.json`.

struct CopilotProvider: UsageProvider {
    static let appsPath = ".config/github-copilot/apps.json"
    static let hostsPath = ".config/github-copilot/hosts.json"
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    let descriptor = ProviderDescriptor(
        id: "copilot",
        name: "GitHub Copilot",
        glyph: ProviderGlyph(symbol: "airplane"),
        tint: Color(red: 0.62, green: 0.5, blue: 0.98),
        category: .subscription,
        stability: .undocumented,
        credential: .toolStore(ToolStore(kind: .file, location: "~/.config/github-copilot/apps.json")),
        summary: "Monthly Copilot quotas and AI credits used",
        reads: "The GitHub sign-in the Copilot editor plugins keep in ~/.config/github-copilot/apps.json (or the older hosts.json), read as stored; with several sign-ins, the first github.com entry in key order. The token is sent only as the Authorization header of GET https://api.github.com/copilot_internal/user and held in memory for that one request. Your GitHub login and id in the answer are ignored. Dogwatch never refreshes or writes the sign-in. GitHub publishes no AI credit allowance, so AI credits show as credits used unless you set your allowance under limits in config.json.",
        source: "Copilot's own quota endpoint, with the Copilot plugins' sign-in",
        allowedHosts: ["api.github.com"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        idleLabel: "Sign in to Copilot in your editor",
        documentation: URL(string: "https://docs.github.com/en/copilot/concepts/billing/individual-plans"),
        timeout: 20,
        localSources: [ToolStore(kind: .file, location: "~/.config/github-copilot/hosts.json")]
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        let apps = context.home.appendingPathComponent(Self.appsPath)
        let hosts = context.home.appendingPathComponent(Self.hostsPath)
        return context.local.fileExists(apps) || context.local.fileExists(hosts)
            ? .available
            : .unavailable("Copilot is not signed in in an editor")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let token = try Self.storedToken(in: context)
        let headers = [
            "Authorization": "token \(token)",
            "X-Github-Api-Version": "2025-04-01",
            "Editor-Version": "Dogwatch/1.0",
            "User-Agent": "Dogwatch",
        ]
        let json: JSONValue
        do {
            json = try await context.http.getJSON(Self.usageURL, headers: headers)
        } catch ProviderError.notSignedIn, ProviderError.expired {
            throw ProviderError.expired("GitHub rejected Copilot's sign-in. Open Copilot in your editor to sign in again.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// The OAuth token the Copilot plugins stored, as stored. GitHub's Copilot tokens carry no
    /// expiry in the file; a JWT's own `exp` is still checked, and a rejected token means
    /// signing in again in the editor.
    static func storedToken(in context: ProviderContext) throws -> String {
        let notSignedIn = ProviderError.notSignedIn("Copilot sign-in not found. Sign in to Copilot in your editor.")
        for path in [appsPath, hostsPath] {
            let url = context.home.appendingPathComponent(path)
            guard context.local.fileExists(url) else { continue }
            guard let data = try? context.local.read(url), let json = try? JSONValue(data: data),
                  let entries = json.objectValue
            else { throw notSignedIn }
            // apps.json keys are "github.com:<app id>"; hosts.json keys are "github.com".
            let keys = entries.keys.filter { $0 == "github.com" || $0.hasPrefix("github.com:") }.sorted()
            guard let first = keys.first, let entry = entries[first] else { continue }
            do {
                return try StoredCredential.token(in: entry, tokenPath: "oauth_token", tool: "Copilot", now: context.now())
            } catch ProviderError.expired {
                throw ProviderError.expired("Copilot's sign-in has expired. Open Copilot in your editor to sign in again.")
            } catch {
                throw notSignedIn
            }
        }
        throw notSignedIn
    }

    /// Readings from the `copilot_internal/user` answer:
    /// - `chat`, `completions`, `premium`: quotas GitHub gives a total for, as windows;
    /// - `ai_credits`: AI credits used this month, as a window GitHub gives no total for; it
    ///   becomes a percentage once the user types their plan's allowance.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let snapshots = json["quota_snapshots"]?.objectValue else {
            if json["access_type_sku"]?.stringValue == "subscription_ended" {
                throw ProviderError.notSignedIn("Your Copilot subscription has ended.")
            }
            throw ProviderError.unexpectedResponse("Copilot's answer has no quota_snapshots.")
        }
        let reset = DateParsing.iso8601(json["quota_reset_date_utc"]?.stringValue)
            ?? DateParsing.iso8601(json["quota_reset_date"]?.stringValue)
        var readings: [Reading] = []

        let kinds: [(key: String, id: String, name: String, meter: String)] = [
            ("premium_interactions", "premium", "Premium requests", "Premium"),
            ("chat", "chat", "Chat", "Chat"),
            ("completions", "completions", "Completions", "Completions"),
        ]
        for kind in kinds {
            guard let quota = snapshots[kind.key], quota["unlimited"]?.boolValue != true,
                  quota["has_quota"]?.boolValue == true,
                  let entitlement = quota["entitlement"]?.doubleValue, entitlement > 0,
                  let percentLeft = quota["percent_remaining"]?.doubleValue
            else { continue }
            let used = 100 - max(0, min(100, percentLeft))
            readings.append(Reading(
                id: kind.id,
                name: kind.name,
                value: .window(QuotaWindow(
                    usedPercent: Int(used.rounded()),
                    period: .named("monthly"),
                    resetsAt: reset ?? DateParsing.date(quota["quota_reset_at"])
                )),
                meterLabel: kind.meter
            ))
        }

        // AI credits: shown as used, never as a share of an allowance GitHub doesn't publish.
        if let premium = snapshots["premium_interactions"],
           premium["token_based_billing"]?.boolValue == true || json["token_based_billing"]?.boolValue == true,
           let creditsUsed = premium["credits_used"]?.doubleValue, creditsUsed >= 0 {
            readings.append(Reading(
                id: "ai_credits",
                name: "AI credits",
                value: .window(.unmetered(
                    used: Amount(value: creditsUsed, unit: .credits),
                    period: .named("this month"),
                    resetsAt: reset ?? DateParsing.date(premium["quota_reset_at"])
                ))
            ))
        }

        let sku = json["access_type_sku"]?.stringValue
        return ProviderSnapshot(
            readings: readings,
            plan: plan(sku: sku, copilotPlan: json["copilot_plan"]?.stringValue),
            note: readings.isEmpty ? "No Copilot quota reported" : nil,
            fetchedAt: now
        )
    }

    /// A plan name from `access_type_sku`, when it is one of the known ones. Unknown SKUs are
    /// left out rather than shown raw.
    static func plan(sku: String?, copilotPlan: String?) -> String? {
        switch sku {
        case "free_limited_copilot"?: return "Free"
        case "subscription_ended"?: return "Ended"
        default:
            switch copilotPlan {
            case "business"?: return "Business"
            case "enterprise"?: return "Enterprise"
            default: return nil
            }
        }
    }
}
