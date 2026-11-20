import Foundation
import XCTest
@testable import Dogwatch

final class LiteLLMDefinitionTests: XCTestCase {
    private let harness = DefinitionHarness(DeclarativeProviders.litellm)
    private let local = ProviderSettings(baseURL: URL(string: "http://localhost:4000"))

    func testBasics() async {
        await assertDefinitionBasics(harness, id: "litellm", hosts: [])
        XCTAssertTrue(harness.descriptor.acceptsCustomBaseURL)
    }

    func testSpendAgainstTheBudgetOnLocalhost() async throws {
        let (snapshot, transport) = try await harness.fetch("litellm/key-budget.json", prefix: "http://localhost:4000/", settings: local)
        let primary = try XCTUnwrap(snapshot.primary())
        XCTAssertEqual(primary.spend?.amount, Amount(value: 2.5, unit: .currency("USD")))
        XCTAssertEqual(primary.spend?.budget, Amount(value: 10, unit: .currency("USD")))
        XCTAssertEqual(primary.remainingPercent, 75)
        XCTAssertEqual(primary.resetsAt, DateParsing.iso8601("2026-12-01T00:00:00+00:00"))
        // The key goes in the header only; `/key/info` without `?key=` describes the calling key.
        assertSentKey(transport, harness: harness, header: "Authorization", value: "Bearer \(harness.key)", url: "http://localhost:4000/key/info")
    }

    func testATrailingSlashAndAnHTTPSGateway() async throws {
        let settings = ProviderSettings(baseURL: URL(string: "https://llm.example.com/"))
        let (_, transport) = try await harness.fetch("litellm/key-budget.json", prefix: "https://llm.example.com/", settings: settings)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://llm.example.com/key/info")
    }

    func testNoBudgetIsSpendWithoutAPercentage() async throws {
        let (snapshot, _) = try await harness.fetch("litellm/key-no-budget.json", prefix: "http://localhost:4000/", settings: local)
        XCTAssertEqual(snapshot.primary()?.amount, Amount(value: 0.0001065, unit: .currency("USD")))
        XCTAssertNil(snapshot.primary()?.remainingPercent)
        XCTAssertNil(snapshot.primary()?.resetsAt)
    }

    func testWithoutABaseURLItAsksForOne() async {
        let transport = FixtureTransport()
        do {
            _ = try await harness.provider.fetch(in: TestContext.make(for: harness.descriptor, transport: transport, key: harness.key))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notConfigured")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPlainHTTPIsRefusedOffLocalhost() async {
        let settings = ProviderSettings(baseURL: URL(string: "http://llm.example.com"))
        do {
            _ = try await harness.fetch("litellm/key-budget.json", prefix: "http://llm.example.com/", settings: settings)
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "hostNotAllowed")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(harness.provider, url: "http://localhost:4000/", key: harness.key, settings: local)
    }
}
