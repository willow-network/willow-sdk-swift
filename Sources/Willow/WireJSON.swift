import Foundation

/// A JSON value as the node reads it from a `/tx/submit` body, numbers kept as
/// their literal text so a u64 or u128 is never rounded through a `Double`.
///
/// The SDK writes a transaction whose signed message hashes the transaction's
/// own encoding (RegisterSubgrove) as one of these, and hashes the value it
/// writes, so what it signs is what it sends. Objects keep their members in
/// order, and `serialized` writes compact JSON that escapes only `"`, `\`, and
/// control characters, as serde_json does.
internal indirect enum WireJSON: Equatable {
    case null
    case bool(Bool)
    /// A number's literal text.
    case number(String)
    case string(String)
    case array([WireJSON])
    case object([Member])

    struct Member: Equatable {
        let key: String
        let value: WireJSON

        init(_ key: String, _ value: WireJSON) {
            self.key = key
            self.value = value
        }
    }

    // MARK: Building

    static func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) -> WireJSON {
        return .number(String(value))
    }

    static func u128(_ value: U128) -> WireJSON {
        return .number(value.description)
    }

    /// Bytes as serde writes a `Vec<u8>` or `[u8; N]`: an array of numbers.
    static func bytes<S: Sequence>(_ bytes: S) -> WireJSON where S.Element == UInt8 {
        return .array(bytes.map { .number(String($0)) })
    }

    static func strings(_ values: [String]) -> WireJSON {
        return .array(values.map { .string($0) })
    }

    static func optional<T>(_ value: T?, _ write: (T) throws -> WireJSON) rethrows -> WireJSON {
        guard let value = value else { return .null }
        return try write(value)
    }

    /// An externally tagged enum variant with fields, as serde writes it: `{"<Variant>": payload}`.
    static func variant(_ name: String, _ payload: WireJSON) -> WireJSON {
        return .object([Member(name, payload)])
    }

    // MARK: Writing

    /// Compact JSON.
    var serialized: Data {
        var out: [UInt8] = []
        write(into: &out)
        return Data(out)
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .null:
            out += Array("null".utf8)
        case .bool(let value):
            out += Array((value ? "true" : "false").utf8)
        case .number(let text):
            out += Array(text.utf8)
        case .string(let text):
            WireJSON.writeString(text, into: &out)
        case .array(let elements):
            out.append(UInt8(ascii: "["))
            for (index, element) in elements.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                element.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                WireJSON.writeString(member.key, into: &out)
                out.append(UInt8(ascii: ":"))
                member.value.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"): out += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
            case 0x08: out += [UInt8(ascii: "\\"), UInt8(ascii: "b")]
            case 0x0C: out += [UInt8(ascii: "\\"), UInt8(ascii: "f")]
            case 0x0A: out += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
            case 0x0D: out += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
            case 0x09: out += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
            case 0x00..<0x20:
                out += Array("\\u00".utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: Reading

    /// Parses JSON text, keeping numbers as their literal text. Refuses
    /// trailing text, duplicate keys in an object, invalid UTF-8, lone
    /// surrogate escapes, and nesting deeper than 128, as the node's JSON
    /// reader does.
    static func parse(_ data: Data) throws -> WireJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw parser.error("trailing characters")
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> WillowError {
            return SerializationError("Invalid JSON at byte \(index): \(message)")
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> WireJSON {
            guard depth < 128 else { throw error("nested too deeply") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                return try object(depth: depth)
            case UInt8(ascii: "["):
                return try array(depth: depth)
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
                throw error("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
                throw error("expected \(word)")
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> WireJSON {
            index += 1
            var members: [Member] = []
            var keys = Set<String>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                guard keys.insert(key).inserted else { throw error("duplicate key \(key)") }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                members.append(Member(key, try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw error("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { throw error("expected ',' or '}'") }
                index += 1
                return .object(members)
            }
        }

        mutating func array(depth: Int) throws -> WireJSON {
            index += 1
            var elements: [WireJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { throw error("expected ',' or ']'") }
                index += 1
                return .array(elements)
            }
        }

        /// A number's literal text, checked against JSON's grammar.
        mutating func number() throws -> String {
            let start = index
            func digits(_ parser: inout Parser) -> Int {
                let begin = parser.index
                while parser.index < parser.bytes.count, (0x30...0x39).contains(parser.bytes[parser.index]) {
                    parser.index += 1
                }
                return parser.index - begin
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw error("invalid number") }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits(&self) == 0 {
                throw error("invalid number")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits(&self) > 0 else { throw error("invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                guard digits(&self) > 0 else { throw error("invalid number") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: out, encoding: .utf8) else { throw error("invalid UTF-8") }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw error("unterminated escape") }
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
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                                throw error("lone surrogate")
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("lone surrogate") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw error("lone surrogate")
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw error("invalid escape") }
                        out += Array(String(Character(unicode)).utf8)
                    default:
                        throw error("invalid escape")
                    }
                case 0x00..<0x20:
                    throw error("control character in string")
                default:
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw error("short \\u escape") }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: throw error("invalid \\u escape")
                }
                value = value << 4 | UInt32(digit)
            }
            index += 4
            return value
        }
    }
}

// MARK: - Reading Fields

/// The members of a JSON object read the way serde reads a struct: by name,
/// unknown members ignored, a missing `Option` as none.
internal struct WireJSONObject {
    let members: [WireJSON.Member]
    let what: String

    init(_ value: WireJSON, _ what: String) throws {
        guard case .object(let members) = value else {
            throw ValidationError("\(what) must be a JSON object")
        }
        self.members = members
        self.what = what
    }

    func optional(_ key: String) -> WireJSON? {
        return members.first { $0.key == key }?.value
    }

    func required(_ key: String) throws -> WireJSON {
        guard let value = optional(key) else {
            throw ValidationError("\(what) is missing \(key)")
        }
        return value
    }

    /// An `Option` member read with `read`: none when missing or null.
    func optionalValue<T>(_ key: String, _ read: (WireJSON) throws -> T) rethrows -> T? {
        guard let value = optional(key), !value.isNull else { return nil }
        return try read(value)
    }

    /// The member, or `fallback` when it is missing (a `#[serde(default)]` field).
    func value(_ key: String, default fallback: WireJSON) -> WireJSON {
        return optional(key) ?? fallback
    }

    func label(_ key: String) -> String {
        return "\(what).\(key)"
    }
}

extension WireJSON {
    func string(_ what: String) throws -> String {
        guard case .string(let text) = self else { throw ValidationError("\(what) must be a string") }
        return text
    }

    func bool(_ what: String) throws -> Bool {
        guard case .bool(let value) = self else { throw ValidationError("\(what) must be true or false") }
        return value
    }

    /// The unsigned integer a JSON number's digits spell, refused when it is
    /// negative, fractional, has an exponent, or is out of `T`'s range.
    func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ what: String, as type: T.Type) throws -> T {
        guard case .number(let text) = self, let value = U128(text)?.exactly(as: T.self) else {
            throw ValidationError("\(what) must be an integer from 0 to \(T.max)")
        }
        return value
    }

    func u128(_ what: String) throws -> U128 {
        guard case .number(let text) = self, let value = U128(text) else {
            throw ValidationError("\(what) must be an integer from 0 to \(U128.max)")
        }
        return value
    }

    /// A u128 the node also reads from a decimal string.
    func flexibleU128(_ what: String) throws -> U128 {
        if case .string(let text) = self {
            guard let value = U128(text) else {
                throw ValidationError("\(what) must be an integer from 0 to \(U128.max)")
            }
            return value
        }
        return try u128(what)
    }

    func array(_ what: String) throws -> [WireJSON] {
        guard case .array(let elements) = self else { throw ValidationError("\(what) must be an array") }
        return elements
    }

    func strings(_ what: String) throws -> [String] {
        return try array(what).map { try $0.string(what) }
    }

    func bytes(_ what: String) throws -> [UInt8] {
        return try array(what).map { try $0.unsigned(what, as: UInt8.self) }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// An externally tagged enum value: a unit variant as `"Variant"` (or
    /// `{"Variant": null}`), a variant with fields as `{"Variant": payload}`.
    func variant(_ what: String) throws -> (name: String, payload: WireJSON?) {
        switch self {
        case .string(let name):
            return (name, nil)
        case .object(let members) where members.count == 1:
            let payload = members[0].value
            return (members[0].key, payload.isNull ? nil : payload)
        default:
            throw ValidationError("\(what) must be an enum variant")
        }
    }
}
