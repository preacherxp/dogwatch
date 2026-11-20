import Foundation
import XCTest
@testable import Dogwatch

/// The declarative engine behind custom providers and built-in definitions.
final class DeclarativeProviderTests: XCTestCase {
    private let key = "test-key-not-real"

    private func spec(_ json: String) throws -> CustomProviderSpec {
        try CustomProviderSpec(json: try JSONValue(data: Data(json.utf8)))
    }

    private func run(_ json: String, fixture: String, prefix: String, settings: ProviderSettings = ProviderSettings()) async throws -> (ProviderSnapshot, FixtureTransport, DeclarativeProvider) {
        let provider = DeclarativeProvider(spec: try spec(json))
        let transport = FixtureTransport()
        try transport.respond(to: prefix, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        return (snapshot, transport, provider)
    }

    func testBalanceInTenThousandthsOfADollar() async throws {
        let (snapshot, transport, provider) = try await run("""
        {"id": "custom-novita", "name": "Novita", "url": "https://api.novita.ai/openapi/v1/billing/balance/detail",
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "balance", "name": "Balance", "kind": "balance", "remaining": "availableBalance", "unit": "USD", "scale": 0.0001}]}
        """, fixture: "custom/novita-balance.json", prefix: "https://api.novita.ai/")

        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 125, unit: .currency("USD")))
        XCTAssertNil(snapshot.primary()?.remainingPercent)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(provider.descriptor.allowedHosts, ["api.novita.ai"])
        XCTAssertEqual(provider.descriptor.stability, .unverified)
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: key), [])
        assertFollowsRules(provider)
    }

    func testUsedOfLimitWithAUnixReset() async throws {
        let (snapshot, _, _) = try await run("""
        {"id": "custom-elevenlabs", "name": "ElevenLabs", "url": "https://api.elevenlabs.io/v1/user/subscription",
         "headers": {"xi-api-key": "{key}"},
         "readings": [{"id": "credits", "name": "Credits", "kind": "window", "used": "character_count", "limit": "character_limit",
                       "unit": "credits", "period": "monthly", "reset": "next_character_count_reset_unix", "resetFormat": "unixSeconds"}]}
        """, fixture: "custom/elevenlabs-subscription.json", prefix: "https://api.elevenlabs.io/")

        let window = try XCTUnwrap(snapshot.primary()?.window)
        XCTAssertEqual(window.usedPercent, 12)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(window.limit, Amount(value: 100_000, unit: .credits))
        XCTAssertEqual(snapshot.primary()?.detailText, "12% used · monthly")
    }

    func testSpendAgainstABudgetOnALocalGateway() async throws {
        let (snapshot, _, _) = try await run("""
        {"id": "custom-litellm", "name": "LiteLLM", "url": "http://localhost:4000/key/info",
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "spend", "name": "Spend", "kind": "spend", "amount": "info.spend", "budget": "info.max_budget",
                       "unit": "USD", "period": "30 days", "reset": "info.budget_reset_at"}]}
        """, fixture: "custom/litellm-key.json", prefix: "http://localhost:4000/")

        XCTAssertEqual(snapshot.primary()?.remainingPercent, 75)
        XCTAssertEqual(snapshot.primary()?.resetsAt, DateParsing.iso8601("2026-12-14T09:30:12+00:00"))
    }

    /// An API that reports errors in the body with HTTP 200. The fields are a made-up example:
    /// don't copy them for a real provider.
    func testErrorsReturnedWithHTTP200AreErrors() async {
        do {
            _ = try await run("""
            {"id": "custom-example-plan", "name": "Example plan", "url": "https://api.example.com/v1/plan/usage",
             "headers": {"Authorization": "Bearer {key}"},
             "okWhen": {"path": "status.code", "equals": 0}, "errorMessage": "status.message",
             "readings": [{"id": "monthly", "kind": "window", "usedPercent": "data.used_percent"}]}
            """, fixture: "custom/status-in-body-error.json", prefix: "https://api.example.com/")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("no active plan on this account"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSettingsInHeadersKeyKindPeriodFromTheAnswerAndTint() async throws {
        let json = """
        {"id": "custom-org", "name": "Org gateway", "url": "https://api.example.com/v1/balance",
         "headers": {"Authorization": "Bearer {key}", "X-Organization": "{field:org}"},
         "fields": [{"id": "org", "label": "Organization id"}],
         "keyKind": "cookie", "tint": "#3FA7D6",
         "readings": [{"id": "spend", "kind": "spend", "amount": "spend", "unit": "USD", "period": "$.period"}]}
        """
        let provider = DeclarativeProvider(spec: try spec(json))
        guard case .pastedKey(let key) = provider.descriptor.credential else { return XCTFail("needs a key") }
        XCTAssertEqual(key.kind, .cookie)

        let transport = FixtureTransport()
        transport.respond(to: "https://api.example.com/", body: Data(#"{"spend": 12.5, "period": "billing period"}"#.utf8))
        let settings = ProviderSettings(values: ["org": "org-123"])
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: self.key, settings: settings))
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "X-Organization"), "org-123")
        XCTAssertEqual(snapshot.primary()?.spend?.period, "billing period")
        XCTAssertEqual(snapshot.primary()?.detailText, "$12.50 spent · billing period")

        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: self.key))
        XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "X-Organization"), "An empty setting leaves its header out.")

        XCTAssertThrowsError(try spec(json.replacingOccurrences(of: "\"keyKind\": \"cookie\"", with: "\"keyKind\": \"password\"")))
        XCTAssertThrowsError(try spec(json.replacingOccurrences(of: "#3FA7D6", with: "teal")))
        XCTAssertThrowsError(try spec(json.replacingOccurrences(of: "{field:org}", with: "{field:team}")), "An undeclared field in a header is rejected.")
    }

    func testAWrongPathIsAReadableError() async {
        do {
            _ = try await run("""
            {"id": "custom-novita", "name": "Novita", "url": "https://api.novita.ai/openapi/v1/billing/balance/detail",
             "headers": {"Authorization": "Bearer {key}"},
             "readings": [{"id": "balance", "kind": "balance", "remaining": "data.available_balance"}]}
            """, fixture: "custom/novita-balance.json", prefix: "https://api.novita.ai/")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertEqual(error.localizedDescription, "Novita: no value at data.available_balance.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRegionalBaseURLsAndAccountFields() async throws {
        let json = """
        {"id": "custom-moonshot", "name": "Moonshot", "url": "{baseURL}/v1/users/{field:account}/balance",
         "baseURLs": [{"label": "International", "url": "https://api.moonshot.ai"}, {"label": "China", "url": "https://api.moonshot.cn"}],
         "fields": [{"id": "account", "label": "Account"}],
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "balance", "kind": "balance", "remaining": "availableBalance", "unit": "CNY"}]}
        """
        let provider = DeclarativeProvider(spec: try spec(json))
        XCTAssertEqual(provider.descriptor.allowedHosts, ["api.moonshot.ai", "api.moonshot.cn"])
        let transport = FixtureTransport()
        try transport.respond(to: "https://api.moonshot.cn/v1/users/me/balance", fixture: "custom/novita-balance.json")
        let settings = ProviderSettings(baseURL: URL(string: "https://api.moonshot.cn"), values: ["account": "me"])
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        XCTAssertEqual(snapshot.primary()?.amount?.unit, .currency("CNY"))
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")

        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, key: key, settings: ProviderSettings()))
            XCTFail("a missing field should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
        }
    }

    func testInvalidDefinitionsAreRejectedWithAReason() {
        let cases: [(String, String)] = [
            (#"{"name": "X", "url": "https://a.example.com", "readings": []}"#, "id"),
            (#"{"id": "Bad Id", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "balance", "remaining": "a"}]}"#, "valid id"),
            (#"{"id": "custom-x", "name": "X", "url": "http://a.example.com", "readings": [{"kind": "balance", "remaining": "a"}]}"#, "https"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com?k={key}", "readings": [{"kind": "balance", "remaining": "a"}]}"#, "{key}"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "balance"}]}"#, "remaining"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "window", "used": "a"}]}"#, "window needs"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "balance", "remaining": "a..b"}]}"#, "path"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "meter", "remaining": "a"}]}"#, "kind"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try spec(json), json) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(error.localizedDescription) should mention \(expected)")
            }
        }
    }

    func testAnInvalidBuiltInDefinitionReportsInsteadOfCrashing() {
        let provider = DeclarativeProvider(definition: #"{"id": "broken", "name": "Broken"}"#)
        XCTAssertEqual(provider.id, "broken")
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor)).isAvailable)
    }

    func testMapsHTTPErrors() async throws {
        let provider = DeclarativeProvider(spec: try spec("""
        {"id": "custom-poe", "name": "Poe", "url": "https://api.poe.com/usage/current_balance",
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "points", "kind": "balance", "remaining": "current_point_balance", "unit": "points"}]}
        """))
        await assertMapsHTTPErrors(provider, url: "https://api.poe.com/", key: key)
    }

    func testJSONPaths() throws {
        let json = try JSONValue(data: Data(#"{"a": {"b": [{"c": "12.5"}, {"c": null}]}, "n": 3}"#.utf8))
        XCTAssertEqual(json.value(at: "a.b[0].c")?.doubleValue, 12.5)
        XCTAssertEqual(json.value(at: "$.a.b[1].c"), .null)
        XCTAssertEqual(json.value(at: "$.n")?.doubleValue, 3)
        XCTAssertNil(json.value(at: "a.b[5].c"))
        XCTAssertNil(json.value(at: "a..b"))
        XCTAssertNil(json.value(at: "a.b[x]"))
        XCTAssertNil(json.value(at: ""))
    }

    // MARK: Options added for the built-in definitions (all optional; definitions without them behave as before)

    private func snapshot(_ definition: String, answer: String, baseURL: URL? = nil) throws -> ProviderSnapshot {
        try DeclarativeProvider.snapshot(from: try JSONValue(data: Data(answer.utf8)), spec: try spec(definition), now: Date(), baseURL: baseURL)
    }

    func testFilterSteps() throws {
        let json = try JSONValue(data: Data(#"{"rows": [{"c": "CNY", "v": "1"}, {"c": "USD", "v": "2", "n": [{"k": 5, "x": [7, 8]}]}], "top": [{"id": 3, "v": 9}]}"#.utf8))
        XCTAssertEqual(DeclarativePath.value(in: json, at: "rows[c=USD].v")?.doubleValue, 2)
        XCTAssertEqual(DeclarativePath.value(in: json, at: "$.rows[c=CNY].v")?.doubleValue, 1)
        XCTAssertEqual(DeclarativePath.value(in: json, at: "rows[c=USD].n[k=5].x[1]")?.doubleValue, 8)
        XCTAssertEqual(DeclarativePath.value(in: json, at: "top[id=3].v")?.doubleValue, 9, "numbers compare as text")
        XCTAssertEqual(DeclarativePath.value(in: json, at: "rows[1].v")?.doubleValue, 2, "plain paths are unchanged")
        XCTAssertNil(DeclarativePath.value(in: json, at: "rows[c=EUR].v"))
        XCTAssertNil(DeclarativePath.value(in: json, at: "top.v[c=USD]"))
        for valid in ["a", "a.b[0]", "a[k=v]", "a[k=v].b", "a[k=v][0].b", "$.a[k = v].b"] {
            XCTAssertTrue(DeclarativePath.isValid(valid), valid)
        }
        for invalid in ["", "a..b", "a[k=]", "a[=v]", "a[k=v].", "a[k=v", "a[x]"] {
            XCTAssertFalse(DeclarativePath.isValid(invalid), invalid)
        }
    }

    func testOptionalReadingsComeAndGo() throws {
        let definition = """
        {"id": "custom-x", "name": "X", "url": "https://a.example.com",
         "readings": [{"id": "pass", "kind": "balance", "remaining": "pass.left", "optional": true},
                      {"id": "main", "kind": "balance", "remaining": "main"}]}
        """
        XCTAssertEqual(try snapshot(definition, answer: #"{"pass": {"left": 3}, "main": 5}"#).readings.map(\.id), ["pass", "main"])
        XCTAssertEqual(try snapshot(definition, answer: #"{"pass": null, "main": 5}"#).readings.map(\.id), ["main"])
        XCTAssertEqual(try snapshot(definition, answer: #"{"main": 5}"#).readings.map(\.id), ["main"])
        XCTAssertThrowsError(try snapshot(definition, answer: #"{"pass": {"left": 3}}"#)) { error in
            XCTAssertEqual(error.localizedDescription, "X: no value at main.", "a reading that isn't optional still fails")
        }
    }

    func testRemainingPercentNullIsZeroMeterLabelAndBalanceReset() throws {
        let snap = try snapshot("""
        {"id": "custom-x", "name": "X", "url": "https://a.example.com",
         "readings": [{"id": "week", "kind": "window", "remainingPercent": "w.left", "meterLabel": "Week", "reset": "w.at"},
                      {"id": "frac", "kind": "window", "remainingPercent": "f", "fraction": true},
                      {"id": "usd", "kind": "balance", "remaining": "usd", "nullIsZero": true},
                      {"id": "gone", "kind": "balance", "remaining": "gone"},
                      {"id": "credit", "kind": "balance", "remaining": "c.left", "total": "c.of", "reset": "c.at"}]}
        """, answer: #"{"w": {"left": 40, "at": "2026-11-23T00:00:00Z"}, "f": 0.25, "usd": null, "gone": null, "c": {"left": 30, "of": 120, "at": 1796083200}}"#)
        let week = try XCTUnwrap(snap.readings.first { $0.id == "week" })
        XCTAssertEqual(week.window?.usedPercent, 60)
        XCTAssertEqual(week.remainingPercent, 40)
        XCTAssertEqual(week.meterLabel, "Week")
        XCTAssertEqual(week.resetsAt, DateParsing.iso8601("2026-11-23T00:00:00Z"))
        XCTAssertEqual(snap.readings.first { $0.id == "frac" }?.remainingPercent, 25)
        XCTAssertEqual(snap.readings.first { $0.id == "usd" }?.amount, Amount(value: 0, unit: .currency("USD")))
        XCTAssertNil(snap.readings.first { $0.id == "gone" }, "null without nullIsZero still means none")
        let credit = try XCTUnwrap(snap.readings.first { $0.id == "credit" })
        XCTAssertEqual(credit.remainingPercent, 25)
        XCTAssertEqual(credit.resetsAt, Date(timeIntervalSince1970: 1_796_083_200))
    }

    func testUnitByBaseURL() throws {
        let definition = """
        {"id": "custom-x", "name": "X", "url": "{baseURL}/balance",
         "baseURLs": [{"label": "Global", "url": "https://a.example.com", "unit": "USD"}, {"label": "China", "url": "https://a.example.cn", "unit": "CNY"}],
         "readings": [{"id": "b", "kind": "balance", "remaining": "b", "unit": "{baseURL.unit}"}]}
        """
        XCTAssertEqual(try snapshot(definition, answer: #"{"b": 4}"#, baseURL: URL(string: "https://a.example.com")).readings.first?.amount?.unit, .currency("USD"))
        XCTAssertEqual(try snapshot(definition, answer: #"{"b": 4}"#, baseURL: URL(string: "https://a.example.cn/")).readings.first?.amount?.unit, .currency("CNY"))
        XCTAssertThrowsError(try snapshot(definition, answer: #"{"b": 4}"#, baseURL: URL(string: "https://elsewhere.example.org"))) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "notConfigured", "an unknown host never gets a guessed unit")
        }
        XCTAssertThrowsError(try spec("""
        {"id": "custom-x", "name": "X", "url": "{baseURL}/balance",
         "baseURLs": [{"label": "Global", "url": "https://a.example.com", "unit": "USD"}, {"label": "China", "url": "https://a.example.cn"}],
         "readings": [{"id": "b", "kind": "balance", "remaining": "b", "unit": "{baseURL.unit}"}]}
        """)) { XCTAssertTrue($0.localizedDescription.contains("needs a \"unit\"")) }
    }

    func testCustomBaseURL() async throws {
        let provider = DeclarativeProvider(spec: try spec("""
        {"id": "custom-gw", "name": "Gateway", "url": "{baseURL}/key/info", "customBaseURL": true,
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "spend", "kind": "spend", "amount": "info.spend", "budget": "info.max_budget", "unit": "USD"}]}
        """))
        XCTAssertTrue(provider.descriptor.acceptsCustomBaseURL)
        XCTAssertEqual(provider.descriptor.allowedHosts, [])
        assertFollowsRules(provider)
        let transport = FixtureTransport()
        try transport.respond(to: "http://127.0.0.1:4000/", fixture: "custom/litellm-key.json")
        let settings = ProviderSettings(baseURL: URL(string: "http://127.0.0.1:4000"))
        let snap = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: key, settings: settings))
        XCTAssertEqual(snap.primary()?.remainingPercent, 75)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "http://127.0.0.1:4000/key/info")

        for (json, expected) in [
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com/x", "customBaseURL": true, "readings": [{"kind": "balance", "remaining": "a"}]}"#, "{baseURL}"),
            (#"{"id": "custom-x", "name": "X", "url": "https://a.example.com/{baseURL}", "customBaseURL": true, "readings": [{"kind": "balance", "remaining": "a"}]}"#, "start with {baseURL}"),
            (#"{"id": "custom-x", "name": "X", "url": "{baseURL}/x", "readings": [{"kind": "balance", "remaining": "a"}]}"#, "{baseURL}"),
        ] {
            XCTAssertThrowsError(try spec(json), json) { XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription) }
        }
    }

    func testPrimaryFromTheAnswer() throws {
        let definition = """
        {"id": "custom-x", "name": "X", "url": "https://a.example.com", "primary": "a",
         "primaryFrom": {"path": "spending", "readings": {"A": "a", "B": "b", "C": "c"}},
         "readings": [{"id": "a", "kind": "balance", "remaining": "a"}, {"id": "b", "kind": "balance", "remaining": "b"},
                      {"id": "c", "kind": "balance", "remaining": "c", "optional": true}]}
        """
        XCTAssertEqual(try snapshot(definition, answer: #"{"spending": "B", "a": 1, "b": 2}"#).primary()?.id, "b")
        XCTAssertEqual(try snapshot(definition, answer: #"{"spending": "Z", "a": 1, "b": 2}"#).primary()?.id, "a", "unknown values fall back to primary")
        XCTAssertEqual(try snapshot(definition, answer: #"{"spending": "C", "a": 1, "b": 2}"#).primary()?.id, "a", "a reading that isn't there falls back")
        XCTAssertThrowsError(try spec("""
        {"id": "custom-x", "name": "X", "url": "https://a.example.com", "primaryFrom": {"path": "s", "readings": {"A": "nope"}},
         "readings": [{"id": "a", "kind": "balance", "remaining": "a"}]}
        """)) { XCTAssertTrue($0.localizedDescription.contains("nope")) }
    }

    func testRefreshFloorAndKeyTexts() throws {
        let provider = DeclarativeProvider(spec: try spec("""
        {"id": "custom-x", "name": "X", "url": "https://a.example.com", "headers": {"Authorization": "Bearer {key}"},
         "minimumRefreshMinutes": 10, "refreshMinutes": 5, "keyAdvice": "Use a read-only key.", "keyPlaceholder": "ex-…",
         "readings": [{"kind": "balance", "remaining": "a"}]}
        """))
        XCTAssertEqual(provider.descriptor.minimumRefreshInterval, 600)
        XCTAssertEqual(provider.descriptor.defaultRefreshInterval, 600, "the default never undercuts the minimum")
        guard case .pastedKey(let key) = provider.descriptor.credential else { return XCTFail("needs a key") }
        XCTAssertEqual(key.advice, "Use a read-only key.")
        XCTAssertEqual(key.placeholder, "ex-…")
        XCTAssertThrowsError(try spec(#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "minimumRefreshMinutes": 0.1, "readings": [{"kind": "balance", "remaining": "a"}]}"#))

        let plain = DeclarativeProvider(spec: try spec(#"{"id": "custom-x", "name": "X", "url": "https://a.example.com", "readings": [{"kind": "balance", "remaining": "a"}]}"#))
        XCTAssertEqual(plain.descriptor.minimumRefreshInterval, 60, "unchanged default")
        XCTAssertEqual(plain.descriptor.defaultRefreshInterval, 300, "unchanged default")
        XCTAssertFalse(plain.descriptor.acceptsCustomBaseURL)
    }

    func testEveryBuiltInDefinitionParses() {
        for provider in ProviderRegistry.builtIn {
            guard let declarative = provider as? DeclarativeProvider else { continue }
            XCTAssertNotNil(declarative.spec, "\(declarative.id): \(declarative.descriptor.summary)")
        }
    }
}
