import Foundation

// MARK: - Ordered object storage

/// A JSON object that preserves the key order of the document it was parsed from.
///
/// Kubernetes serialises objects in a meaningful order (`apiVersion`, `kind`,
/// `metadata`, `spec`, `status`, …) and users expect the YAML tab to show that
/// same order, so the app never round-trips through `Dictionary`.
struct JSONObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var pairs: [(key: String, value: JSONValue)] {
        keys.map { ($0, storage[$0] ?? .null) }
    }
}

extension JSONObject: Sequence {
    func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var index = 0
        return AnyIterator {
            guard index < self.keys.count else { return nil }
            let key = self.keys[index]
            index += 1
            return (key, self.storage[key] ?? .null)
        }
    }
}

// MARK: - Numbers

/// Keeps the literal spelling of a number so re-emitting YAML does not turn
/// `1` into `1.0` or lose precision on large `resourceVersion` values.
struct JSONNumber: Sendable, Equatable {
    let text: String
    let isInteger: Bool

    init(text: String) {
        self.text = text
        self.isInteger = !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" })
    }

    init(_ value: Int) {
        self.text = String(value)
        self.isInteger = true
    }

    init(_ value: Double) {
        if value == value.rounded(), abs(value) < 1e15 {
            self.text = String(Int(value))
            self.isInteger = true
        } else {
            self.text = String(value)
            self.isInteger = false
        }
    }

    var intValue: Int? { isInteger ? Int(text) : Int(Double(text) ?? .nan) }
    var doubleValue: Double? { Double(text) }
}

// MARK: - JSONValue

indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

extension JSONValue {
    static func int(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }
    static func double(_ value: Double) -> JSONValue { .number(JSONNumber(value)) }

    var isNull: Bool { if case .null = self { return true }; return false }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s) where s == "true": return true
        case .string(let s) where s == "false": return false
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n): return n.intValue
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n.doubleValue
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Best-effort scalar rendering used by table cells.
    var displayString: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.text
        case .string(let s): return s
        case .array(let a): return a.map(\.displayString).joined(separator: ", ")
        case .object: return "{…}"
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Dotted path lookup, e.g. `obj.value(at: "metadata.labels.app")`.
    /// Numeric components index into arrays.
    func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for component in path.split(separator: ".") {
            guard let node = current else { return nil }
            if let index = Int(component), node.arrayValue != nil {
                current = node[index]
            } else {
                current = node[String(component)]
            }
        }
        return current
    }

    func string(at path: String) -> String? { value(at: path)?.stringValue }
    func int(at path: String) -> Int? { value(at: path)?.intValue }
    func bool(at path: String) -> Bool? { value(at: path)?.boolValue }
    func array(at path: String) -> [JSONValue] { value(at: path)?.arrayValue ?? [] }
    func object(at path: String) -> JSONObject? { value(at: path)?.objectValue }

    /// Returns a copy with the value at `path` removed. Intermediate objects
    /// that do not exist are ignored.
    func removing(_ path: String) -> JSONValue {
        let components = path.split(separator: ".").map(String.init)
        guard let first = components.first, var object = objectValue else { return self }
        if components.count == 1 {
            object[first] = nil
        } else if let child = object[first] {
            object[first] = child.removing(components.dropFirst().joined(separator: "."))
        }
        return .object(object)
    }
}

// MARK: - Parsing

enum JSONParseError: Error, CustomStringConvertible {
    case unexpectedEnd
    case unexpected(UInt8, at: Int)
    case invalidNumber(at: Int)
    case invalidEscape(at: Int)
    case invalidUTF8

    var description: String {
        switch self {
        case .unexpectedEnd: return "Unexpected end of JSON input"
        case .unexpected(let byte, let offset):
            return "Unexpected byte '\(Character(UnicodeScalar(byte)))' at offset \(offset)"
        case .invalidNumber(let offset): return "Invalid number at offset \(offset)"
        case .invalidEscape(let offset): return "Invalid escape sequence at offset \(offset)"
        case .invalidUTF8: return "Input was not valid UTF-8"
        }
    }
}

/// A small, allocation-conscious JSON reader.
///
/// `JSONSerialization` cannot preserve key order, and `JSONDecoder` would force
/// every Kubernetes resource into a static shape, so the app parses JSON itself.
struct JSONParser {
    private let bytes: [UInt8]
    private var index: Int = 0

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        return value
    }

    static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    // MARK: Scanning primitives

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard let c = current else { throw JSONParseError.unexpectedEnd }
        guard c == byte else { throw JSONParseError.unexpected(c, at: index) }
        index += 1
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let c = current else { throw JSONParseError.unexpectedEnd }
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try consume("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try consume("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try consume("null")
            return .null
        default: return try parseNumber()
        }
    }

    private mutating func consume(_ literal: String) throws {
        for expected in literal.utf8 {
            guard let c = current else { throw JSONParseError.unexpectedEnd }
            guard c == expected else { throw JSONParseError.unexpected(c, at: index) }
            index += 1
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect(UInt8(ascii: "{"))
        var object = JSONObject()
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard let c = current else { throw JSONParseError.unexpectedEnd }
            if c == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if c == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw JSONParseError.unexpected(c, at: index)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect(UInt8(ascii: "["))
        var array: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard let c = current else { throw JSONParseError.unexpectedEnd }
            if c == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if c == UInt8(ascii: "]") {
                index += 1
                return .array(array)
            }
            throw JSONParseError.unexpected(c, at: index)
        }
    }

    private mutating func parseString() throws -> String {
        try expect(UInt8(ascii: "\""))
        var scratch: [UInt8] = []
        let start = index
        // Fast path: scan for a closing quote with no escapes.
        while index < bytes.count {
            let c = bytes[index]
            if c == UInt8(ascii: "\"") {
                let slice = bytes[start..<index]
                index += 1
                if scratch.isEmpty {
                    guard let s = String(bytes: slice, encoding: .utf8) else { throw JSONParseError.invalidUTF8 }
                    return s
                }
                scratch.append(contentsOf: slice)
                guard let s = String(bytes: scratch, encoding: .utf8) else { throw JSONParseError.invalidUTF8 }
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            index += 1
        }
        // Slow path: at least one escape sequence.
        scratch.append(contentsOf: bytes[start..<index])
        while index < bytes.count {
            let c = bytes[index]
            if c == UInt8(ascii: "\"") {
                index += 1
                guard let s = String(bytes: scratch, encoding: .utf8) else { throw JSONParseError.invalidUTF8 }
                return s
            }
            if c == UInt8(ascii: "\\") {
                index += 1
                guard let escape = current else { throw JSONParseError.unexpectedEnd }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scratch.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): scratch.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): scratch.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    scratch.append(contentsOf: Array(String(scalar).utf8))
                default: throw JSONParseError.invalidEscape(at: index - 1)
                }
            } else {
                scratch.append(c)
                index += 1
            }
        }
        throw JSONParseError.unexpectedEnd
    }

    private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
        let high = try parseHex4()
        if high >= 0xD800, high <= 0xDBFF {
            // Surrogate pair; the low half must follow immediately.
            if current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
                index += 2
                let low = try parseHex4()
                if low >= 0xDC00, low <= 0xDFFF {
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return UnicodeScalar(combined) ?? "\u{FFFD}"
                }
            }
            return "\u{FFFD}"
        }
        return UnicodeScalar(high) ?? "\u{FFFD}"
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let c = current else { throw JSONParseError.unexpectedEnd }
            let digit: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A")) + 10
            default: throw JSONParseError.invalidEscape(at: index)
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if current == UInt8(ascii: "-") { index += 1 }
        while let c = current {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                 UInt8(ascii: "+"), UInt8(ascii: "-"):
                index += 1
            default:
                guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
                    throw JSONParseError.invalidNumber(at: start)
                }
                return .number(JSONNumber(text: text))
            }
        }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw JSONParseError.invalidNumber(at: start)
        }
        return .number(JSONNumber(text: text))
    }
}

// MARK: - Serialisation

extension JSONValue {
    func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(into: &out, indent: 0, pretty: pretty)
        return out
    }

    func serializedData(pretty: Bool = false) -> Data {
        Data(serialized(pretty: pretty).utf8)
    }

    private func write(into out: inout String, indent: Int, pretty: Bool) {
        let pad = pretty ? String(repeating: " ", count: indent * 2) : ""
        let childPad = pretty ? String(repeating: " ", count: (indent + 1) * 2) : ""
        let newline = pretty ? "\n" : ""
        let space = pretty ? " " : ""

        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.text
        case .string(let s): out += JSONValue.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (offset, item) in items.enumerated() {
                out += childPad
                item.write(into: &out, indent: indent + 1, pretty: pretty)
                if offset < items.count - 1 { out += "," }
                out += newline
            }
            out += pad + "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{" + newline
            let pairs = object.pairs
            for (offset, pair) in pairs.enumerated() {
                out += childPad + JSONValue.quote(pair.key) + ":" + space
                pair.value.write(into: &out, indent: indent + 1, pretty: pretty)
                if offset < pairs.count - 1 { out += "," }
                out += newline
            }
            out += pad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var out = "\""
        out.reserveCapacity(string.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
