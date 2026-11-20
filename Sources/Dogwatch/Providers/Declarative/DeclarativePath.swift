import Foundation

/// The paths a declarative definition may use: everything `JSONPath` accepts (`data.limit`,
/// `limits[1].percent`, `$.usage`), plus a filter step `[field=value]` that picks the first
/// element of an array whose `field` equals `value` as text:
///
/// ```
/// balance_infos[currency=USD].total_balance
/// ```
///
/// A path without a filter resolves exactly as `JSONValue.value(at:)`. Lives with the engine so
/// the shared `JSONPath` stays unchanged.
enum DeclarativePath {
    private struct Filter {
        let field: String
        let value: String
    }

    /// A path split at its filters: `[plain, filter, plain, filter, …, plain]`, where a plain
    /// piece may be empty (a filter at the start, two filters in a row, or one at the end).
    private static func split(_ path: String) -> (plain: [String], filters: [Filter])? {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("$") { text.removeFirst(); if text.hasPrefix(".") { text.removeFirst() } }
        guard !text.isEmpty else { return nil }
        var plain: [String] = []
        var filters: [Filter] = []
        var current = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]") else { return nil }
            let inside = rest[rest.index(after: open)..<close]
            if let equals = inside.firstIndex(of: "=") {
                let field = inside[..<equals].trimmingCharacters(in: .whitespaces)
                let value = inside[inside.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard !field.isEmpty, !value.isEmpty, JSONPath.parse(field) != nil else { return nil }
                current += rest[..<open]
                plain.append(current)
                filters.append(Filter(field: field, value: value))
                current = ""
                rest = rest[rest.index(after: close)...]
                if rest.hasPrefix(".") {
                    rest = rest.dropFirst()
                    guard !rest.isEmpty else { return nil }
                }
            } else {
                current += rest[...close]
                rest = rest[rest.index(after: close)...]
            }
        }
        current += rest
        plain.append(current)
        return (plain, filters)
    }

    /// Whether the path is well formed.
    static func isValid(_ path: String) -> Bool {
        guard let (plain, filters) = split(path) else { return false }
        if filters.isEmpty { return JSONPath.parse(path) != nil }
        return plain.allSatisfy { $0.isEmpty || JSONPath.parse($0) != nil }
    }

    /// The value at the path, or nil for any missing step, a filter that matches nothing, or a
    /// malformed path. Never traps.
    static func value(in json: JSONValue, at path: String) -> JSONValue? {
        guard let (plain, filters) = split(path) else { return nil }
        if filters.isEmpty { return json.value(at: path) }
        var current: JSONValue? = json
        for (index, piece) in plain.enumerated() {
            if !piece.isEmpty { current = current?.value(at: piece) }
            guard let value = current else { return nil }
            guard index < filters.count else { break }
            let filter = filters[index]
            current = value.arrayValue?.first { $0.value(at: filter.field)?.stringValue == filter.value }
            if current == nil { return nil }
        }
        return current
    }
}
