// Willow Swift SDK - Full Notes Application Example
//
// A complete SwiftUI notes application demonstrating:
// 1. Authentication flow (generate DID, login/logout)
// 2. First-run setup (app registration, subgrove creation)
// 3. Balance checking
// 4. Full CRUD operations on notes
// 5. Search and filtering
// 6. Categories and tags
// 7. Pinning notes
//
// This example shows how all Willow SDK features work together
// in a real-world SwiftUI application.
//
// Prerequisites:
// - Add Willow SDK to your Swift package or Xcode project
// - Run a local Willow node with funding
//
// To run: Include in an iOS/macOS app target

import SwiftUI
import Willow

// MARK: - App Entry Point

@main
struct WillowNotesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Content View (Router)

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .loading:
                LoadingView()
            case .login:
                LoginView()
            case .setup:
                SetupView()
            case .main:
                MainView()
            }
        }
        .task {
            await appState.initialize()
        }
    }
}

// MARK: - App State

enum AppScreen {
    case loading
    case login
    case setup
    case main
}

@MainActor
class AppState: ObservableObject {
    @Published var currentScreen: AppScreen = .loading
    @Published var isAuthenticated = false
    @Published var currentDID: String?
    @Published var privateKey: String?
    @Published var subgroveRegistered = false
    @Published var balance: Double = 0
    @Published var error: String?

    private var client: WillowClient?

    let apiURL = "http://localhost:3031"
    let collectionId = "notes"

    func initialize() async {
        // Check if we have saved credentials
        if let savedKey = UserDefaults.standard.string(forKey: "willow_private_key"),
           let savedDID = UserDefaults.standard.string(forKey: "willow_did") {
            privateKey = savedKey
            currentDID = savedDID
            await attemptLogin()
        } else {
            currentScreen = .login
        }
    }

    func getClient() throws -> WillowClient {
        if let client = client {
            return client
        }
        let newClient = try WillowClient(baseURL: apiURL)
        client = newClient
        return newClient
    }

    func generateAndRegister() async throws -> (did: String, privateKey: String) {
        let identity = try newIdentity(algorithm: .ed25519)
        let client = try getClient()

        // Register DID + set identity for per-request signing (synchronous).
        _ = try await client.registerDID(identity.didDocument)
        client.setIdentity(identity)

        // Save credentials. In a real app, prefer Keychain over UserDefaults.
        UserDefaults.standard.set(identity.keyPair.privateKeyHex, forKey: "willow_private_key")
        UserDefaults.standard.set(identity.did, forKey: "willow_did")

        privateKey = identity.keyPair.privateKeyHex
        currentDID = identity.did
        isAuthenticated = true

        return (identity.did, identity.keyPair.privateKeyHex)
    }

    func login(with privateKeyHex: String) async throws {
        let identity = try identityFromPrivateKey(algorithm: .ed25519, privateKeyHex: privateKeyHex)
        let client = try getClient()

        // registerDID is idempotent server-side, so we just try it and ignore
        // a "DID already exists" error rather than probing first.
        _ = try? await client.registerDID(identity.didDocument)
        client.setIdentity(identity)

        UserDefaults.standard.set(privateKeyHex, forKey: "willow_private_key")
        UserDefaults.standard.set(identity.did, forKey: "willow_did")

        privateKey = privateKeyHex
        currentDID = identity.did
        isAuthenticated = true
    }

    func attemptLogin() async {
        guard let key = privateKey else {
            currentScreen = .login
            return
        }

        do {
            try await login(with: key)
            await checkSubgroveRegistration()
        } catch {
            self.error = error.localizedDescription
            currentScreen = .login
        }
    }

    func checkSubgroveRegistration() async {
        do {
            let client = try getClient()
            _ = try await client.registration.getSubgrove(subgroveId: collectionId)
            subgroveRegistered = true
            currentScreen = .main
            await refreshBalances()
        } catch {
            subgroveRegistered = false
            currentScreen = .setup
        }
    }

    func setupApp() async throws {
        guard let did = currentDID else { throw AuthenticationError("Not authenticated") }
        let client = try getClient()

        // Notes schema: fields are an [SchemaField] array (each with its own name).
        let schema = SchemaDefinition(
            name: "notes",
            description: "User notes",
            fields: [
                SchemaField(name: "id", type: "string", required: true, indexed: true),
                SchemaField(name: "title", type: "string", required: true, indexed: true),
                SchemaField(name: "content", type: "string", required: false, indexed: false),
                SchemaField(name: "category", type: "string", required: false, indexed: true),
                SchemaField(name: "tags", type: "array", required: false, indexed: true),
                SchemaField(name: "created", type: "number", required: false, indexed: true),
                SchemaField(name: "updated", type: "number", required: false, indexed: true),
                SchemaField(name: "pinned", type: "boolean", required: false, indexed: true),
            ],
            indexes: [
                IndexDefinition(name: "by_category", fields: ["category"], type: .hash),
                IndexDefinition(name: "by_updated", fields: ["updated"], type: .range),
            ]
        )

        let request = RegisterSubgroveRequest(
            subgroveId: collectionId,
            name: "Notes",
            description: "Per-user notes",
            schema: schema,
            ownerDid: did,
            writers: [did],
            readers: [],
            rewardRate: 0
        )
        _ = try await client.registration.registerSubgrove(request)

        subgroveRegistered = true
        currentScreen = .main
        await refreshBalances()
    }

    func refreshBalances() async {
        guard let did = currentDID else { return }

        do {
            let client = try getClient()
            if let balanceInfo = try? await client.token.getBalance(did: did) {
                balance = Double(balanceInfo.available)
            }
        } catch {
            // Silently fail - balances are optional display
        }
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: "willow_private_key")
        UserDefaults.standard.removeObject(forKey: "willow_did")
        privateKey = nil
        currentDID = nil
        isAuthenticated = false
        subgroveRegistered = false
        client?.close()
        client = nil
        currentScreen = .login
    }
}
