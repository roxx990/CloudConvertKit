//  A small, type-safe representation of arbitrary JSON. CloudConvert task
//  options are open-ended (every engine exposes its own set), so we need a
//  value type that can encode anything the API accepts without falling back to
//  `[String: Any]`, which is neither Codable nor Sendable.
//

import Foundation

public enum JSONValue: Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral,
                     ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral,
                     ExpressibleByNilLiteral {

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Accessors

public extension JSONValue {

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
