import XCTest
@testable import Dogwatch

final class BridgeLayoutTests: XCTestCase {
    func testHeroIsLowestRemaining() {
        let items = [
            instrument(.codex, remaining: 80),
            instrument(.claude, remaining: 22),
            instrument(.grok, remaining: 50)
        ]

        XCTAssertEqual(BridgeLayout.hero(in: items)?.provider, .claude)
        XCTAssertEqual(BridgeLayout.satellites(in: items).map(\.provider), [.codex, .grok])
    }

    func testHeroPrefersKnownOverMissing() {
        let items = [
            instrument(.codex, remaining: nil),
            instrument(.claude, remaining: 40),
            instrument(.grok, remaining: nil)
        ]

        XCTAssertEqual(BridgeLayout.hero(in: items)?.provider, .claude)
    }

    func testHeroFallsBackToFirstWhenAllUnknown() {
        let items = [
            instrument(.codex, remaining: nil),
            instrument(.grok, remaining: nil)
        ]

        XCTAssertEqual(BridgeLayout.hero(in: items)?.provider, .codex)
    }

    func testTiedRemainingKeepsHarnessOrder() {
        let items = [
            instrument(.codex, remaining: 30),
            instrument(.claude, remaining: 30)
        ]

        XCTAssertEqual(BridgeLayout.hero(in: items)?.provider, .codex)
    }

    func testWarningWhenTwentyOrBelow() {
        XCTAssertTrue(instrument(.codex, remaining: 20).isWarning)
        XCTAssertFalse(instrument(.codex, remaining: 21).isWarning)
        XCTAssertFalse(instrument(.codex, remaining: nil).isWarning)
    }

    private func instrument(_ harness: ProviderID, remaining: Int?) -> BridgeInstrument {
        BridgeInstrument(provider: harness,
            remaining: remaining,
            detail: "",
            resetDate: nil,
            secondaryLabel: ""
        )
    }
}
