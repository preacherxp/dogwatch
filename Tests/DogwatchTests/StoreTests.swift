import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Dogwatch

/// The store, menu bar and panel with any number of providers, using fake providers.
@MainActor
final class StoreTests: XCTestCase {
    private func store(
        _ providers: [any UsageProvider],
        enabled: [String]? = nil,
        configure: (inout DogwatchConfig) -> Void = { _ in },
        transport: FixtureTransport = FixtureTransport(),
        tools: LocalTools = LocalTools(gate: RecordingGate())
    ) -> UsageStore {
        var config = DogwatchConfig.defaults(enabled: (enabled ?? providers.map(\.id.rawValue)).map { ProviderID($0) })
        configure(&config)
        return UsageStore(
            configStore: .inMemory(config), providers: providers, historyDatabase: nil,
            secrets: InMemorySecretStore(), transport: transport, tools: tools, automaticallyRefresh: false
        )
    }

    private func fakes(_ count: Int) -> [any UsageProvider] {
        (0..<count).map { index in
            let snapshot = index % 3 == 2 ? FakeProvider.balance(Double(index) * 10.5) : FakeProvider.window(index * 3 % 100)
            return FakeProvider("fake-\(String(format: "%02d", index))", category: index % 2 == 0 ? .subscription : .api, result: .success(snapshot))
        }
    }

    private func waitUntilIdle(_ store: UsageStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isLoading, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testOneThreeTwelveAndThirtyProviders() async {
        for count in [1, 3, 12, 30] {
            let store = store(fakes(count))
            store.refresh(userInitiated: true)
            await waitUntilIdle(store)

            XCTAssertEqual(store.instruments.count, count)
            XCTAssertTrue(store.instruments.allSatisfy { $0.remaining != nil || $0.amount != nil }, "\(count): every provider has a reading")
            let entries = store.menuBarEntries
            XCTAssertEqual(entries.count, count)
            XCTAssertEqual(MenuBarLabel.accessibilityText(entries).components(separatedBy: ", ").count, count, "The spoken text lists every provider.")
            let image = MenuBarLabel.image(entries: entries, design: .nautical, scale: 2)
            XCTAssertLessThanOrEqual(image.size.width, MenuBarLabel.maximumWidth, "\(count): the menu bar row is capped")
            XCTAssertLessThanOrEqual(image.size.height, 22)
            XCTAssertEqual(PanelLayout.isCompact(count), count > 4)
            XCTAssertEqual(PanelLayout.scrolls(count), count > 8)
        }
    }

    func testMenuBarFollowsTheConfiguration() async {
        let providers: [any UsageProvider] = [
            FakeProvider("alpha", result: .success(FakeProvider.window(10))),
            FakeProvider("bravo", result: .success(FakeProvider.window(70))),
            FakeProvider("charlie", result: .success(FakeProvider.window(40))),
        ]
        let limited = store(providers) { $0.menuBarMaxItems = 2; $0.update("charlie") { $0.inMenuBar = false } }
        limited.refresh(userInitiated: true)
        await waitUntilIdle(limited)
        XCTAssertEqual(limited.menuBarEntries.map(\.provider), ["alpha", "bravo"])

        let lowest = store(providers) { $0.menuBarMode = .lowest }
        lowest.refresh(userInitiated: true)
        await waitUntilIdle(lowest)
        XCTAssertEqual(lowest.menuBarEntries, [MenuBarEntry(provider: "bravo", value: "30%")])

        let used = store(providers) { $0.percentage = .used }
        used.refresh(userInitiated: true)
        await waitUntilIdle(used)
        XCTAssertEqual(used.menuBarEntries.first?.value, "10%")
        XCTAssertEqual(used.instruments.first?.displayPercent, 10)
    }

    func testOneSlowOrFailingProviderNeverBlocksAnother() async {
        let providers: [any UsageProvider] = [
            FakeProvider("slow", result: .success(FakeProvider.window(10)), delay: 1.5),
            FakeProvider("broken", result: .failure(.network("offline"))),
            FakeProvider("quick", result: .success(FakeProvider.window(50))),
        ]
        let store = store(providers)
        store.refresh(userInitiated: true)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.instrument(for: "quick")?.remaining, 50, "The quick provider shows while the slow one is still loading.")
        XCTAssertEqual(store.states["broken"]?.error?.kind, "network")
        XCTAssertTrue(store.states["slow"]?.isLoading == true)
        XCTAssertEqual(store.instrument(for: "slow")?.menuValue, "…")
        await waitUntilIdle(store)
        XCTAssertEqual(store.instrument(for: "slow")?.remaining, 90)
    }

    func testATimeoutIsATypedError() async {
        let slow = FakeProvider("stuck", result: .success(FakeProvider.window(1)), delay: 5)
        let store = store([slow])
        store.refresh(userInitiated: true)
        await waitUntilIdle(store, timeout: 4)
        XCTAssertEqual(store.states["stuck"]?.error?.kind, "timedOut")
    }

    func testNothingFetchesForAProviderThatIsOff() async {
        let store = store([
            FakeProvider("on", result: .success(FakeProvider.window(10))),
            FakeProvider("off", result: .success(FakeProvider.window(10))),
        ], enabled: ["on"])
        store.refresh(userInitiated: true)
        store.refreshDue()
        await waitUntilIdle(store)
        XCTAssertNotNil(store.states["on"]?.snapshot)
        XCTAssertNil(store.states["off"], "A provider that is off is never fetched.")
        XCTAssertEqual(store.instruments.map(\.provider), ["on"])
    }

    func testADeniedPromptIsNotRetriedUntilTheUserAsks() async {
        let store = store([FakeProvider("prompted", result: .failure(.accessDenied("Denied.")), minimumRefresh: 30)])
        store.refresh(userInitiated: true)
        await waitUntilIdle(store)
        let first = store.states["prompted"]?.lastAttempt
        XCTAssertEqual(store.states["prompted"]?.error?.kind, "accessDenied")

        store.refreshDue()
        store.refresh()
        XCTAssertEqual(store.states["prompted"]?.lastAttempt, first, "No retry on the timer or when the panel opens.")
    }

    func testUnavailableProvidersSayWhyAndAreNotFetched() async {
        var missing = FakeProvider("cursor", result: .success(FakeProvider.window(10)))
        missing.available = false
        let store = store([missing])
        store.refresh(userInitiated: true)
        await waitUntilIdle(store)
        let item = store.instrument(for: "cursor")
        XCTAssertEqual(item?.detail, "Cursor is not installed")
        XCTAssertEqual(item?.state, .notSetUp)
        XCTAssertNil(store.states["cursor"]?.snapshot)
    }

    func testAnExpiredStoredTokenShowsSignInAgainWithNoRequestAndNoProcess() async throws {
        // A provider that reads another tool's token file the sanctioned way.
        struct ToolTokenProvider: UsageProvider {
            let descriptor = ProviderDescriptor(
                id: "tooltoken", name: "Tool", glyph: ProviderGlyph(symbol: "circle"), tint: .gray, category: .subscription,
                stability: .unverified, credential: .toolStore(ToolStore(kind: .file, location: "~/.tool/auth.json")),
                summary: "", reads: "Tool's own token file, read-only.", source: "Tests", allowedHosts: ["api.tool.example"]
            )
            func availability(in context: ProviderContext) -> ProviderAvailability { .available }
            func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
                let token = try StoredCredential.token(
                    file: context.home.appendingPathComponent(".tool/auth.json"), local: context.local,
                    tokenPath: "access", expiryPath: "expires", tool: "Tool", now: context.now()
                )
                _ = try await context.http.get(URL(string: "https://api.tool.example/usage")!, headers: ["Authorization": "Bearer \(token)"])
                return FakeProvider.window(1)
            }
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"access": "stored-token", "expires": "2020-01-01T00:00:00Z"}"#.utf8).write(to: home.appendingPathComponent(".tool/auth.json"))

        let transport = FixtureTransport()
        let gate = RecordingGate()
        let store = store([ToolTokenProvider()], transport: transport, tools: LocalTools(home: home, environment: [:], gate: gate))
        store.refresh(userInitiated: true)
        await waitUntilIdle(store)

        XCTAssertEqual(store.states["tooltoken"]?.error?.kind, "expired")
        XCTAssertEqual(store.instrument(for: "tooltoken")?.detail, "Tool's sign-in has expired. Open Tool to sign in again.")
        XCTAssertTrue(transport.requests.isEmpty, "No network call with an expired token.")
        XCTAssertTrue(gate.attempts.isEmpty, "No process started.")
        let original = try String(contentsOf: home.appendingPathComponent(".tool/auth.json"))
        XCTAssertTrue(original.contains("stored-token"), "The tool's file is unchanged.")
    }

    func testPastedKeysStayInTheSecretStore() throws {
        let store = store([OpenRouterProvider()])
        XCTAssertEqual(store.instrument(for: "openrouter")?.state, .notSetUp)
        try store.saveKey("  sk-or-v1-secret  ", for: "openrouter")
        XCTAssertTrue(store.hasKey("openrouter"))
        XCTAssertEqual(store.secrets.read("openrouter"), "sk-or-v1-secret")
        let file = String(data: try store.config.json.encodedForFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(file.contains("sk-or-v1-secret"), "Keys never appear in config.json.")
        try store.removeKey(for: "openrouter")
        XCTAssertFalse(store.hasKey("openrouter"))
    }

    func testCustomProvidersComeFromTheConfiguration() throws {
        let store = store([FakeProvider("alpha", result: .success(FakeProvider.window(10)))])
        try store.addCustomProvider(try JSONValue(data: Data("""
        {"id": "custom-poe", "name": "Poe", "url": "https://api.poe.com/usage/current_balance",
         "headers": {"Authorization": "Bearer {key}"},
         "readings": [{"id": "points", "kind": "balance", "remaining": "current_point_balance", "unit": "points"}]}
        """.utf8)))
        XCTAssertTrue(store.isVisible("custom-poe"))
        XCTAssertEqual(store.descriptor("custom-poe")?.allowedHosts, ["api.poe.com"])
        XCTAssertThrowsError(try store.addCustomProvider(.object(["id": .string("alpha"), "name": .string("A"), "url": .string("https://a.example.com"),
            "readings": .array([.object(["kind": .string("balance"), "remaining": .string("a")])])])))
        store.removeCustomProvider("custom-poe")
        XCTAssertNil(store.descriptor("custom-poe"))
    }

    func testReorderingWritesTheOrder() {
        let store = store([
            FakeProvider("alpha", result: .success(FakeProvider.window(10))),
            FakeProvider("bravo", result: .success(FakeProvider.window(10))),
            FakeProvider("charlie", result: .success(FakeProvider.window(10))),
        ])
        store.moveProviders(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.enabledProviders, ["charlie", "alpha", "bravo"])
    }

    func testManyProvidersRenderInEveryDesign() throws {
        for count in [12, 30] {
            let store = store(fakes(count))
            let items = store.providers.keys.sorted().compactMap { id -> BridgeInstrument? in
                let fake = store.providers[id] as? FakeProvider
                return BridgeLayout.instrument(descriptor: fake!.descriptor, snapshot: try? fake!.result.get(), error: nil)
            }
            for design in DashboardDesign.allCases {
                let panel = design == .nautical
                    ? AnyView(NauticalPanel(items: items).padding(.horizontal, Bridge.inset))
                    : AnyView(DashboardVariantView(design: design, items: items, activity: nil, isLoading: false, lastUpdated: Date()))
                let image = try render(panel, design: design)
                XCTAssertEqual(image.width, Int(Bridge.windowWidth * 2))
                XCTAssertLessThan(image.height, 1_400, "\(count) providers in \(design.title) must scroll, not grow")
                if count == 12 { try savePreview(image, name: "\(design.rawValue)-many") }
            }
        }
    }

    func testBalancesAndSpendRenderInEveryDesign() throws {
        let openRouter = try OpenRouterProvider.snapshot(from: Fixture.json("openrouter/key-uncapped.json"), now: Date())
        let capped = try OpenRouterProvider.snapshot(from: Fixture.json("openrouter/key-weekly-budget.json"), now: Date())
        var items = [
            BridgeLayout.instrument(descriptor: OpenRouterProvider().descriptor, snapshot: capped, error: nil),
            BridgeLayout.instrument(descriptor: FakeProvider("deepseek", category: .api, result: .success(FakeProvider.balance(110))).descriptor,
                                    snapshot: FakeProvider.balance(110), error: nil),
        ]
        var uncapped = BridgeLayout.instrument(descriptor: OpenRouterProvider().descriptor, snapshot: openRouter, error: nil)
        uncapped = BridgeInstrument(copying: uncapped, provider: "openrouter-spend")
        items.append(uncapped)
        items.insert(BridgeInstrument(provider: .codex, remaining: 76, detail: "24% used · weekly", resetDate: Date().addingTimeInterval(172_800), secondaryLabel: "Pro"), at: 0)
        for design in DashboardDesign.allCases {
            let panel = design == .nautical
                ? AnyView(NauticalPanel(items: items).padding(.horizontal, Bridge.inset))
                : AnyView(DashboardVariantView(design: design, items: items, activity: nil, isLoading: false, lastUpdated: Date()))
            let image = try render(panel, design: design)
            XCTAssertGreaterThan(image.height, 200)
            try savePreview(image, name: "\(design.rawValue)-balances")
        }
    }

    private func render(_ view: AnyView, design: DashboardDesign) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .padding(.vertical, 16)
            .frame(width: Bridge.windowWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignBackdrop(design: design))
            .environment(\.colorScheme, design.colorScheme)
            .environment(\.renderingStillImage, true))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func savePreview(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent("\(name).png"))
    }
}

extension BridgeInstrument {
    /// The same instrument under another id, for previews that show one provider twice.
    init(copying other: BridgeInstrument, provider: ProviderID) {
        self = BridgeInstrument(provider: provider, remaining: other.remaining, detail: other.detail, resetDate: other.resetDate, secondaryLabel: other.secondaryLabel)
        meters = other.meters
        amount = other.amount
        amountCaption = other.amountCaption
        notes = other.notes
        category = other.category
        menuValue = other.menuValue
    }
}

@MainActor
final class StoreGroupOrderTests: XCTestCase {
    func testReorderingWithinAGroupKeepsTheOtherGroupInPlace() {
        let providers: [any UsageProvider] = [
            FakeProvider("sub-a", category: .subscription, result: .success(FakeProvider.window(1))),
            FakeProvider("api-a", category: .api, result: .success(FakeProvider.window(1))),
            FakeProvider("sub-b", category: .subscription, result: .success(FakeProvider.window(1))),
            FakeProvider("api-b", category: .api, result: .success(FakeProvider.window(1))),
        ]
        let store = UsageStore(configStore: .inMemory(.defaults(enabled: ["sub-a", "api-a", "sub-b", "api-b"])), providers: providers,
                               historyDatabase: nil, secrets: InMemorySecretStore(), automaticallyRefresh: false)
        store.moveProviders(["sub-a", "sub-b"], from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.enabledProviders, ["sub-b", "api-a", "sub-a", "api-b"])
    }
}
