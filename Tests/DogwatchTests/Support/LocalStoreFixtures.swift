import CSQLite
import Foundation
import XCTest
@testable import Dogwatch

/// Builds sample local stores (another tool's SQLite files, JWTs) in a temporary home, so
/// providers that read local data can be tested without any real tool's files.
enum LocalStoreFixture {
    /// A fresh temporary folder standing in for the home directory.
    static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dogwatch-batchb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Creates a SQLite file at `path` under `home`, runs `schema`, and inserts `rows` as
    /// `(table, key, value)`. `value` is stored as text, or as a blob when `asBlob` is set.
    @discardableResult
    static func sqlite(at path: String, in home: URL, schema: [String], rows: [(table: String, key: String, value: Data, asBlob: Bool)]) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(handle) }
        for statement in schema {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO \(row.table) (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "sqlite", code: 3)
            }
            sqlite3_bind_text(statement, 1, row.key, -1, transient)
            _ = row.value.withUnsafeBytes { buffer in
                row.asBlob
                    ? sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(row.value.count), transient)
                    : sqlite3_bind_text(statement, 2, buffer.bindMemory(to: CChar.self).baseAddress, Int32(row.value.count), transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 4) }
            sqlite3_finalize(statement)
        }
        return url
    }

    /// A VS Code `state.vscdb` with the given `ItemTable` entries.
    @discardableResult
    static func vscodeState(at path: String, in home: URL, _ items: [String: Data], asBlob: Bool = false) throws -> URL {
        try sqlite(at: path, in: home, schema: ["CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"],
                   rows: items.map { ("ItemTable", $0.key, $0.value, asBlob) })
    }

    /// An unsigned sample JWT with the given claims. Never a real token.
    static func jwt(_ claims: [String: Any]) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return "\(encode(["alg": "none", "typ": "JWT"])).\(encode(claims)).sample-signature"
    }
}
