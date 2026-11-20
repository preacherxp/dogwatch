import Foundation
import XCTest
@testable import Dogwatch

/// The foundation gaps the provider batches found, closed after the merge.
final class FoundationGapTests: XCTestCase {
    private func window(_ id: String, _ used: Int) -> Reading {
        Reading(id: id, name: id, value: .window(QuotaWindow(usedPercent: used, period: .named("weekly"), resetsAt: nil)))
    }

    func testAReadingThatCantHeadlineIsNeverTheDefaultOrTheTightest() {
        var extra = Reading(id: "extra", name: "Extra usage", value: .spend(Spend(
            amount: Amount(value: 95, unit: .currency("USD")), period: "this month", budget: Amount(value: 100, unit: .currency("USD")))))
        extra.canHeadline = false
        let snapshot = ProviderSnapshot(readings: [window("weekly", 40), extra], menuBar: .tightest)

        XCTAssertEqual(extra.remainingPercent, 5, "It still has its own percentage.")
        XCTAssertEqual(snapshot.primary()?.id, "weekly")
        XCTAssertEqual(snapshot.tightestRemainingPercent, 60)
        XCTAssertEqual(snapshot.primary(override: "extra")?.id, "extra", "The user can still pick it.")
        let item = BridgeLayout.instrument(descriptor: FakeProvider("x", result: .success(snapshot)).descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.menuValue, "60%")
        XCTAssertTrue(item.notes.contains("Extra usage 5% left"))
    }

    func testAnUnmeteredWindowBecomesAPercentageOnlyWithAUserTotal() {
        let credits = Reading(id: "ai_credits", name: "AI credits", value: .window(.unmetered(
            used: Amount(value: 312, unit: .credits), period: .named("monthly"), resetsAt: nil)))
        let snapshot = ProviderSnapshot(readings: [credits])

        XCTAssertNil(credits.remainingPercent)
        XCTAssertEqual(credits.amount, Amount(value: 312, unit: .credits))
        XCTAssertEqual(credits.detailText, "312 credits used · monthly")
        let bare = BridgeLayout.instrument(descriptor: FakeProvider("x", result: .success(snapshot)).descriptor, snapshot: snapshot, error: nil)
        XCTAssertNil(bare.remaining)
        XCTAssertEqual(bare.amount, "312 credits")
        XCTAssertEqual(bare.amountCaption, "used")

        let limited = snapshot.applying(userLimits: ["ai_credits": 1_500])
        XCTAssertEqual(limited.readings.first?.remainingPercent, 79)
        XCTAssertEqual(limited.readings.first?.window?.limit, Amount(value: 1_500, unit: .credits))
        XCTAssertEqual(limited.readings.first?.detailText, "21% used · monthly")

        let metered = ProviderSnapshot(readings: [window("weekly", 30)]).applying(userLimits: ["weekly": 10])
        XCTAssertEqual(metered.readings.first?.remainingPercent, 70, "A provider's own percentage is never replaced.")
    }

    func testAnIncompleteReadingIsNeverAPercentage() {
        let cutOff = Reading.spendReading(id: "spend_month", name: "This month", amount: Amount(value: 80, unit: .currency("USD")),
                                          period: "this month (UTC)", budget: Amount(value: 100, unit: .currency("USD")), truncated: true)
        XCTAssertNil(cutOff.remainingPercent)
        XCTAssertEqual(cutOff.detailText, "At least $80.00 spent · this month (UTC) · report cut off")

        let typed = ProviderSnapshot(readings: [Reading.spendReading(id: "spend_month", name: "This month",
            amount: Amount(value: 80, unit: .currency("USD")), period: "this month", truncated: true)])
            .applying(userLimits: ["spend_month": 100])
        XCTAssertNil(typed.readings.first?.remainingPercent, "A user budget doesn't make a cut-off total a percentage.")
        let item = BridgeLayout.instrument(descriptor: FakeProvider("x", result: .success(typed)).descriptor, snapshot: typed, error: nil)
        XCTAssertNil(item.remaining)
        XCTAssertEqual(item.amount, "$80.00")
    }

    func testPaymentRequiredAndNotFoundAreTypedAndHeadersAreReadable() async throws {
        let transport = FixtureTransport()
        transport.respond(to: "https://api.example.com/402", status: 402, body: Data("{}".utf8))
        transport.respond(to: "https://api.example.com/404", status: 404, body: Data("{}".utf8))
        transport.respond(to: "https://api.example.com/page", body: Data("[]".utf8), headers: ["Link": "<https://api.example.com/page?p=2>; rel=\"next\""])
        let client = HTTPClient(allowedHosts: ["api.example.com"], transport: transport)

        for (path, kind) in [("402", "paymentRequired"), ("404", "notFound")] {
            do {
                _ = try await client.get(URL(string: "https://api.example.com/\(path)")!)
                XCTFail("HTTP \(path) should fail")
            } catch let error as ProviderError {
                XCTAssertEqual(error.kind, kind)
            }
        }
        let response = try await client.response(for: URLRequest(url: URL(string: "https://api.example.com/page")!))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("link"), "<https://api.example.com/page?p=2>; rel=\"next\"")
    }

    func testFolderListingStaysUnderTheToolsFolderAndIsSortedNewestFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: home.appendingPathComponent("a").path)
        let tools = LocalTools(home: home, environment: [:])

        XCTAssertEqual(tools.contents(of: home).map(\.lastPathComponent), ["b", "a"])
        XCTAssertEqual(tools.contents(of: home.appendingPathComponent("missing")), [])
    }
}

/// Settings warnings follow what a provider declares.
final class SettingsTextTests: XCTestCase {
    func testCursorSaysTheTogglePromptsAndTheCookieIsTheWholeAccount() {
        let descriptor = CursorProvider().descriptor
        let prompts = ProviderDetailText.prompts(in: descriptor)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].hasPrefix("With “Read Cursor's own sign-in” on, reading Cursor's stored password"), prompts[0])
        guard case .pastedKey(let spec) = descriptor.credential else { return XCTFail("Cursor takes a pasted cookie") }
        XCTAssertEqual(spec.kind, .cookie)
        XCTAssertTrue(spec.warning?.contains("full access to your Cursor account") == true)
        XCTAssertTrue(spec.warning?.contains("stop working at any time") == true)
        XCTAssertTrue(descriptor.fields.first?.help?.contains("macOS asks you for permission") == true)
    }

    func testACommandBehindAToggleSaysSo() {
        let toggle = SettingField(id: "readTool", label: "Read the tool's data", isRequired: false, kind: .toggle)
        var always = DeclaredCommand(executable: "tool", arguments: ["usage"], reason: "Reads usage.")
        let descriptor = ProviderDescriptor(
            id: "t", name: "T", glyph: ProviderGlyph(symbol: "circle"), tint: .gray, category: .api, stability: .unverified,
            credential: .none, summary: "", reads: "", source: "", fields: [toggle]
        )
        XCTAssertTrue(ProviderDetailText.command(always, in: descriptor).hasPrefix("Turning this provider on runs `tool usage`"))
        always.onlyWhen = "readTool"
        XCTAssertTrue(ProviderDetailText.command(always, in: descriptor).hasPrefix("With “Read the tool's data” on, Dogwatch runs `tool usage`"))
    }

    func testClaudesKeychainReadNeedsNoPromptWarning() {
        XCTAssertEqual(ProviderDetailText.prompts(in: ClaudeProvider().descriptor), [])
    }
}
