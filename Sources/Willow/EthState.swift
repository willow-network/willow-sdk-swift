// Verifiable Ethereum state reads.
//
// Counterpart to the indexer's POST /verifiable-rpc/eth/state and
// /verifiable-rpc/eth/call routes. Walks EIP-1186 MPT proofs locally
// and exposes ergonomic storage-layout helpers (ERC-20 balance,
// Uniswap V2 reserves).
//
// Three trust modes follow the Rust/TS/Python/Go SDK conventions.

import Foundation
import CryptoSwift

public enum StateVerifyMode: String, Sendable {
    case strict
    case anchorOnly
    case disabled
}

public struct VerifiedStorage: Sendable {
    public let slot: String   // 0x-prefixed
    public let value: BigUInt
}

public struct VerifiedStateRead: Sendable {
    public let address: String
    public let blockNumber: UInt64
    public let blockHash: String
    public let stateRoot: String
    public let nonce: UInt64
    public let balance: BigUInt
    public let storageHash: String
    public let codeHash: String
    public let storage: [VerifiedStorage]
    public let mode: StateVerifyMode
}

public struct VerifiedCall: Sendable {
    public let blockNumber: UInt64
    public let blockHash: String
    public let stateRoot: String
    public let result: Data
    public let accessStateReads: [VerifiedStateRead]
    public let mode: StateVerifyMode
}

public enum EthStateError: Error, LocalizedError {
    case http(Int, String)
    case decode(String)
    case noStateProof
    case verificationFailed(String)
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .noStateProof: return "response carried no state proof"
        case .verificationFailed(let msg): return "verification failed: \(msg)"
        case .invalidAddress(let msg): return "invalid address: \(msg)"
        }
    }
}

// MARK: - SDK operations

public actor EthOperations {
    private let indexerBaseURL: URL
    private let session: URLSession
    public private(set) var mode: StateVerifyMode = .strict

    public init(indexerBaseURL: URL, session: URLSession = .shared) {
        self.indexerBaseURL = indexerBaseURL
        self.session = session
    }

    public func setMode(_ mode: StateVerifyMode) { self.mode = mode }

    /// Verified account + storage read at `block`.
    public func getState(
        address: String,
        slots: [String],
        block: UInt64
    ) async throws -> VerifiedStateRead {
        let body: [String: Any] = [
            "address": address,
            "slots": slots,
            "block": block,
        ]
        let env = try await post(path: "verifiable-rpc/eth/state", body: body)
        guard let proof = env.stateProofs.first else { throw EthStateError.noStateProof }
        if mode == .strict {
            try verifyStateProof(proof)
        }
        return toVerified(proof, mode: mode)
    }

    /// Verified `eth_call`: ABI-encoded result + state proofs for every
    /// touched account.
    public func getCall(tx: [String: Any], block: UInt64) async throws -> VerifiedCall {
        let body: [String: Any] = ["tx": tx, "block": block]
        let env = try await post(path: "verifiable-rpc/eth/call", body: body)
        if mode == .strict {
            for proof in env.stateProofs {
                try verifyStateProof(proof)
            }
        }
        // env.answer is base64-encoded ABI return data.
        guard let result = Data(base64EncodedNoPad: env.answer) else {
            throw EthStateError.decode("answer is not valid base64")
        }
        let blockHash = env.stateProofs.first.map { bytesIntsToHex($0.blockHash, width: 32) }
            ?? "0x" + String(repeating: "00", count: 32)
        return VerifiedCall(
            blockNumber: env.blockRange.0,
            blockHash: blockHash,
            stateRoot: bytesIntsToHex(env.stateRoot, width: 32),
            result: result,
            accessStateReads: env.stateProofs.map { toVerified($0, mode: mode) },
            mode: mode
        )
    }

    public func erc20Balance(
        token: String,
        holder: String,
        balanceSlot: UInt8,
        block: UInt64
    ) async throws -> BigUInt {
        guard let holderBytes = decodeHex20(holder) else {
            throw EthStateError.invalidAddress(holder)
        }
        let slot = mappingSlotForAddress(holderBytes, slotIndex: balanceSlot)
        let state = try await getState(
            address: token,
            slots: ["0x" + slot.hexString],
            block: block
        )
        guard let first = state.storage.first else {
            throw EthStateError.verificationFailed("erc20Balance: empty storage proofs")
        }
        return first.value
    }

    // MARK: - private

    private func post(path: String, body: [String: Any]) async throws -> WireEnvelope {
        let url = indexerBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: request)
        guard let httpResp = resp as? HTTPURLResponse else {
            throw EthStateError.http(0, "non-http response")
        }
        guard (200..<300).contains(httpResp.statusCode) else {
            throw EthStateError.http(httpResp.statusCode, String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw EthStateError.decode("\(error)")
        }
    }
}

// MARK: - Wire types
//
// The Rust server serializes fixed [u8; N] arrays as JSON arrays of
// numbers (default serde behavior), so the wire decoder matches.

struct WireMptProof: Decodable {
    let key: [UInt8]
    let value: [UInt8]
    let proofNodes: [[UInt8]]

    enum CodingKeys: String, CodingKey {
        case key, value
        case proofNodes = "proof_nodes"
    }
}

struct WireAccountState: Decodable {
    let nonce: UInt64
    let balance: [UInt8]
    let storageHash: [UInt8]
    let codeHash: [UInt8]

    enum CodingKeys: String, CodingKey {
        case nonce, balance
        case storageHash = "storage_hash"
        case codeHash = "code_hash"
    }
}

struct WireStorageSlot: Decodable {
    let slot: [UInt8]
    let value: [UInt8]
    let proof: WireMptProof
}

struct WireStateProof: Decodable {
    let address: [UInt8]
    let blockNumber: UInt64
    let blockHash: [UInt8]
    let stateRoot: [UInt8]
    let accountProof: WireMptProof
    let accountState: WireAccountState
    let storageProofs: [WireStorageSlot]

    enum CodingKeys: String, CodingKey {
        case address
        case blockNumber = "block_number"
        case blockHash = "block_hash"
        case stateRoot = "state_root"
        case accountProof = "account_proof"
        case accountState = "account_state"
        case storageProofs = "storage_proofs"
    }
}

struct WireEnvelope: Decodable {
    let answer: String
    let stateRoot: [UInt8]
    let blockRange: (UInt64, UInt64)
    let stateProofs: [WireStateProof]

    enum CodingKeys: String, CodingKey {
        case answer
        case stateRoot = "state_root"
        case blockRange = "block_range"
        case stateProofs = "state_proofs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        stateRoot = try c.decode([UInt8].self, forKey: .stateRoot)
        let range = try c.decode([UInt64].self, forKey: .blockRange)
        guard range.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .blockRange,
                in: c,
                debugDescription: "block_range must have 2 elements"
            )
        }
        blockRange = (range[0], range[1])
        stateProofs = try c.decodeIfPresent([WireStateProof].self, forKey: .stateProofs) ?? []
    }
}

// MARK: - Verification

func verifyStateProof(_ proof: WireStateProof) throws {
    let stateRoot = Data(proof.stateRoot)
    let address = Data(proof.address)
    let addrHash = keccak256(address)
    let balance = BigUInt(bytesBE: proof.accountState.balance)
    let storageHash = Data(proof.accountState.storageHash)
    let codeHash = Data(proof.accountState.codeHash)
    let accountLeaf = rlpEncodeAccount(
        nonce: proof.accountState.nonce,
        balance: balance,
        storageHash: storageHash,
        codeHash: codeHash
    )
    let nodes = proof.accountProof.proofNodes.map { Data($0) }
    try verifyMptProof(
        root: stateRoot,
        keyHash: addrHash,
        expectedValue: accountLeaf,
        proofNodes: nodes
    )
    for sp in proof.storageProofs {
        let slot = Data(sp.slot)
        let valueInt = BigUInt(bytesBE: sp.value)
        let valueRlp: Data
        if valueInt == 0 {
            valueRlp = rlpEncodeBytes(Data())
        } else {
            valueRlp = rlpEncodeBytes(valueInt.bigEndianMinimal())
        }
        let storageNodes = sp.proof.proofNodes.map { Data($0) }
        do {
            try verifyMptProof(
                root: storageHash,
                keyHash: keccak256(slot),
                expectedValue: valueRlp,
                proofNodes: storageNodes
            )
        } catch let err {
            throw EthStateError.verificationFailed(
                "storage slot 0x\(slot.hexString): \(err.localizedDescription)"
            )
        }
    }
}

func verifyMptProof(
    root: Data,
    keyHash: Data,
    expectedValue: Data,
    proofNodes: [Data]
) throws {
    if root.count != 32 {
        throw EthStateError.verificationFailed("root must be 32 bytes")
    }
    if keyHash.count != 32 {
        throw EthStateError.verificationFailed("key must be 32 bytes")
    }
    if proofNodes.isEmpty {
        throw EthStateError.verificationFailed("proof is empty")
    }
    let nibs = bytesToNibbles(keyHash)
    var expected = root
    var idx = 0
    for (i, node) in proofNodes.enumerated() {
        if keccak256(node) != expected {
            throw EthStateError.verificationFailed("node \(i): hash mismatch")
        }
        let decoded = try rlpDecodeList(node)
        switch decoded.count {
        case 17:
            if idx == nibs.count {
                try checkValue(decoded[16], expected: expectedValue)
                return
            }
            let next = decoded[nibs[idx]]
            idx += 1
            if next.isEmpty {
                try checkValue(Data(), expected: expectedValue)
                return
            }
            if next.count != 32 {
                throw EthStateError.verificationFailed(
                    "node \(i): inline-embedded child not supported (len \(next.count))"
                )
            }
            expected = next
        case 2:
            let (path, isLeaf) = decodeCompactPath(decoded[0])
            let remaining = Array(nibs[idx...])
            if path.count > remaining.count
                || !path.elementsEqual(remaining.prefix(path.count))
            {
                try checkValue(Data(), expected: expectedValue)
                return
            }
            idx += path.count
            if isLeaf {
                if idx != nibs.count {
                    try checkValue(Data(), expected: expectedValue)
                    return
                }
                try checkValue(decoded[1], expected: expectedValue)
                return
            }
            let ref = decoded[1]
            if ref.count != 32 {
                throw EthStateError.verificationFailed(
                    "node \(i): inline-embedded extension child not supported (len \(ref.count))"
                )
            }
            expected = ref
        default:
            throw EthStateError.verificationFailed(
                "node \(i): unexpected RLP shape (len \(decoded.count))"
            )
        }
    }
    throw EthStateError.verificationFailed("proof exhausted without reaching leaf")
}

private func checkValue(_ actual: Data, expected: Data) throws {
    if actual == expected { return }
    throw EthStateError.verificationFailed("leaf value mismatch")
}

// MARK: - Minimal RLP

func rlpEncodeBytes(_ b: Data) -> Data {
    if b.count == 1 && b[0] < 0x80 {
        return Data([b[0]])
    }
    if b.count <= 55 {
        var out = Data([0x80 + UInt8(b.count)])
        out.append(b)
        return out
    }
    let lenBytes = uintToMinBE(UInt64(b.count))
    var out = Data([0xb7 + UInt8(lenBytes.count)])
    out.append(lenBytes)
    out.append(b)
    return out
}

func rlpEncodeList(_ items: [Data]) -> Data {
    var payload = Data()
    for it in items { payload.append(it) }
    if payload.count <= 55 {
        var out = Data([0xc0 + UInt8(payload.count)])
        out.append(payload)
        return out
    }
    let lenBytes = uintToMinBE(UInt64(payload.count))
    var out = Data([0xf7 + UInt8(lenBytes.count)])
    out.append(lenBytes)
    out.append(payload)
    return out
}

func rlpEncodeAccount(nonce: UInt64, balance: BigUInt, storageHash: Data, codeHash: Data) -> Data {
    let nonceBytes = uintToMinBE(nonce)
    let balanceBytes = balance == 0 ? Data() : balance.bigEndianMinimal()
    return rlpEncodeList([
        rlpEncodeBytes(nonceBytes),
        rlpEncodeBytes(balanceBytes),
        rlpEncodeBytes(storageHash),
        rlpEncodeBytes(codeHash),
    ])
}

/// Decodes an RLP list of byte-strings (the only shape MPT nodes take
/// at the depths we walk). Returns inner byte-strings (already stripped
/// of their length prefixes).
func rlpDecodeList(_ data: Data) throws -> [Data] {
    if data.isEmpty {
        throw EthStateError.decode("rlp: empty input")
    }
    let first = data[data.startIndex]
    if first < 0xc0 {
        throw EthStateError.decode("rlp: expected list")
    }
    let payloadStart: Int
    let payloadLen: Int
    if first <= 0xf7 {
        payloadStart = 1
        payloadLen = Int(first - 0xc0)
    } else {
        let lenOfLen = Int(first - 0xf7)
        if 1 + lenOfLen > data.count {
            throw EthStateError.decode("rlp: list length overflow")
        }
        payloadStart = 1 + lenOfLen
        var l = 0
        for b in data[1..<(1 + lenOfLen)] {
            l = (l << 8) | Int(b)
        }
        payloadLen = l
    }
    if payloadStart + payloadLen > data.count {
        throw EthStateError.decode("rlp: list payload truncated")
    }
    let payload = data[payloadStart..<(payloadStart + payloadLen)]
    var out: [Data] = []
    var pos = payload.startIndex
    while pos < payload.endIndex {
        let (item, advance) = try rlpDecodeItem(payload.suffix(from: pos))
        out.append(item)
        pos += advance
    }
    return out
}

private func rlpDecodeItem(_ data: Data) throws -> (Data, Int) {
    if data.isEmpty {
        throw EthStateError.decode("rlp: item empty")
    }
    let base = data.startIndex
    let first = data[base]
    if first <= 0x7f {
        return (Data([first]), 1)
    }
    if first <= 0xb7 {
        let l = Int(first - 0x80)
        if 1 + l > data.count {
            throw EthStateError.decode("rlp: item truncated")
        }
        return (Data(data[(base + 1)..<(base + 1 + l)]), 1 + l)
    }
    if first <= 0xbf {
        let lenOfLen = Int(first - 0xb7)
        if 1 + lenOfLen > data.count {
            throw EthStateError.decode("rlp: item length overflow")
        }
        var l = 0
        for b in data[(base + 1)..<(base + 1 + lenOfLen)] {
            l = (l << 8) | Int(b)
        }
        if 1 + lenOfLen + l > data.count {
            throw EthStateError.decode("rlp: long item truncated")
        }
        return (
            Data(data[(base + 1 + lenOfLen)..<(base + 1 + lenOfLen + l)]),
            1 + lenOfLen + l
        )
    }
    throw EthStateError.decode("rlp: nested list not supported in MPT verifier")
}

// MARK: - Misc helpers

func keccak256(_ data: Data) -> Data {
    return Data(Digest.sha3([UInt8](data), variant: .keccak256))
}

func bytesToNibbles(_ data: Data) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(data.count * 2)
    for b in data {
        out.append(Int(b >> 4) & 0x0f)
        out.append(Int(b) & 0x0f)
    }
    return out
}

func decodeCompactPath(_ encoded: Data) -> ([Int], Bool) {
    if encoded.isEmpty { return ([], false) }
    let first = encoded[encoded.startIndex]
    let flag = (first >> 4) & 0x0f
    let isLeaf = flag >= 2
    let odd = (flag & 1) == 1
    var nibs: [Int] = []
    if odd {
        nibs.append(Int(first & 0x0f))
    }
    for b in encoded.dropFirst() {
        nibs.append(Int(b >> 4) & 0x0f)
        nibs.append(Int(b) & 0x0f)
    }
    return (nibs, isLeaf)
}

func uintToMinBE(_ n: UInt64) -> Data {
    if n == 0 { return Data() }
    var bytes: [UInt8] = []
    var v = n
    while v > 0 {
        bytes.insert(UInt8(v & 0xff), at: 0)
        v >>= 8
    }
    return Data(bytes)
}

func mappingSlotForAddress(_ addr: Data, slotIndex: UInt8) -> Data {
    var buf = Data(repeating: 0, count: 64)
    buf.replaceSubrange(12..<32, with: addr)
    buf[63] = slotIndex
    return keccak256(buf)
}

func decodeHex20(_ s: String) -> Data? {
    var hex = s.lowercased()
    if hex.hasPrefix("0x") { hex.removeFirst(2) }
    guard hex.count == 40 else { return nil }
    var out = Data(capacity: 20)
    var i = hex.startIndex
    while i < hex.endIndex {
        let next = hex.index(i, offsetBy: 2)
        guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
        out.append(byte)
        i = next
    }
    return out
}

func bytesIntsToHex(_ bytes: [UInt8], width: Int) -> String {
    var b = bytes
    if b.count < width {
        b = Array(repeating: 0, count: width - b.count) + b
    }
    return "0x" + Data(b).hexString
}

func toVerified(_ proof: WireStateProof, mode: StateVerifyMode) -> VerifiedStateRead {
    let storage = proof.storageProofs.map { sp in
        VerifiedStorage(
            slot: bytesIntsToHex(sp.slot, width: 32),
            value: BigUInt(bytesBE: sp.value)
        )
    }
    return VerifiedStateRead(
        address: bytesIntsToHex(proof.address, width: 20),
        blockNumber: proof.blockNumber,
        blockHash: bytesIntsToHex(proof.blockHash, width: 32),
        stateRoot: bytesIntsToHex(proof.stateRoot, width: 32),
        nonce: proof.accountState.nonce,
        balance: BigUInt(bytesBE: proof.accountState.balance),
        storageHash: bytesIntsToHex(proof.accountState.storageHash, width: 32),
        codeHash: bytesIntsToHex(proof.accountState.codeHash, width: 32),
        storage: storage,
        mode: mode
    )
}

// MARK: - BigUInt
//
// Minimal arbitrary-precision unsigned integer wrapper backed by
// big-endian byte arrays. The SDK has no other arbitrary-precision
// needs, so we keep this internal rather than pull in an external dep.

public struct BigUInt: Equatable, Hashable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    let bytes: [UInt8]

    public init(_ value: UInt64) {
        if value == 0 {
            bytes = []
            return
        }
        var b: [UInt8] = []
        var v = value
        while v > 0 {
            b.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        bytes = b
    }

    public init(integerLiteral value: UInt64) { self.init(value) }

    init(bytesBE: [UInt8]) {
        var b = bytesBE
        while b.first == 0 { b.removeFirst() }
        self.bytes = b
    }

    public static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.bytes == rhs.bytes
    }

    public func bigEndianMinimal() -> Data {
        Data(bytes)
    }

    public var description: String {
        if bytes.isEmpty { return "0" }
        return "0x" + Data(bytes).hexString
    }
}

// MARK: - Data base64 helper
//
// `Data.hexString` and `Data(hexString:)` already live in Auth.swift /
// GroveDBTypes.swift; we reuse those. Only the base64-no-pad init below
// is new to EthState — Rust server uses STANDARD_NO_PAD encoding.

extension Data {
    init?(base64EncodedNoPad s: String) {
        let rem = s.count % 4
        let padded: String
        switch rem {
        case 0: padded = s
        case 2: padded = s + "=="
        case 3: padded = s + "="
        default: return nil
        }
        if let d = Data(base64Encoded: padded) {
            self = d
        } else {
            return nil
        }
    }
}
