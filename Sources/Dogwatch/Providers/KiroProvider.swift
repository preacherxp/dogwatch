import SwiftUI

// Kiro: the credit allowance Kiro CLI itself reads, with Kiro CLI's stored sign-in, read-only.
// Dogwatch never starts `kiro-cli`: per CodexBar its `/usage` command opens chat sessions, and
// Kiro's documentation doesn't say it leaves the sign-in untouched.
//
// Sources, read 2026-11-19:
// - Credits: https://kiro.dev/docs/cli/billing/ and https://kiro.dev/pricing/ (monthly plan credits
//   that reset at the start of the billing month; overage when enabled).
// - Endpoint and fields (Kiro CLI's private service, undocumented): the open source CodexBar,
//   https://github.com/steipete/CodexBar/blob/main/docs/kiro.md and
//   `Sources/CodexBarCore/Providers/Kiro/KiroUsageLimitsAPI.swift`:
//   `POST https://codewhisperer.us-east-1.amazonaws.com/` (Frankfurt profiles:
//   `https://q.eu-central-1.amazonaws.com/`) with `X-Amz-Target:
//   AmazonCodeWhispererService.GetUsageLimits`, `Content-Type: application/x-amz-json-1.0`, body
//   `{"profileArn": …}` or `{}` → `usageBreakdownList[] {resourceType "CREDIT",
//   currentUsageWithPrecision, usageLimitWithPrecision, currentOveragesWithPrecision,
//   overageCharges, currency, nextDateReset (Unix seconds), bonuses[]}`.
// - Credential: `~/Library/Application Support/kiro-cli/data.sqlite3`, table `auth_kv`, key
//   `kirocli:odic:token` (`access_token`, `expires_at` RFC 3339, as in the open source Amazon Q
//   Developer CLI it descends from: `crates/chat-cli/src/auth/builder_id.rs`), and table `state`,
//   key `api.codewhisperer.profile` (`arn`). Read with `queryReadOnly` (never locked or written); never refreshed. The access token is
//   short-lived and only Kiro CLI refreshes it.
// Kiro IDE's own sign-in is not read. Not verified against a real account.

struct KiroProvider: UsageProvider {
    static let databasePath = "Library/Application Support/kiro-cli/data.sqlite3"
    static let endpoints = [
        "us-east-1": URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!,
        "eu-central-1": URL(string: "https://q.eu-central-1.amazonaws.com/")!,
    ]

    let descriptor = ProviderDescriptor(
        id: "kiro",
        name: "Kiro",
        glyph: ProviderGlyph(symbol: "k.circle"),
        tint: Color(red: 0.6, green: 0.45, blue: 0.95),
        category: .subscription,
        stability: .unverified,
        credential: .toolStore(ToolStore(kind: .file, location: "~/Library/Application Support/kiro-cli/data.sqlite3")),
        summary: "Monthly credits used of your plan, and overage",
        reads: "Kiro CLI's sign-in token and profile from ~/Library/Application Support/kiro-cli/data.sqlite3, read-only and as stored. If the token has expired, Dogwatch asks you to open Kiro CLI and never refreshes it. Otherwise it is sent only in the Authorization header of one POST to Kiro's usage service (codewhisperer.us-east-1.amazonaws.com, or q.eu-central-1.amazonaws.com for Frankfurt profiles), the GetUsageLimits lookup Kiro CLI makes. Dogwatch never starts kiro-cli.",
        source: "Kiro CLI's GetUsageLimits lookup, with Kiro CLI's stored sign-in",
        allowedHosts: ["codewhisperer.us-east-1.amazonaws.com", "q.eu-central-1.amazonaws.com"],
        minimumRefreshInterval: 300,
        defaultRefreshInterval: 900,
        idleLabel: "Open Kiro CLI",
        documentation: URL(string: "https://kiro.dev/docs/cli/billing/"),
        timeout: 20
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        context.local.fileExists(context.home.appendingPathComponent(Self.databasePath))
            ? .available : .unavailable("Kiro CLI is not installed")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let database = context.home.appendingPathComponent(Self.databasePath)
        guard context.local.fileExists(database) else { throw ProviderError.notInstalled("Kiro CLI is not installed") }
        let tokenRow = try context.local.queryReadOnly(database, "SELECT value FROM auth_kv WHERE key = ?", ["kirocli:odic:token"])
        guard let tokenText = tokenRow.first?["value"]?.stringValue, let tokenJSON = try? JSONValue(data: Data(tokenText.utf8)) else {
            throw ProviderError.notSignedIn("Kiro CLI sign-in not found. Open Kiro CLI to sign in.")
        }
        let token = try StoredCredential.token(in: tokenJSON, tokenPath: "access_token", expiryPath: "expires_at", tool: "Kiro CLI", now: context.now())

        let profileRow = try? context.local.queryReadOnly(database, "SELECT value FROM state WHERE key = ?", ["api.codewhisperer.profile"])
        let arn = profileRow?.first?["value"]?.stringValue.flatMap { try? JSONValue(data: Data($0.utf8)) }?["arn"]?.stringValue
        let endpoint = try Self.endpoint(for: arn)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: arn.map { ["profileArn": $0] } ?? [:])
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("AmazonCodeWhispererService.GetUsageLimits", forHTTPHeaderField: "X-Amz-Target")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await context.http.send(request)
        } catch let error as ProviderError where error.kind == "notSignedIn" || error.kind == "expired" {
            throw ProviderError.expired("Kiro CLI's sign-in was rejected. Open Kiro CLI to sign in again.")
        }
        guard let json = try? JSONValue(data: data) else {
            throw ProviderError.unexpectedResponse("Kiro's usage service did not answer with JSON.")
        }
        return try Self.snapshot(from: json, now: context.now())
    }

    /// The region's endpoint from a profile ARN (`arn:aws:codewhisperer:<region>:<account>:profile/<id>`);
    /// US East without a profile, as Builder ID sign-ins have none.
    static func endpoint(for arn: String?) throws -> URL {
        guard let arn else { return endpoints["us-east-1"]! }
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[2] == "codewhisperer", parts[5].hasPrefix("profile/"),
              let url = endpoints[String(parts[3])]
        else {
            throw ProviderError.notConfigured("Kiro CLI's profile is in a region Dogwatch doesn't know.")
        }
        return url
    }

    /// `monthly` credits used of the plan's limit, and `overage` charges when there are any. When
    /// bonus credits are mixed into the total, the plan share can't be separated, so no
    /// percentage is shown.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        let credits = (json["usageBreakdownList"]?.arrayValue ?? []).filter { $0["resourceType"]?.stringValue == "CREDIT" }
        guard credits.count == 1, let credit = credits.first,
              let limit = credit["usageLimitWithPrecision"]?.doubleValue, limit >= 0,
              let total = credit["currentUsageWithPrecision"]?.doubleValue, total >= 0
        else {
            throw ProviderError.unexpectedResponse("Kiro's answer has no single CREDIT entry in usageBreakdownList.")
        }
        let overage = max(0, credit["currentOveragesWithPrecision"]?.doubleValue ?? 0)
        let planUsed = max(0, total - overage)
        let reset = DateParsing.epoch(credit["nextDateReset"]?.doubleValue ?? json["nextDateReset"]?.doubleValue)
            .flatMap { $0 > now ? $0 : nil }
        let hasBonus = !(credit["bonuses"]?.arrayValue ?? []).isEmpty

        var readings: [Reading] = []
        var note: String?
        if hasBonus {
            note = "Kiro counts bonus credits in the same total, so the plan's share can't be shown. \(UsageFormatters.amount(Amount(value: total, unit: .credits))) used this month."
        } else if limit > 0 {
            readings.append(Reading(
                id: "monthly", name: "Monthly credits",
                value: .window(QuotaWindow(
                    usedPercent: max(0, min(100, Int((planUsed / limit * 100).rounded()))),
                    period: .named("monthly"),
                    resetsAt: reset,
                    used: Amount(value: planUsed, unit: .credits),
                    limit: Amount(value: limit, unit: .credits)
                )),
                meterLabel: "Month"
            ))
        } else {
            note = "Kiro reports no plan credits for this account."
        }
        if let charges = credit["overageCharges"]?.doubleValue, charges > 0 {
            let currency = credit["currency"]?.stringValue.flatMap { $0.count == 3 ? $0.uppercased() : nil } ?? "USD"
            readings.append(Reading(
                id: "overage", name: "Overage",
                value: .spend(Spend(amount: Amount(value: charges, unit: .currency(currency)), period: "this month", resetsAt: reset))
            ))
        }
        return ProviderSnapshot(readings: readings, note: note, primaryHint: readings.isEmpty ? nil : "monthly", fetchedAt: now)
    }
}
