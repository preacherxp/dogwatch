import AppKit
import SwiftUI
import XCTest
@testable import Dogwatch

/// Real providers' parsers and fixtures side by side, rendered in every design, and the settings
/// list with every registered provider. Writes PNGs when DOGWATCH_DESIGN_PREVIEWS is set.
@MainActor
final class ManyProviderPreviewTests: XCTestCase {
    private func definition(_ id: String) throws -> CustomProviderSpec {
        let provider = ProviderRegistry.builtIn.first { $0.id.rawValue == id } as? DeclarativeProvider
        return try XCTUnwrap(provider?.spec, id)
    }

    private func instruments() throws -> [BridgeInstrument] {
        let now = Date()
        func item(_ provider: any UsageProvider, _ snapshot: ProviderSnapshot) -> BridgeInstrument {
            BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        }
        let claude = try ClaudeUsageClient.parseUsage(Fixture.data("claude/usage-weekly-scoped.json"), fetchedAt: now)
        let codex = UsageSnapshot(planName: "Pro", usedPercent: 24, resetDate: now.addingTimeInterval(172_800), windowMinutes: 10_080,
                                  lifetimeTokens: 28_400_000, dailyUsage: [], creditBalance: "125.5")
        let registry = Dictionary(uniqueKeysWithValues: ProviderRegistry.builtIn.map { ($0.id.rawValue, $0) })
        return [
            item(registry["codex"]!, CodexProvider.snapshot(from: codex)),
            item(registry["claude"]!, ClaudeProvider.snapshot(from: claude)),
            item(registry["copilot"]!, try CopilotProvider.snapshot(from: Fixture.json("copilot/free.json"), now: now)),
            item(registry["opencode-go"]!, try OpenCodeGoProvider.snapshot(from: Fixture.json("opencode-go/usage.json"), now: now)),
            item(registry["zai"]!, try ZaiProvider.snapshot(from: Fixture.json("zai/quota.json"), now: now)),
            item(registry["factory"]!, try FactoryProvider.snapshot(from: Fixture.json("factory/limits.json"), now: now)),
            item(registry["openrouter"]!, try OpenRouterProvider.snapshot(from: Fixture.json("openrouter/key-uncapped.json"), now: now)),
            item(registry["deepseek"]!, try DeclarativeProvider.snapshot(from: Fixture.json("deepseek/balance-cny.json"), spec: definition("deepseek"), now: now)),
            item(registry["elevenlabs"]!, try DeclarativeProvider.snapshot(from: Fixture.json("elevenlabs/subscription.json"), spec: definition("elevenlabs"), now: now)),
            item(registry["fal"]!, try DeclarativeProvider.snapshot(from: Fixture.json("fal/billing.json"), spec: definition("fal"), now: now)),
            item(registry["cline"]!, try ClineProvider.snapshot(balance: XCTUnwrap(Fixture.json("cline/balance.json")["data"]), organization: false, now: now)),
            item(registry["grok"]!, GrokProvider.snapshot(from: GrokUsageSnapshot(usedPercent: 4, resetDate: now.addingTimeInterval(86_400),
                periodLabel: "weekly", planName: "SuperGrok", prepaidBalance: nil, fetchedAt: now))),
        ]
    }

    func testRealProvidersSideBySideInEveryDesign() throws {
        let items = try instruments()
        XCTAssertTrue(items.contains { $0.amount != nil }, "Balances and spend are shown as amounts.")
        XCTAssertTrue(items.contains { $0.remaining != nil }, "Windows are shown as percentages.")
        // The panel scrolls, so render it in two halves to see every row.
        let halves = [Array(items.prefix(6)), Array(items.dropFirst(6))]
        for design in DashboardDesign.allCases {
            for (index, half) in halves.enumerated() {
                let panel = design == .nautical
                    ? AnyView(NauticalPanel(items: half).padding(.horizontal, Bridge.inset))
                    : AnyView(DashboardVariantView(design: design, items: half, activity: nil, isLoading: false, lastUpdated: Date()))
                let image = try render(panel, design: design)
                XCTAssertLessThan(image.height, 1_400)
                try save(image, "\(design.rawValue)-providers-\(index + 1)")
            }
        }
    }

    func testSettingsListsEveryProviderInGroups() throws {
        let store = UsageStore(configStore: .inMemory(ConfigStore.migratedConfig(from: InMemoryDefaults())), historyDatabase: nil,
                               secrets: InMemorySecretStore(), automaticallyRefresh: false)
        XCTAssertEqual(store.allProviderIDs.count, ProviderRegistry.builtIn.count)
        XCTAssertEqual(store.enabledProviders, [.codex, .claude, .grok], "A stranger starts with only Codex, Claude and Grok on.")
        for design in DashboardDesign.allCases {
            let hosting = NSHostingView(rootView: HarnessSettingsView(store: store, design: design)
                .padding(16)
                .frame(width: Bridge.windowWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignBackdrop(design: design))
                .environment(\.colorScheme, design.colorScheme))
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            // A list draws its rows only inside a window.
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertLessThan(hosting.frame.height, 900, "The list scrolls; the page doesn't grow with 40 providers.")
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let cg = bitmap.cgImage { try save(cg, "\(design.rawValue)-settings-all") }
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

    private func save(_ image: CGImage, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent("\(name).png"))
    }
}
