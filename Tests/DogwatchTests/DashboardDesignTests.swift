import AppKit
import SwiftUI
import XCTest
@testable import Dogwatch

final class DashboardDesignTests: XCTestCase {
    @MainActor
    func testMenuBarLabelsFitInLightAndDarkAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let preview = VStack(alignment: .leading, spacing: 0) {
                ForEach(DashboardDesign.allCases) { design in
                    HStack(spacing: 12) {
                        Text(design.title)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        MenuBarProviderLabel(design: design, harness: .codex, value: "100%")
                        MenuBarProviderLabel(design: design, harness: .claude, value: "18%")
                        MenuBarProviderLabel(design: design, harness: .grok, value: "—")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                }
            }
            .background(scheme == .light ? Color(white: 0.96) : Color(white: 0.12))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: preview)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.height, 28 * DashboardDesign.allCases.count * 2)
            XCTAssertLessThan(image.width, 650)
            if let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(scheme == .light ? "menu-bar-light.png" : "menu-bar-dark.png"))
            }
        }
    }

    func testEveryThemeHasAvailableDistinctMenuBarSymbols() {
        XCTAssertEqual(Set(DashboardDesign.allCases.map { $0.menuBarIcon(for: .codex) }).count, DashboardDesign.allCases.count)
        for design in DashboardDesign.allCases {
            let symbols = HarnessVisibility.legacyProviders.map { design.menuBarIcon(for: $0) }
            XCTAssertEqual(Set(symbols).count, HarnessVisibility.legacyProviders.count)
            for symbol in symbols {
                XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            }
        }
    }

    @MainActor
    func testHistoryAndSettingsInEveryDesign() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = InMemoryDefaults()
        let database = try UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite3"))
        let emptyStore = UsageStore(defaults: defaults, historyDatabase: database, automaticallyRefresh: false)
        for offset in 0..<7 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            try database.record(
                codex: UsageSnapshot(planName: "Pro", usedPercent: 24 + offset * 5, resetDate: nil,
                    windowMinutes: 10_080, lifetimeTokens: 28_400_000,
                    dailyUsage: [DailyUsage(date: date, tokens: Int64(74_000 - offset * 7_000))], creditBalance: "125.5"),
                claude: ClaudeUsageSnapshot(fiveHourUsedPercent: 36, fiveHourResetDate: nil,
                    weeklyUsedPercent: 82 - offset * 8, weeklyResetDate: nil, cacheUpdatedAt: date),
                grok: GrokUsageSnapshot(usedPercent: 45 - offset * 3, resetDate: nil,
                    periodLabel: "weekly", planName: "Grok", prepaidBalance: nil, fetchedAt: date),
                observedAt: date
            )
        }
        let store = UsageStore(defaults: defaults, historyDatabase: database, automaticallyRefresh: false)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.historyEntries.count, 21)
        XCTAssertTrue(emptyStore.historyEntries.isEmpty)
        for design in DashboardDesign.allCases {
            try renderScreen(HarnessSettingsView(store: store, design: design), design: design, name: "settings")
            try renderScreen(UsageStatsView(store: store, design: design), design: design, name: "history")
            try renderScreen(UsageStatsView(store: emptyStore, design: design), design: design, name: "history-empty")
        }
        store.setHarness(.claude, visible: false)
        store.setHarness(.grok, visible: false)
        XCTAssertFalse(store.canHide(.codex))
        for design in DashboardDesign.allCases {
            try renderScreen(HarnessSettingsView(store: store, design: design), design: design, name: "settings-hidden")
        }
    }

    @MainActor
    private func renderScreen<Content: View>(_ content: Content, design: DashboardDesign, name: String) throws {
        let hosting = NSHostingView(rootView: content
            .padding(16)
            .frame(width: Bridge.windowWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(DesignBackdrop(design: design))
            .environment(\.colorScheme, design.colorScheme))
        hosting.appearance = NSAppearance(named: design.colorScheme == .light ? .aqua : .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertEqual(hosting.frame.width, Bridge.windowWidth)
        XCTAssertGreaterThan(hosting.frame.height, 100)
        XCTAssertLessThan(hosting.frame.height, 700)
        if let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("\(design.rawValue)-\(name).png"))
        }
    }

    @MainActor
    func testVariantsRenderWithVisibleMissingAndLowAllowances() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let snapshot = UsageSnapshot(
            planName: "Pro", usedPercent: 24, resetDate: today.addingTimeInterval(172_800),
            windowMinutes: 10_080, lifetimeTokens: 28_400_000,
            dailyUsage: [42_000, 68_000, 29_000, 91_000, 57_000, 36_000, 74_000].enumerated().map {
                DailyUsage(date: Calendar.current.date(byAdding: .day, value: $0.offset - 6, to: today)!, tokens: Int64($0.element))
            },
            creditBalance: "125.50"
        )
        let items = [
            BridgeInstrument(provider: .codex, remaining: 76, detail: "24% used · weekly", resetDate: snapshot.resetDate, secondaryLabel: "Pro"),
            BridgeInstrument(provider: .claude, remaining: 18, detail: "82% used · 5h", resetDate: snapshot.resetDate, secondaryLabel: "5h session", weeklyRemaining: 64),
            BridgeInstrument(provider: .grok, remaining: nil, detail: "Waiting for usage", resetDate: nil, secondaryLabel: "Open Grok")
        ]

        for design in DashboardDesign.allCases {
            for count in 1...3 {
                let panel = design == .nautical
                    ? AnyView(NauticalPanel(items: Array(items.suffix(count)), snapshot: count == 3 ? snapshot : nil)
                        .padding(.horizontal, Bridge.inset))
                    : AnyView(DashboardVariantView(
                        design: design, items: Array(items.suffix(count)),
                        snapshot: count == 3 ? snapshot : nil, isLoading: count == 1, lastUpdated: today
                    ))
                let view = panel
                .padding(.vertical, 16)
                .frame(width: Bridge.windowWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(DesignBackdrop(design: design))
                .environment(\.colorScheme, design.colorScheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(design.title), \(count) providers")
                XCTAssertEqual(image.width, Int(Bridge.windowWidth * 2))
                XCTAssertGreaterThan(image.height, 200)
                XCTAssertLessThan(image.height, 1400, "Dashboard must fit a menu-bar panel")

                if count == 3, let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("\(design.rawValue).png"))
                }
            }
        }
    }
}
