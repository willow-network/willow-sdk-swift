import XCTest
@testable import Willow

final class ComputedFieldsTests: XCTestCase {

    // MARK: - ParseNumeric Tests

    func testParseNumericDouble() {
        XCTAssertEqual(parseNumeric(42.5), 42.5)
    }

    func testParseNumericInt() {
        XCTAssertEqual(parseNumeric(42), 42.0)
    }

    func testParseNumericInt64() {
        let value: Int64 = 1000000000000
        XCTAssertEqual(parseNumeric(value), Double(value))
    }

    func testParseNumericUInt64() {
        let value: UInt64 = 1000000000000
        XCTAssertEqual(parseNumeric(value), Double(value))
    }

    func testParseNumericFloat() {
        let value: Float = 3.14
        guard let result = parseNumeric(value) else {
            XCTFail("Expected non-nil result")
            return
        }
        XCTAssertEqual(result, Double(value), accuracy: 0.0001)
    }

    func testParseNumericString() {
        XCTAssertEqual(parseNumeric("123.45"), 123.45)
    }

    func testParseNumericHexString() {
        XCTAssertEqual(parseNumeric("0x64"), 100.0) // 0x64 = 100
    }

    func testParseNumericNil() {
        XCTAssertNil(parseNumeric(nil))
    }

    func testParseNumericNSNull() {
        XCTAssertNil(parseNumeric(NSNull()))
    }

    func testParseNumericInvalidString() {
        XCTAssertNil(parseNumeric("not a number"))
    }

    // MARK: - GetNestedValue Tests

    func testGetNestedValueSingleLevel() {
        let record: [String: Any] = ["name": "test", "value": 42]
        XCTAssertEqual(getNestedValue(record, keyPath: "name") as? String, "test")
        XCTAssertEqual(getNestedValue(record, keyPath: "value") as? Int, 42)
    }

    func testGetNestedValueMultiLevel() {
        let record: [String: Any] = [
            "token0": ["decimals": 18, "symbol": "WETH"],
            "token1": ["decimals": 6, "symbol": "USDC"]
        ]
        XCTAssertEqual(getNestedValue(record, keyPath: "token0.decimals") as? Int, 18)
        XCTAssertEqual(getNestedValue(record, keyPath: "token1.symbol") as? String, "USDC")
    }

    func testGetNestedValueNotFound() {
        let record: [String: Any] = ["name": "test"]
        XCTAssertNil(getNestedValue(record, keyPath: "missing"))
        XCTAssertNil(getNestedValue(record, keyPath: "name.nested"))
    }

    // MARK: - ComputedFieldRegistry Tests

    func testRegistryRegisterAndGet() {
        let registry = ComputedFieldRegistry()
        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "testField",
                description: "Test",
                dependencies: [],
                compute: { _ in 42 }
            )
        ]

        registry.register(datasetId: "dataset1", fields: fields)

        let result = registry.get(datasetId: "dataset1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?[0].name, "testField")
    }

    func testRegistryHas() {
        let registry = ComputedFieldRegistry()
        let fields: ComputedFieldSet = []

        XCTAssertFalse(registry.has(datasetId: "dataset1"))

        registry.register(datasetId: "dataset1", fields: fields)

        XCTAssertTrue(registry.has(datasetId: "dataset1"))
        XCTAssertFalse(registry.has(datasetId: "other"))
    }

    func testRegistryUnregister() {
        let registry = ComputedFieldRegistry()
        let fields: ComputedFieldSet = []

        registry.register(datasetId: "dataset1", fields: fields)
        XCTAssertTrue(registry.has(datasetId: "dataset1"))

        let removed = registry.unregister(datasetId: "dataset1")
        XCTAssertTrue(removed)
        XCTAssertFalse(registry.has(datasetId: "dataset1"))

        // Second unregister returns false
        let removedAgain = registry.unregister(datasetId: "dataset1")
        XCTAssertFalse(removedAgain)
    }

    func testRegistryClear() {
        let registry = ComputedFieldRegistry()
        let fields: ComputedFieldSet = []

        registry.register(datasetId: "dataset1", fields: fields)
        registry.register(datasetId: "dataset2", fields: fields)

        XCTAssertTrue(registry.has(datasetId: "dataset1"))
        XCTAssertTrue(registry.has(datasetId: "dataset2"))

        registry.clear()

        XCTAssertFalse(registry.has(datasetId: "dataset1"))
        XCTAssertFalse(registry.has(datasetId: "dataset2"))
    }

    // MARK: - ApplyComputedFields Tests

    func testApplyComputedFieldsBasic() {
        let record: [String: Any] = ["a": 10, "b": 20]
        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "sum",
                description: "Sum of a and b",
                dependencies: ["a", "b"],
                compute: { record in
                    guard let a = parseNumeric(record["a"]),
                          let b = parseNumeric(record["b"]) else { return nil }
                    return a + b
                }
            )
        ]

        let result = applyComputedFields(record: record, fields: fields)

        XCTAssertEqual(result["a"] as? Int, 10)
        XCTAssertEqual(result["b"] as? Int, 20)
        XCTAssertEqual(result["sum"] as? Double, 30.0)
    }

    func testApplyComputedFieldsMissingDependency() {
        let record: [String: Any] = ["a": 10]
        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "sum",
                description: "Sum of a and b",
                dependencies: ["a", "b"],
                compute: { record in
                    guard let a = parseNumeric(record["a"]),
                          let b = parseNumeric(record["b"]) else { return nil }
                    return a + b
                }
            )
        ]

        let result = applyComputedFields(record: record, fields: fields)

        XCTAssertNil(result["sum"])
    }

    func testApplyComputedFieldsNullDependency() {
        let record: [String: Any] = ["a": 10, "b": NSNull()]
        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "sum",
                description: "Sum of a and b",
                dependencies: ["a", "b"],
                compute: { _ in 42 }
            )
        ]

        let result = applyComputedFields(record: record, fields: fields)

        XCTAssertNil(result["sum"])
    }

    func testApplyComputedFieldsComputeReturnsNil() {
        let record: [String: Any] = ["a": 10, "b": 0]
        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "ratio",
                description: "a / b",
                dependencies: ["a", "b"],
                compute: { record in
                    guard let a = parseNumeric(record["a"]),
                          let b = parseNumeric(record["b"]),
                          b != 0 else { return nil }
                    return a / b
                }
            )
        ]

        let result = applyComputedFields(record: record, fields: fields)

        // Division by zero returns nil, so field should not be added
        XCTAssertNil(result["ratio"])
    }

    // MARK: - Pre-built Field Set Tests

    func testUniswapV2PairFieldsToken0Price() {
        let record: [String: Any] = [
            "reserve0": 1000000,
            "reserve1": 2000000
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2PairFields)

        // token0Price = reserve1 / reserve0 = 2000000 / 1000000 = 2.0
        guard let price = result["token0Price"] as? Double else {
            XCTFail("Expected token0Price")
            return
        }
        XCTAssertEqual(price, 2.0, accuracy: 0.0001)
    }

    func testUniswapV2PairFieldsToken1Price() {
        let record: [String: Any] = [
            "reserve0": 1000000,
            "reserve1": 2000000
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2PairFields)

        // token1Price = reserve0 / reserve1 = 1000000 / 2000000 = 0.5
        guard let price = result["token1Price"] as? Double else {
            XCTFail("Expected token1Price")
            return
        }
        XCTAssertEqual(price, 0.5, accuracy: 0.0001)
    }

    func testUniswapV2PairFieldsWithDecimals() {
        let record: [String: Any] = [
            "reserve0": 1000000000000000000, // 1e18 (18 decimals)
            "reserve1": 1000000, // 1e6 (6 decimals)
            "token0": ["decimals": 18],
            "token1": ["decimals": 6]
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2PairFields)

        // token0Price = (reserve1 / reserve0) * 10^(d0 - d1)
        // = (1e6 / 1e18) * 10^(18-6) = 1e-12 * 1e12 = 1.0
        guard let price = result["token0Price"] as? Double else {
            XCTFail("Expected token0Price")
            return
        }
        XCTAssertEqual(price, 1.0, accuracy: 0.0001)
    }

    func testUniswapV2PairFieldsDivisionByZero() {
        let record: [String: Any] = [
            "reserve0": 0,
            "reserve1": 2000000
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2PairFields)

        // token0Price should be nil due to division by zero
        XCTAssertNil(result["token0Price"])
    }

    func testGenericAmmPairFields() {
        let record: [String: Any] = [
            "reserve0": 500,
            "reserve1": 1000
        ]

        let result = applyComputedFields(record: record, fields: genericAmmPairFields)

        guard let token0Price = result["token0Price"] as? Double,
              let token1Price = result["token1Price"] as? Double else {
            XCTFail("Expected prices")
            return
        }
        XCTAssertEqual(token0Price, 2.0, accuracy: 0.0001)
        XCTAssertEqual(token1Price, 0.5, accuracy: 0.0001)
    }

    func testLendingProtocolFieldsUtilization() {
        let record: [String: Any] = [
            "totalBorrows": 30000,
            "totalSupply": 100000
        ]

        let result = applyComputedFields(record: record, fields: lendingProtocolFields)

        guard let utilization = result["utilizationRate"] as? Double,
              let available = result["availableLiquidity"] as? Double else {
            XCTFail("Expected utilization and availability")
            return
        }
        // utilizationRate = 30000 / 100000 = 0.3
        XCTAssertEqual(utilization, 0.3, accuracy: 0.0001)
        // availableLiquidity = 100000 - 30000 = 70000
        XCTAssertEqual(available, 70000.0, accuracy: 0.0001)
    }

    func testLpShareFields() {
        let record: [String: Any] = [
            "userLPBalance": 100,
            "totalLPSupply": 1000,
            "reserve0": 50000,
            "reserve1": 100000
        ]

        let result = applyComputedFields(record: record, fields: lpShareFields)

        guard let share = result["shareOfPool"] as? Double,
              let token0 = result["userToken0Amount"] as? Double,
              let token1 = result["userToken1Amount"] as? Double else {
            XCTFail("Expected LP share values")
            return
        }
        // shareOfPool = 100 / 1000 = 0.1
        XCTAssertEqual(share, 0.1, accuracy: 0.0001)
        // userToken0Amount = 0.1 * 50000 = 5000
        XCTAssertEqual(token0, 5000.0, accuracy: 0.0001)
        // userToken1Amount = 0.1 * 100000 = 10000
        XCTAssertEqual(token1, 10000.0, accuracy: 0.0001)
    }

    func testUniswapV2TokenFieldsWeth() {
        let record: [String: Any] = [
            "symbol": "WETH"
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2TokenFields)

        // WETH derivedETH should be 1.0
        guard let derived = result["derivedETH"] as? Double else {
            XCTFail("Expected derivedETH")
            return
        }
        XCTAssertEqual(derived, 1.0, accuracy: 0.0001)
    }

    func testUniswapV2TokenFieldsIsWeth() {
        let record: [String: Any] = [
            "isWeth": true
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2TokenFields)

        guard let derived = result["derivedETH"] as? Double else {
            XCTFail("Expected derivedETH")
            return
        }
        XCTAssertEqual(derived, 1.0, accuracy: 0.0001)
    }

    func testUniswapV2TokenFieldsOtherToken() {
        let record: [String: Any] = [
            "symbol": "USDC",
            "ethPairReserve0": 100, // ETH
            "ethPairReserve1": 200, // Token
            "ethPairToken0IsWeth": true
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2TokenFields)

        // derivedETH = reserve0 / reserve1 = 100 / 200 = 0.5
        guard let derived = result["derivedETH"] as? Double else {
            XCTFail("Expected derivedETH")
            return
        }
        XCTAssertEqual(derived, 0.5, accuracy: 0.0001)
    }

    func testUniswapV2AggregationFields() {
        let record: [String: Any] = [
            "dailyVolumeETH": 1000,
            "totalLiquidityETH": 50000,
            "ethPriceUSD": 2000
        ]

        let result = applyComputedFields(record: record, fields: uniswapV2AggregationFields)

        guard let volume = result["dailyVolumeUSD"] as? Double,
              let liquidity = result["totalLiquidityUSD"] as? Double else {
            XCTFail("Expected USD values")
            return
        }
        // dailyVolumeUSD = 1000 * 2000 = 2000000
        XCTAssertEqual(volume, 2000000.0, accuracy: 0.01)
        // totalLiquidityUSD = 50000 * 2000 = 100000000
        XCTAssertEqual(liquidity, 100000000.0, accuracy: 0.01)
    }

    // MARK: - Global Registry Test

    func testGlobalComputedFieldRegistry() {
        // Clear any existing registrations
        globalComputedFieldRegistry.clear()

        let fields: ComputedFieldSet = [
            ComputedFieldDefinition(
                name: "test",
                description: "Test",
                dependencies: [],
                compute: { _ in 42 }
            )
        ]

        globalComputedFieldRegistry.register(datasetId: "global-dataset", fields: fields)

        XCTAssertTrue(globalComputedFieldRegistry.has(datasetId: "global-dataset"))

        // Cleanup
        globalComputedFieldRegistry.clear()
    }
}
