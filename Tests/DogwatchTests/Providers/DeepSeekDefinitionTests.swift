import Foundation
import XCTest
@testable import Dogwatch

final class DeepSeekDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.deepseek)
    private let url = "https://api.deepseek.com/user/balance"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "deepseek", hosts: ["api.deepseek.com"])
    }

    func testBalanceInYuanFromADecimalString() async throws {
        let (snapshot, transport) = try await harness.fetch("deepseek/balance-cny.json", prefix: url)
        XCTAssertEqual(snapshot.readings.map(\.id), ["balance_cny"])
        // "110.00" is yuan, not fen: a factor-of-100 mistake would show 1.10 or 11,000.
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 110, unit: .currency("CNY")))
        XCTAssertNil(snapshot.primary()?.remainingPercent, "a prepaid balance has no total")
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: url)
    }

    func testEachCurrencyIsItsOwnReadingWhateverTheOrder() async throws {
        let (snapshot, _) = try await harness.fetch("deepseek/balance-both.json", prefix: url)
        XCTAssertEqual(harness.reading("balance_usd", in: snapshot)?.amount, Amount(value: 7.25, unit: .currency("USD")))
        XCTAssertEqual(harness.reading("balance_cny", in: snapshot)?.amount, Amount(value: 52.4, unit: .currency("CNY")))
    }

    func testNoBalanceIsANoteNotAnError() async throws {
        let (snapshot, _) = try await harness.fetch("deepseek/balance-empty.json", prefix: url)
        XCTAssertTrue(snapshot.readings.isEmpty)
        XCTAssertNotNil(snapshot.note)
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: url, key: harness.key)
    }
}
