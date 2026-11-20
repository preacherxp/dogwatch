import CSQLite
import Foundation

extension LocalTools {
    /// Runs one query against another tool's SQLite database without any chance of changing or
    /// disturbing it, and returns each row as column name to value. Use it for a tool's own
    /// credential or state table; select only the columns you need.
    ///
    /// What it guarantees:
    /// - **Never writes and never locks the other tool's files.** With no write-ahead log, the
    ///   file is opened read-only and immutable: no locks, no journal, no `-shm`.
    /// - **Sees changes the tool hasn't merged yet.** When a non-empty `-wal` file exists (the tool
    ///   wrote recently and hasn't checkpointed), an immutable read would see the old main file:
    ///   a token the tool just renewed would look expired. Then the `-wal` and the main file are
    ///   copied, in that order, into a private temporary folder (an instant copy-on-write clone
    ///   on APFS), the copy is queried, and the copy is deleted before this returns. The original
    ///   is never opened. Copying the log first keeps the pair consistent if the tool checkpoints
    ///   in between: frames already in the main file are applied again, which changes nothing.
    /// - The copy holds whatever the tool stores (tokens included) for the length of one query, in
    ///   your own temporary folder, readable only by you.
    func queryReadOnly(_ database: URL, _ sql: String, _ parameters: [String] = []) throws -> [[String: JSONValue]] {
        guard fileExists(database) else { throw ProviderError.notInstalled("\(database.lastPathComponent) not found.") }
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int ?? 0
        guard walSize > 0 else {
            return try query(database, immutable: true, displayName: database.lastPathComponent, sql, parameters)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("snapshot.db")
        do {
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            try FileManager.default.copyItem(at: database, to: copy)
        } catch {
            // The log can vanish between the size check and the copy (a checkpoint): read as is.
            return try query(database, immutable: true, displayName: database.lastPathComponent, sql, parameters)
        }
        return try query(copy, immutable: false, displayName: database.lastPathComponent, sql, parameters)
    }

    private func query(_ database: URL, immutable: Bool, displayName: String, _ sql: String, _ parameters: [String]) throws -> [[String: JSONValue]] {
        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        // The private copy is opened normally so SQLite can replay its log; it is ours and is
        // deleted afterwards. The original is only ever opened immutable.
        components.queryItems = immutable ? [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")] : []
        guard let uri = components.string else { throw ProviderError.notConfigured("Bad database path.") }

        var handle: OpaquePointer?
        let flags = (immutable ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw ProviderError.unexpectedResponse("\(displayName) could not be opened.")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.unexpectedResponse("\(displayName): the query doesn't match its tables.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }

        var rows: [[String: JSONValue]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var row: [String: JSONValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER, SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(statement, column))
                case SQLITE_NULL: row[name] = .null
                default:
                    if let text = sqlite3_column_text(statement, column) { row[name] = .string(String(cString: text)) }
                    else { row[name] = .null }
                }
            }
            rows.append(row)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw ProviderError.unexpectedResponse("\(displayName): the query failed (\(String(cString: sqlite3_errstr(result)))).")
        }
        return rows
    }
}
