import Foundation

/// A parsed JSON document with safe lookups. Used for provider answers, the custom provider's
/// paths, and to keep unknown keys in `config.json` when the app rewrites it.
indirect enum JSONValue: Equatable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    var isNull: Bool { self == .null }

    /// A number, or a string holding one (`"12.50"`), as many billing APIs send amounts.
    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

    /// Looks up a path such as `data.limit_remaining`, `limits[1].percent` or `$.data.usage`.
    /// Returns nil for any missing step, a wrong type or a malformed path; never traps.
    func value(at path: String) -> JSONValue? {
        guard let steps = JSONPath.parse(path) else { return nil }
        var current: JSONValue? = self
        for step in steps {
            switch step {
            case .key(let key): current = current?[key]
            case .index(let index): current = current?[index]
            }
            if current == nil { return nil }
        }
        return current
    }
}

enum JSONPath {
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    /// Parses dotted keys with optional `[n]` indexes. A leading `$` or `$.` is allowed.
    /// Returns nil when the path is empty or malformed.
    static func parse(_ path: String) -> [Step]? {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("$") { text.removeFirst(); if text.hasPrefix(".") { text.removeFirst() } }
        guard !text.isEmpty else { return nil }

        var steps: [Step] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { return nil }
            var rest = Substring(part)
            if let bracket = rest.firstIndex(of: "[") {
                let key = rest[..<bracket]
                if !key.isEmpty { steps.append(.key(String(key))) }
                rest = rest[bracket...]
                while rest.hasPrefix("[") {
                    guard let close = rest.firstIndex(of: "]"),
                          let index = Int(rest[rest.index(after: rest.startIndex)..<close]), index >= 0
                    else { return nil }
                    steps.append(.index(index))
                    rest = rest[rest.index(after: close)...]
                }
                guard rest.isEmpty else { return nil }
            } else {
                steps.append(.key(String(rest)))
            }
        }
        return steps
    }
}
