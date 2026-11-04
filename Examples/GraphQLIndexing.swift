// GraphQL indexing example for the Willow Swift SDK
//
// This example demonstrates:
// - Querying indexed blockchain data via GraphQL
// - Reading a GraphQL answer, which the SDK does not verify
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
            // 1. Create a client. GraphQL answers are not verified, so it
            // needs no light client.
            print("1. Creating client...")
            let client = try WillowClient(baseURL: "http://localhost:3031")
            print("   Client created")
            print()

            // 2. List available subgroves
            print("2. Listing available subgroves...")
            do {
                let subgroves = try await client.indexing.listSubgroves()
                print("   Found \(subgroves.count) subgroves:")
                for subgrove in subgroves {
                    print("   - \(subgrove.name) (\(subgrove.chain ?? "")): block \(subgrove.latestBlock)")
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

                // The answer is not verified: a proof object, if the node
                // attached one, doesn't bind `data`.
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

            // 6. Summary
            print("6. Summary:")
            print()
            print("   - GraphQL answers come back unverified")
            print("   - For proof-checked reads of a DataStorage subgrove, use client.data.get and client.data.query")
            print()

            // Clean up
            client.close()

            print("GraphQL indexing example complete!")

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
