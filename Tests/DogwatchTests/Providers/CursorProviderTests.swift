import Foundation
import XCTest
@testable import Dogwatch

/// A Safe Storage reader that answers from memory and records every attempt, so tests can prove
/// when the Keychain would and wouldn't be asked.
final class FakeSafeStorage: SafeStoragePasswordReading {
    var passwords: [String: String] = [:]
    var denied = false
    private(set) var asked: [String] = []

    func password(service: String, account: String) throws -> String {
        asked.append(account)
        if denied { throw ProviderError.accessDenied("Keychain access to “\(service)” was denied.") }
        guard let password = passwords[account] else { throw ProviderError.notSignedIn("“\(service)” is not in your login Keychain.") }
        return password
    }
}

final class CursorProviderTests: XCTestCase {
    private let cookie = "WorkosCursorSessionToken=sample-user%3A%3Asample-session-not-real"
    private let summaryURL = "https://cursor.com/api/usage-summary"
    private let poolURL = "https://cursor.com/api/dashboard/get-sand-usage-status"
    private let now = Date()
    private var home: URL!

    override func setUpWithError() throws { home = try LocalStoreFixture.makeHome() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func transport(summary: String, pool: String? = nil) throws -> FixtureTransport {
        let transport = FixtureTransport()
        try transport.respond(to: summaryURL, fixture: summary)
        if let pool { try transport.respond(to: poolURL, fixture: pool) }
        return transport
    }

    private func appSettings() -> ProviderSettings {
        ProviderSettings(values: [CursorProvider.readAppSignIn: "true"])
    }

    private func writeAppToken(_ value: String) throws {
        try LocalStoreFixture.vscodeState(at: CursorProvider.databasePath, in: home, [CursorProvider.tokenKey: Data(value.utf8)])
    }

    private func freshJWT(expiresIn seconds: TimeInterval = 86_400) -> String {
        LocalStoreFixture.jwt(["sub": "auth0|user_sample123", "exp": Int(now.timeIntervalSince1970 + seconds)])
    }

    func testFollowsTheRules() {
        assertFollowsRules(CursorProvider())
    }

    func testLegacyPlanShowsIncludedUsageMetersAndOnDemandSpend() async throws {
        let provider = CursorProvider()
        let transport = try transport(summary: "cursor/usage-summary-legacy.json", pool: "cursor/pool-not-unified.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: cookie, now: now))

        XCTAssertEqual(snapshot.readings.map(\.id), ["included", "auto", "api", "on_demand"])
        XCTAssertEqual(snapshot.primary()?.id, "included")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 38)
        XCTAssertEqual(snapshot.primary()?.window?.limit, Amount(value: 20, unit: .currency("USD")))
        XCTAssertEqual(snapshot.readings.first { $0.id == "api" }?.remainingPercent, 29)
        let onDemand = try XCTUnwrap(snapshot.readings.first { $0.id == "on_demand" }?.spend)
        XCTAssertEqual(onDemand.amount, Amount(value: 4.55, unit: .currency("USD")))
        XCTAssertEqual(onDemand.budget, Amount(value: 20, unit: .currency("USD")))
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.menuBar, .tightest)

        let item = BridgeLayout.instrument(descriptor: provider.descriptor, snapshot: snapshot, error: nil)
        XCTAssertEqual(item.remaining, 38)
        XCTAssertEqual(item.menuValue, "29%", "The menu bar shows the tightest pool.")

        XCTAssertEqual(transport.requests.count, 2)
        let summary = try XCTUnwrap(transport.requests.first { $0.url?.absoluteString == summaryURL })
        XCTAssertEqual(summary.httpMethod, "GET")
        XCTAssertEqual(summary.value(forHTTPHeaderField: "Cookie"), cookie)
        XCTAssertNil(summary.value(forHTTPHeaderField: "Authorization"))
        let pool = try XCTUnwrap(transport.requests.first { $0.url?.absoluteString == poolURL })
        XCTAssertEqual(pool.httpMethod, "POST")
        XCTAssertEqual(pool.httpBody, Data("{}".utf8))
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: cookie), [])
    }

    func testUnifiedAccountShowsTheWeeklyPoolInstead() async throws {
        let provider = CursorProvider()
        let transport = try transport(summary: "cursor/usage-summary-unified.json", pool: "cursor/pool-unified.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: cookie, now: now))

        XCTAssertEqual(snapshot.readings.map(\.id), ["weekly"], "The monthly breakdown is stale on unified plans; on-demand is off and unused.")
        XCTAssertEqual(snapshot.primary()?.remainingPercent, 56)
        XCTAssertEqual(snapshot.primary()?.resetsAt, DateParsing.iso8601("2099-11-23T00:00:00.000Z"))
        XCTAssertEqual(snapshot.plan, "Premium")
    }

    func testAFailedPoolRequestKeepsTheSummary() async throws {
        let provider = CursorProvider()
        let transport = try transport(summary: "cursor/usage-summary-legacy.json")
        let snapshot = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: cookie, now: now))
        XCTAssertEqual(snapshot.primary()?.id, "included")
    }

    func testABareCookieValueIsSentAsTheSessionCookie() async throws {
        let provider = CursorProvider()
        let transport = try transport(summary: "cursor/usage-summary-legacy.json")
        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, key: "sample-user%3A%3Asample", now: now))
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=sample-user%3A%3Asample")
    }

    func testWithoutACookieOrOptInNothingIsReadOrSent() async throws {
        let keychain = FakeSafeStorage()
        let provider = CursorProvider(keychain: keychain)
        try writeAppToken(freshJWT())
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, now: now))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "notSignedIn")
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(keychain.asked.isEmpty, "Cursor's sign-in is read only after the user opts in.")
        XCTAssertFalse(provider.availability(in: TestContext.make(for: provider.descriptor, home: home)).isAvailable)
        XCTAssertTrue(provider.availability(in: TestContext.make(for: provider.descriptor, home: home, settings: appSettings())).isAvailable)
    }

    func testOptInWithAPlainAppTokenNeedsNoKeychain() async throws {
        let keychain = FakeSafeStorage()
        let provider = CursorProvider(keychain: keychain)
        let token = freshJWT()
        try writeAppToken(token)
        let transport = try transport(summary: "cursor/usage-summary-legacy.json")
        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))

        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_sample123%3A%3A\(token)")
        XCTAssertTrue(keychain.asked.isEmpty)
    }

    func testOptInDecryptsAnEncryptedAppToken() async throws {
        let keychain = FakeSafeStorage()
        keychain.passwords["Cursor Key"] = "sample-safe-storage-password"
        let provider = CursorProvider(keychain: keychain)
        let token = freshJWT()
        let encrypted = try XCTUnwrap(ElectronSafeStorage.encrypt(Data(token.utf8), password: "sample-safe-storage-password"))
        try writeAppToken(CursorProvider.encryptedPrefix + encrypted.base64EncodedString())
        let transport = try transport(summary: "cursor/usage-summary-legacy.json")
        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))

        XCTAssertEqual(keychain.asked, ["Cursor Key"])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_sample123%3A%3A\(token)")
    }

    func testALegacyKeychainAccountIsTriedWhenTheFirstIsMissing() async throws {
        let keychain = FakeSafeStorage()
        keychain.passwords["Cursor"] = "older-sample-password"
        let provider = CursorProvider(keychain: keychain)
        let encrypted = try XCTUnwrap(ElectronSafeStorage.encrypt(Data(freshJWT().utf8), password: "older-sample-password"))
        try writeAppToken(CursorProvider.encryptedPrefix + encrypted.base64EncodedString())
        let transport = try transport(summary: "cursor/usage-summary-legacy.json")
        _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))
        XCTAssertEqual(keychain.asked, ["Cursor Key", "Cursor"])
    }

    func testADeniedKeychainPromptStopsWithoutARequestAndIsNotRetried() async throws {
        let keychain = FakeSafeStorage()
        keychain.denied = true
        let provider = CursorProvider(keychain: keychain)
        let encrypted = try XCTUnwrap(ElectronSafeStorage.encrypt(Data(freshJWT().utf8), password: "x"))
        try writeAppToken(CursorProvider.encryptedPrefix + encrypted.base64EncodedString())
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "accessDenied")
            XCTAssertTrue(error.waitsForUser, "A denied prompt must not be repeated on the timer.")
        }
        XCTAssertEqual(keychain.asked, ["Cursor Key"], "Asked once, not again for the second account.")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnExpiredAppTokenSaysSignInAgainWithNoRequest() async throws {
        let keychain = FakeSafeStorage()
        keychain.passwords["Cursor Key"] = "pw"
        let provider = CursorProvider(keychain: keychain)
        let encrypted = try XCTUnwrap(ElectronSafeStorage.encrypt(Data(freshJWT(expiresIn: -60).utf8), password: "pw"))
        try writeAppToken(CursorProvider.encryptedPrefix + encrypted.base64EncodedString())
        let transport = FixtureTransport()
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertEqual(error.localizedDescription, "Cursor's sign-in has expired. Open Cursor to sign in again.")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testARejectedAppTokenSaysSignInAgain() async throws {
        let provider = CursorProvider(keychain: FakeSafeStorage())
        try writeAppToken(freshJWT())
        let transport = FixtureTransport()
        transport.respond(to: summaryURL, status: 401, body: Data("{}".utf8))
        do {
            _ = try await provider.fetch(in: TestContext.make(for: provider.descriptor, transport: transport, home: home, settings: appSettings(), now: now))
            XCTFail("should fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error.kind, "expired")
            XCTAssertTrue(error.localizedDescription.contains("Open Cursor"))
        }
        XCTAssertEqual(ProviderContract.violations(in: transport.requests, descriptor: provider.descriptor, key: nil), [])
    }

    func testMapsHTTPErrors() async {
        await assertMapsHTTPErrors(CursorProvider(), url: summaryURL, key: cookie)
    }

    func testSafeStorageRoundTripsAndRejectsAWrongPassword() throws {
        let sealed = try XCTUnwrap(ElectronSafeStorage.encrypt(Data("sample value".utf8), password: "right"))
        XCTAssertTrue(sealed.starts(with: Data("v10".utf8)))
        XCTAssertEqual(ElectronSafeStorage.decrypt(sealed, password: "right"), Data("sample value".utf8))
        XCTAssertNotEqual(ElectronSafeStorage.decrypt(sealed, password: "wrong"), Data("sample value".utf8))
        XCTAssertNil(ElectronSafeStorage.decrypt(Data("v11abc".utf8), password: "right"))
    }

    func testSafeStorageMatchesChromiumsFormat() throws {
        // Expected values computed independently: the key with Python's
        // hashlib.pbkdf2_hmac("sha1", b"peanuts", b"saltysalt", 1003, 16), the ciphertext with
        // `openssl enc -aes-128-cbc -K <key> -iv 2020…20` of "sample value".
        let key = try XCTUnwrap(ElectronSafeStorage.key(from: "peanuts"))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "d9a09d499b4e1b7461f28e67972c6dbd")
        let sealed = Data("v10".utf8) + Data(base64Encoded: "cxqLfP8fRzQefdVQ3eAq4Q==")!
        XCTAssertEqual(ElectronSafeStorage.decrypt(sealed, password: "peanuts"), Data("sample value".utf8))
    }

    func testVSCodeStateValuesStoredAsUTF16AreRead() throws {
        let utf16 = try XCTUnwrap("sample".data(using: .utf16LittleEndian))
        try LocalStoreFixture.vscodeState(at: "state.vscdb", in: home, ["k": utf16], asBlob: true)
        XCTAssertEqual(try LocalTools(home: home).vscodeStateValue(home.appendingPathComponent("state.vscdb"), key: "k"), "sample")
        XCTAssertNil(try LocalTools(home: home).vscodeStateValue(home.appendingPathComponent("state.vscdb"), key: "missing"))
    }
}
