# Willow Notes App - SwiftUI Example

A complete SwiftUI notes application demonstrating the Willow Swift SDK.

## Features

- **Authentication Flow**
  - Generate new DID (decentralized identity)
  - Login with existing private key
  - Secure credential storage via UserDefaults

- **First-Run Setup**
  - Automatic subgrove registration on Willow network
  - Collection/schema creation for notes

- **Notes Management**
  - Create and list notes. A note is written once: editing, pinning, or deleting one would be an UpdateData or DeleteData transaction, which the SDK doesn't build, so the app offers none of them.
  - The list comes from `client.data.query`, checked against a GroveDB proof of the whole notes tree and the light client's header. When it can't be checked (the query throws), the app lists the notes with `client.data.queryUnverified` and labels the list "Not verified", with the reason.
  - Categories (Personal, Work, Ideas, Archive)
  - Tags support
  - Search across title, content, and tags

- **Balance Display**
  - User WILL token balance

## Project Structure

```
NotesApp/
├── NotesApp.swift       # App entry point, AppState, ContentView
├── Models.swift         # Note model, categories, filters
├── NotesViewModel.swift # Notes data management
├── Views.swift          # All SwiftUI views
└── README.md           # This file
```

## Prerequisites

1. Add the Willow SDK to your project:
   - Via Swift Package Manager, add the Willow package
   - Or copy the SDK files to your project

2. Run a local Willow node:
   ```bash
   # From the willow repository root
   cargo build --release
   ./scripts/start_node.sh
   ```

## Usage

### Adding to Your Project

1. Copy the `NotesApp/` folder to your Xcode project
2. Ensure all files are added to your target
3. Import the Willow SDK in your project

### Running as Standalone

1. Create a new iOS/macOS app in Xcode
2. Replace the generated ContentView with the NotesApp files
3. Add the Willow SDK dependency
4. Build and run

## Architecture

### AppState
Central state management using `@Observable` pattern:
- Handles authentication state
- Manages Willow client connection
- Tracks subgrove registration status

### NotesViewModel
MVVM pattern for notes operations:
- Create and list operations via Willow SDK
- Local filtering and sorting
- Async/await for all network operations

### Views
SwiftUI views with:
- `@EnvironmentObject` for shared state
- Sheet presentations for editors
- Pull-to-refresh support

## SDK Features Demonstrated

| Feature | Implementation |
|---------|---------------|
| DID Generation | `newIdentity(algorithm: .ed25519)` |
| Request and transaction signing | `client.setIdentity(identity)` |
| Subgrove Registration | `client.registration.registerSubgrove(request)` |
| Schema Definition | `SchemaDefinition` with fields and indexes |
| Data Storage | `client.data.store(...)` (a StoreData transaction) |
| Data Queries | `client.data.query(...)` (proof-checked), `client.data.queryUnverified(...)` (labeled unverified) |
| Token Balance | `client.token.getBalance(did:)` |

## Customization

### Changing the API URL
In `NotesApp.swift`, modify:
```swift
let apiURL = "http://localhost:3031"
```

### Adding New Categories
In `Models.swift`, extend the `NoteCategory` enum:
```swift
enum NoteCategory: String, CaseIterable, Codable {
    case personal
    case work
    case ideas
    case archive
    case custom // Add new category
}
```

### Modifying the Schema
In `NotesApp.swift`, update the `SchemaDefinition` in `setupApp()`.

## Notes

- This example uses `UserDefaults` for credential storage. In production, use Keychain.
- The app connects to `localhost:3031` by default. Update for production deployment.
- `client.data.query` checks the notes against a GroveDB proof and compares its root with the chain's app hash after the proof's block, from a header the light client accepts; the light client accepts headers without verifying their commit signatures. See the SDK README's Verification section for what is and isn't checked.
