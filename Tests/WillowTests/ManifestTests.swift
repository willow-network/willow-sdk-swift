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

    private func sampleEvmManifest() -> WillowManifest {
        WillowManifest(
            description: "Sample",
            dataSources: [
                .evm(EvmDataSource(
                    name: "lst",
                    network: .mainnet,
                    address: "0x1234567890ABCDEF1234567890abcdef12345678",
                    abi: "ERC20",
                    startBlock: 18_000_000,
                    events: ["Transfer(address,address,uint256)"]
                ))
            ]
        )
    }

    private func sampleSolanaManifest() -> WillowManifest {
        WillowManifest(
            description: "Spl",
            dataSources: [
                .solana(SolanaDataSource(
                    name: "spl",
                    network: .solanaMainnet,
                    programID: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                    startSlot: 100_000_000,
                    instructions: ["0x03"]
                ))
            ]
        )
    }

    private func mutateEvm(
        _ m: inout WillowManifest, idx: Int = 0, _ fn: (inout EvmDataSource) -> Void
    ) {
        guard case .evm(var d) = m.dataSources[idx] else {
            XCTFail("expected .evm at idx \(idx)")
            return
        }
        fn(&d)
        m.dataSources[idx] = .evm(d)
    }

    private func mutateSolana(
        _ m: inout WillowManifest, idx: Int = 0, _ fn: (inout SolanaDataSource) -> Void
    ) {
        guard case .solana(var d) = m.dataSources[idx] else {
            XCTFail("expected .solana at idx \(idx)")
            return
        }
        fn(&d)
        m.dataSources[idx] = .solana(d)
    }

    // MARK: - Round-trip

    func testSerializeParseRoundTrip() throws {
        let data = try serializeManifest(sampleEvmManifest())
        let parsed = try parseManifest(data)
        XCTAssertEqual(parsed.specVersion, "1.0.0")
        XCTAssertEqual(parsed.description, "Sample")
        XCTAssertEqual(parsed.dataSources.count, 1)
        XCTAssertEqual(parsed.dataSources[0].network, .mainnet)
        if case .evm(let d) = parsed.dataSources[0] {
            XCTAssertEqual(d.startBlock, 18_000_000)
        } else {
            XCTFail("expected .evm")
        }
    }

    func testAddressNormalizedToLowercase() throws {
        let bytes = try serializeManifest(sampleEvmManifest())
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains("0x1234567890abcdef1234567890abcdef12345678"))
        XCTAssertFalse(json.contains("0x1234567890ABCDEF"))
    }

    func testJSONShape() throws {
        let bytes = try serializeManifest(sampleEvmManifest())
        let obj = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(obj["spec_version"] as? String, "1.0.0")
        let sources = obj["data_sources"] as! [[String: Any]]
        XCTAssertEqual(sources[0]["start_block"] as? Int, 18_000_000)
    }

    // MARK: - Spec version

    func testRejectsWrongSpecVersion() {
        var m = sampleEvmManifest()
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
        let oneTooMany: [DataSource] = (0..<(maxDataSources + 1)).map { i in
            .evm(EvmDataSource(
                name: "s\(i)",
                network: .mainnet,
                address: "0x" + String(repeating: "1", count: 40),
                abi: "ERC20",
                startBlock: 0,
                events: ["E()"]
            ))
        }
        let m = WillowManifest(dataSources: oneTooMany)
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources")
        }
    }

    // MARK: - Name

    func testRejectsEmptyName() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.name = "" }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].name")
        }
    }

    func testRejectsInvalidNameCharacters() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.name = "has space" }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].name")
        }
    }

    // MARK: - Address

    func testRejectsBadAddress() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.address = "0xzz" }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].address")
        }
    }

    func testRejectsAddressWithoutPrefix() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.address = String(repeating: "a", count: 40) }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].address")
        }
    }

    // MARK: - Events

    func testRejectsEmptyEvents() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.events = [] }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].events")
        }
    }

    func testRejectsMalformedEventSignature() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.events = ["Transfer address,uint256)"] }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].events[0]")
        }
    }

    func testAcceptsParameterlessEvent() throws {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.events = ["Heartbeat()"] }
        _ = try serializeManifest(m)
    }

    // MARK: - Network

    func testRejectsEvmFieldsOnSolanaNetwork() {
        var m = sampleEvmManifest()
        mutateEvm(&m) { $0.network = .solanaMainnet }
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

    // MARK: - Solana

    func testSolanaRoundTripNativeSpl() throws {
        let data = try serializeManifest(sampleSolanaManifest())
        let parsed = try parseManifest(data)
        guard case .solana(let d) = parsed.dataSources[0] else {
            XCTFail("expected .solana")
            return
        }
        XCTAssertEqual(d.programID, "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
        XCTAssertEqual(d.instructions, ["0x03"])
    }

    func testSolanaAcceptsAnchorAndSystemDiscriminators() throws {
        let cases: [[String]] = [
            ["0xc1209b3341d69c81"],                  // anchor
            ["0x02000000"],                          // system program 4-byte
            ["0x03", "0x07", "0xc1209b3341d69c81"],  // mixed lengths
        ]
        for ix in cases {
            var m = sampleSolanaManifest()
            mutateSolana(&m) { $0.instructions = ix }
            _ = try serializeManifest(m)
        }
    }

    func testSolanaNormalizesDiscriminatorToLowercase() throws {
        var m = sampleSolanaManifest()
        mutateSolana(&m) { $0.instructions = ["0xABCD"] }
        let bytes = try serializeManifest(m)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains("0xabcd"))
        XCTAssertFalse(json.contains("0xABCD"))
    }

    func testSolanaRejectsBadDiscriminators() {
        for bad in ["0x123", "0x", "03"] {
            var m = sampleSolanaManifest()
            mutateSolana(&m) { $0.instructions = [bad] }
            XCTAssertThrowsError(try serializeManifest(m)) { error in
                let e = error as! ManifestValidationError
                XCTAssertEqual(e.field, "data_sources[0].instructions[0]")
            }
        }
    }

    func testSolanaRejectsEmptyInstructions() {
        var m = sampleSolanaManifest()
        mutateSolana(&m) { $0.instructions = [] }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].instructions")
        }
    }

    func testSolanaRejectsBadProgramID() {
        var m = sampleSolanaManifest()
        mutateSolana(&m) { $0.programID = "Tokenkeg0feZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].program_id")
        }

        var m2 = sampleSolanaManifest()
        mutateSolana(&m2) { $0.programID = "Token" }
        XCTAssertThrowsError(try serializeManifest(m2)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].program_id")
        }
    }

    func testSolanaRejectsSolanaFieldsOnEvmNetwork() {
        var m = sampleSolanaManifest()
        mutateSolana(&m) { $0.network = .mainnet }
        XCTAssertThrowsError(try serializeManifest(m)) { error in
            let e = error as! ManifestValidationError
            XCTAssertEqual(e.field, "data_sources[0].network")
        }
    }

    func testSolanaMixedManifest() throws {
        let mixed = WillowManifest(
            description: nil,
            dataSources: sampleEvmManifest().dataSources + sampleSolanaManifest().dataSources
        )
        let bytes = try serializeManifest(mixed)
        let parsed = try parseManifest(bytes)
        XCTAssertEqual(parsed.dataSources.count, 2)
        if case .evm = parsed.dataSources[0] {} else { XCTFail("first should be .evm") }
        if case .solana = parsed.dataSources[1] {} else { XCTFail("second should be .solana") }
    }
}
