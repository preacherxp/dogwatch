import CSQLite
import Foundation

enum UsageHistoryDatabaseError: LocalizedError {
    case applicationSupportUnavailable
    case openFailed(String)
    case sqlite(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Application Support is unavailable."
        case .openFailed(let message):
            return "Usage history could not be opened: \(message)"
        case .sqlite(let message):
            return "Usage history could not be saved: \(message)"
        case .migrationFailed(let message):
            return "Usage history could not be upgraded: \(message). The old file is unchanged."
        }
    }
}

/// One row per provider, reading and day: the latest percentage, amount and reset time seen
/// that day, plus exact token counts where the provider reports them. One reading per provider
/// is the "chart" reading, the line in the history view.
///
/// Schema versions (`PRAGMA user_version`):
/// - 1: `daily_usage(day_start, harness, tokens, used_percent, reset_at, observed_at)`, one row
///   per day for each of Codex, Claude and Grok.
/// - 2: `readings`, keyed by provider and reading id. Version 1 rows move over unchanged as each
///   provider's chart reading, after a backup copy of the file is written next to it.
final class UsageHistoryDatabase {
    static let schemaVersion: Int32 = 2
    /// Rows older than this are deleted at launch. The longest view is 90 days.
    static let retentionDays = 400

    private var database: OpaquePointer?
    private let calendar: Calendar
    private let url: URL
    /// Set when this open migrated version 1: the backup's path and the row counts before and after.
    private(set) var migration: (backup: URL, before: Int, after: Int)?

    init(url: URL? = nil, calendar: Calendar = .current) throws {
        self.calendar = calendar
        let databaseURL = try url ?? Self.defaultURL()
        self.url = databaseURL
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw UsageHistoryDatabaseError.openFailed(message)
        }

        database = handle
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode = WAL;")
        try migrate()
        try prune()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: Schema

    private func migrate() throws {
        let version = try userVersion()
        let hasV1 = try tableExists("daily_usage")
        if version >= Self.schemaVersion { return }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS readings (
                day_start REAL NOT NULL,
                provider TEXT NOT NULL,
                reading TEXT NOT NULL,
                is_chart INTEGER NOT NULL DEFAULT 0,
                tokens INTEGER,
                used_percent INTEGER,
                amount REAL,
                unit TEXT,
                reset_at REAL,
                observed_at REAL NOT NULL,
                PRIMARY KEY (day_start, provider, reading)
            );
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS readings_day_index ON readings(day_start);")

        if hasV1 {
            let before = try count("SELECT COUNT(*) FROM daily_usage;")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".v1-backup.sqlite3")
            if !FileManager.default.fileExists(atPath: backup.path) {
                // VACUUM INTO writes a consistent copy, including anything still in the WAL.
                try execute("VACUUM INTO '\(backup.path.replacingOccurrences(of: "'", with: "''"))';")
            }
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(
                    """
                    INSERT OR REPLACE INTO readings (day_start, provider, reading, is_chart, tokens, used_percent, reset_at, observed_at)
                    SELECT day_start, harness,
                           CASE harness WHEN 'codex' THEN 'primary' WHEN 'claude' THEN 'seven_day' WHEN 'grok' THEN 'credits' ELSE 'primary' END,
                           1, tokens, used_percent, reset_at, observed_at
                    FROM daily_usage;
                    """
                )
                let after = try count("SELECT COUNT(*) FROM readings WHERE is_chart = 1;")
                guard after == before else {
                    throw UsageHistoryDatabaseError.migrationFailed("\(before) rows before, \(after) after")
                }
                try execute("DROP TABLE daily_usage;")
                try execute("PRAGMA user_version = \(Self.schemaVersion);")
                try execute("COMMIT;")
                migration = (backup, before, after)
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } else {
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    /// Deletes rows older than `retentionDays`.
    func prune(now: Date = Date()) throws {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: calendar.startOfDay(for: now)) else { return }
        var statement: OpaquePointer?
        try prepare("DELETE FROM readings WHERE day_start < ?;", statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    var rowCount: Int {
        (try? count("SELECT COUNT(*) FROM readings;")) ?? 0
    }

    // MARK: Recording

    /// Records every reading in a snapshot for the day it was observed, and the provider's daily
    /// token counts on its chart reading.
    func record(provider: ProviderID, snapshot: ProviderSnapshot, observedAt: Date = Date()) throws {
        let chartID = snapshot.historyReadingID ?? snapshot.primary()?.id
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if let chartID, let activity = snapshot.activity {
                for usage in activity.dailyUsage {
                    let isToday = calendar.isDate(usage.date, inSameDayAs: observedAt)
                    let chart = snapshot.readings.first { $0.id == chartID }
                    try upsert(
                        date: usage.date, provider: provider, reading: chartID, isChart: true,
                        tokens: usage.tokens,
                        usedPercent: isToday ? chart.flatMap(Self.usedPercent) : nil,
                        amount: nil, unit: nil,
                        resetDate: isToday ? chart?.resetsAt : nil,
                        observedAt: observedAt
                    )
                }
            }
            for reading in snapshot.readings {
                try upsert(
                    date: observedAt, provider: provider, reading: reading.id, isChart: reading.id == chartID,
                    tokens: nil,
                    usedPercent: Self.usedPercent(reading),
                    amount: reading.amount?.value, unit: reading.amount?.unit.code,
                    resetDate: reading.resetsAt,
                    observedAt: observedAt
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Records the three original providers' parsed snapshots.
    func record(
        codex: UsageSnapshot?,
        claude: ClaudeUsageSnapshot?,
        grok: GrokUsageSnapshot?,
        observedAt: Date = Date()
    ) throws {
        if let codex { try record(provider: .codex, snapshot: CodexProvider.snapshot(from: codex), observedAt: observedAt) }
        if let claude { try record(provider: .claude, snapshot: ClaudeProvider.snapshot(from: claude), observedAt: observedAt) }
        if let grok { try record(provider: .grok, snapshot: GrokProvider.snapshot(from: grok), observedAt: observedAt) }
    }

    private static func usedPercent(_ reading: Reading) -> Int? {
        if let window = reading.window { return window.isMetered ? window.usedPercent : nil }
        return reading.remainingPercent.map { 100 - $0 }
    }

    // MARK: Reading

    /// Each provider's chart reading per day in the range.
    func entries(in range: UsageHistoryRange, now: Date = Date()) throws -> [UsageHistoryEntry] {
        guard let startDate = calendar.date(
            byAdding: .day,
            value: -(range.rawValue - 1),
            to: calendar.startOfDay(for: now)
        ) else { return [] }

        let sql = """
            SELECT day_start, provider, tokens, used_percent
            FROM readings
            WHERE is_chart = 1 AND day_start >= ?
            ORDER BY day_start ASC, provider ASC;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)

        var result: [UsageHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawProvider = sqlite3_column_text(statement, 1) else { continue }
            let tokens = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
            let usedPercent = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))
            result.append(UsageHistoryEntry(
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                provider: ProviderID(String(cString: rawProvider)),
                tokens: tokens,
                usedPercent: usedPercent
            ))
        }

        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw sqliteError()
        }
        return result
    }

    // MARK: SQLite

    private func upsert(
        date: Date,
        provider: ProviderID,
        reading: String,
        isChart: Bool,
        tokens: Int64?,
        usedPercent: Int?,
        amount: Double?,
        unit: String?,
        resetDate: Date?,
        observedAt: Date
    ) throws {
        let sql = """
            INSERT INTO readings (
                day_start, provider, reading, is_chart, tokens, used_percent, amount, unit, reset_at, observed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day_start, provider, reading) DO UPDATE SET
                is_chart = MAX(readings.is_chart, excluded.is_chart),
                tokens = CASE
                    WHEN excluded.tokens IS NULL THEN readings.tokens
                    WHEN readings.tokens IS NULL THEN excluded.tokens
                    ELSE MAX(readings.tokens, excluded.tokens)
                END,
                used_percent = CASE
                    WHEN excluded.used_percent IS NULL THEN readings.used_percent
                    WHEN excluded.observed_at >= readings.observed_at THEN excluded.used_percent
                    ELSE readings.used_percent
                END,
                amount = CASE
                    WHEN excluded.amount IS NULL THEN readings.amount
                    WHEN excluded.observed_at >= readings.observed_at THEN excluded.amount
                    ELSE readings.amount
                END,
                unit = COALESCE(excluded.unit, readings.unit),
                reset_at = CASE
                    WHEN excluded.reset_at IS NULL THEN readings.reset_at
                    WHEN excluded.observed_at >= readings.observed_at THEN excluded.reset_at
                    ELSE readings.reset_at
                END,
                observed_at = MAX(readings.observed_at, excluded.observed_at);
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, calendar.startOfDay(for: date).timeIntervalSince1970)
        bind(provider.rawValue, to: statement, at: 2)
        bind(reading, to: statement, at: 3)
        sqlite3_bind_int(statement, 4, isChart ? 1 : 0)
        bind(tokens, to: statement, at: 5)
        bind(usedPercent, to: statement, at: 6)
        bind(amount, to: statement, at: 7)
        if let unit { bind(unit, to: statement, at: 8) } else { sqlite3_bind_null(statement, 8) }
        bind(resetDate?.timeIntervalSince1970, to: statement, at: 9)
        sqlite3_bind_double(statement, 10, observedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        try prepare("PRAGMA user_version;", statement: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int(statement, 0)
    }

    private func tableExists(_ name: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", statement: &statement)
        defer { sqlite3_finalize(statement) }
        bind(name, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func count(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Int?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func bind(_ value: Double?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value)
    }

    private func sqliteError() -> UsageHistoryDatabaseError {
        guard let database else { return .sqlite("Database is closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UsageHistoryDatabaseError.applicationSupportUnavailable
        }
        // Never move or copy another folder in here: a folder under an older or generic name
        // may belong to someone else's app.
        let directory = applicationSupport.appendingPathComponent("Dogwatch", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage-history.sqlite3")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
