import Foundation

/// Minimal dynamic JSON value used for Gateway protocol payloads.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // Whole numbers MUST serialize as integers (e.g. 1784557247746,
            // not 1.784557247746e12) — gateway schemas use strict integer types.
            if n.truncatingRemainder(dividingBy: 1) == 0,
               n >= -9_007_199_254_740_991, n <= 9_007_199_254_740_991 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .bool(let b):   try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }

    // MARK: Convenience accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int?       { doubleValue.map(Int.init) }
    var boolValue: Bool?     { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Builds a JSONValue from Swift literals/collections.
    static func from(_ any: Any?) -> JSONValue {
        switch any {
        case nil: return .null
        case let v as JSONValue: return v
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let i as Int64: return .number(Double(i))
        case let i as UInt: return .number(Double(i))
        case let i as UInt64: return .number(Double(i))
        case let i as Int32: return .number(Double(i))
        case let f as Float: return .number(Double(f))
        case let d as Double: return .number(d)
        case let a as [Any?]: return .array(a.map { JSONValue.from($0) })
        case let o as [String: Any?]:
            return .object(o.mapValues { JSONValue.from($0) })
        default: return .null
        }
    }

    var jsonData: Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
    var jsonString: String { String(data: jsonData, encoding: .utf8) ?? "null" }
}
