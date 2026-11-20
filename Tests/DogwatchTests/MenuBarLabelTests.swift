import AppKit
import XCTest
@testable import Dogwatch

final class MenuBarLabelTests: XCTestCase {
    private let values: [ProviderID: String] = [.codex: "76%", .claude: "18%", .grok: "—"]

    func testEntriesFollowSettingsOrder() {
        let entries = MenuBarLabel.entries(visibility: HarnessVisibility()) { self.values[$0]! }

        XCTAssertEqual(entries.map(\.provider), [.codex, .claude, .grok])
        XCTAssertEqual(entries.map(\.value), ["76%", "18%", "—"])
    }

    func testHiddenProvidersAreLeftOut() {
        let visibility = HarnessVisibility(visible: [.grok, .codex])
        let entries = MenuBarLabel.entries(visibility: visibility) { self.values[$0]! }

        XCTAssertEqual(entries.map(\.provider), [.codex, .grok])
    }

    func testAccessibilityTextReadsEveryProvider() {
        let entries = MenuBarLabel.entries(visibility: HarnessVisibility()) { self.values[$0]! }

        XCTAssertEqual(
            MenuBarLabel.accessibilityText(entries),
            "Codex 76% remaining, Claude 18% remaining, Grok no reading yet"
        )
        XCTAssertEqual(MenuBarEntry(provider: .claude, value: "…").accessibilityText, "Claude loading")
    }

    @MainActor
    func testStoreWithoutReadingsShowsDashes() throws {
        let defaults = InMemoryDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite3"))
        let store = UsageStore(defaults: defaults, historyDatabase: database, automaticallyRefresh: false)

        store.setHarness(.claude, visible: false)
        let entries = MenuBarLabel.entries(visibility: store.visibility, value: store.menuTitle(for:))

        XCTAssertEqual(entries, [MenuBarEntry(provider: .codex, value: "—"), MenuBarEntry(provider: .grok, value: "—")])
    }

    @MainActor
    func testImageIsATemplateThatWidensWithEachProvider() throws {
        var widths: [CGFloat] = []
        for count in 1...3 {
            let visible = Set(HarnessVisibility.legacyProviders.prefix(count))
            let entries = MenuBarLabel.entries(visibility: HarnessVisibility(visible: visible)) { self.values[$0]! }
            for design in DashboardDesign.allCases {
                let image = MenuBarLabel.image(entries: entries, design: design, scale: 2)
                XCTAssertTrue(image.isTemplate)
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertLessThanOrEqual(image.size.height, 22, "Must fit the menu bar")
                XCTAssertLessThan(image.size.width, 220, "\(design.title), \(count) providers")
                XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                if design == .nautical { widths.append(image.size.width) }
            }
            if count == 3, let directory = ProcessInfo.processInfo.environment["DOGWATCH_DESIGN_PREVIEWS"] {
                let image = MenuBarLabel.image(entries: entries, design: .nautical, scale: 2)
                let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("menu-bar-template.png"))
            }
        }
        XCTAssertLessThan(widths[0], widths[1])
        XCTAssertLessThan(widths[1], widths[2])
    }
}
