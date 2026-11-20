import Foundation
import XCTest
@testable import Dogwatch

final class UsageHistoryDatabaseTests: XCTestCase {
    func testRecordsEveryPlatformAndBackfillsCodexTokens() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let now = date(2026, 8, 30, hour: 14)
        let yesterday = date(2026, 8, 29, hour: 12)

        try fixture.database.record(
            codex: UsageSnapshot(
                planName: "Plus",
                usedPercent: 32,
                resetDate: date(2026, 9, 1),
                windowMinutes: 10_080,
                lifetimeTokens: 5_000,
                dailyUsage: [
                    DailyUsage(date: yesterday, tokens: 120),
                    DailyUsage(date: now, tokens: 250)
                ],
                creditBalance: nil
            ),
            claude: ClaudeUsageSnapshot(
                fiveHourUsedPercent: 12,
                fiveHourResetDate: nil,
                weeklyUsedPercent: 48,
                weeklyResetDate: date(2026, 9, 2),
                cacheUpdatedAt: now
            ),
            grok: GrokUsageSnapshot(
                usedPercent: 19,
                resetDate: date(2026, 9, 3),
                periodLabel: "weekly",
                planName: "Grok",
                prepaidBalance: nil,
                fetchedAt: now
            ),
            observedAt: now
        )

        let entries = try fixture.database.entries(in: .sevenDays, now: now)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entry(in: entries, harness: .codex, date: yesterday)?.tokens, 120)
        XCTAssertNil(entry(in: entries, harness: .codex, date: yesterday)?.usedPercent)
        XCTAssertEqual(entry(in: entries, harness: .codex, date: now)?.tokens, 250)
        XCTAssertEqual(entry(in: entries, harness: .codex, date: now)?.usedPercent, 32)
        XCTAssertEqual(entry(in: entries, harness: .claude, date: now)?.usedPercent, 48)
        XCTAssertEqual(entry(in: entries, harness: .grok, date: now)?.usedPercent, 19)
    }

    func testRefreshKeepsHighestTokenCountAndLatestPercentage() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let noon = date(2026, 8, 30, hour: 12)
        let afternoon = date(2026, 8, 30, hour: 15)

        try fixture.database.record(
            codex: codexSnapshot(tokens: 500, usedPercent: 20, date: noon),
            claude: nil,
            grok: nil,
            observedAt: noon
        )
        try fixture.database.record(
            codex: codexSnapshot(tokens: 450, usedPercent: 37, date: afternoon),
            claude: nil,
            grok: nil,
            observedAt: afternoon
        )

        let entries = try fixture.database.entries(in: .sevenDays, now: afternoon)
        let codex = entry(in: entries, harness: .codex, date: afternoon)
        XCTAssertEqual(codex?.tokens, 500)
        XCTAssertEqual(codex?.usedPercent, 37)
    }

    func testDateRangeExcludesOlderRows() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let now = date(2026, 8, 30, hour: 12)
        let twentyDaysAgo = date(2026, 8, 10, hour: 12)
        let snapshot = UsageSnapshot(
            planName: "Plus",
            usedPercent: 10,
            resetDate: nil,
            windowMinutes: nil,
            lifetimeTokens: nil,
            dailyUsage: [
                DailyUsage(date: twentyDaysAgo, tokens: 90),
                DailyUsage(date: now, tokens: 110)
            ],
            creditBalance: nil
        )

        try fixture.database.record(codex: snapshot, claude: nil, grok: nil, observedAt: now)

        let sevenDays = try fixture.database.entries(in: .sevenDays, now: now)
        let thirtyDays = try fixture.database.entries(in: .thirtyDays, now: now)
        XCTAssertEqual(sevenDays.map(\.tokens), [110])
        XCTAssertEqual(thirtyDays.compactMap(\.tokens), [90, 110])
    }

    func testCorruptDatabaseThrowsInsteadOfCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogwatch-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        try Data(repeating: 0x41, count: 4_096).write(to: url)

        XCTAssertThrowsError(try UsageHistoryDatabase(url: url))
    }

    func testReopeningKeepsExistingRows() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        let now = date(2026, 8, 30, hour: 12)
        try fixture.database.record(
            codex: codexSnapshot(tokens: 42, usedPercent: 5, date: now),
            claude: nil,
            grok: nil,
            observedAt: now
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reopened = try UsageHistoryDatabase(
            url: fixture.directory.appendingPathComponent("history.sqlite3"),
            calendar: calendar
        )

        XCTAssertEqual(try reopened.entries(in: .sevenDays, now: now).map(\.tokens), [42])
    }

    private func codexSnapshot(tokens: Int64, usedPercent: Int, date: Date) -> UsageSnapshot {
        UsageSnapshot(
            planName: "Plus",
            usedPercent: usedPercent,
            resetDate: nil,
            windowMinutes: nil,
            lifetimeTokens: nil,
            dailyUsage: [DailyUsage(date: date, tokens: tokens)],
            creditBalance: nil
        )
    }

    private func entry(
        in entries: [UsageHistoryEntry],
        harness: ProviderID,
        date: Date
    ) -> UsageHistoryEntry? {
        entries.first {
            $0.provider == harness && Calendar(identifier: .gregorian).isDate($0.date, inSameDayAs: date)
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

private final class DatabaseFixture {
    let directory: URL
    let database: UsageHistoryDatabase

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogwatch-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        database = try UsageHistoryDatabase(
            url: directory.appendingPathComponent("history.sqlite3"),
            calendar: calendar
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Upgrading a version 1 file, the format before providers became pluggable.
final class UsageHistoryMigrationTests: XCTestCase {
    func testVersionOneRowsMoveOverWithABackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-history.sqlite3")
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var statements = ["""
            CREATE TABLE daily_usage (day_start REAL NOT NULL, harness TEXT NOT NULL, tokens INTEGER, used_percent INTEGER,
                reset_at REAL, observed_at REAL NOT NULL, PRIMARY KEY (day_start, harness));
            """]
        for offset in 0..<40 {
            let start = day - Double(offset) * 86_400
            statements.append("INSERT INTO daily_usage VALUES (\(start), 'codex', \(1_000 * offset), \(offset % 100), NULL, \(start + 60));")
            statements.append("INSERT INTO daily_usage VALUES (\(start), 'claude', NULL, \(offset), \(start + 86_400), \(start + 60));")
            if offset < 10 { statements.append("INSERT INTO daily_usage VALUES (\(start), 'grok', NULL, 50, NULL, \(start + 60));") }
        }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, statements.joined(separator: "\n")]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        let database = try UsageHistoryDatabase(url: url)
        let migration = try XCTUnwrap(database.migration)
        XCTAssertEqual(migration.before, 90)
        XCTAssertEqual(migration.after, 90)
        XCTAssertEqual(database.rowCount, 90)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.backup.path))

        let entries = try database.entries(in: .ninetyDays)
        XCTAssertEqual(entries.count, 90)
        XCTAssertEqual(entries.filter { $0.provider == .codex }.count, 40)
        XCTAssertEqual(entries.filter { $0.provider == .claude }.count, 40)
        XCTAssertEqual(entries.filter { $0.provider == .grok }.count, 10)
        XCTAssertEqual(entries.first { $0.provider == .codex && Calendar.current.isDateInToday($0.date) }?.tokens, 0)

        // A new reading for Claude's week lands on the migrated row, not beside it.
        let claude = ClaudeUsageSnapshot(fiveHourUsedPercent: nil, fiveHourResetDate: nil, weeklyUsedPercent: 33,
                                         weeklyResetDate: Date().addingTimeInterval(86_400), cacheUpdatedAt: Date(), hasFiveHourWindow: false)
        try database.record(codex: nil, claude: claude, grok: nil, observedAt: Date())
        let today = try database.entries(in: .sevenDays).filter { $0.provider == .claude && Calendar.current.isDateInToday($0.date) }
        XCTAssertEqual(today.map(\.usedPercent), [33])

        // Opening again changes nothing.
        let reopened = try UsageHistoryDatabase(url: url)
        XCTAssertNil(reopened.migration)
        XCTAssertEqual(try reopened.entries(in: .ninetyDays).count, 90)
    }

    func testOldRowsArePruned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite3"))
        let old = Date().addingTimeInterval(-Double(UsageHistoryDatabase.retentionDays + 5) * 86_400)
        try database.record(provider: "fake", snapshot: FakeProvider.window(10), observedAt: old)
        try database.record(provider: "fake", snapshot: FakeProvider.window(10), observedAt: Date())
        XCTAssertEqual(database.rowCount, 2)
        try database.prune()
        XCTAssertEqual(database.rowCount, 1)
    }

    func testBalancesAndSpendAreRecorded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-amounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try UsageHistoryDatabase(url: directory.appendingPathComponent("history.sqlite3"))
        let snapshot = try OpenRouterProvider.snapshot(from: Fixture.json("openrouter/key-capped.json"), now: Date())
        try database.record(provider: "openrouter", snapshot: snapshot, observedAt: Date())
        XCTAssertEqual(database.rowCount, 3)
        XCTAssertEqual(try database.entries(in: .sevenDays).map(\.usedPercent), [38], "The chart row is the budget, 38% used.")
    }
}
