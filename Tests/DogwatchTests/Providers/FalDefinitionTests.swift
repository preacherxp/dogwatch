import Foundation
import XCTest
@testable import Dogwatch

final class FalDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.fal)
    private let url = "https://api.fal.ai/v1/account/billing?expand=credits"

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "fal", hosts: ["api.fal.ai"])
        guard case .pastedKey(let spec) = harness.descriptor.credential else { return XCTFail("needs a pasted key") }
        XCTAssertTrue(spec.advice?.contains("BILLING") ?? false, "recommends the billing-only key")
    }

    func testBalanceInTheCurrencyTheAnswerNames() async throws {
        let (snapshot, transport) = try await harness.fetch("fal/billing.json", prefix: "https://api.fal.ai/v1/account/billing")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 24.5, unit: .currency("USD")))
        XCTAssertNil(snapshot.label, "the account name is never shown")
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Key \(harness.key)", url: url)
    }

    func testAnswerWithoutCreditsNamesThePath() async {
        do {
            _ = try await harness.fetch("fal/billing-no-credits.json", prefix: "https://api.fal.ai/")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
            XCTAssertTrue(error.localizedDescription.contains("credits."))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: "https://api.fal.ai/", key: harness.key)
    }
}
