import SwiftUI

// OpenCode Go: the usage endpoint OpenCode built for its own CLI,
// `GET https://opencode.ai/zen/go/v1/usage`, with a credential the OpenCode CLI stored.
// Not in OpenCode's public documentation; the plan's limits are.
//
// Limits (https://opencode.ai/docs/go/, read 2026-11-19): one allowance shared by the paid models;
// - a 5-hour limit, 20% of the monthly allowance, starting at first use;
// - a weekly limit, 50% of the monthly allowance, resetting Monday 00:00 UTC;
// - the monthly allowance, resetting when a new paid period starts.
// The answer (shape checked live on this Mac on 2026-11-19 with the OpenCode sign-in):
//   {"usage": {"rolling": {"status", "percent", "resetsAt"}, "weekly": {...}, "monthly": {...}}}
// `percent` is 0-100 used, `resetsAt` ISO 8601. `status` was "ok"; OpenCode's own draft of
// this endpoint (github.com/anomalyco/opencode pull 32913) also names "rate-limited".
// All three windows are readings; the one with least left is the primary, and a window
// OpenCode reports as limited is marked binding.
//
// Credentials, read as stored and never refreshed or written:
// - v2: the `credential` table of OpenCode's SQLite database (~/.local/share/opencode/opencode.db,
//   honouring XDG_DATA_HOME and OPENCODE_DB), read with `queryReadOnly` (never locked or written, recent changes included);
// - older installs: ~/.local/share/opencode/auth.json, only when the database has no credential table.
// Order: the `opencode-go` API key, then the `opencode` sign-in's access token if it hasn't
// expired. A rejected credential (401/403) moves on to the next; none is ever renewed.

struct OpenCodeGoProvider: UsageProvider {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    let descriptor = ProviderDescriptor(
        id: "opencode-go",
        name: "OpenCode Go",
        glyph: ProviderGlyph(symbol: "terminal"),
        tint: Color(red: 0.95, green: 0.6, blue: 0.3),
        category: .subscription,
        stability: .undocumented,
        credential: .toolStore(ToolStore(kind: .file, location: "~/.local/share/opencode/opencode.db (credential table)")),
        summary: "Go plan 5-hour, weekly and monthly limits",
        reads: "Reads OpenCode's stored credentials from the credential table of ~/.local/share/opencode/opencode.db (opened read-only), or from ~/.local/share/opencode/auth.json on older installs: the OpenCode Go API key, else the OpenCode sign-in if it hasn't expired. The credential is sent only as the Authorization header of GET https://opencode.ai/zen/go/v1/usage and held in memory for that request. Dogwatch never refreshes or writes OpenCode's sign-in.",
        source: "OpenCode's Go usage endpoint, with OpenCode's stored sign-in",
        allowedHosts: ["opencode.ai"],
        minimumRefreshInterval: 60,
        defaultRefreshInterval: 300,
        idleLabel: "Open OpenCode",
        documentation: URL(string: "https://opencode.ai/docs/go/"),
        timeout: 20,
        localSources: [ToolStore(kind: .file, location: "~/.local/share/opencode/auth.json")]
    )

    /// One stored credential, in the order it is tried.
    struct Candidate: Equatable {
        enum Kind: Equatable { case goKey, openCodeSignIn }
        let kind: Kind
        let token: String
    }

    func availability(in context: ProviderContext) -> ProviderAvailability {
        let paths = Self.paths(in: context)
        return context.local.fileExists(paths.database) || context.local.fileExists(paths.legacy)
            ? .available
            : .unavailable("OpenCode is not installed")
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        let candidates = try Self.candidates(in: context)
        var rejectedGoKey = false
        for candidate in candidates {
            do {
                let json = try await context.http.getJSON(Self.usageURL, headers: [
                    "Authorization": "Bearer \(candidate.token)",
                    "User-Agent": "Dogwatch",
                ])
                var snapshot = try Self.snapshot(from: json, now: context.now())
                if rejectedGoKey, candidate.kind == .openCodeSignIn {
                    snapshot.note = [snapshot.note, "Read with your OpenCode sign-in: the OpenCode Go key stored in OpenCode was rejected."]
                        .compactMap { $0 }.joined(separator: " ")
                }
                return snapshot
            } catch ProviderError.notSignedIn, ProviderError.expired {
                if candidate.kind == .goKey { rejectedGoKey = true }
                continue
            }
        }
        throw ProviderError.expired(rejectedGoKey && candidates.count == 1
            ? "OpenCode Go rejected the key stored in OpenCode. Open OpenCode to connect OpenCode Go again."
            : "OpenCode rejected its stored sign-in. Open OpenCode to sign in again.")
    }

    // MARK: Credentials

    static func paths(in context: ProviderContext) -> (database: URL, legacy: URL) {
        let env = context.local.environment
        let data: URL
        if let xdg = env["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            data = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            data = context.home.appendingPathComponent(".local/share", isDirectory: true)
        }
        let folder = data.appendingPathComponent("opencode", isDirectory: true)
        var database = folder.appendingPathComponent("opencode.db")
        if let override = env["OPENCODE_DB"], !override.isEmpty, override != ":memory:" {
            database = override.hasPrefix("/") ? URL(fileURLWithPath: override) : folder.appendingPathComponent(override)
        }
        return (database, folder.appendingPathComponent("auth.json"))
    }

    /// The credentials to try, in order. Throws "sign in" when there are none, and "sign in
    /// again" when the only ones are expired.
    static func candidates(in context: ProviderContext) throws -> [Candidate] {
        let paths = paths(in: context)
        var entries: [(integration: String, active: Bool?, value: JSONValue)] = []
        var fromDatabase = false
        if context.local.fileExists(paths.database),
           let rows = try? context.local.queryReadOnly(
               paths.database,
               "SELECT integration_id, value, active FROM credential WHERE integration_id IN ('opencode-go', 'opencode')"
           ) {
            fromDatabase = true
            for row in rows {
                guard let integration = row["integration_id"]?.stringValue,
                      let text = row["value"]?.stringValue,
                      let value = try? JSONValue(data: Data(text.utf8))
                else { continue }
                entries.append((integration, row["active"]?.boolValue, value))
            }
        }
        // An existing credential table is authoritative, so a stale auth.json is never used.
        if !fromDatabase, context.local.fileExists(paths.legacy),
           let data = try? context.local.read(paths.legacy), let json = try? JSONValue(data: data) {
            for integration in ["opencode-go", "opencode"] {
                if let value = json[integration] { entries.append((integration, nil, value)) }
            }
        }
        if !fromDatabase, !context.local.fileExists(paths.legacy), !context.local.fileExists(paths.database) {
            throw ProviderError.notInstalled("OpenCode is not installed.")
        }

        var candidates: [Candidate] = []
        var sawExpired = false
        for (integration, kind) in [("opencode-go", Candidate.Kind.goKey), ("opencode", .openCodeSignIn)] {
            // Active rows first; a row OpenCode marked inactive is never used.
            let rows = entries.filter { $0.integration == integration && $0.active != false }
                .sorted { ($0.active == true ? 0 : 1) < ($1.active == true ? 0 : 1) }
            for row in rows {
                let path = row.value["access"]?.stringValue != nil ? "access" : "key"
                do {
                    let token = try StoredCredential.token(
                        in: row.value, tokenPath: path,
                        expiryPath: path == "access" ? "expires" : nil,
                        tool: "OpenCode", now: context.now()
                    )
                    if !candidates.contains(where: { $0.token == token }) {
                        candidates.append(Candidate(kind: kind, token: token))
                    }
                } catch ProviderError.expired {
                    sawExpired = true
                } catch {
                    continue
                }
            }
        }
        if candidates.isEmpty {
            if sawExpired { throw ProviderError.expired("OpenCode's sign-in has expired. Open OpenCode to sign in again.") }
            throw ProviderError.notSignedIn("OpenCode Go sign-in not found. Open OpenCode and connect OpenCode Go.")
        }
        return candidates
    }

    // MARK: Readings

    /// `five_hour`, `weekly` and `monthly` windows, in that order.
    static func snapshot(from json: JSONValue, now: Date) throws -> ProviderSnapshot {
        guard let usage = json["usage"]?.objectValue else {
            throw ProviderError.unexpectedResponse("OpenCode Go's answer has no usage.")
        }
        let windows: [(key: String, id: String, name: String, meter: String, period: WindowPeriod)] = [
            ("rolling", "five_hour", "5h window", "5h", .duration(5 * 3_600)),
            ("weekly", "weekly", "Weekly", "Week", .named("weekly")),
            ("monthly", "monthly", "Monthly", "Month", .named("monthly")),
        ]
        var readings: [Reading] = []
        for window in windows {
            guard let entry = usage[window.key], let percent = entry["percent"]?.doubleValue else { continue }
            let reset = DateParsing.date(entry["resetsAt"])
            let status = entry["status"]?.stringValue?.lowercased()
            let limited = status.map { $0 != "ok" && $0.contains("limit") } ?? false
            // A window whose reset has passed is a fresh one with nothing used yet.
            let ended = reset.map { $0 <= now } ?? false
            readings.append(Reading(
                id: window.id,
                name: window.name,
                value: .window(QuotaWindow(
                    usedPercent: ended ? 0 : Int(max(0, min(100, percent)).rounded()),
                    period: window.period,
                    resetsAt: ended ? nil : reset
                )),
                meterLabel: window.meter,
                detail: limited && !ended ? "Limit reached · \(window.period.label)"
                    : ended && window.id == "five_hour" ? "New 5h window · starts with your next request" : nil,
                isBinding: limited && !ended
            ))
        }
        return ProviderSnapshot(
            readings: readings,
            note: readings.isEmpty ? "No usage window reported" : nil,
            historyReadingID: readings.contains { $0.id == "weekly" } ? "weekly" : nil,
            fetchedAt: now
        )
    }
}
