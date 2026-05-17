import XCTest
@testable import Willow

final class ManifestTests: XCTestCase {
    // MARK: - SupportedChain

    func testCanonicalIDs() {
        XCTAssertEqual(SupportedChain.mainnet.rawValue, "mainnet")
        XCTAssertEqual(SupportedChain.arbitrumOne.rawValue, "arbitrum-one")
        XCTAssertEqual(SupportedChain.solanaMainnet.rawValue, "solana-mainnet")
    }

    func testFamilyAndEvmChainID() {
        XCTAssertEqual(SupportedChain.mainnet.family, .evm)
        XCTAssertEqual(SupportedChain.mainnet.evmChainID, 1)
        XCTAssertEqual(SupportedChain.arbitrumOne.evmChainID, 42_161)
        XCTAssertEqual(SupportedChain.solanaMainnet.family, .solana)
        XCTAssertNil(SupportedChain.solanaMainnet.evmChainID)
    }

    func testFromCanonicalIDRoundTrip() {
        for chain in SupportedChain.allCases {
            XCTAssertEqual(SupportedChain.from(canonicalID: chain.rawValue), chain)
        }
        XCTAssertNil(SupportedChain.from(canonicalID: "ethereum"))
        XCTAssertNil(SupportedChain.from(canonicalID: ""))
    }

    func testFromEvmChainID() {
        XCTAssertEqual(SupportedChain.from(evmChainID: 1), .mainnet)
        XCTAssertEqual(SupportedChain.from(evmChainID: 11_155_111), .sepolia)
        XCTAssertEqual(SupportedChain.from(evmChainID: 8453), .base)
        XCTAssertNil(SupportedChain.from(evmChainID: 99_999))
    }

    // MARK: - Helpers

    private func sampleManifest() -> WillowManifest {
        WillowManifest(
            description: "Sample",
            dataSources: [
                EvmDataSource(
                    name: "lst",
                    network: .mainnet,
                    address: "0x1234567890ABCDEF1234567890abcdef12345678",
                    abi: "ERC20",
                    startBlock: 18_000_000,
                    events: ["Transfer(address,address,uint256)"]
                )
            ]
        )
    }

    // MARK: - Round-trip

    func testSerializeParseRoundTrip() throws {
        let data = try serializeManifest(sampleManifest())
        let parsed = try parseManifest(data)
        XCTAssertEqual(parsed.specVersion, "1.0.0")
        XCTAssertEqual(parsed.description, "Sample")
        XCTAssertEqual(parsed.dataSources.count, 1)
        XCTAssertEqual(parsed.dataSources[0].network, .mainnet)
        XCTAssertEqual(parsed.dataSources[0].startBlock, 18_000_000)
    }

    func testAddressNormalizedToLowercase() throws {
        let bytes = try serializeManifest(sampleManifest())
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains("0x1234567890abcdef1234567890abcdef12345678"))
        XCTAssertFalse(json.contains("0x1234567890ABCDEF"))
    }

    func testJSONShape() throws {
        let bytes = try serializeManifest(sampleManifest())
        let obj = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(obj["spec_version"] as? String, "1.0.0")
        let sources = obj["data_sources"] as! [[String: Any]]
        XCTAssertEqual(sources[0]["start_block"] as? Int, 18_000_000)
    }

    // MARK: - Spec version

    func testRejectsWrongSpecVersion() {
        var m = sampleManifest()
        m.specVersion = "2.0.0"
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "spec_version")
        }
    }

    // MARK: - Data sources

    func testRejectsEmptyDataSources() {
        let m = WillowManifest(description: nil, dataSources: [])
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources")
        }
    }

    func testRejectsTooManyDataSources() {
        let oneTooMany = (0..<(maxDataSources + 1)).map { i in
            EvmDataSource(
                name: "s\(i)",
                network: .mainnet,
                address: "0x" + String(repeating: "1", count: 40),
                abi: "ERC20",
                startBlock: 0,
                events: ["E()"]
            )
        }
        let m = WillowManifest(dataSources: oneTooMany)
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources")
        }
    }

    // MARK: - Name

    func testRejectsEmptyName() {
        var m = sampleManifest()
        m.dataSources[0].name = ""
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].name")
        }
    }

    func testRejectsInvalidNameCharacters() {
        var m = sampleManifest()
        m.dataSources[0].name = "has space"
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].name")
        }
    }

    // MARK: - Address

    func testRejectsBadAddress() {
        var m = sampleManifest()
        m.dataSources[0].address = "0xzz"
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].address")
        }
    }

    func testRejectsAddressWithoutPrefix() {
        var m = sampleManifest()
        m.dataSources[0].address = String(repeating: "a", count: 40)
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].address")
        }
    }

    // MARK: - Events

    func testRejectsEmptyEvents() {
        var m = sampleManifest()
        m.dataSources[0].events = []
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].events")
        }
    }

    func testRejectsMalformedEventSignature() {
        var m = sampleManifest()
        m.dataSources[0].events = ["Transfer address,uint256)"]
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].events[0]")
        }
    }

    func testAcceptsParameterlessEvent() throws {
        var m = sampleManifest()
        m.dataSources[0].events = ["Heartbeat()"]
        _ = try serializeManifest(m)
    }

    // MARK: - Network

    func testRejectsSolanaInEvmBuilder() {
        var m = sampleManifest()
        m.dataSources[0].network = .solanaMainnet
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].network")
        }
    }

    // MARK: - Parse

    func testParseRejectsUnknownTopLevelField() {
        let bad = #"""
        {"spec_version":"1.0.0","data_sources":[{"name":"x","network":"mainnet","address":"0x0000000000000000000000000000000000000000","abi":"A","start_block":0,"events":["E()"]}],"surprise":1}
        """#
        XCTAssertThrowsError(try parseManifest(Data(bad.utf8)))
    }

    func testParseRejectsUnknownDataSourceField() {
        let bad = #"""
        {"spec_version":"1.0.0","data_sources":[{"name":"x","network":"mainnet","address":"0x0000000000000000000000000000000000000000","abi":"A","start_block":0,"events":["E()"],"extra":true}]}
        """#
        XCTAssertThrowsError(try parseManifest(Data(bad.utf8)))
    }

    func testParseRejectsInvalidJSON() {
        XCTAssertThrowsError(try parseManifest(Data("not json".utf8)))
    }
}
