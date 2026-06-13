/// ConnectionID Tests
///
/// Tests for ConnectionID type including random generation with various lengths.

import Testing
import Foundation
@testable import QUICCore

@Suite("ConnectionID Tests")
struct ConnectionIDTests {

    // MARK: - Basic Tests

    @Test("Empty connection ID")
    func emptyConnectionID() {
        let cid = ConnectionID.empty
        #expect(cid.isEmpty == true)
        #expect(cid.length == 0)
        #expect(cid.bytes.count == 0)
    }

    @Test("Create from bytes")
    func createFromBytes() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let cid = try ConnectionID(bytes: bytes)
        #expect(cid.length == 4)
        #expect(cid.bytes == bytes)
        #expect(cid.isEmpty == false)
    }

    @Test("Create from sequence")
    func createFromSequence() throws {
        let cid = try ConnectionID([0xAA, 0xBB, 0xCC])
        #expect(cid.length == 3)
        #expect(cid.bytes == Data([0xAA, 0xBB, 0xCC]))
    }

    @Test("Create from bytes fails for oversized input")
    func createFromBytesFailsForOversized() {
        let oversizedBytes = Data(repeating: 0xAA, count: 21)
        #expect(throws: ConnectionID.ConnectionIDError.self) {
            _ = try ConnectionID(bytes: oversizedBytes)
        }
    }

    // MARK: - Random Generation Tests (Memory Safety)

    @Test("Random with length 0")
    func randomLength0() throws {
        let cid = try #require(ConnectionID.random(length: 0))
        #expect(cid.isEmpty == true)
        #expect(cid.length == 0)
    }

    @Test("Random with length 1 (edge case < 8)")
    func randomLength1() throws {
        // This was the bug: length < 8 caused buffer overflow with unsafe pointer
        let cid = try #require(ConnectionID.random(length: 1))
        #expect(cid.length == 1)
        #expect(cid.bytes.count == 1)
    }

    @Test("Random with length 7 (edge case < 8)")
    func randomLength7() throws {
        // Another edge case: 7 bytes, less than one UInt64
        let cid = try #require(ConnectionID.random(length: 7))
        #expect(cid.length == 7)
        #expect(cid.bytes.count == 7)
    }

    @Test("Random with default length 8")
    func randomLength8() throws {
        let cid = try #require(ConnectionID.random())
        #expect(cid.length == 8)
        #expect(cid.bytes.count == 8)
    }

    @Test("Random with length 9 (1 full + partial)")
    func randomLength9() throws {
        let cid = try #require(ConnectionID.random(length: 9))
        #expect(cid.length == 9)
        #expect(cid.bytes.count == 9)
    }

    @Test("Random with length 16 (2 full UInt64)")
    func randomLength16() throws {
        let cid = try #require(ConnectionID.random(length: 16))
        #expect(cid.length == 16)
        #expect(cid.bytes.count == 16)
    }

    @Test("Random with max length 20")
    func randomLength20() throws {
        let cid = try #require(ConnectionID.random(length: 20))
        #expect(cid.length == 20)
        #expect(cid.bytes.count == 20)
    }

    @Test("Random with invalid length returns nil")
    func randomInvalidLength() {
        #expect(ConnectionID.random(length: -1) == nil)
        #expect(ConnectionID.random(length: 21) == nil)
        #expect(ConnectionID.random(length: 100) == nil)
    }

    @Test("Random generates different values")
    func randomGeneratesDifferentValues() throws {
        let cid1 = try #require(ConnectionID.random(length: 8))
        let cid2 = try #require(ConnectionID.random(length: 8))
        // Very unlikely to generate same random bytes
        #expect(cid1 != cid2)
    }

    @Test("Random all lengths from 1 to 20")
    func randomAllLengths() throws {
        // Comprehensive test for all valid lengths
        for length in 1...20 {
            let cid = try #require(ConnectionID.random(length: length))
            #expect(cid.length == length, "Random failed for length \(length)")
            #expect(cid.bytes.count == length, "Bytes count mismatch for length \(length)")
        }
    }

    // MARK: - Encoding/Decoding Tests

    @Test("Encode with length prefix")
    func encodeWithLengthPrefix() throws {
        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        let encoded = cid.encode()

        #expect(encoded.count == 4)  // 1 length byte + 3 data bytes
        #expect(encoded[0] == 3)      // Length
        #expect(encoded[1] == 0x01)
        #expect(encoded[2] == 0x02)
        #expect(encoded[3] == 0x03)
    }

    @Test("Encode empty connection ID")
    func encodeEmpty() {
        let cid = ConnectionID.empty
        let encoded = cid.encode()

        #expect(encoded.count == 1)
        #expect(encoded[0] == 0)  // Zero length
    }

    @Test("Decode with length prefix")
    func decodeWithLengthPrefix() throws {
        let data = Data([0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        var reader = DataReader(data)

        let cid = try ConnectionID.decode(from: &reader)

        #expect(cid.length == 4)
        #expect(cid.bytes == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test("Decode empty connection ID")
    func decodeEmpty() throws {
        let data = Data([0x00])
        var reader = DataReader(data)

        let cid = try ConnectionID.decode(from: &reader)

        #expect(cid.isEmpty == true)
    }

    @Test("Decode bytes without length prefix")
    func decodeBytesWithoutPrefix() throws {
        let data = Data([0x11, 0x22, 0x33, 0x44, 0x55])
        var reader = DataReader(data)

        let cid = try ConnectionID.decodeBytes(from: &reader, length: 3)

        #expect(cid.length == 3)
        #expect(cid.bytes == Data([0x11, 0x22, 0x33]))
        #expect(reader.remainingCount == 2)  // 2 bytes left
    }

    // MARK: - Error Tests

    @Test("Decode fails with insufficient data")
    func decodeInsufficientData() throws {
        let data = Data([0x05, 0x01, 0x02])  // Says 5 bytes, only has 2
        var reader = DataReader(data)

        #expect(throws: ConnectionID.DecodeError.self) {
            _ = try ConnectionID.decode(from: &reader)
        }
    }

    @Test("Decode fails with invalid length")
    func decodeInvalidLength() throws {
        let data = Data([0x15])  // 21 bytes (> max 20)
        var reader = DataReader(data)

        #expect(throws: ConnectionID.DecodeError.self) {
            _ = try ConnectionID.decode(from: &reader)
        }
    }

    // MARK: - Equality Tests

    @Test("Equal connection IDs")
    func equalConnectionIDs() throws {
        let cid1 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        let cid2 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        #expect(cid1 == cid2)
    }

    @Test("Unequal connection IDs")
    func unequalConnectionIDs() throws {
        let cid1 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        let cid2 = try ConnectionID(bytes: Data([0x01, 0x02, 0x04]))
        #expect(cid1 != cid2)
    }

    @Test("Hashable conformance")
    func hashableConformance() throws {
        let cid1 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        let cid2 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        let cid3 = try ConnectionID(bytes: Data([0x04, 0x05, 0x06]))

        var set = Set<ConnectionID>()
        set.insert(cid1)
        set.insert(cid2)
        set.insert(cid3)

        #expect(set.count == 2)  // cid1 and cid2 are equal
    }

    // MARK: - Description Tests

    @Test("Description for empty")
    func descriptionEmpty() {
        let cid = ConnectionID.empty
        #expect(cid.description == "ConnectionID(empty)")
    }

    @Test("Description for non-empty")
    func descriptionNonEmpty() throws {
        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03]))
        #expect(cid.description == "ConnectionID(010203)")
    }
}
