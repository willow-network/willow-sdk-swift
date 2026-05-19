// Registration example for the Willow Swift SDK
//
// This example demonstrates:
// - Registering subgroves with schemas
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
            client.setIdentity(identity)
            print("   Authenticated as: \(identity.did)")
            print()

            // 3. Create schema for user data
            print("3. Creating schema for user data...")
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

            // 4. Register a subgrove with the schema
            print("4. Registering subgrove...")
            let subgroveRequest = SubgroveBuilder(
                subgroveId: "users",
                name: "User Data"
            )
                .description("User profiles and account data")
                .schema(userSchema)
                .owner(identity.did)
                .rewardRate(1000) // 1000 WILL per epoch for indexers
                .build()

            do {
                let subgrove = try await client.registration.registerSubgrove(subgroveRequest)
                print("   Subgrove registered: \(subgrove.name)")
                print("   Subgrove ID: \(subgrove.subgroveId)")
                print("   Reward rate: \(subgrove.rewardRate ?? 0) WILL/epoch")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 5. Create another subgrove for transactions
            print("5. Creating transactions subgrove...")
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

            // 6. List subgroves
            print("6. Listing subgroves...")
            do {
                let subgroves = try await client.registration.listSubgroves()
                print("   Found \(subgroves.count) subgroves:")
                for subgrove in subgroves {
                    print("   - \(subgrove.name) (items: \(subgrove.itemCount), storage: \(subgrove.storageUsed) bytes)")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 7. Grant permissions
            print("7. Managing permissions...")
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
            print()

            // 8. Clean up
            print("8. Cleanup...")
            client.close()

            print("Registration example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
