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

let client = try WillowClient(baseURL: "http://localhost:3031")

// An identity signs requests and transactions. Its DID must be registered on
// chain and hold a balance for fees before it can write.
let identity = try newIdentity(algorithm: .ed25519)
client.setIdentity(identity)

// A write is a StoreData transaction, signed by the identity.
try await client.data.store(subgroveId: "knowledge-base", key: "article-42", data: ["title": "Hello"])

// A read is checked against a GroveDB proof.
let item = try await client.data.get(subgroveId: "knowledge-base", key: "article-42")
```

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

The API serves no REST write route: every write is a consensus transaction, sent as JSON to `POST /tx/submit`. With an identity set, the client builds, signs, and submits these itself, each under the identity's next nonce (`GET /account/{did}/nonce`):

- `data.store` — StoreData
- `registration.registerSubgrove` — RegisterSubgrove, a DataStorage subgrove the identity owns, its schema in the node's form (`SubgroveSchema`)
- `registration.deleteSubgrove` — DeregisterSubgrove

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

- StoreData carries its value, a JSON object, as the UTF-8 bytes of its JSON text, and `DataHash` is over those bytes. Anything but a JSON object is refused before signing.
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

### Rules for every message

- A text field written as a line (a subgrove ID, key, DID, key id, filename, or content type) holding a line break (the byte 0x0A, including in `\r\n`) is refused with a validation error before anything is signed.
- `storeDataMessage`, `storeFileManifestMessage`, `deleteFileManifestMessage`, `registerSubgroveMessage`, `grantSubgroveKeyMessage`, `rotateSubgroveKeyMessage`, `revokeSubgroveKeyMessage`, and `unregisterStorageNodeMessage` return the exact message, and the SDK's own transactions are built with them.
- Ed25519 signs the message's UTF-8 bytes; secp256k1 signs their Keccak-256.
- The message is built after the nonce is chosen. A transaction refused in its block after its signature and nonce verify still spends its nonce; one that never landed spends nothing, and a retry of it should sign under the same nonce, so that at most one of the two can run.
- The client's writes take the account's next nonce, or the one after the last nonce the client handed out if that is higher, so writes sent before the previous one lands take consecutive nonces. A write the API doesn't accept gives its nonce back, so calling again signs under the same nonce. The `ConsensusClient` methods fetch the account's next nonce on each call. For `files`, pass new `FileSigningOptions` with the nonce to sign under.

## What's in the box

- `Auth` — DID generation, signing
- `Client` — top-level entry point
- `Data` — proof-verified `get` and `query`; `store` as a StoreData transaction
- `Files` — upload / download with chunk Merkle verification
- `Indexing`, `Indexers` — GraphQL / SQL queries against indexed blockchain data
- `Manifest` — canonical `WillowManifest` types for subgrove registration
- `Privacy` — XChaCha20-Poly1305 encrypted subgroves
- `LightClient` — CometBFT light-client implementation (header verification, trust-on-first-use)
- `GroveDB` — GroveDB proof verifier (verify-only, no full DB): Merk's BLAKE3 hash rules, grovedb's proof encoding, and a descent check on the query path
- `Completeness` — client-side crypto-completeness verify (`canonicalEventSetHash`, `verifyServedEvents`)
- `Validators`, `Token`, `Consensus`, `Registration`, `Subscriptions`, `ERC8004`

## Example app

`Examples/NotesApp` is a SwiftUI iOS app that uses the SDK end-to-end: subgrove registration, request signing, and storing and reading data with proofs.

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
