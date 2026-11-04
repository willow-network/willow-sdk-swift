import Foundation

/// A JSON value as the node's query route reads one: serde_json's `Value`,
/// built with arbitrary precision, so a number is kept as text.
///
/// The node filters a query with `Value` equality and sorts on a field's
/// numbers and strings, so a verified query is answered over these values,
/// read from the proven items and from the request body the SDK sends:
///
/// - A number is its text as the node keeps it. An integer that fits u64
///   (or, negative, i64) is its decimal digits, so `-0` is `0`. Any other
///   number is kept as written, except that an exponent is written as `e`
///   with an explicit sign (`1E5` is `1e+5`). So `1` and `1.0` are different
///   numbers, and so are `9007199254740993` and `9007199254740992`.
/// - A string is its UTF-8 bytes, compared byte for byte.
/// - An object maps keys, compared as UTF-8 bytes, to values; a repeated key
///   keeps its last value.
internal indirect enum NodeJSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string([UInt8])
    case array([NodeJSON])
    case object(NodeJSONObject)

    /// Why bytes can't be read as the node reads them.
    enum ReadError: Error {
        /// The node's reader refuses the bytes, so the node skips such an item.
        case notJSON(String)
        /// The node reads these bytes in a way the SDK doesn't reproduce.
        case unsupported(String)
    }

    /// Reads `bytes` as `serde_json::from_slice::<Value>` does: strict JSON,
    /// whitespace only around values, strings of valid UTF-8 with paired
    /// surrogate escapes and no raw control characters, and at most 127
    /// nested arrays and objects.
    static func parse(_ bytes: [UInt8]) throws -> NodeJSON {
        var reader = Reader(bytes: bytes)
        reader.skipWhitespace()
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        guard reader.index == bytes.count else {
            throw ReadError.notJSON("trailing characters at byte \(reader.index)")
        }
        return value
    }

    static func parse(_ data: Data) throws -> NodeJSON {
        return try parse([UInt8](data))
    }

    /// The value at a dotted field path, as the node's query engine reads
    /// one: the path's UTF-8 bytes split at each `.`, each part a key of an
    /// object (an array has no members), keys compared as bytes.
    func value(atPath path: [UInt8]) -> NodeJSON? {
        var current = self
        for part in path.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false) {
            guard case .object(let object) = current, let next = object[Array(part)] else { return nil }
            current = next
        }
        return current
    }

    /// The value as Foundation types: `NSNull`, `Bool`, `Int` for an integer
    /// that fits, `Double` for any other number, `String`, `[Any]`, and
    /// `[String: Any]`. Throws `unsupported` for a number outside `Double`'s
    /// range, and for an object two of whose keys are different bytes but
    /// the same Swift `String` (Unicode canonical equivalents).
    func foundationValue() throws -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let text):
            if !text.contains("."), !text.contains("e"), let int = Int(text) {
                return int
            }
            guard let double = Double(text), double.isFinite else {
                throw ReadError.unsupported("the number \(text) is outside Double's range")
            }
            return double
        case .string(let bytes):
            return String(decoding: bytes, as: UTF8.self)
        case .array(let elements):
            return try elements.map { try $0.foundationValue() }
        case .object(let object):
            var out: [String: Any] = [:]
            for key in object.keys {
                let name = String(decoding: key, as: UTF8.self)
                guard out[name] == nil else {
                    throw ReadError.unsupported("an object has keys that differ in bytes but are equal as Swift strings (\(name))")
                }
                out[name] = try object[key]!.foundationValue()
            }
            return out
        }
    }

    // MARK: - Reader

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        /// serde_json's reader refuses a 128th level of nesting.
        static let maxDepth = 127

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        func notJSON(_ message: String) -> ReadError {
            return .notJSON("\(message) at byte \(index)")
        }

        mutating func value(depth: Int) throws -> NodeJSON {
            guard index < bytes.count else { throw notJSON("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                guard depth < Self.maxDepth else { throw notJSON("nested too deeply") }
                return .object(try object(depth: depth + 1))
            case UInt8(ascii: "["):
                guard depth < Self.maxDepth else { throw notJSON("nested too deeply") }
                return .array(try array(depth: depth + 1))
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try number())
            default:
                throw notJSON("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
                throw notJSON("expected \(word)")
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> NodeJSONObject {
            index += 1
            var object = NodeJSONObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return object
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw notJSON("expected a key") }
                let key = try string()
                if object.keys.isEmpty, NodeJSON.privateKeys.contains(key) {
                    // serde_json reads an object whose first key is one of
                    // its private tokens as something other than an object.
                    throw ReadError.unsupported("an object's first key is serde_json's private token \(String(decoding: key, as: UTF8.self))")
                }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw notJSON("expected ':'") }
                index += 1
                skipWhitespace()
                object.set(key, try value(depth: depth))
                skipWhitespace()
                guard index < bytes.count else { throw notJSON("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { throw notJSON("expected ',' or '}'") }
                index += 1
                return object
            }
        }

        mutating func array(depth: Int) throws -> [NodeJSON] {
            index += 1
            var elements: [NodeJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return elements
            }
            while true {
                skipWhitespace()
                elements.append(try value(depth: depth))
                skipWhitespace()
                guard index < bytes.count else { throw notJSON("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { throw notJSON("expected ',' or ']'") }
                index += 1
                return elements
            }
        }

        /// A number's text as serde_json keeps it with arbitrary precision.
        mutating func number() throws -> String {
            var text: [UInt8] = []
            var integer = true
            func digits(_ reader: inout Reader, into text: inout [UInt8]) -> Int {
                var count = 0
                while reader.index < reader.bytes.count, (0x30...0x39).contains(reader.bytes[reader.index]) {
                    text.append(reader.bytes[reader.index])
                    reader.index += 1
                    count += 1
                }
                return count
            }
            let negative = bytes[index] == UInt8(ascii: "-")
            if negative {
                text.append(bytes[index])
                index += 1
            }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw notJSON("invalid number") }
            if bytes[index] == UInt8(ascii: "0") {
                text.append(bytes[index])
                index += 1
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw notJSON("invalid number")
                }
            } else {
                _ = digits(&self, into: &text)
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                integer = false
                text.append(bytes[index])
                index += 1
                guard digits(&self, into: &text) > 0 else { throw notJSON("invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                integer = false
                index += 1
                text.append(UInt8(ascii: "e"))
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    text.append(bytes[index])
                    index += 1
                } else {
                    text.append(UInt8(ascii: "+"))
                }
                guard digits(&self, into: &text) > 0 else { throw notJSON("invalid number") }
            }
            let written = String(decoding: text, as: UTF8.self)
            if integer {
                if negative, let value = Int64(written) {
                    return String(value)
                }
                if !negative, let value = UInt64(written) {
                    return String(value)
                }
            }
            return written
        }

        /// A string's UTF-8 bytes, its escapes decoded.
        mutating func string() throws -> [UInt8] {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw notJSON("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    // Valid UTF-8 decodes and re-encodes to the same bytes;
                    // anything else is repaired with U+FFFD.
                    guard Array(String(decoding: out, as: UTF8.self).utf8) == out else {
                        throw notJSON("invalid UTF-8 in a string")
                    }
                    return out
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw notJSON("unterminated escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xDC00...0xDFFF).contains(scalar) {
                            throw notJSON("lone surrogate")
                        }
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                                throw notJSON("lone surrogate")
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw notJSON("lone surrogate") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw notJSON("invalid escape") }
                        out += Array(String(Character(unicode)).utf8)
                    default:
                        throw notJSON("invalid escape")
                    }
                case 0x00..<0x20:
                    throw notJSON("control character in a string")
                default:
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw notJSON("short \\u escape") }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: throw notJSON("invalid \\u escape")
                }
                value = value << 4 | UInt32(digit)
            }
            index += 4
            return value
        }
    }

    /// The keys serde_json reserves: as an object's first key, its `Value`
    /// reader takes the object for a number (with arbitrary precision) or a
    /// raw value.
    static let privateKeys: Set<[UInt8]> = [
        Array("$serde_json::private::Number".utf8),
        Array("$serde_json::private::RawValue".utf8),
    ]
}

/// A JSON object's members, keyed by their UTF-8 bytes. A repeated key keeps
/// its last value, as serde_json's map does.
internal struct NodeJSONObject: Equatable {
    /// The keys, in the order first written.
    private(set) var keys: [[UInt8]] = []
    private var members: [[UInt8]: NodeJSON] = [:]

    var count: Int { return keys.count }

    subscript(key: [UInt8]) -> NodeJSON? {
        return members[key]
    }

    mutating func set(_ key: [UInt8], _ value: NodeJSON) {
        if members.updateValue(value, forKey: key) == nil {
            keys.append(key)
        }
    }

    /// Equal when both hold the same keys with equal values, in any order.
    static func == (lhs: NodeJSONObject, rhs: NodeJSONObject) -> Bool {
        return lhs.members == rhs.members
    }
}
