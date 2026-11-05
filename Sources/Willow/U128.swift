import Foundation

/// An unsigned 128-bit integer: the chain's `u128` token amounts (initial
/// funding, read prices).
///
/// It holds every value exactly, prints and parses as decimal, and is written
/// into the transactions the SDK sends as a JSON number of those digits, never
/// through a `Double`.
public struct U128: Hashable, Comparable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    /// The upper 64 bits.
    public let high: UInt64
    /// The lower 64 bits.
    public let low: UInt64

    public static let zero = U128(high: 0, low: 0)
    public static let max = U128(high: .max, low: .max)

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init(_ value: UInt64) {
        self.init(high: 0, low: value)
    }

    public init(integerLiteral value: UInt64) {
        self.init(value)
    }

    /// The value of `decimal`, unsigned decimal digits with no sign, spaces,
    /// or exponent; `nil` when it is anything else or above `U128.max`.
    public init?(_ decimal: String) {
        var high: UInt64 = 0
        var low: UInt64 = 0
        var digits = 0
        for byte in decimal.utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            digits += 1
            let lowTimesTen = low.multipliedFullWidth(by: 10)
            let (highTimesTen, overflowA) = high.multipliedReportingOverflow(by: 10)
            let (carried, overflowB) = highTimesTen.addingReportingOverflow(lowTimesTen.high)
            let (newLow, carry) = lowTimesTen.low.addingReportingOverflow(UInt64(byte - 0x30))
            let (newHigh, overflowC) = carried.addingReportingOverflow(carry ? 1 : 0)
            if overflowA || overflowB || overflowC { return nil }
            high = newHigh
            low = newLow
        }
        guard digits > 0 else { return nil }
        self.init(high: high, low: low)
    }

    /// `self + other`, or `nil` when it overflows.
    public func adding(_ other: U128) -> U128? {
        let (low, carry) = self.low.addingReportingOverflow(other.low)
        let (high, overflowA) = self.high.addingReportingOverflow(other.high)
        let (highWithCarry, overflowB) = high.addingReportingOverflow(carry ? 1 : 0)
        if overflowA || overflowB { return nil }
        return U128(high: highWithCarry, low: low)
    }

    /// The value as `T`, or `nil` when it does not fit.
    public func exactly<T: FixedWidthInteger & UnsignedInteger>(as type: T.Type) -> T? {
        guard high == 0 else { return nil }
        return T(exactly: low)
    }

    /// Unsigned decimal, no leading zeros.
    public var description: String {
        let chunk: UInt64 = 10_000_000_000_000_000_000 // 10^19
        var high = self.high
        var low = self.low
        var chunks: [UInt64] = []
        while high != 0 {
            let (quotientHigh, remainderHigh) = high.quotientAndRemainder(dividingBy: chunk)
            let (quotientLow, remainder) = chunk.dividingFullWidth((high: remainderHigh, low: low))
            chunks.append(remainder)
            high = quotientHigh
            low = quotientLow
        }
        var text = String(low)
        for part in chunks.reversed() {
            let digits = String(part)
            text += String(repeating: "0", count: 19 - digits.count) + digits
        }
        return text
    }

    /// The 16 bytes bincode writes: little-endian.
    internal var littleEndianBytes: [UInt8] {
        return withUnsafeBytes(of: low.littleEndian, Array.init) + withUnsafeBytes(of: high.littleEndian, Array.init)
    }

    public static func < (lhs: U128, rhs: U128) -> Bool {
        return (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}

extension U128: Codable {
    /// Reads a JSON number or a decimal string. `JSONDecoder` hands a number
    /// above `UInt64.max` over as a `Decimal`, exact only below 10^38, so a
    /// larger value must come as a string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(UInt64.self) {
            self.init(value)
            return
        }
        if let text = try? container.decode(String.self), let value = U128(text) {
            self = value
            return
        }
        if let decimal = try? container.decode(Decimal.self) {
            let text = NSDecimalNumber(decimal: decimal).stringValue
            if text.count <= 38, let value = U128(text) {
                self = value
                return
            }
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected an unsigned integer below 2^128")
    }

    /// Writes a JSON number up to `UInt64.max` and a decimal string above it
    /// (`JSONEncoder` can't write a larger integer). The transactions the SDK
    /// sends are written by its own encoder, which writes every `U128` as a
    /// JSON number.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if high == 0 {
            try container.encode(low)
        } else {
            try container.encode(description)
        }
    }
}
