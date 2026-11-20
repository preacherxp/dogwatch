import Foundation

// VS Code-based editors (Cursor, Devin Desktop/Windsurf) keep their global state in a SQLite file,
// `User/globalStorage/state.vscdb`, table `ItemTable (key TEXT, value BLOB)`. Values are usually
// UTF-8 text, sometimes stored as UTF-16LE blobs. This reads one value, read-only, through
// `LocalTools.queryReadOnly`, which never opens the editor's own files for writing or locking and
// still sees changes the editor hasn't checkpointed yet (see its documentation).

extension LocalTools {
    /// The value stored under `key` in a VS Code `state.vscdb`, or nil when there is none.
    func vscodeStateValue(_ database: URL, key: String) throws -> String? {
        let rows = try queryReadOnly(database, "SELECT hex(value) AS value FROM ItemTable WHERE key = ? LIMIT 1", [key])
        guard let hex = rows.first?["value"]?.stringValue, let data = Data(hexString: hex), !data.isEmpty else { return nil }
        return VSCodeStateText.decode(data)
    }
}

enum VSCodeStateText {
    /// UTF-8, or UTF-16LE when every other byte is zero (ASCII stored as UTF-16).
    static func decode(_ data: Data) -> String? {
        let looksUTF16 = data.count >= 2 && data.count % 2 == 0
            && stride(from: 1, to: data.count, by: 2).allSatisfy { data[data.startIndex + $0] == 0 }
        let text = looksUTF16 ? String(data: data, encoding: .utf16LittleEndian) : String(data: data, encoding: .utf8)
        return text?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }
}

extension Data {
    /// Bytes from a hex string such as SQLite's `hex()` returns. nil for anything else.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
