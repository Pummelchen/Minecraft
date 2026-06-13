import Testing
import Foundation
@testable import QUICCore

@Suite("Varint Tests")
struct VarintTests {

    @Test("Encode 1-byte varint")
    func encode1Byte() {
        let varint = Varint(37)
        let encoded = varint.encode()
        #expect(encoded.count == 1)
        #expect(encoded[0] == 37)
    }

    @Test("Encode 2-byte varint")
    func encode2Byte() {
        let varint = Varint(15293)
        let encoded = varint.encode()
        #expect(encoded.count == 2)
        #expect(encoded[0] == 0x7b)
        #expect(encoded[1] == 0xbd)
    }

    @Test("Encode 4-byte varint")
    func encode4Byte() {
        let varint = Varint(494_878_333)
        let encoded = varint.encode()
        #expect(encoded.count == 4)
        #expect(encoded[0] == 0x9d)
        #expect(encoded[1] == 0x7f)
        #expect(encoded[2] == 0x3e)
        #expect(encoded[3] == 0x7d)
    }

    @Test("Encode 8-byte varint")
    func encode8Byte() {
        let varint = Varint(151_288_809_941_952_652)
        let encoded = varint.encode()
        #expect(encoded.count == 8)
        #expect(encoded[0] == 0xc2)
        #expect(encoded[1] == 0x19)
        #expect(encoded[2] == 0x7c)
        #expect(encoded[3] == 0x5e)
        #expect(encoded[4] == 0xff)
        #expect(encoded[5] == 0x14)
        #expect(encoded[6] == 0xe8)
        #expect(encoded[7] == 0x8c)
    }

    @Test("Decode 1-byte varint")
    func decode1Byte() throws {
        let data = Data([37])
        let (varint, length) = try Varint.decode(from: data)
        #expect(varint.value == 37)
        #expect(length == 1)
    }

    @Test("Decode 2-byte varint")
    func decode2Byte() throws {
        let data = Data([0x7b, 0xbd])
        let (varint, length) = try Varint.decode(from: data)
        #expect(varint.value == 15293)
        #expect(length == 2)
    }

    @Test("Roundtrip encoding")
    func roundtrip() throws {
        let testValues: [UInt64] = [0, 1, 63, 64, 16383, 16384, 1073741823, 1073741824]

        for value in testValues {
            let original = Varint(value)
            let encoded = original.encode()
            let (decoded, _) = try Varint.decode(from: encoded)
            #expect(decoded.value == value, "Roundtrip failed for value \(value)")
        }
    }

    @Test("Encoded length calculation")
    func encodedLength() {
        #expect(Varint(0).encodedLength == 1)
        #expect(Varint(63).encodedLength == 1)
        #expect(Varint(64).encodedLength == 2)
        #expect(Varint(16383).encodedLength == 2)
        #expect(Varint(16384).encodedLength == 4)
        #expect(Varint(1073741823).encodedLength == 4)
        #expect(Varint(1073741824).encodedLength == 8)
    }
}
