// Registration example for the Willow Swift SDK
//
// This example demonstrates:
// - Registering an application
// - Creating subgroves with schemas
// - Managing permissions
//
// To run this example, include it in an iOS/macOS app or Swift package.

import Foundation
import Willow

@main
struct RegistrationExample {
    static func main() async {
        print("Willow SDK - Registration Example")
        print("==================================")
        print()

        do {
            // 1. Create client
            print("1. Creating client...")
            let client = try WillowClient(baseURL: "http://localhost:3031")
            print("   Connected to Willow node")
            print()

            // 2. Generate and register identity
            print("2. Generating and registering identity...")
            let identity = try newIdentity(algorithm: .ed25519)
            _ = try? await client.registerDID(identity.didDocument)
            _ = try await client.authenticate(identity)
            print("   Authenticated as: \(identity.did)")
            print()

            // 3. Register an application
            print("3. Registering application...")
            let appRequest = AppBuilder(appId: "my-defi-app", name: "My DeFi App")
                .description("A decentralized finance application")
                .type(.standard)
                .owner(identity.did)
                .build()

            do {
                let app = try await client.registration.registerApp(appRequest)
                print("   App registered: \(app.name)")
                print("   App ID: \(app.appId)")
                print("   Balance: \(app.balance) CAN")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 4. Create schema for user data
            print("4. Creating schema for user data...")
            let userSchema = SchemaBuilder(name: "users")
                .description("User profiles and balances")
                .stringField("name", required: true)
                .stringField("email", required: true)
                .intField("balance", required: false)
                .stringField("wallet_address", required: true)
                .boolField("verified", required: false)
                .arrayField("transactions", itemType: "string", required: false)
                .hashIndex("email_idx", fields: ["email"])
                .rangeIndex("balance_idx", fields: ["balance"])
                .uniqueIndex("wallet_idx", fields: ["wallet_address"])
                .build()

            print("   Schema: \(userSchema.name)")
            print("   Fields: \(userSchema.fields.count)")
            print("   Indexes: \(userSchema.indexes.count)")
            print()

            // 5. Register a subgrove with the schema
            print("5. Registering subgrove...")
            let subgroveRequest = SubgroveBuilder(
                subgroveId: "users",
                appId: "my-defi-app",
                name: "User Data"
            )
                .description("User profiles and account data")
                .schema(userSchema)
                .owner(identity.did)
                .rewardRate(1000) // 1000 CAN per epoch for indexers
                .build()

            do {
                let subgrove = try await client.registration.registerSubgrove(subgroveRequest)
                print("   Subgrove registered: \(subgrove.name)")
                print("   Subgrove ID: \(subgrove.subgroveId)")
                print("   Reward rate: \(subgrove.rewardRate ?? 0) CAN/epoch")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 6. Create another subgrove for transactions
            print("6. Creating transactions subgrove...")
            let txSchema = SchemaBuilder(name: "transactions")
                .stringField("tx_hash", required: true)
                .stringField("from", required: true)
                .stringField("to", required: true)
                .intField("amount", required: true)
                .intField("timestamp", required: true)
                .stringField("status", required: true)
                .hashIndex("hash_idx", fields: ["tx_hash"])
                .rangeIndex("time_idx", fields: ["timestamp"])
                .hashIndex("from_idx", fields: ["from"])
                .hashIndex("to_idx", fields: ["to"])
                .build()

            let txSubgroveRequest = SubgroveBuilder(
                subgroveId: "transactions",
                appId: "my-defi-app",
                name: "Transaction History"
            )
                .schema(txSchema)
                .owner(identity.did)
                .rewardRate(2000)
                .build()

            do {
                let subgrove = try await client.registration.registerSubgrove(txSubgroveRequest)
                print("   Transaction subgrove registered: \(subgrove.name)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 7. List subgroves
            print("7. Listing subgroves...")
            do {
                let subgroves = try await client.registration.listSubgroves(appId: "my-defi-app")
                print("   Found \(subgroves.count) subgroves:")
                for subgrove in subgroves {
                    print("   - \(subgrove.name) (items: \(subgrove.itemCount), storage: \(subgrove.storageUsed) bytes)")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 8. Grant permissions
            print("8. Managing permissions...")
            // Create another identity for a collaborator
            let collaborator = try newIdentity(algorithm: .ed25519)
            _ = try? await client.registerDID(collaborator.didDocument)

            print("   Collaborator DID: \(collaborator.did)")
            print()

            // Note: In a real app, you would grant specific permissions
            // The permission structure would be defined by the protocol
            print("   Permissions can be granted to allow:")
            print("   - Read access to subgroves")
            print("   - Write access to subgroves")
            print("   - Admin access to apps")
            print()

            // 9. Get app info
            print("9. Getting app info...")
            do {
                let app = try await client.registration.getApp(appId: "my-defi-app")
                print("   App: \(app.name)")
                print("   Type: \(app.appType.rawValue)")
                print("   Balance: \(app.balance) CAN")
                print("   Created: \(Date(timeIntervalSince1970: TimeInterval(app.createdAt)))")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 10. Clean up
            print("10. Cleanup...")
            client.close()

            print("Registration example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
