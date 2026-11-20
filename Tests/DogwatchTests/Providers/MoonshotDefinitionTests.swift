import Foundation
import XCTest
@testable import Dogwatch

final class MoonshotDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.moonshot)

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "moonshot", hosts: ["api.moonshot.ai", "api.moonshot.cn"])
        XCTAssertEqual(harness.descriptor.baseURLs.map(\.url.absoluteString), ["https://api.moonshot.ai", "https://api.moonshot.cn"])
    }

    func testInternationalIsDollarsByDefault() async throws {
        let (snapshot, transport) = try await harness.fetch("moonshot/balance.json", prefix: "https://api.moonshot.ai/")
        XCTAssertEqual(snapshot.primary()?.id, "balance")
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 49.58894, unit: .currency("USD")))
        XCTAssertEqual(harness.reading("voucher", in: snapshot)?.amount, Amount(value: 46.58893, unit: .currency("USD")))
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: "https://api.moonshot.ai/v1/users/me/balance")
    }

    func testChinaIsYuan() async throws {
        let settings = ProviderSettings(baseURL: URL(string: "https://api.moonshot.cn"))
        let (snapshot, transport) = try await harness.fetch("moonshot/balance.json", prefix: "https://api.moonshot.cn/", settings: settings)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 49.58894, unit: .currency("CNY")))
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")
    }

    func testOwedCashIsNegative() async throws {
        let (snapshot, _) = try await harness.fetch("moonshot/balance-owed.json", prefix: "https://api.moonshot.ai/")
        XCTAssertEqual(harness.reading("cash", in: snapshot)?.amount?.value, -4.2)
        XCTAssertEqual(snapshot.primary()?.amount?.value, 12.5)
    }

    func testANonZeroCodeIsAnError() async {
        do {
            _ = try await harness.fetch("moonshot/error.json", prefix: "https://api.moonshot.ai/")
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "unexpectedResponse")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: "https://api.moonshot.ai/", key: harness.key)
    }
}
