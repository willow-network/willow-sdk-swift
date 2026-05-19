// Basic usage example for the Willow Swift SDK
//
// This example demonstrates:
// - Creating a client
// - Generating and registering a DID
// - Authenticating
// - Storing and retrieving data with automatic proof verification
//
// To run this example, include it in an iOS/macOS app or Swift package.

import Foundation
import Willow

@main
struct BasicUsageExample {
    static func main() async {
        print("Willow SDK - Basic Usage Example")
        print("=================================")
        print()

        do {
            // 1. Create client
            print("1. Creating client...")
            let client = try WillowClient(baseURL: "http://localhost:3031")
            print("   Connected to Willow node")
            print()

            // 2. Generate a DID
            print("2. Generating Ed25519 DID...")
            let identity = try newIdentity(algorithm: .ed25519)
            print("   DID: \(identity.did)")
            print("   Public Key ID: \(identity.publicKeyId)")
            print()

            // 3. Register the DID
            print("3. Registering DID...")
            do {
                _ = try await client.registerDID(identity.didDocument)
                print("   DID registered successfully")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 4. Set identity for per-request signing (synchronous; no server session).
            print("4. Setting identity...")
            client.setIdentity(identity)
            print("   Identity set — every write is signed with this key")
            print()

            // 5. Store data (requires an existing app and subgrove)
            print("5. Storing data...")
            let testData: [String: Any] = [
                "name": "Alice",
                "score": 100,
                "active": true
            ]

            do {
                try await client.data.store(
                    subgroveId: "users",
                    key: "alice",
                    data: testData
                )
                print("   Data stored successfully")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 6. Retrieve data with automatic proof verification
            print("6. Retrieving data (with proof verification)...")
            do {
                let response = try await client.data.get(
                    subgroveId: "users",
                    key: "alice"
                )
                print("   Data retrieved and verified:")
                print("   \(response.data)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 7. Retrieve data without verification (faster)
            print("7. Retrieving data (without verification)...")
            do {
                let response = try await client.data.getUnverified(
                    subgroveId: "users",
                    key: "alice"
                )
                print("   Data retrieved (unverified):")
                print("   \(response.data)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 8. Get root hash
            print("8. Getting root hash...")
            do {
                let rootHash = try await client.getRootHash()
                print("   Root hash: \(rootHash)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // Clean up
            client.close()

            print("Basic usage example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
