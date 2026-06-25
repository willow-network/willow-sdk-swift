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

## Installation

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/willow-network/willow-sdk-swift.git", from: "0.1.0"),
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
