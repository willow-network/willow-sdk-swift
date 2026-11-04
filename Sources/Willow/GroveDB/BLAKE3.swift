import Foundation

/// BLAKE3 in its default hash mode with a 32-byte output: the hash GroveDB and
/// Merk use for every value, key-value, node, and combined hash.
///
/// A direct implementation of the BLAKE3 specification (the reference
/// implementation's structure: 1 KiB chunks, a stack of chaining values, the
/// 7-round compression function), checked against BLAKE3's official test
/// vectors in the tests.
internal enum BLAKE3 {
    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private static let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3

    private static let blockLength = 64
    private static let chunkLength = 1024

    /// The 32-byte BLAKE3 hash of `input`.
    static func hash<C: Collection>(_ input: C) -> [UInt8] where C.Element == UInt8 {
        var hasher = Hasher()
        hasher.update(Array(input))
        return hasher.finalize()
    }

    // MARK: Compression

    @inline(__always)
    private static func g(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        s[a] = s[a] &+ s[b] &+ x
        s[d] = (s[d] ^ s[a]).rotatedRight(16)
        s[c] = s[c] &+ s[d]
        s[b] = (s[b] ^ s[c]).rotatedRight(12)
        s[a] = s[a] &+ s[b] &+ y
        s[d] = (s[d] ^ s[a]).rotatedRight(8)
        s[c] = s[c] &+ s[d]
        s[b] = (s[b] ^ s[c]).rotatedRight(7)
    }

    private static func compress(_ cv: [UInt32], _ block: [UInt32], _ counter: UInt64, _ length: UInt32, _ flags: UInt32) -> [UInt32] {
        var s = [
            cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), length, flags,
        ]
        var m = block
        for round in 0..<7 {
            g(&s, 0, 4, 8, 12, m[0], m[1])
            g(&s, 1, 5, 9, 13, m[2], m[3])
            g(&s, 2, 6, 10, 14, m[4], m[5])
            g(&s, 3, 7, 11, 15, m[6], m[7])
            g(&s, 0, 5, 10, 15, m[8], m[9])
            g(&s, 1, 6, 11, 12, m[10], m[11])
            g(&s, 2, 7, 8, 13, m[12], m[13])
            g(&s, 3, 4, 9, 14, m[14], m[15])
            if round < 6 {
                m = permutation.map { m[$0] }
            }
        }
        for i in 0..<8 {
            s[i] ^= s[i + 8]
            s[i + 8] ^= cv[i]
        }
        return s
    }

    private static func words(_ block: [UInt8]) -> [UInt32] {
        return (0..<16).map { i in
            UInt32(block[4 * i]) | UInt32(block[4 * i + 1]) << 8 | UInt32(block[4 * i + 2]) << 16 | UInt32(block[4 * i + 3]) << 24
        }
    }

    // MARK: Tree

    /// A compression's inputs, kept so a node can be finished as a chaining
    /// value or as the root.
    private struct Output {
        let cv: [UInt32]
        let block: [UInt32]
        let counter: UInt64
        let length: UInt32
        let flags: UInt32

        var chainingValue: [UInt32] {
            return Array(BLAKE3.compress(cv, block, counter, length, flags).prefix(8))
        }

        var rootBytes: [UInt8] {
            let words = BLAKE3.compress(cv, block, 0, length, flags | BLAKE3.root).prefix(8)
            return words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
        }
    }

    private static func parentOutput(_ left: [UInt32], _ right: [UInt32]) -> Output {
        return Output(cv: iv, block: left + right, counter: 0, length: UInt32(blockLength), flags: parent)
    }

    private struct ChunkState {
        var cv: [UInt32] = BLAKE3.iv
        let counter: UInt64
        var block = [UInt8](repeating: 0, count: BLAKE3.blockLength)
        var blockLen = 0
        var blocksCompressed = 0

        init(counter: UInt64) {
            self.counter = counter
        }

        var length: Int {
            return BLAKE3.blockLength * blocksCompressed + blockLen
        }

        var startFlag: UInt32 {
            return blocksCompressed == 0 ? BLAKE3.chunkStart : 0
        }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var input = input
            while !input.isEmpty {
                if blockLen == BLAKE3.blockLength {
                    cv = Array(BLAKE3.compress(cv, BLAKE3.words(block), counter, UInt32(BLAKE3.blockLength), startFlag).prefix(8))
                    blocksCompressed += 1
                    block = [UInt8](repeating: 0, count: BLAKE3.blockLength)
                    blockLen = 0
                }
                let take = min(BLAKE3.blockLength - blockLen, input.count)
                block.replaceSubrange(blockLen..<(blockLen + take), with: input.prefix(take))
                blockLen += take
                input = input.dropFirst(take)
            }
        }

        var output: Output {
            return Output(cv: cv, block: BLAKE3.words(block), counter: counter, length: UInt32(blockLen), flags: startFlag | BLAKE3.chunkEnd)
        }
    }

    private struct Hasher {
        var chunk = ChunkState(counter: 0)
        var stack: [[UInt32]] = []

        /// Pushes a finished chunk's chaining value, first merging every
        /// completed subtree to its left (one per trailing zero bit of the
        /// chunk count).
        mutating func push(_ cv: [UInt32], totalChunks: UInt64) {
            var cv = cv
            var total = totalChunks
            while total & 1 == 0 {
                cv = BLAKE3.parentOutput(stack.removeLast(), cv).chainingValue
                total >>= 1
            }
            stack.append(cv)
        }

        mutating func update(_ input: [UInt8]) {
            var rest = input[...]
            while !rest.isEmpty {
                if chunk.length == BLAKE3.chunkLength {
                    let total = chunk.counter + 1
                    push(chunk.output.chainingValue, totalChunks: total)
                    chunk = ChunkState(counter: total)
                }
                let take = min(BLAKE3.chunkLength - chunk.length, rest.count)
                chunk.update(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
        }

        func finalize() -> [UInt8] {
            var output = chunk.output
            for cv in stack.reversed() {
                output = BLAKE3.parentOutput(cv, output.chainingValue)
            }
            return output.rootBytes
        }
    }
}

private extension UInt32 {
    @inline(__always)
    func rotatedRight(_ n: UInt32) -> UInt32 {
        return (self >> n) | (self << (32 - n))
    }
}
