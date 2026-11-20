import Foundation
import XCTest
@testable import Dogwatch

/// Runs a built-in declarative definition against fixtures, for the `<Name>DefinitionTests`.
struct DefinitionHarness {
    let provider: DeclarativeProvider
    let key = "test-key-not-real"

    init(_ definition: String) {
        provider = DeclarativeProvider(definition: definition)
    }

    var descriptor: ProviderDescriptor { provider.descriptor }

    /// Fetches with the fixture answering every URL that starts with `prefix`.
    func fetch(_ fixture: String, prefix: String, settings: ProviderSettings = ProviderSettings()) async throws -> (ProviderSnapshot, FixtureTransport) {
        let transport = FixtureTransport()
        try transport.respond(to: prefix, fixture: fixture)
        let snapshot = try await provider.fetch(in: TestContext.make(for: descriptor, transport: transport, key: key, settings: settings))
        return (snapshot, transport)
    }

    func reading(_ id: String, in snapshot: ProviderSnapshot) -> Reading? {
        snapshot.readings.first { $0.id == id }
    }
}

extension XCTestCase {
    /// The checks every definition shares: it parsed (an invalid one becomes a provider that
    /// can't be enabled), it follows the rules, it calls only `hosts`, it starts off, it isn't
    /// labelled more confidently than `unverified`, and a missing key fails with no request.
    func assertDefinitionBasics(_ harness: DefinitionHarness, id: ProviderID, hosts: [String], file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertNotNil(harness.provider.spec, "the definition doesn't parse: \(harness.descriptor.summary)", file: file, line: line)
        XCTAssertEqual(harness.descriptor.id, id, file: file, line: line)
        assertFollowsRules(harness.provider, file: file, line: line)
        XCTAssertEqual(harness.descriptor.allowedHosts, hosts, file: file, line: line)
        XCTAssertEqual(harness.descriptor.stability, .unverified, file: file, line: line)
        XCTAssertFalse(ProviderRegistry.defaultEnabled.contains(id), "new providers start switched off", file: file, line: line)
        XCTAssertTrue(ProviderRegistry.builtIn.contains { $0.descriptor.id == id }, "not in the registry", file: file, line: line)

        let transport = FixtureTransport()
        do {
            _ = try await harness.provider.fetch(in: TestContext.make(for: harness.descriptor, transport: transport, key: nil))
            XCTFail("a missing key should fail", file: file, line: line)
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
        XCTAssertTrue(transport.requests.isEmpty, "no request without a key", file: file, line: line)
    }

    /// One GET, the key only in `header` as `value`, nowhere else.
    func assertSentKey(_ transport: FixtureTransport, harness: DefinitionHarness, header: String, value: String, url: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(transport.requests.count, 1, file: file, line: line)
        let request = transport.requests.first
        XCTAssertEqual(request?.httpMethod, "GET", file: file, line: line)
        XCTAssertEqual(request?.url?.absoluteString, url, file: file, line: line)
        XCTAssertEqual(request?.value(forHTTPHeaderField: header), value, file: file, line: line)
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: harness.descriptor, key: harness.key), [], file: file, line: line)
    }
}
