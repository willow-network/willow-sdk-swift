# Willow Swift SDK

A Swift SDK for interacting with the Willow decentralized data infrastructure protocol. Targets iOS 15+, macOS 12+, tvOS 15+, and watchOS 8+.

## Features

- **Trustless by Default**: Embedded CometBFT light client verifies state roots against validator signatures
- **GroveDB Proof Verification**: Merkle proofs verified locally for every `get` / `query`
- **DID Authentication**: Ed25519 + secp256k1 signature support
- **File Storage**: Upload / download / list with chunk-level Merkle verification
- **Privacy**: XChaCha20-Poly1305 encryption for private subgroves
- **GraphQL Indexing**: Query indexed blockchain data with cryptographic proofs
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

let client = WillowClient(apiURL: URL(string: "http://localhost:3031")!)

// Generate a DID + register
let did = try Auth.generateDID(algorithm: .ed25519)
try await client.registerDID(did.didDocument)
try await client.authenticate(
    did: did.id,
    privateKeyHex: did.privateKeyHex,
    publicKeyID: did.publicKeyID
)

// Data operations automatically verify proofs
let value = try await client.data.get(
    subgroveID: "knowledge-base",
    key: "article-42"
)
```

## Request signing

With an identity set (`setIdentity`), the client signs each read of subgrove data it sends to the API (`GET /data/{subgrove}/{key}`, `GET /proof/{subgrove}/{key}`, and `POST /query`, `/sql`, and `/graphql`) with a one-time nonce over the whole request. Only this form carries the DID's read rights: a Reader permission on a subgrove, or a place on a priced subgrove's free-reader list. Other requests it signs use the older form below, which the server also accepts in the first 30 s after it restarts, when it refuses nonce-signed requests.

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

## Signed writes

StoreData (`ConsensusClient.storeData`), StoreFileManifest (`storeFileManifest`, `files.upload`), and DeleteFileManifest (`deleteFileManifest`, `files.delete`) transactions are signed over a message that binds the transaction's nonce and every field it writes. It is the kind on the first line, then one `Label: value` line per field, the nonce last, joined by `\n` (the byte 0x0A) with no trailing newline, as UTF-8. Text fields go in verbatim, with no escaping or normalization. Hex is lowercase, and numbers are unsigned decimal.

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

- StoreData carries its value as the UTF-8 bytes of its JSON text, and `DataHash` is over those bytes.
- `Encryption` is `none` for a manifest with no encryption, else `<key epoch>:<hex 24-byte nonce>`.
- A subgrove ID, key, owner DID, filename, or content type holding a line break (the byte 0x0A, including in `\r\n`) is refused with a validation error before anything is signed.
- `storeDataMessage`, `storeFileManifestMessage`, and `deleteFileManifestMessage` return the exact message, and the SDK's own transactions are built with them.
- Ed25519 signs the message's UTF-8 bytes; secp256k1 signs their Keccak-256.
- The message is built after the nonce is chosen. A write that lands in a block and is refused there after its signature and nonce verify still spends its nonce, so a retry is signed again under the next free nonce. The `ConsensusClient` methods fetch the next nonce on each call; for `files`, pass new `FileSigningOptions` with the next free nonce.

## What's in the box

- `Auth` — DID generation, signing
- `Client` — top-level entry point
- `Data` — `get` / `store` / `update` / `delete` with proof verification
- `Files` — upload / download with chunk Merkle verification
- `Indexing`, `Indexers` — GraphQL / SQL queries against indexed blockchain data
- `Manifest` — canonical `WillowManifest` types for subgrove registration
- `Privacy` — XChaCha20-Poly1305 encrypted subgroves
- `LightClient` — CometBFT light-client implementation (header verification, trust-on-first-use)
- `GroveDB` — Merkle proof verifier (verify-only mode, no full DB)
- `Completeness` — client-side crypto-completeness verify (`canonicalEventSetHash`, `verifyServedEvents`)
- `Validators`, `Token`, `Consensus`, `Registration`, `Subscriptions`, `ERC8004`

## Example app

`Examples/NotesApp` is a SwiftUI iOS app that uses the SDK end-to-end: registration, DID auth, data store/retrieve with proofs.

## Development

```bash
swift build
swift test
```

## Design

- **Proof-first**: data reads return verified values, not raw bytes — `get` raises on proof mismatch
- **No external HTTP layer**: `URLSession` only, no Alamofire/Moya runtime dep
- **Apple-platforms only for now**: Linux Swift toolchain is plausible but not tested

## License

MIT — see [LICENSE](LICENSE).
