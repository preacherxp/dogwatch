import XCTest
@testable import Dogwatch

final class HarnessVisibilityTests: XCTestCase {
    func testDefaultsToAllHarnesses() {
        XCTAssertEqual(HarnessVisibility().visible, Set(HarnessVisibility.legacyProviders))
    }

    func testHidesAndShowsAHarness() {
        var visibility = HarnessVisibility()
        visibility.set(.claude, visible: false)

        XCTAssertFalse(visibility.isVisible(.claude))
        XCTAssertTrue(visibility.isVisible(.codex))

        visibility.set(.claude, visible: true)
        XCTAssertTrue(visibility.isVisible(.claude))
    }

    func testCannotHideTheLastHarness() {
        var visibility = HarnessVisibility(visible: [.codex])
        visibility.set(.codex, visible: false)

        XCTAssertTrue(visibility.isVisible(.codex))
        XCTAssertFalse(visibility.canHide(.codex))
    }

    func testPersistsVisibleHarnesses() {
        let defaults = InMemoryDefaults()

        var visibility = HarnessVisibility()
        visibility.set(.claude, visible: false)
        visibility.save(to: defaults)

        let loaded = HarnessVisibility.load(from: defaults)
        XCTAssertEqual(loaded.visible, [.codex, .grok])
        XCTAssertEqual(loaded.logbookSubtitle, "CODEX + GROK LOGBOOK")
    }

    func testMigratesNewGrokHarnessOntoLegacySavedSet() {
        let defaults = InMemoryDefaults()

        defaults.set("codex,claude", forKey: HarnessVisibility.storageKey)

        XCTAssertEqual(HarnessVisibility.load(from: defaults).visible, Set(HarnessVisibility.legacyProviders))
    }

    func testEmptyStoredValueFallsBackToAllHarnesses() {
        let defaults = InMemoryDefaults()

        defaults.set("", forKey: HarnessVisibility.storageKey)

        XCTAssertEqual(HarnessVisibility.load(from: defaults).visible, Set(HarnessVisibility.legacyProviders))
    }
}
