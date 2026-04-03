import Foundation

// MARK: - Computed Fields Module

public typealias ComputeFunction = (_ record: [String: Any]) -> Any?

public struct ComputedFieldDefinition {
    public let name: String
    public let description: String
    public let dependencies: [String]
    public let compute: ComputeFunction

    public init(
        name: String,
        description: String,
        dependencies: [String],
        compute: @escaping ComputeFunction
    ) {
        self.name = name
        self.description = description
        self.dependencies = dependencies
        self.compute = compute
    }
}

public typealias ComputedFieldSet = [ComputedFieldDefinition]

public class ComputedFieldRegistry {
    private var registry: [String: ComputedFieldSet] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(datasetId: String, fields: ComputedFieldSet) {
        lock.lock()
        defer { lock.unlock() }
        registry[datasetId] = fields
    }

    public func get(datasetId: String) -> ComputedFieldSet? {
        lock.lock()
        defer { lock.unlock() }
        return registry[datasetId]
    }

    public func has(datasetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registry[datasetId] != nil
    }

    @discardableResult
    public func unregister(datasetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registry.removeValue(forKey: datasetId) != nil
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        registry.removeAll()
    }
}



// MARK: - Apply Computed Fields Functions

/// Apply computed fields to a single record.
public func applyComputedFields(record: [String: Any], fields: ComputedFieldSet) -> [String: Any] {
    var result = record
    for field in fields {
        let hasDependencies = field.dependencies.allSatisfy { dep in
            if let value = record[dep] { return !(value is NSNull) }
            return false
        }
        if hasDependencies { if let computed = field.compute(record) { result[field.name] = computed } }
    }
    return result
}

/// Apply computed fields to a query response.
public func applyComputedFieldsToResponse(response: QueryResponse, fields: ComputedFieldSet) -> QueryResponse {
    let updatedResults = response.results.map { result -> QueryResult in
        var recordDict: [String: Any] = [:]
        for (key, value) in result.data { recordDict[key] = value.value }
        let computedDict = applyComputedFields(record: recordDict, fields: fields)
        var newData: [String: AnyCodable] = [:]
        for (key, value) in computedDict { newData[key] = AnyCodable(value) }
        return QueryResult(key: result.key, data: newData)
    }
    return QueryResponse(results: updatedResults, totalCount: response.totalCount, hasMore: response.hasMore, proof: response.proof)
}

// MARK: - Numeric Parsing Helper

public func parseNumeric(_ value: Any?) -> Double? {
    guard let value = value else { return nil }
    if value is NSNull { return nil }
    if let n = value as? Double { return n }
    if let n = value as? Int { return Double(n) }
    if let n = value as? Int64 { return Double(n) }
    if let n = value as? UInt64 { return Double(n) }
    if let n = value as? Float { return Double(n) }
    if let s = value as? String {
        if s.hasPrefix("0x"), let i = UInt64(String(s.dropFirst(2)), radix: 16) { return Double(i) }
        if let p = Double(s) { return p }
    }
    return nil
}

public func getNestedValue(_ record: [String: Any], keyPath: String) -> Any? {
    var current: Any = record
    for component in keyPath.split(separator: ".").map(String.init) {
        guard let dict = current as? [String: Any], let value = dict[component] else { return nil }
        current = value
    }
    return current
}

// MARK: - Pre-built Field Sets

public let uniswapV2PairFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "token0Price", description: "Price of token0 in terms of token1", dependencies: ["reserve0", "reserve1"], compute: { record in
        guard let r0 = parseNumeric(record["reserve0"]), let r1 = parseNumeric(record["reserve1"]), r0 != 0 else { return nil }
        let d0 = parseNumeric(getNestedValue(record, keyPath: "token0.decimals")) ?? 18.0
        let d1 = parseNumeric(getNestedValue(record, keyPath: "token1.decimals")) ?? 18.0
        return (r1 / r0) * pow(10.0, d0 - d1)
    }),
    ComputedFieldDefinition(name: "token1Price", description: "Price of token1 in terms of token0", dependencies: ["reserve0", "reserve1"], compute: { record in
        guard let r0 = parseNumeric(record["reserve0"]), let r1 = parseNumeric(record["reserve1"]), r1 != 0 else { return nil }
        let d0 = parseNumeric(getNestedValue(record, keyPath: "token0.decimals")) ?? 18.0
        let d1 = parseNumeric(getNestedValue(record, keyPath: "token1.decimals")) ?? 18.0
        return (r0 / r1) * pow(10.0, d1 - d0)
    })
]

public let uniswapV2TokenFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "derivedETH", description: "Price of token in ETH", dependencies: [], compute: { record in
        if let isWeth = record["isWeth"] as? Bool, isWeth { return 1.0 }
        if let symbol = record["symbol"] as? String, symbol == "WETH" { return 1.0 }
        guard let r0 = parseNumeric(record["ethPairReserve0"]), let r1 = parseNumeric(record["ethPairReserve1"]) else { return nil }
        let t0IsWeth = (record["ethPairToken0IsWeth"] as? Bool) ?? false
        if t0IsWeth { guard r1 != 0 else { return nil }; return r0 / r1 }
        else { guard r0 != 0 else { return nil }; return r1 / r0 }
    })
]

public let uniswapV2AggregationFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "dailyVolumeUSD", description: "Daily volume in USD", dependencies: ["dailyVolumeETH", "ethPriceUSD"], compute: { record in
        guard let v = parseNumeric(record["dailyVolumeETH"]), let p = parseNumeric(record["ethPriceUSD"]) else { return nil }
        return v * p
    }),
    ComputedFieldDefinition(name: "totalLiquidityUSD", description: "Total liquidity in USD", dependencies: ["totalLiquidityETH", "ethPriceUSD"], compute: { record in
        guard let l = parseNumeric(record["totalLiquidityETH"]), let p = parseNumeric(record["ethPriceUSD"]) else { return nil }
        return l * p
    })
]

public let genericAmmPairFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "token0Price", description: "Price of token0 in terms of token1", dependencies: ["reserve0", "reserve1"], compute: { record in
        guard let r0 = parseNumeric(record["reserve0"]), let r1 = parseNumeric(record["reserve1"]), r0 != 0 else { return nil }
        return r1 / r0
    }),
    ComputedFieldDefinition(name: "token1Price", description: "Price of token1 in terms of token0", dependencies: ["reserve0", "reserve1"], compute: { record in
        guard let r0 = parseNumeric(record["reserve0"]), let r1 = parseNumeric(record["reserve1"]), r1 != 0 else { return nil }
        return r0 / r1
    })
]

public let lendingProtocolFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "utilizationRate", description: "Utilization rate", dependencies: ["totalBorrows", "totalSupply"], compute: { record in
        guard let b = parseNumeric(record["totalBorrows"]), let s = parseNumeric(record["totalSupply"]), s != 0 else { return nil }
        return b / s
    }),
    ComputedFieldDefinition(name: "availableLiquidity", description: "Available liquidity", dependencies: ["totalBorrows", "totalSupply"], compute: { record in
        guard let b = parseNumeric(record["totalBorrows"]), let s = parseNumeric(record["totalSupply"]) else { return nil }
        return s - b
    })
]

public let lpShareFields: ComputedFieldSet = [
    ComputedFieldDefinition(name: "shareOfPool", description: "User share of pool", dependencies: ["userLPBalance", "totalLPSupply"], compute: { record in
        guard let u = parseNumeric(record["userLPBalance"]), let t = parseNumeric(record["totalLPSupply"]), t != 0 else { return nil }
        return u / t
    }),
    ComputedFieldDefinition(name: "userToken0Amount", description: "User share of token0", dependencies: ["userLPBalance", "totalLPSupply", "reserve0"], compute: { record in
        guard let u = parseNumeric(record["userLPBalance"]), let t = parseNumeric(record["totalLPSupply"]), let r0 = parseNumeric(record["reserve0"]), t != 0 else { return nil }
        return (u / t) * r0
    }),
    ComputedFieldDefinition(name: "userToken1Amount", description: "User share of token1", dependencies: ["userLPBalance", "totalLPSupply", "reserve1"], compute: { record in
        guard let u = parseNumeric(record["userLPBalance"]), let t = parseNumeric(record["totalLPSupply"]), let r1 = parseNumeric(record["reserve1"]), t != 0 else { return nil }
        return (u / t) * r1
    })
]

public let globalComputedFieldRegistry = ComputedFieldRegistry()
