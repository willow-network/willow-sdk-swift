// Light client example for the Willow Swift SDK
//
// This example demonstrates:
// - Configuring a light client, the source of the app hash a proof's root
//   is compared with
// - Proof-checked reads, and what they check
// - Exporting and importing trusted state
//
// To run this example, include it in an iOS/macOS app or Swift package.

import Foundation
import Willow

@main
struct LightClientExample {
    static func main() async {
        print("Willow SDK - Light Client Example")
        print("==================================")
        print()

        do {
            // 1. Configure light client with multiple validators
            print("1. Configuring light client...")
            let lcConfig = LightClientConfig(
                chainId: "willow-testnet",
                validatorEndpoints: [
                    "http://localhost:26657",
                    "http://localhost:26757",
                    "http://localhost:26857"
                ],
                trustThreshold: TrustThreshold(numerator: 2, denominator: 3),
                trustingPeriod: 24 * 60 * 60, // 24 hours
                maxClockDrift: 10, // 10 seconds
                minValidatorsForConsensus: 2,
                autoSync: true,
                syncInterval: 5 * 60 // 5 minutes
            )

            print("   Chain ID: willow-testnet")
            print("   Validators: 3 endpoints configured")
            print("   Trust threshold: 2/3")
            print("   Trusting period: 24 hours")
            print()

            // 2. Create light client
            print("2. Creating light client...")
            let lc = try LightClient(lcConfig)
            lc.start()
            print("   Light client: ACTIVE")
            print()

            // 3. Create client with light client
            print("3. Creating Willow client with light client...")
            let client = try WillowClient(
                baseURL: "http://localhost:3031",
                lightClient: lc
            )

            if client.hasLightClient() {
                print("   Light client: ENABLED")
            }
            print()

            // 4. Set identity for per-request signing
            print("4. Setting identity...")
            let identity = try newIdentity(algorithm: .ed25519)
            client.setIdentity(identity)
            print("   Authenticated as: \(identity.did)")
            print()

            // 5. Store test data
            print("5. Storing test data...")
            let testData: [String: Any] = [
                "message": "This data is read back with a GroveDB proof",
                "timestamp": Int(Date().timeIntervalSince1970),
                "verified": true
            ]

            do {
                try await client.data.store(
                    subgroveId: "secure-data",
                    key: "entry-1",
                    data: testData
                )
                print("   Data stored")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 6. Retrieve with a proof
            print("6. Retrieving data with a proof...")
            print("   This checks:")
            print("   - a GroveDB proof of the key and value in the subgrove's data tree")
            print("   - that its root is the app hash of the header after the proof's block")
            print("   The light client accepts headers without verifying their commit")
            print("   signatures, so that app hash is as trustworthy as its endpoints.")
            print()

            do {
                let response = try await client.data.get(
                    subgroveId: "secure-data",
                    key: "entry-1"
                )
                print("   Data retrieved and checked against its proof:")
                print("   \(response.data)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 7. Query with a proof of the whole data tree
            print("7. Querying with a proof...")
            let query = QueryBuilder()
                .limit(10)
                .build()

            do {
                let queryResponse = try await client.data.query(
                    subgroveId: "secure-data",
                    query: query
                )
                print("   Query returned \(queryResponse.results.count) documents")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 8. Export trusted state for persistence
            print("8. Exporting trusted state...")
            do {
                let state = try lc.exportTrustedState()
                print("   Exported trusted state at height \(state.header.height)")
                print("   State can be persisted and restored later")

                // In production, you would serialize and save this:
                // let encoder = JSONEncoder()
                // let stateData = try encoder.encode(state)
                // try stateData.write(to: URL(fileURLWithPath: "trusted_state.json"))
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 9. Get sync status
            print("9. Getting sync status...")
            let syncStatus = lc.getSyncStatus()
            print("   Latest trusted height: \(syncStatus.latestTrustedHeight)")
            print("   Is synced: \(syncStatus.isSynced)")
            if let lastError = syncStatus.lastSyncError {
                print("   Last error: \(lastError)")
            }
            print()

            // 10. Show verification comparison
            print("10. Verification comparison...")
            print()
            print("   PROOF-CHECKED (get, query):")
            print("   + GroveDB proof bound to the path and key, checked locally")
            print("   + Root compared with the app hash of the header after the proof's block")
            print("   - Headers are accepted without verifying commit signatures")
            print()
            print("   UNVERIFIED (getUnverified, queryUnverified, GraphQL, SQL):")
            print("   + Fastest response times")
            print("   - Trusts the node completely")
            print("   - Only use with trusted nodes")
            print()

            // Clean up
            lc.stop()
            client.close()

            print("Light client example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
