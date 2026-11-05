// Ethereum state reads served by an indexer.
//
// Counterpart to the indexer's POST /verifiable-rpc/eth/state and
// /verifiable-rpc/eth/call routes. Walks EIP-1186 MPT proofs locally
// and exposes a storage-layout helper (ERC-20 balance).
//
// The SDK doesn't verify these reads against Ethereum (see EthOperations).

import Foundation
import CryptoSwift

/// How much of an indexer's Ethereum state answer `EthOperations` checks. No
/// mode verifies the answer against Ethereum (see `EthOperations`).
public enum StateVerifyMode: String, Sendable {
    /// Walks the account proof and every storage proof against the state
    /// root the answer itself carries (the default).
    case strict
    /// Walks no proof, as `.disabled` does: nothing anchors the answer's
    /// root.
    @available(*, deprecated, message: "Anchors nothing: no proof is walked, as with .disabled. Use .strict to walk the proofs against the answer's own root.")
    case anchorOnly
    /// Walks no proof.
    case disabled
}

/// A storage slot's value as an indexer's answer carries it.
public struct EthStorageSlot: Sendable {
    public let slot: String   // 0x-prefixed, 32 bytes
    public let value: BigUInt
}

/// An account's state, and the storage slots asked of it, at a block, as an
/// indexer's answer carries it, unverified against Ethereum (see
/// `EthOperations`). `mode` says whether its proofs were walked against
/// `stateRoot`.
public struct EthStateRead: Sendable {
    public let address: String
    public let blockNumber: UInt64
    public let blockHash: String
    public let stateRoot: String
    public let nonce: UInt64
    public let balance: BigUInt
    public let storageHash: String
    public let codeHash: String
    public let storage: [EthStorageSlot]
    public let mode: StateVerifyMode
}

/// An `eth_call` as an indexer ran it: its result, and the state of every
/// account the call touched, unverified against Ethereum (see
/// `EthOperations`). No proof binds `result`: the SDK doesn't run the call.
public struct EthCallResult: Sendable {
    public let blockNumber: UInt64
    public let blockHash: String
    public let stateRoot: String
    public let result: Data
    public let accessStateReads: [EthStateRead]
    public let mode: StateVerifyMode
}

/// `EthStorageSlot`.
@available(*, deprecated, renamed: "EthStorageSlot", message: "The value isn't verified against Ethereum.")
public typealias VerifiedStorage = EthStorageSlot
/// `EthStateRead`.
@available(*, deprecated, renamed: "EthStateRead", message: "The state isn't verified against Ethereum.")
public typealias VerifiedStateRead = EthStateRead
/// `EthCallResult`.
@available(*, deprecated, renamed: "EthCallResult", message: "The call isn't verified against Ethereum.")
public typealias VerifiedCall = EthCallResult

public enum EthStateError: Error, LocalizedError {
    case http(Int, String)
    case decode(String)
    case noStateProof
    case verificationFailed(String)
    case invalidAddress(String)
    /// An answer that isn't about what was asked (another address, block,
    /// or slot), or that carries a balance or value longer than a uint256's
    /// 32 bytes.
    case unexpectedAnswer(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .noStateProof: return "response carried no state proof"
        case .verificationFailed(let msg): return "verification failed: \(msg)"
        case .invalidAddress(let msg): return "invalid address: \(msg)"
        case .unexpectedAnswer(let msg): return "unexpected answer: \(msg)"
        }
    }
}

// MARK: - SDK operations

/// Reads Ethereum state through an indexer.
///
/// Nothing it returns is verified against Ethereum. Each answer carries the
/// block's state root, and its MPT proofs bind the account and slot values to
/// that root, but the SDK has no trusted source of Ethereum block headers (it
/// runs no Ethereum light client; the block hash and state root it has are
/// the indexer's), so it can't check that the root is the state root of the
/// block asked for. Treat every result as the indexer's claim. In `.strict`
/// mode (the default) the SDK walks the proofs, so a result is at least
/// consistent with the root the answer names; in the other modes it doesn't.
///
/// In every mode an answer must be about what was asked: a state read's proof
/// must be for the address, block, and slots requested, in order, and a
/// call's state proofs for the block requested, under the answer's state
/// root; a balance or value longer than 32 bytes is refused. A zero storage
/// value is proved by the slot's absence from the account's storage trie.
public actor EthOperations {
    private let indexerBaseURL: URL
    private let session: URLSession
    public private(set) var mode: StateVerifyMode = .strict

    public init(indexerBaseURL: URL, session: URLSession = .shared) {
        self.indexerBaseURL = indexerBaseURL
        self.session = session
    }

    public func setMode(_ mode: StateVerifyMode) { self.mode = mode }

    /// An account's state, and the storage slots asked of it, at `block`, as
    /// the indexer reports it (see `EthOperations`). `address` is 20 bytes of
    /// hex; each slot is up to 32 bytes of hex, read as a big-endian number
    /// and sent as 32 bytes. Throws, rather than return the answer, when the
    /// answer's proof isn't for that address, block, and those slots in that
    /// order, or carries a balance or value longer than 32 bytes
    /// (`EthStateError.unexpectedAnswer`), or, in `.strict` mode, when a
    /// proof doesn't walk.
    public func getState(
        address: String,
        slots: [String],
        block: UInt64
    ) async throws -> EthStateRead {
        guard let addressBytes = decodeHex20(address) else {
            throw EthStateError.invalidAddress(address)
        }
        let keys = try slots.enumerated().map { index, slot in try slotKey(slot, index: index) }
        let body: [String: Any] = [
            "address": "0x" + addressBytes.hexString,
            "slots": keys.map { "0x" + $0.hexString },
            "block": block,
        ]
        let env = try await post(path: "verifiable-rpc/eth/state", body: body)
        guard !env.stateProofs.isEmpty else { throw EthStateError.noStateProof }
        guard env.stateProofs.count == 1 else {
            throw EthStateError.unexpectedAnswer("the answer carried \(env.stateProofs.count) state proofs, not 1")
        }
        let proof = env.stateProofs[0]
        try checkStateAnswer(proof, address: addressBytes, slots: keys, block: block)
        if mode == .strict {
            try verifyStateProof(proof)
        }
        return toEthStateRead(proof, mode: mode)
    }

    /// Asks the indexer to run `tx` at `block` and returns the ABI-encoded
    /// result it reports, with its state proofs for every account the call
    /// touched (see `EthOperations`). No proof binds the result. Throws when
    /// the answer or a state proof isn't for `block`, a state proof isn't
    /// under the answer's state root, or one carries a balance or value
    /// longer than 32 bytes (`EthStateError.unexpectedAnswer`), or, in
    /// `.strict` mode, when a proof doesn't walk.
    public func getCall(tx: [String: Any], block: UInt64) async throws -> EthCallResult {
        let body: [String: Any] = ["tx": tx, "block": block]
        let env = try await post(path: "verifiable-rpc/eth/call", body: body)
        guard env.blockRange.0 == block else {
            throw EthStateError.unexpectedAnswer("the answer is for block \(env.blockRange.0), not \(block)")
        }
        guard env.stateRoot.count == 32 else {
            throw EthStateError.unexpectedAnswer("the answer's state root is \(env.stateRoot.count) bytes, not 32")
        }
        for (index, proof) in env.stateProofs.enumerated() {
            guard proof.blockNumber == block else {
                throw EthStateError.unexpectedAnswer("state proof \(index) is for block \(proof.blockNumber), not \(block)")
            }
            guard proof.stateRoot == env.stateRoot else {
                throw EthStateError.unexpectedAnswer("state proof \(index) is under another state root than the answer's")
            }
            try checkWords(proof, "state proof \(index): ")
        }
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
        return EthCallResult(
            blockNumber: env.blockRange.0,
            blockHash: blockHash,
            stateRoot: bytesIntsToHex(env.stateRoot, width: 32),
            result: result,
            accessStateReads: env.stateProofs.map { toEthStateRead($0, mode: mode) },
            mode: mode
        )
    }

    /// `balanceOf(holder)` for a token whose balance mapping lives at slot
    /// `balanceSlot`, as the indexer reports it (see `EthOperations`): the
    /// value of the slot `getState` asked for. Throws when there is no
    /// contract at `token` (its account doesn't exist, or has no code). It
    /// can't tell whether `balanceSlot` is the token's balance mapping: a
    /// wrong one reads a slot the token never set, which reads as zero.
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
        // An account that doesn't exist reads with the empty code hash or the
        // zero hash, as one without code does.
        if state.codeHash == "0x" + emptyCodeHash.hexString || state.codeHash == "0x" + String(repeating: "00", count: 32) {
            throw EthStateError.unexpectedAnswer("erc20Balance: no contract at \(state.address): its account doesn't exist or has no code")
        }
        guard state.storage.count == 1 else {
            throw EthStateError.unexpectedAnswer("erc20Balance: no storage value for the balance slot")
        }
        return state.storage[0].value
    }

    // MARK: - private

    private func post(path: String, body: [String: Any]) async throws -> WireEnvelope {
        let url = indexerBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await HTTPBody.read(session, request, limit: ResponseLimit.large)
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

// MARK: - Answer checks

/// keccak256(""), the code hash of an account without code.
let emptyCodeHash = keccak256(Data())

/// A storage slot given as up to 32 bytes of hex (with or without `0x`), as a
/// big-endian number left-padded to 32 bytes.
func slotKey(_ slot: String, index: Int) throws -> Data {
    var digits = Substring(slot)
    if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
        digits = digits.dropFirst(2)
    }
    guard !digits.isEmpty, digits.count <= 64, digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
        throw ValidationError("slot \(index): \(slot) isn't 1 to 64 hex digits")
    }
    let even = digits.count % 2 == 1 ? "0" + digits : String(digits)
    guard let bytes = Data(hexString: even) else {
        throw ValidationError("slot \(index): \(slot) isn't hex")
    }
    return Data(repeating: 0, count: 32 - bytes.count) + bytes
}

/// Refuses a state proof whose balance or a storage value is longer than
/// 32 bytes: both are uint256s, and a longer one would be read as a number of
/// any size.
func checkWords(_ proof: WireStateProof, _ what: String = "") throws {
    guard proof.accountState.balance.count <= 32 else {
        throw EthStateError.unexpectedAnswer("\(what)the balance is \(proof.accountState.balance.count) bytes, more than a uint256's 32")
    }
    for (index, storage) in proof.storageProofs.enumerated() where storage.value.count > 32 {
        throw EthStateError.unexpectedAnswer("\(what)storage proof \(index)'s value is \(storage.value.count) bytes, more than a uint256's 32")
    }
}

/// Refuses a state proof that isn't for `address` at `block` with exactly the
/// storage slots `slots`, in order, or whose balance or a value is longer
/// than 32 bytes.
func checkStateAnswer(_ proof: WireStateProof, address: Data, slots: [Data], block: UInt64) throws {
    try checkWords(proof)
    guard Data(proof.address) == address else {
        throw EthStateError.unexpectedAnswer("the proof is for address 0x\(Data(proof.address).hexString), not 0x\(address.hexString)")
    }
    guard proof.blockNumber == block else {
        throw EthStateError.unexpectedAnswer("the proof is for block \(proof.blockNumber), not \(block)")
    }
    guard proof.storageProofs.count == slots.count else {
        throw EthStateError.unexpectedAnswer("the proof carries \(proof.storageProofs.count) storage slots, not the \(slots.count) asked for")
    }
    for (index, storage) in proof.storageProofs.enumerated() where Data(storage.slot) != slots[index] {
        throw EthStateError.unexpectedAnswer("storage proof \(index) is for slot 0x\(Data(storage.slot).hexString), not 0x\(slots[index].hexString)")
    }
}

// MARK: - Verification

/// Walks the account proof against the proof's own state root, and every
/// storage proof against the account's storage hash: it checks the answer is
/// consistent with that root, not that the root is Ethereum's. The address
/// must be 20 bytes and every slot 32 (a key of another length hashes to
/// another path), and a zero value must be proved by the slot's absence (a
/// zero is never stored).
func verifyStateProof(_ proof: WireStateProof) throws {
    let stateRoot = Data(proof.stateRoot)
    let address = Data(proof.address)
    guard address.count == 20 else {
        throw EthStateError.verificationFailed("the proof's address is \(address.count) bytes, not 20")
    }
    for (index, storage) in proof.storageProofs.enumerated() where storage.slot.count != 32 {
        throw EthStateError.verificationFailed("storage proof \(index)'s slot is \(storage.slot.count) bytes, not 32")
    }
    try checkWords(proof)
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
        // A zero value isn't stored: the proof must show the slot absent,
        // which the walk reports as an empty value.
        let valueRlp: Data
        if valueInt == 0 {
            valueRlp = Data()
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
        payloadLen = try rlpLength(data[1..<(1 + lenOfLen)], atMost: data.count - payloadStart)
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

/// A long RLP string's or list's length, from its big-endian length bytes
/// (at most 8), refused when it is more than `limit`, the bytes left in the
/// input, so adding it to an index can't overflow.
private func rlpLength(_ bytes: Data, atMost limit: Int) throws -> Int {
    var length: UInt64 = 0
    for byte in bytes {
        guard length >> 56 == 0 else {
            throw EthStateError.decode("rlp: length too long")
        }
        length = length << 8 | UInt64(byte)
    }
    guard limit >= 0, length <= UInt64(limit) else {
        throw EthStateError.decode("rlp: length \(length) past the end of the input")
    }
    return Int(length)
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
        let l = try rlpLength(data[(base + 1)..<(base + 1 + lenOfLen)], atMost: data.count - 1 - lenOfLen)
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

func toEthStateRead(_ proof: WireStateProof, mode: StateVerifyMode) -> EthStateRead {
    let storage = proof.storageProofs.map { sp in
        EthStorageSlot(
            slot: bytesIntsToHex(sp.slot, width: 32),
            value: BigUInt(bytesBE: sp.value)
        )
    }
    return EthStateRead(
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
        // Leading zeros dropped in one pass (removing them one at a time from
        // the front of the array was quadratic in their count).
        let start: Int = bytesBE.firstIndex(where: { $0 != 0 }) ?? bytesBE.endIndex
        self.bytes = Array(bytesBE[start...])
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
