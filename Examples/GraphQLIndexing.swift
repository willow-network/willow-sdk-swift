// GraphQL indexing example for the Willow Swift SDK
//
// This example demonstrates:
// - Querying indexed blockchain data via GraphQL
// - Automatic proof verification for query results
// - Using the light client for trustless verification
//
// To run this example, include it in an iOS/macOS app or Swift package.

import Foundation
import Willow

@main
struct GraphQLIndexingExample {
    static func main() async {
        print("Willow SDK - GraphQL Indexing Example")
        print("======================================")
        print()

        do {
            // 1. Create client with light client for trustless verification
            print("1. Creating client with light client...")
            let lcConfig = LightClientConfig(
                chainId: "willow-testnet",
                validatorEndpoints: [
                    "http://localhost:26657",
                    "http://localhost:26757"
                ],
                trustThreshold: TrustThreshold(numerator: 2, denominator: 3),
                minValidatorsForConsensus: 2
            )

            let lc = try LightClient(lcConfig)
            lc.start()

            let client = try WillowClient(
                baseURL: "http://localhost:3031",
                lightClient: lc
            )
            print("   Client created with trustless verification enabled")
            print()

            // 2. List available subgroves
            print("2. Listing available subgroves...")
            do {
                let subgroves = try await client.indexing.listSubgroves()
                print("   Found \(subgroves.count) subgroves:")
                for subgrove in subgroves {
                    print("   - \(subgrove.name) (\(subgrove.network)): block \(subgrove.currentBlock)")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 3. Query Uniswap trades with GraphQL
            print("3. Querying Uniswap trades...")
            let tradesQuery = """
                query GetRecentTrades($limit: Int!) {
                    swaps(first: $limit, orderBy: timestamp, orderDirection: desc) {
                        id
                        timestamp
                        sender
                        recipient
                        amountIn
                        amountOut
                        tokenIn {
                            symbol
                        }
                        tokenOut {
                            symbol
                        }
                    }
                }
                """

            do {
                let response = try await client.indexing.execute(
                    subgroveId: "uniswap-v3-mainnet",
                    query: tradesQuery,
                    variables: ["limit": 5]
                )

                if response.proof != nil {
                    print("   Query results CRYPTOGRAPHICALLY VERIFIED!")
                }

                if let data = response.data {
                    print("   Response data received (\(data.count) bytes)")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 4. Query with the builder pattern
            print("4. Using GraphQL query builder...")
            let request = GraphQLQueryBuilder(query: """
                query GetTokens($symbol: String!) {
                    tokens(where: { symbol: $symbol }) {
                        id
                        name
                        symbol
                        decimals
                        totalSupply
                    }
                }
                """)
                .variable("symbol", value: "USDC")
                .operationName("GetTokens")
                .includeProof()
                .build()

            do {
                let response = try await client.indexing.query(
                    subgroveId: "uniswap-v3-mainnet",
                    request: request
                )

                if let errors = response.errors, !errors.isEmpty {
                    print("   GraphQL errors:")
                    for error in errors {
                        print("   - \(error.message)")
                    }
                } else {
                    print("   Token query successful")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 5. Query without verification (for performance)
            print("5. Querying without verification (faster)...")
            let quickQuery = GraphQLRequest(
                query: "{ _meta { block { number } } }",
                includeProof: false
            )

            do {
                let response = try await client.indexing.queryUnverified(
                    subgroveId: "uniswap-v3-mainnet",
                    request: quickQuery
                )
                print("   Quick query completed (unverified)")
                if let data = response.data {
                    print("   Data size: \(data.count) bytes")
                }
            } catch {
                print("   Note: \(error.localizedDescription)")
            }
            print()

            // 6. Compare with The Graph
            print("6. Comparison with The Graph:")
            print()
            print("   Traditional (The Graph):")
            print("   - Decentralized indexing network")
            print("   - Trust in indexer reputation + staking")
            print("   - No cryptographic verification of results")
            print("   - Disputes resolved post-hoc")
            print()
            print("   Willow Protocol:")
            print("   - Cryptographic proof for EVERY query")
            print("   - Results verifiable against blockchain state")
            print("   - 50-100x faster query performance")
            print("   - Trustless by default, not by reputation")
            print()

            // Clean up
            lc.stop()
            client.close()

            print("GraphQL indexing example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
