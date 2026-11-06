# Willow Swift SDK

A Swift SDK for interacting with the Willow decentralized data infrastructure protocol. Targets iOS 15+, macOS 12+, tvOS 15+, and watchOS 8+.

## Features

- **Proof-checked reads**: `data.get` and `data.query` verify a GroveDB proof locally, bound to the subgrove's data tree, and compare its root with the app hash a consensus node you configure reports. The SDK trusts that node; it doesn't verify validator signatures (see [Verification](#verification))
- **DID Authentication**: Ed25519 + secp256k1 signature support
- **File Storage**: Upload / download / list with chunk-level Merkle verification
- **Privacy**: XChaCha20-Poly1305 encryption for private subgroves
- **GraphQL Indexing**: Query indexed blockchain data (answers are not verified)
- **Async/Await**: Built on Swift Concurrency

> **Install from source.** Willow's SDKs are not yet published to package registries.
> The commands below install directly from this repository and work today.

## Installation

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/willow-network/willow-sdk-swift.git", branch: "master"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Willow", package: "willow-sdk-swift"),
    ]),
],
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

## Quick Start

```swift
import Willow

// Verified reads compare proofs with the headers of a consensus node you run
// or trust. For an API on this machine at port 3031, its node's RPC at port
// 26657 is used; for any other API, pass consensusRpcURL.
let client = try WillowClient(baseURL: "http://localhost:3031")
// let client = try WillowClient(baseURL: "https://api.example.com", consensusRpcURL: "https://rpc.example.com")

// An identity signs requests and transactions. Its DID must be registered on
// chain and hold a balance for fees before it can write.
let identity = try newIdentity(algorithm: .ed25519)
client.setIdentity(identity)

// A write is a StoreData transaction, signed by the identity. It returns once
// the node's CheckTx admits the transaction, before the transaction is in a
// block.
try await client.data.store(subgroveId: "knowledge-base", key: "article-42", data: ["title": "Hello"])

// The item is readable once its block is committed; until then a read throws
// NotFoundError. A read is checked against a GroveDB proof (see Verification).
var item: DataResponse?
for _ in 0..<10 {
    do {
        item = try await client.data.get(subgroveId: "knowledge-base", key: "article-42")
        break
    } catch let error as WillowError where error.type == .notFound {
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
```

## Verification

What the SDK checks, and what it doesn't:

- **`data.get`** verifies the GroveDB proof the API serves for the key (`GET /proof/{subgrove}/{key}`). The proof must prove the key in the subgrove's data tree, `subgroves/{subgrove}/data`, through a tree element at every segment of that path, as an item (a reference is refused) with the value the API served (compared as JSON). Its root must be the chain's app hash after the block the proof's state is from. The API serves that block's height H with the proof. A header at H+1 carries the state after block H, and so does every later header up to and including the header of the next block with transactions: the node leaves its state, and so its app hash, unchanged in a block without transactions, and changes it in every block with them. So the root must be the app hash of a header the light client has accepted at H+1 or later, or else of the header at H+1. Hex is compared in any case. The API chooses the state it proves, so the state must be recent: a proof of a state more than `maxProofLagBlocks` (default 20) blocks behind the chain's latest height, the height a majority of the light client's endpoints report (`LightClient.latestChainHeight()`), throws `ProofHeightOutOfRangeError` (type `.proofHeightOutOfRange`), as does a height that far ahead of it. A state's age is taken at the newest header known to carry it, so a proof of an old block's state passes while no block with transactions has come since (the latest header still carries it). The read proves the value as of the matched header's state, not as of now: `proof.header` (`VerifiedHeader`) gives that header's height and block time. It returns the proven value, read as the node reads it, or throws. Numbers come back as `Int` when they are integers that fit, else as the `Double` that is the number; a value holding a number a `Double` would round (`0.12345678901234567890`, `18446744073709551615`) throws `NotVerifiableError`, so store such numbers as strings. A key the API reports missing throws `NotFoundError`; that answer comes without a proof, so it doesn't prove the key absent.
- **`data.query`** verifies the proof the node serves with a query, which covers the subgrove's whole data tree. The proof must show every element of that tree (no pruned or hidden node) or prove it empty, every element must be an item, and its root is checked as for `get`, staleness included; `QueryResponse.header` is the header it matched, and the answer is as of that header's state. The SDK then answers the query itself from the proven items, as the node does: the items that parse as JSON in key order, then every filter (all must match), the sort, offset, and limit, reading the items and the request body it sends as the node's JSON reader does. A filter compares JSON values as the node does: numbers by their exact decimal value (so `1`, `1.0`, and `1e0` are equal), in arrays and objects too, and strings by their bytes. The sort is the node's total order, stable in either direction: a missing field, `null`, `false`, `true`, numbers (by value), strings (by their bytes), arrays, then objects. Only the proof and its height are read from the answer; the documents the API serves are not used. Numbers in the results follow the same rule as `get`'s. Where a result can't be returned exactly, the query throws `NotVerifiableError` (type `.notVerifiable`, not `.proof`, since nothing shows the answer is wrong) instead of returning an unverified answer. A query the node refuses or can't run (an operator other than `eq`, more than 32 filters, two on one field, a `$and`, `$or`, `$not`, or `$nor` field, a filter or sort field over 256 bytes, a filter value that is an object or over 4,096 bytes as JSON, a search) is refused before anything is sent, by `query` and `queryUnverified` alike.
- **What a verified read trusts.** The header, and so the app hash, comes from the CometBFT RPC of a consensus node you configure: `consensusRpcURL` (a `WillowClient` argument), or, for an API on this machine (`localhost`, `127.0.0.1`, or `::1` at port 3031), that node's RPC at port 26657, or a `LightClient` you set (`setLightClient`). The SDK trusts that node, the way a client trusts its own node: it does not verify validator signatures, validator sets, or header hashes. A forged value or proof from the API fails, but a dishonest consensus node can make a forged value verify, so run that node yourself or use one you trust. The SDK never takes headers from the API, since a header the API serves can't vouch for a proof the API serves: with no consensus RPC configured, `data.get` and `data.query` throw a config error before sending anything.
- **The light client** (`LightClient`) starts from a header you pin (one whose block time is older than the trusting period is refused) or, without one, the latest header its RPC serves, taken as served. When the highest header it has accepted outlives the trusting period, it takes the RPC's latest header the same way. It reads CometBFT's RPC answers. It accepts another header after checking that it is consistent with the highest header it has accepted below it: the chain ID, that height and time move forward, that the earlier header is within the trusting period (counted from its block time), that the header's time isn't ahead of the local clock by more than the allowed drift (a header may be any age), and that the commit names validators holding the trust threshold (two thirds by default) of the served set's voting power, each counted once, by address. These checks don't verify the signatures, nor that the served validator set matches the header. A header below every one it has accepted can't be checked, so a proof of a state older than all of them that has since changed throws. The client's default light client follows the chain its consensus RPC reports (`/status` `node_info.network`), or the one `chainId` names (a `WillowClient` argument), and refuses an RPC that serves another; a light client you set follows the chain its config names.
- **Not verified:** `getUnverified`, `queryUnverified`, `queryHistorical`, GraphQL (`indexing.query`, `indexing.queryUnverified`, `indexing.execute`), and SQL. A GraphQL proof object is returned as JSON bytes, unchecked: it lists value hashes and a state root, which don't bind the answer. `queryHistoricalVerified` throws: a checkpoint's state root isn't a GroveDB root, and the answer isn't bound to its proof.
- **`GroveDBVerifier.verifyProof(proofBytes:expectedPath:)`** returns only the elements of the tree at the path asked for, each key bound to the root. Each value is bound too, except a tree element's: grovedb proves one without its lower layer, so its bytes aren't bound (`isValueBound` is false). `coversWholeTree` is true when the proof shows that whole tree with every value bound, so a key missing from the results is absent; otherwise a missing key proves nothing. The path-less `verifyProof(proofBytes:)`, `verifyProofAgainstRoot(proofBytes:expectedRootHash:)`, and `quickVerify` prove only the root and are deprecated.

## Request signing

With an identity set (`setIdentity`), the client signs each read of subgrove data it sends to the API (`GET /data/{subgrove}/{key}`, `GET /proof/{subgrove}/{key}`, and `POST /query`, `/sql`, and `/graphql`) and each key grant read (`GET /key-grants/...` and `GET /proof/key-grant/...`) with a one-time nonce over the whole request. Only this form carries the DID's read rights: a Reader permission on a subgrove, or a place on a priced subgrove's free-reader list; the API answers a key grant read only for a caller signed this way. Other requests it signs use the older form below, which the server also accepts in the first 30 s after it restarts, when it refuses nonce-signed requests.

The headers are `X-DID`, `X-Public-Key-ID`, `X-Signature`, `X-Timestamp`, and `X-Nonce`. The signature is over eight lines:

```
willow-request-v2
<DID>
<public key id>
<METHOD>
<path and query, exactly as sent>
<Unix timestamp>
<nonce>
<hex SHA-256 of the body>
```

- The server accepts a timestamp up to 300 s old and 30 s ahead of its clock, and each (DID, nonce) once. The client signs each retry with a new nonce.
- A nonce is 16 to 128 characters of `A-Z a-z 0-9 - _`. `newRequestNonce()` makes one of 32 hex characters.
- Ed25519 signatures are sent as hex. secp256k1 signatures are over the Keccak-256 of the message and are sent as `0x`-prefixed hex.
- Requests sent to an indexer (`indexerURL`) are not signed this way.

To sign a request you send yourself:

```swift
let headers = try signRequestWithNonce(method: "POST", pathAndQuery: "/query/my-subgrove", body: body, identity: identity)
```

`signRequest(method:path:identity:)` makes the older `{METHOD}:{PATH}:{TIMESTAMP}` form, over the path without its query string. It proves the DID but carries none of its read rights, and it can be replayed with any body until the timestamp expires.

## Writes

The API serves no REST write route: every write is a consensus transaction, sent as JSON to `POST /tx/submit`. With an identity set, the client builds, signs, and submits these itself, each under the identity's next free nonce (see [Nonces](#nonces)):

- `data.store` — StoreData
- `registration.registerSubgrove` — RegisterSubgrove, a DataStorage subgrove the identity owns, its schema in the node's form (`SubgroveSchema`)
- `registration.deleteSubgrove` — DeregisterSubgrove
- `files.upload` and `files.delete` — StoreFileManifest and DeleteFileManifest (without `FileSigningOptions`; with no identity they throw and send nothing)

`store` and the other writes return once the node's CheckTx admits the transaction, before it is in a block: what a write stores is readable once its block is committed.

`ConsensusClient` builds the same transactions with a sign function you pass, along with file manifests and key grants. Writes the SDK has no transaction for throw a validation error and send nothing: `data.update`, `data.delete`, `data.batchStore`, `registration.updateSubgrove`, `registration.grantPermission`, `registration.revokePermission`, and `registerDID`.

## Signed messages

Each transaction is signed over a message that binds its nonce and every field it writes. A message is the kind on the first line, then one `Label: value` line per field, the nonce last, joined by `\n` (the byte 0x0A) with no trailing newline, as UTF-8. Text fields go in verbatim, with no escaping or normalization. Hex is lowercase, and numbers are unsigned decimal.

### Data and file writes

StoreData (`data.store`, `ConsensusClient.storeData`), StoreFileManifest (`storeFileManifest`, `files.upload`), and DeleteFileManifest (`deleteFileManifest`, `files.delete`):

```
StoreData
Subgrove: <subgrove id>
Key: <key>
Owner: <owner DID>
DataHash: <hex SHA-256 of the data bytes sent>
Nonce: <nonce>
```

```
StoreFileManifest
Subgrove: <subgrove id>
Key: <file key>
Owner: <owner DID>
Filename: <filename>
ContentType: <content type>
TotalSize: <total size>
ContentHash: <hex content hash>
ChunkCount: <chunk count>
ChunkSize: <chunk size>
ChunkMerkleRoot: <hex chunk Merkle root>
Encryption: none
Nonce: <nonce>
```

```
DeleteFileManifest
Subgrove: <subgrove id>
Key: <file key>
Owner: <owner DID>
Nonce: <nonce>
```

- StoreData carries its value, a JSON object, as the UTF-8 bytes of its JSON text, and `DataHash` is over those bytes. The SDK writes that text with sorted keys and each `Double` in its shortest form (`0.1`, not `JSONSerialization`'s `0.10000000000000001`), the text the node keeps, so a value it stores reads back verified, and `equals(field, 0.1)` matches a stored `0.1` (the node compares numbers by their exact decimal value). Anything but a JSON object is refused before signing.
- `Encryption` is `none` for a manifest with no encryption, else `<key epoch>:<hex 24-byte nonce>`.

### Registrations, key grants, and storage nodes

RegisterSubgrove (`registration.registerSubgrove`, `ConsensusClient.registerSubgrove`):

```
RegisterSubgrove
Subgrove: <subgrove id>
Owner: <owner DID>
Config: <hex SHA-256 of the transaction's bincode with an empty signature>
Nonce: <nonce>
```

`Config` hashes the bincode (bincode 1.x's default encoding: fixed-width little-endian integers, u64 lengths) of the `RegisterSubgroveTx` the node decodes from the JSON sent, so it binds every field but the signature. The SDK sends every field explicitly and hashes exactly what it sends; `registerSubgroveUnsignedBincode` returns those bytes. u128 amounts (`U128`) are written as exact JSON numbers. A BlockchainIndexing registration needs fields `SubgroveBlockchainIndexing` doesn't carry, so the SDK refuses to sign one.

The node refuses a DataStorage or FileStorage registration that breaks one of these rules, and the SDK refuses it before signing:

- The subgrove ID is 1 to 64 ASCII letters, digits, `-`, or `_`, starting with a letter or digit.
- Admins, writers, and free readers are Willow DIDs: `did:willow:` then one or more ASCII letters, digits, `-`, or `_`, at most 128 bytes.
- The schema reads as the node's schema definition, `{"version": 1, "fields": {"<name>": "string" | "number" | "boolean" | "array" | "object" | "bytes"}, "indexes": [], "required_fields": ["<name>"]}` (each key optional, other keys ignored), and declares no indexes.
- A private DataStorage subgrove's initial key grant, if it has one, is key epoch 0 to the owner.

GrantSubgroveKey (`PrivacyOperations.grantSubgroveKey`):

```
GrantSubgroveKey
Subgrove: <subgrove id>
Sender: <sender DID>
Grantee: <grantee DID>
GranteeKey: <grantee public key id>
KeyEpoch: <key epoch>
EphemeralKey: <hex ephemeral public key>
EncryptedKey: <hex encrypted key>
GrantedBy: <granting DID>
GrantedAt: <granted at>
Nonce: <nonce>
```

RotateSubgroveKey (`PrivacyOperations.rotateSubgroveKey`): `RotateSubgroveKey`, `Subgrove`, `Sender`, `NewEpoch`, `Grants: <count>`, then each grant's seven lines (`Grantee` through `GrantedAt`) in order, then `Nonce`.

UnregisterStorageNode (`files.unregisterStorageNode`):

```
UnregisterStorageNode
Node: <node DID>
Nonce: <nonce>
```

RevokeSubgroveKey is signed over `RevokeSubgroveKey:<subgrove id>:<revokee DID>:<sender DID>:<nonce>`, which already binds every field.

A grantee in a grant or rotation, and a revokee, must be a Willow DID, and a revoked subgrove's ID can't hold `:`, so the revoke message reads one way. The SDK refuses anything else before signing.

### Rules for every message

- A text field written as a line (a subgrove ID, key, DID, key id, filename, or content type) holding a line break (the byte 0x0A, including in `\r\n`) is refused with a validation error before anything is signed.
- `storeDataMessage`, `storeFileManifestMessage`, `deleteFileManifestMessage`, `registerSubgroveMessage`, `grantSubgroveKeyMessage`, `rotateSubgroveKeyMessage`, `revokeSubgroveKeyMessage`, and `unregisterStorageNodeMessage` return the exact message, and the SDK's own transactions are built with them.
- Ed25519 signs the message's UTF-8 bytes; secp256k1 signs their Keccak-256.
- The message is built after the nonce is chosen. A transaction refused in its block after its signature and nonce verify still spends its nonce; one that never landed spends nothing, and a retry of it must go under the same nonce, so that at most one of the two can run (see [Nonces](#nonces): `resubmit`).
- A write refused as "already used" may be one whose earlier attempt landed. Read what it wrote before signing it again under a fresh nonce, or it can run twice.

### Nonces

The node accepts a nonce in the 24 above the account's base that it hasn't used, and the base advances only over used nonces with no gap, so a nonce handed out and never used blocks the window until something uses it. The client's writes and the `ConsensusClient` methods take their nonces from one allocator per process, kept per DID and API URL:

- Each write takes the lowest nonce above the base that isn't used and isn't held by another write in flight from this process, so writes it sends together take distinct nonces. For the client's writes, the base comes from the API's `GET /account/{did}/nonce`. `ConsensusClient` reads the base, and which nonces above it are used, from the ABCI query `/store/account_nonce_state/{did}` on its CometBFT RPC, and falls back to the API's base when the RPC can't answer that query. Writes from other processes or devices aren't coordinated with these: a nonce one of them takes shows up as used, or as a refusal that says so.
- A nonce is held from when it is handed out until the chain shows it used, or for 120 s if it never lands. The node holds a pending transaction's nonce for 3 blocks or 120 s, whichever ends first, so 120 s is the longest it can be held.
- A write whose nonce another write takes while it is being built (signing took longer than 120 s) is signed again under a new nonce before it is sent. A write only ever changes the hold on its own nonce.
- A write refused at CheckTx, or by the API before it (a 4xx, in JSON or plain text), gives its nonce back, unless the refusal says the nonce is held by a pending transaction, already used, or spent; then it is treated as taken.
- A write whose outcome is unknown (its submission failed in transit, or the API answered a 5xx or a 408) may have reached the node and may still land, so its nonce stays held and it throws `TransactionSubmitError`, which carries the signed transaction (`submission`: its DID, nonce, and the exact body sent). Retry it only with `client.resubmit(error.submission)` (or `ConsensusClient.resubmit`), which sends that same body under the same nonce: whichever copy lands first spends the nonce and the other is refused, so the write runs at most once. Calling `store` or `transfer` again would sign the write under a fresh nonce, and both could run. A `BroadcastResult` and a CheckTx refusal (`TransactionError`) carry `submission` too. When the node already holds the identical transaction, `resubmit` returns success with no transaction hash.
- With every nonce in the window held or used, a write fails with a "nonce window is full" error instead of signing one the node refuses. More than 24 writes from one identity have to wait for earlier ones to land.
- `files.upload` posts each chunk until the storage node takes it, which it does once the manifest is on chain (`landingTimeout`, 60 s by default). A manifest whose outcome is unknown doesn't stop that: if the chunks are taken, the upload succeeded. If not, it throws the submission's error: `resubmit` it, then call `upload` again to get the chunks up (the second manifest is refused in its block, which spends its nonce and changes nothing).
- `files.upload` and `files.delete` without signing options sign with the identity under a nonce from the allocator. With `FileSigningOptions` (a key the identity doesn't hold), they, and `files.unregisterStorageNode`, sign under the nonce the options give, outside the allocator: pick one no other write of that DID holds.

## What's in the box

- `Auth` — DID generation, signing
- `Client` — top-level entry point
- `Data` — `get` and `query` checked against GroveDB proofs (see [Verification](#verification)); `store` as a StoreData transaction
- `Files` — upload / download with chunk Merkle verification
- `Indexing`, `Indexers` — GraphQL / SQL queries against indexed blockchain data
- `Manifest` — canonical `WillowManifest` types for subgrove registration
- `Privacy` — XChaCha20-Poly1305 encrypted subgroves
- `LightClient` — follows the CometBFT headers of the consensus RPC you configure, from a pinned or first-served header; it trusts that node and doesn't verify commit signatures (see [Verification](#verification))
- `GroveDB` — GroveDB proof verifier (verify-only, no full DB): Merk's BLAKE3 hash rules, grovedb's proof encoding, and results confined to the path asked for
- `Completeness` — client-side crypto-completeness verify (`canonicalEventSetHash`, `verifyServedEvents`)
- `Validators`, `Token`, `Consensus`, `Registration`, `Subscriptions`, `ERC8004`

## Example app

`Examples/NotesApp` is a SwiftUI iOS app that uses the SDK end-to-end: subgrove registration, request signing, storing notes, and listing them with a proof-checked query (or, when the SDK can't check that query, an unverified one it labels as such).

## Development

```bash
swift build
swift test
```

## Design

- **Proof-first**: `get` and `query` return only what the proof proves, and throw when it can't be checked
- **No external HTTP layer**: `URLSession` only, no Alamofire/Moya runtime dep
- **Apple-platforms only for now**: Linux Swift toolchain is plausible but not tested

## License

MIT — see [LICENSE](LICENSE).
