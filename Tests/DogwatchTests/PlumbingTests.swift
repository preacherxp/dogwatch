import Foundation
import XCTest
@testable import Dogwatch

/// Shared helpers providers rely on.
final class PlumbingTests: XCTestCase {
    func testReadOnlySQLiteNeverChangesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tool.db")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, "PRAGMA journal_mode=WAL; CREATE TABLE credential (id TEXT, value TEXT, active INTEGER); INSERT INTO credential VALUES ('tool', '{\"type\":\"api\"}', 1);"]
        try sqlite.run()
        sqlite.waitUntilExit()
        let before = try Data(contentsOf: url)
        let listing = { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
        let filesBefore = try listing()

        let rows = try LocalTools().queryReadOnly(url, "SELECT value, active FROM credential WHERE id = ?", ["tool"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["active"], .number(1))
        XCTAssertEqual(rows.first?["value"]?.stringValue, #"{"type":"api"}"#)
        XCTAssertEqual(try Data(contentsOf: url), before, "The database file is unchanged.")
        XCTAssertEqual(try listing(), filesBefore, "No journal, WAL or lock files were added.")

        XCTAssertThrowsError(try LocalTools().queryReadOnly(url, "DELETE FROM credential")) { _ in }
        XCTAssertEqual(try LocalTools().queryReadOnly(url, "SELECT COUNT(*) AS n FROM credential").first?["n"], .number(1))
        XCTAssertThrowsError(try LocalTools().queryReadOnly(url, "SELECT nope FROM credential")) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, "unexpectedResponse")
        }
    }

    func testReadOnlySQLiteSeesChangesStillInTheWriteAheadLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tool.db")
        func sqlite(_ script: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [url.path]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        try sqlite("PRAGMA journal_mode=WAL;\nCREATE TABLE credential (id TEXT, token TEXT);\nINSERT INTO credential VALUES ('tool', 'expired-token');\n")
        // The tool renews its token and keeps the change in its log, as a running app does.
        try sqlite(".dbconfig no_ckpt_on_close on\nUPDATE credential SET token = 'renewed-token';\n")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0, 0, "The change is still in the log.")
        let snapshot = { (path: String) in try? Data(contentsOf: URL(fileURLWithPath: path)) }
        let before = [url.path, wal.path, url.path + "-shm"].map(snapshot)
        let temporaryBefore = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("dogwatch-read-") }

        let rows = try LocalTools().queryReadOnly(url, "SELECT token FROM credential WHERE id = ?", ["tool"])

        XCTAssertEqual(rows.first?["token"]?.stringValue, "renewed-token", "The renewed token in the log is seen.")
        XCTAssertEqual([url.path, wal.path, url.path + "-shm"].map(snapshot), before, "The tool's files are byte for byte unchanged.")
        let temporaryAfter = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("dogwatch-read-") }
        XCTAssertEqual(temporaryAfter, temporaryBefore, "The private copy is deleted.")
    }

    func testDatesInEveryFormatSeenSoFar() {
        XCTAssertEqual(DateParsing.iso8601("2026-11-23T22:00:00.956366+00:00")?.timeIntervalSince1970 ?? 0, 1_795_471_200.956, accuracy: 0.01)
        XCTAssertEqual(DateParsing.iso8601("2026-12-01T00:00:00.000Z"), Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(DateParsing.iso8601("2026-12-01"), Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(DateParsing.epoch(1_796_083_200), Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(DateParsing.epoch(1_796_083_200_000), Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(DateParsing.date(.string("1796083200")), Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertNil(DateParsing.iso8601("soon"))
    }

    func testAmountsFormatInTheirUnits() {
        XCTAssertEqual(UsageFormatters.amount(Amount(value: 12.4, unit: .currency("USD"))), "$12.40")
        XCTAssertEqual(UsageFormatters.amount(Amount(value: 1_234.5, unit: .currency("USD")), style: .compact), "$1.2k")
        XCTAssertEqual(UsageFormatters.amount(Amount(value: 110, unit: .currency("CNY"))), "¥110.00")
        XCTAssertEqual(UsageFormatters.amount(Amount(value: 49.5, unit: .currency("CHF"))), "49.50 CHF")
        XCTAssertEqual(UsageFormatters.amount(Amount(value: 1_500, unit: .credits)), "1,500 credits")
        XCTAssertEqual(UsageFormatters.amount(Amount(value: -3, unit: .currency("USD"))), "-$3.00")
        XCTAssertEqual(UsageFormatters.menuAmount(Amount(value: 1_500, unit: .custom("points"))), "1.5k")
        XCTAssertEqual(AmountUnit("USD"), .currency("USD"))
        XCTAssertEqual(AmountUnit("points"), .custom("points"))
    }

    @MainActor
    func testARateLimitedProviderWaitsForRetryAfter() async {
        let store = UsageStore(
            configStore: .inMemory(.defaults(enabled: ["limited"])),
            providers: [FakeProvider("limited", result: .failure(.rateLimited(retryAfter: 900)))],
            historyDatabase: nil, secrets: InMemorySecretStore(), automaticallyRefresh: false
        )
        store.refresh(userInitiated: true)
        let deadline = Date().addingTimeInterval(3)
        while store.isLoading, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let attempt = store.states["limited"]?.lastAttempt
        XCTAssertEqual(store.states["limited"]?.error?.kind, "rateLimited")
        XCTAssertGreaterThan(store.states["limited"]?.notBefore ?? .distantPast, Date().addingTimeInterval(800))
        store.refresh(userInitiated: true)
        store.refreshDue()
        XCTAssertEqual(store.states["limited"]?.lastAttempt, attempt, "Not asked again before Retry-After.")
    }
}
