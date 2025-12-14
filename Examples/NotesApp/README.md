# Willow Notes App - SwiftUI Example

A complete SwiftUI notes application demonstrating the Willow Swift SDK.

## Features

- **Authentication Flow**
  - Generate new DID (decentralized identity)
  - Login with existing private key
  - Secure credential storage via UserDefaults

- **First-Run Setup**
  - Automatic app registration on Willow network
  - Collection/schema creation for notes

- **Notes Management**
  - Create, read, update, delete notes
  - Categories (Personal, Work, Ideas, Archive)
  - Tags support
  - Pin important notes
  - Search across title, content, and tags

- **Balance Display**
  - User WILL token balance
  - App funding balance

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
- Tracks app registration status

### NotesViewModel
MVVM pattern for notes operations:
- CRUD operations via Willow SDK
- Local filtering and sorting
- Async/await for all network operations

### Views
SwiftUI views with:
- `@EnvironmentObject` for shared state
- Sheet presentations for editors
- Pull-to-refresh support
- Swipe actions for quick operations

## SDK Features Demonstrated

| Feature | Implementation |
|---------|---------------|
| DID Generation | `newIdentity(algorithm: .ed25519)` |
| DID Registration | `client.registerDID(didDocument)` |
| Authentication | `client.authenticate(identity)` |
| App Registration | `client.registration.registerApp(request)` |
| Schema Definition | `SchemaDefinition` with fields and indexes |
| Data Storage | `client.data.store(...)` |
| Data Queries | `client.data.query(...)` |
| Data Updates | `client.data.update(...)` |
| Data Deletion | `client.data.delete(...)` |
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
- All data operations include automatic cryptographic proof verification.
