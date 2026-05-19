// Light client example for the Willow Swift SDK
//
// This example demonstrates:
// - Configuring a light client for trustless verification
// - Verifying data against multiple validators
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
            _ = try? await client.registerDID(identity.didDocument)
            client.setIdentity(identity)
            print("   Authenticated as: \(identity.did)")
            print()

            // 5. Store test data
            print("5. Storing test data...")
            let testData: [String: Any] = [
                "message": "This data will be cryptographically verified",
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

            // 6. Retrieve with full trustless verification
            print("6. Retrieving data with trustless verification...")
            print("   This verifies:")
            print("   - 2/3+ validator signatures on block headers")
            print("   - GroveDB Merkle proof against consensus app_hash")
            print("   - Data integrity without trusting any single node")
            print()

            do {
                let response = try await client.data.get(
                    subgroveId: "secure-data",
                    key: "entry-1"
                )
                print("   Data retrieved and CRYPTOGRAPHICALLY VERIFIED:")
                print("   \(response.data)")
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 7. Query with verification
            print("7. Querying with trustless verification...")
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
            print("   LIGHT CLIENT (trustless):")
            print("   + Verifies validator signatures (2/3+ threshold)")
            print("   + Validates block header chain")
            print("   + Verifies proofs against consensus app_hash")
            print("   + No trust in any single node required")
            print("   - Slightly higher latency")
            print()
            print("   STANDARD VERIFICATION (root hash):")
            print("   + Fast verification")
            print("   + Verifies GroveDB proofs locally")
            print("   - Trusts that API returns correct root hash")
            print()
            print("   UNVERIFIED (performance mode):")
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
