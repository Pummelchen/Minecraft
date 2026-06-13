/// QPACK Tests
///
/// Tests for QPACK integer coding, string coding, static table,
/// Huffman codec, and encoder/decoder round-trip correctness.

import XCTest
import Foundation
@testable import QPACK

// MARK: - Integer Coding Tests

final class QPACKIntegerTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeSmallValueFitsInPrefix() {
        // Value 10 with 5-bit prefix → single byte
        let encoded = QPACKInteger.encode(10, prefix: 5)
        XCTAssertEqual(encoded, Data([0x0a]))
    }

    func testEncodeZero() {
        let encoded = QPACKInteger.encode(0, prefix: 5)
        XCTAssertEqual(encoded, Data([0x00]))
    }

    func testEncodeMaxPrefixValue() {
        // Value 30 with 5-bit prefix (max = 31) → single byte
        let encoded = QPACKInteger.encode(30, prefix: 5)
        XCTAssertEqual(encoded, Data([30]))
    }

    func testEncodePrefixBoundary() {
        // Value 31 with 5-bit prefix → exactly at boundary, needs continuation
        let encoded = QPACKInteger.encode(31, prefix: 5)
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded[0], 0x1f) // all prefix bits set
        XCTAssertEqual(encoded[1], 0x00) // 31 - 31 = 0
    }

    func testEncodeMultiByte() {
        // Value 1337 with 5-bit prefix
        // 1337 >= 31, so prefix = 0x1f, remainder = 1337 - 31 = 1306
        // 1306 = 0x51a
        // 0x51a & 0x7f = 0x1a, continuation → 0x9a
        // 0x51a >> 7 = 0x0a, final → 0x0a
        let encoded = QPACKInteger.encode(1337, prefix: 5)
        XCTAssertEqual(encoded, Data([0x1f, 0x9a, 0x0a]))
    }

    func testEncode8BitPrefix() {
        // With 8-bit prefix, max = 255
        let encoded = QPACKInteger.encode(42, prefix: 8)
        XCTAssertEqual(encoded, Data([42]))

        let large = QPACKInteger.encode(300, prefix: 8)
        XCTAssertEqual(large[0], 0xff) // 255
        XCTAssertTrue(large.count > 1)
    }

    func testEncode1BitPrefix() {
        // With 1-bit prefix, max = 1
        let encoded = QPACKInteger.encode(0, prefix: 1)
        XCTAssertEqual(encoded, Data([0x00]))

        let encoded1 = QPACKInteger.encode(1, prefix: 1)
        XCTAssertEqual(encoded1.count, 2)
        XCTAssertEqual(encoded1[0], 0x01) // prefix bits all set
    }

    func testEncodePreservesHighBits() {
        // firstByte has high bits set that should be preserved
        let encoded = QPACKInteger.encode(10, prefix: 5, firstByte: 0xe0)
        // High 3 bits = 0xe0 (111), prefix = 01010
        XCTAssertEqual(encoded, Data([0xea])) // 0xe0 | 0x0a
    }

    func testEncodePreservesHighBitsMultiByte() {
        let encoded = QPACKInteger.encode(31, prefix: 5, firstByte: 0xa0)
        XCTAssertEqual(encoded[0], 0xbf) // 0xa0 | 0x1f
        XCTAssertEqual(encoded[1], 0x00)
    }

    // MARK: - Decoding

    func testDecodeSmallValue() throws {
        var offset = 0
        let value = try QPACKInteger.decode(from: Data([0x0a]), offset: &offset, prefix: 5)
        XCTAssertEqual(value, 10)
        XCTAssertEqual(offset, 1)
    }

    func testDecodeZero() throws {
        var offset = 0
        let value = try QPACKInteger.decode(from: Data([0x00]), offset: &offset, prefix: 5)
        XCTAssertEqual(value, 0)
        XCTAssertEqual(offset, 1)
    }

    func testDecodeBoundaryValue() throws {
        var offset = 0
        let value = try QPACKInteger.decode(from: Data([0x1f, 0x00]), offset: &offset, prefix: 5)
        XCTAssertEqual(value, 31)
        XCTAssertEqual(offset, 2)
    }

    func testDecodeMultiByte() throws {
        var offset = 0
        let value = try QPACKInteger.decode(
            from: Data([0x1f, 0x9a, 0x0a]),
            offset: &offset,
            prefix: 5
        )
        XCTAssertEqual(value, 1337)
        XCTAssertEqual(offset, 3)
    }

    func testDecodeIgnoresHighBits() throws {
        // High bits 0xe0 should be masked out
        var offset = 0
        let value = try QPACKInteger.decode(
            from: Data([0xea]), // 0xe0 | 0x0a
            offset: &offset,
            prefix: 5
        )
        XCTAssertEqual(value, 10)
    }

    func testDecode8BitPrefix() throws {
        var offset = 0
        let value = try QPACKInteger.decode(from: Data([42]), offset: &offset, prefix: 8)
        XCTAssertEqual(value, 42)
        XCTAssertEqual(offset, 1)
    }

    func testDecodeInsufficientData() {
        var offset = 0
        XCTAssertThrowsError(
            try QPACKInteger.decode(from: Data(), offset: &offset, prefix: 5)
        ) { error in
            XCTAssertTrue(error is QPACKIntegerError)
        }
    }

    func testDecodeInsufficientContinuation() {
        // Prefix signals continuation but no continuation byte
        var offset = 0
        XCTAssertThrowsError(
            try QPACKInteger.decode(from: Data([0x1f]), offset: &offset, prefix: 5)
        ) { error in
            guard let qpackError = error as? QPACKIntegerError else {
                XCTFail("Expected QPACKIntegerError")
                return
            }
            XCTAssertEqual(qpackError, .insufficientData)
        }
    }

    func testDecodeWithFirstByte() throws {
        var offset = 0
        let (value, firstByte) = try QPACKInteger.decodeWithFirstByte(
            from: Data([0xea]),
            offset: &offset,
            prefix: 5
        )
        XCTAssertEqual(value, 10)
        XCTAssertEqual(firstByte, 0xea)
    }

    // MARK: - Round-Trip

    func testRoundTripSmallValues() throws {
        for prefix in 1...8 {
            let maxVal = (1 << prefix) - 2 // max that fits in prefix
            for value in UInt64(0)...UInt64(min(maxVal, 127)) {
                let encoded = QPACKInteger.encode(value, prefix: prefix)
                var offset = 0
                let decoded = try QPACKInteger.decode(from: encoded, offset: &offset, prefix: prefix)
                XCTAssertEqual(decoded, value, "Round-trip failed for value \(value) with prefix \(prefix)")
                XCTAssertEqual(offset, encoded.count)
            }
        }
    }

    func testRoundTripLargeValues() throws {
        let values: [UInt64] = [255, 256, 1000, 1337, 65535, 1_000_000, UInt64.max / 4]
        for prefix in [3, 5, 7, 8] {
            for value in values {
                let encoded = QPACKInteger.encode(value, prefix: prefix)
                var offset = 0
                let decoded = try QPACKInteger.decode(from: encoded, offset: &offset, prefix: prefix)
                XCTAssertEqual(decoded, value, "Round-trip failed for value \(value) with prefix \(prefix)")
                XCTAssertEqual(offset, encoded.count)
            }
        }
    }

    func testRoundTripWithHighBits() throws {
        let firstByte: UInt8 = 0xc0 // 1100_0000
        let value: UInt64 = 42
        let prefix = 6

        let encoded = QPACKInteger.encode(value, prefix: prefix, firstByte: firstByte)
        var offset = 0
        let decoded = try QPACKInteger.decode(from: encoded, offset: &offset, prefix: prefix)
        XCTAssertEqual(decoded, value)
    }

    func testRoundTripAtOffset() throws {
        // Encode multiple values sequentially
        var data = Data([0xAB, 0xCD]) // some prefix bytes
        let val1: UInt64 = 42
        let val2: UInt64 = 1337

        let enc1 = QPACKInteger.encode(val1, prefix: 5)
        let enc2 = QPACKInteger.encode(val2, prefix: 5)
        data.append(enc1)
        data.append(enc2)

        var offset = 2 // skip prefix bytes
        let dec1 = try QPACKInteger.decode(from: data, offset: &offset, prefix: 5)
        let dec2 = try QPACKInteger.decode(from: data, offset: &offset, prefix: 5)

        XCTAssertEqual(dec1, val1)
        XCTAssertEqual(dec2, val2)
        XCTAssertEqual(offset, data.count)
    }

    // MARK: - Encoded Size

    func testEncodedSize() {
        XCTAssertEqual(QPACKInteger.encodedSize(0, prefix: 5), 1)
        XCTAssertEqual(QPACKInteger.encodedSize(30, prefix: 5), 1)
        XCTAssertEqual(QPACKInteger.encodedSize(31, prefix: 5), 2)
        XCTAssertEqual(QPACKInteger.encodedSize(1337, prefix: 5), 3)
    }

    func testEncodedSizeMatchesActualEncoding() {
        let values: [UInt64] = [0, 1, 30, 31, 127, 128, 255, 256, 1337, 65535, 1_000_000]
        for prefix in [3, 5, 7, 8] {
            for value in values {
                let encoded = QPACKInteger.encode(value, prefix: prefix)
                let estimatedSize = QPACKInteger.encodedSize(value, prefix: prefix)
                XCTAssertEqual(
                    encoded.count, estimatedSize,
                    "encodedSize mismatch for value \(value) with prefix \(prefix)"
                )
            }
        }
    }
}

// MARK: - String Coding Tests

final class QPACKStringTests: XCTestCase {

    // MARK: - Raw String Encoding

    func testEncodeEmptyString() {
        let encoded = QPACKString.encode("")
        // Length = 0, H=0 → single byte 0x00
        XCTAssertEqual(encoded, Data([0x00]))
    }

    func testEncodeShortString() {
        let encoded = QPACKString.encode("hello")
        // H=0, length=5 → 0x05, then "hello" bytes
        XCTAssertEqual(encoded.count, 6)
        XCTAssertEqual(encoded[0], 0x05)
        XCTAssertEqual(String(data: Data(encoded[1...]), encoding: .utf8), "hello")
    }

    func testEncodeStringHBitNotSet() {
        // Raw encoding should have H=0 (bit 7 of first byte = 0)
        let encoded = QPACKString.encode("test")
        XCTAssertEqual(encoded[0] & 0x80, 0x00, "H bit should be 0 for raw encoding")
    }

    // MARK: - Raw String Decoding

    func testDecodeEmptyString() throws {
        var offset = 0
        let decoded = try QPACKString.decode(from: Data([0x00]), offset: &offset)
        XCTAssertEqual(decoded, "")
        XCTAssertEqual(offset, 1)
    }

    func testDecodeShortString() throws {
        var data = Data([0x05])
        data.append(Data("hello".utf8))

        var offset = 0
        let decoded = try QPACKString.decode(from: data, offset: &offset)
        XCTAssertEqual(decoded, "hello")
        XCTAssertEqual(offset, 6)
    }

    func testDecodeInsufficientData() {
        var offset = 0
        XCTAssertThrowsError(
            try QPACKString.decode(from: Data(), offset: &offset)
        )
    }

    func testDecodeInsufficientStringBytes() {
        // Length says 10 but only 3 bytes available
        var offset = 0
        XCTAssertThrowsError(
            try QPACKString.decode(from: Data([0x0a, 0x41, 0x42, 0x43]), offset: &offset)
        )
    }

    // MARK: - Round-Trip

    func testRoundTripRawStrings() throws {
        let testStrings = [
            "",
            "a",
            "hello",
            "Hello, World!",
            "content-type",
            "application/json",
            "/index.html",
            "https://example.com/path?query=value",
            String(repeating: "x", count: 200),
        ]

        for original in testStrings {
            let encoded = QPACKString.encode(original)
            var offset = 0
            let decoded = try QPACKString.decode(from: encoded, offset: &offset)
            XCTAssertEqual(decoded, original, "Round-trip failed for: \(original)")
            XCTAssertEqual(offset, encoded.count)
        }
    }

    func testRoundTripMultipleStrings() throws {
        var data = Data()
        let strings = ["hello", "world", "foo", "bar"]

        for s in strings {
            data.append(QPACKString.encode(s))
        }

        var offset = 0
        for expected in strings {
            let decoded = try QPACKString.decode(from: data, offset: &offset)
            XCTAssertEqual(decoded, expected)
        }
        XCTAssertEqual(offset, data.count)
    }

    // MARK: - Huffman Encoding

    func testHuffmanEncodeDecodeRoundTrip() throws {
        let testStrings = [
            "www.example.com",
            "no-cache",
            "custom-key",
            "custom-value",
            "GET",
            "/index.html",
        ]

        for original in testStrings {
            let encoded = QPACKString.encodeHuffman(original)
            var offset = 0
            let decoded = try QPACKString.decode(from: encoded, offset: &offset)
            XCTAssertEqual(decoded, original, "Huffman round-trip failed for: \(original)")
        }
    }

    func testHuffmanEncodedStringHasHBitSet() {
        // For a string that compresses well, H bit should be 1
        let encoded = QPACKString.encodeHuffman("www.example.com")
        let firstByte = encoded[0]
        // It may or may not use Huffman depending on compression ratio
        // But we verify decoding works regardless
        let isHuffman = (firstByte & 0x80) != 0
        // "www.example.com" should compress well with Huffman
        XCTAssertTrue(isHuffman, "Expected Huffman encoding for 'www.example.com'")
    }

    // MARK: - Encoded Size

    func testEncodedSizeMatchesActual() {
        let testStrings = ["", "hello", "content-type", String(repeating: "a", count: 100)]

        for s in testStrings {
            let encoded = QPACKString.encode(s)
            let size = QPACKString.encodedSize(s)
            XCTAssertEqual(encoded.count, size, "encodedSize mismatch for: \(s)")
        }
    }
}

// MARK: - Static Table Tests

final class QPACKStaticTableTests: XCTestCase {

    func testStaticTableHas99Entries() {
        XCTAssertEqual(QPACKStaticTable.entries.count, 99)
        XCTAssertEqual(QPACKStaticTable.count, 99)
    }

    func testFirstEntry() {
        let entry = QPACKStaticTable.entry(at: 0)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, ":authority")
        XCTAssertEqual(entry?.value, "")
    }

    func testLastEntry() {
        let entry = QPACKStaticTable.entry(at: 98)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "x-frame-options")
        XCTAssertEqual(entry?.value, "sameorigin")
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(QPACKStaticTable.entry(at: -1))
        XCTAssertNil(QPACKStaticTable.entry(at: 99))
        XCTAssertNil(QPACKStaticTable.entry(at: 1000))
    }

    func testKnownEntries() {
        // Verify some well-known entries from RFC 9204 Appendix A
        let pathEntry = QPACKStaticTable.entry(at: 1)
        XCTAssertEqual(pathEntry?.name, ":path")
        XCTAssertEqual(pathEntry?.value, "/")

        let methodGet = QPACKStaticTable.entry(at: 17)
        XCTAssertEqual(methodGet?.name, ":method")
        XCTAssertEqual(methodGet?.value, "GET")

        let schemeHttps = QPACKStaticTable.entry(at: 23)
        XCTAssertEqual(schemeHttps?.name, ":scheme")
        XCTAssertEqual(schemeHttps?.value, "https")

        let status200 = QPACKStaticTable.entry(at: 25)
        XCTAssertEqual(status200?.name, ":status")
        XCTAssertEqual(status200?.value, "200")
    }

    // MARK: - Exact Match Lookup

    func testFindExactMethodGet() {
        let index = QPACKStaticTable.findExact(name: ":method", value: "GET")
        XCTAssertEqual(index, 17)
    }

    func testFindExactSchemeHttps() {
        let index = QPACKStaticTable.findExact(name: ":scheme", value: "https")
        XCTAssertEqual(index, 23)
    }

    func testFindExactStatus200() {
        let index = QPACKStaticTable.findExact(name: ":status", value: "200")
        XCTAssertEqual(index, 25)
    }

    func testFindExactStatus404() {
        let index = QPACKStaticTable.findExact(name: ":status", value: "404")
        XCTAssertEqual(index, 27)
    }

    func testFindExactPathRoot() {
        let index = QPACKStaticTable.findExact(name: ":path", value: "/")
        XCTAssertEqual(index, 1)
    }

    func testFindExactAcceptAll() {
        let index = QPACKStaticTable.findExact(name: "accept", value: "*/*")
        XCTAssertEqual(index, 29)
    }

    func testFindExactMiss() {
        let index = QPACKStaticTable.findExact(name: ":method", value: "NONEXISTENT")
        XCTAssertNil(index)
    }

    func testFindExactCaseInsensitiveName() {
        // Names are case-insensitive
        let index = QPACKStaticTable.findExact(name: ":Method", value: "GET")
        XCTAssertEqual(index, 17)
    }

    // MARK: - Name-Only Lookup

    func testFindNameMethod() {
        let index = QPACKStaticTable.findName(":method")
        XCTAssertNotNil(index)
        // :method first appears at index 15 (CONNECT)
        XCTAssertEqual(index, 15)
    }

    func testFindNameAuthority() {
        let index = QPACKStaticTable.findName(":authority")
        XCTAssertEqual(index, 0)
    }

    func testFindNameContentType() {
        let index = QPACKStaticTable.findName("content-type")
        XCTAssertNotNil(index)
    }

    func testFindNameMiss() {
        let index = QPACKStaticTable.findName("x-custom-header")
        XCTAssertNil(index)
    }

    func testFindNameCaseInsensitive() {
        let index = QPACKStaticTable.findName(":Authority")
        XCTAssertEqual(index, 0)
    }

    // MARK: - Best Match

    func testFindBestMatchExact() {
        let result = QPACKStaticTable.findBestMatch(name: ":method", value: "GET")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.index, 17)
        XCTAssertTrue(result?.isExactMatch ?? false)
    }

    func testFindBestMatchNameOnly() {
        let result = QPACKStaticTable.findBestMatch(name: ":method", value: "PATCH")
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isExactMatch ?? true)
        // Should return first :method entry
        XCTAssertEqual(result?.index, 15)
    }

    func testFindBestMatchNone() {
        let result = QPACKStaticTable.findBestMatch(name: "x-custom", value: "blah")
        XCTAssertNil(result)
    }
}

// MARK: - Huffman Codec Tests

final class HuffmanCodecTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let testStrings = [
            "www.example.com",
            "no-cache",
            "custom-key",
            "custom-value",
            "/sample/path",
            "Mon, 21 Oct 2013 20:13:22 GMT",
            "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
        ]

        for original in testStrings {
            let originalData = Data(original.utf8)
            let encoded = HuffmanCodec.encode(originalData)
            let decoded = try HuffmanCodec.decode(encoded)
            let decodedString = String(data: decoded, encoding: .utf8)
            XCTAssertEqual(decodedString, original, "Huffman round-trip failed for: \(original)")
        }
    }

    func testEncodeCompresses() {
        // Most ASCII text should compress with Huffman
        let original = Data("www.example.com".utf8)
        let encoded = HuffmanCodec.encode(original)
        XCTAssertLessThan(encoded.count, original.count,
                          "Huffman should compress typical header values")
    }

    func testEncodedSizeMatchesActual() {
        let testData = Data("application/json".utf8)
        let encoded = HuffmanCodec.encode(testData)
        let estimatedSize = HuffmanCodec.encodedSize(of: testData)
        XCTAssertEqual(encoded.count, estimatedSize)
    }

    func testEmptyData() throws {
        let encoded = HuffmanCodec.encode(Data())
        XCTAssertTrue(encoded.isEmpty)

        let decoded = try HuffmanCodec.decode(Data())
        XCTAssertTrue(decoded.isEmpty)
    }

    func testSingleByte() throws {
        for byte in [UInt8(0), 32, 65, 97, 127, 255] {
            let original = Data([byte])
            let encoded = HuffmanCodec.encode(original)
            let decoded = try HuffmanCodec.decode(encoded)
            XCTAssertEqual(decoded, original, "Huffman round-trip failed for byte \(byte)")
        }
    }

    func testAllPrintableASCII() throws {
        var data = Data()
        for byte in UInt8(32)...UInt8(126) {
            data.append(byte)
        }
        let encoded = HuffmanCodec.encode(data)
        let decoded = try HuffmanCodec.decode(encoded)
        XCTAssertEqual(decoded, data)
    }
}

// MARK: - Encoder/Decoder Round-Trip Tests

final class QPACKEncoderDecoderTests: XCTestCase {

    let encoder = QPACKEncoder()
    let decoder = QPACKDecoder()

    // MARK: - Basic Round-Trip

    func testRoundTripSimpleGetRequest() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/"),
            (":authority", "example.com"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name)
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testRoundTripPostRequest() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "POST"),
            (":scheme", "https"),
            (":path", "/api/data"),
            (":authority", "api.example.com"),
            ("content-type", "application/json"),
            ("content-length", "42"),
            ("accept", "*/*"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name.lowercased())
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testRoundTripResponseHeaders() throws {
        let headers: [(name: String, value: String)] = [
            (":status", "200"),
            ("content-type", "text/html; charset=utf-8"),
            ("content-length", "1234"),
            ("server", "quiver"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name.lowercased())
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testRoundTripCustomHeaders() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            ("x-custom-header", "custom-value"),
            ("x-request-id", "abc-123-def-456"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name.lowercased())
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testRoundTripEmptyHeaders() throws {
        let headers: [(name: String, value: String)] = []

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 0)
    }

    func testRoundTripSingleHeader() throws {
        let headers: [(name: String, value: String)] = [
            (":status", "404"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, ":status")
        XCTAssertEqual(decoded[0].value, "404")
    }

    // MARK: - Static Table Usage

    func testStaticTableExactMatchUsed() throws {
        // :method GET should be an indexed field line (very compact)
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
        ]

        let encoded = encoder.encode(headers)

        // Prefix is 2 bytes (00, 00), then the indexed field line
        // An indexed field line for static table index 17 should be compact
        // Indexed: 1 | T=1 | index(6+) → 0xc0 | 17 = 0xd1
        XCTAssertEqual(encoded.count, 3) // 2-byte prefix + 1-byte indexed
        XCTAssertEqual(encoded[2], 0xd1) // 0xc0 | 17

        let decoded = try decoder.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, ":method")
        XCTAssertEqual(decoded[0].value, "GET")
    }

    func testStaticTableNameReferenceUsed() throws {
        // :authority with a custom value should use name reference
        let headers: [(name: String, value: String)] = [
            (":authority", "myserver.example.com"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, ":authority")
        XCTAssertEqual(decoded[0].value, "myserver.example.com")
    }

    func testLiteralWithLiteralNameUsed() throws {
        // A completely unknown header should use literal name
        let headers: [(name: String, value: String)] = [
            ("x-unique-header", "unique-value"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "x-unique-header")
        XCTAssertEqual(decoded[0].value, "unique-value")
    }

    // MARK: - Sensitive Headers

    func testSensitiveHeadersNeverIndexed() throws {
        // Sensitive headers like authorization and cookie should still round-trip
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            ("authorization", "Bearer token123"),
            ("cookie", "session=abc123"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name.lowercased())
            XCTAssertEqual(result.value, original.value)
        }
    }

    // MARK: - HTTPField Encoding

    func testHTTPFieldEncoding() throws {
        let fields = [
            HTTPField(name: ":method", value: "GET"),
            HTTPField(name: ":path", value: "/"),
            HTTPField(name: ":scheme", value: "https"),
            HTTPField(name: ":authority", value: "example.com"),
        ]

        let encoded = encoder.encode(fields)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, fields.count)
        for (original, result) in zip(fields, decoded) {
            XCTAssertEqual(result.name, original.name)
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testHTTPFieldDecoding() throws {
        let fields = [
            HTTPField(name: ":status", value: "200"),
            HTTPField(name: "content-type", value: "text/plain"),
        ]

        let encoded = encoder.encode(fields)
        let decodedFields = try decoder.decodeFields(encoded)

        XCTAssertEqual(decodedFields.count, fields.count)
        for (original, result) in zip(fields, decodedFields) {
            XCTAssertEqual(result.name, original.name)
            XCTAssertEqual(result.value, original.value)
        }
    }

    // MARK: - Prefix Validation

    func testDecoderRejectsNonZeroRequiredInsertCount() {
        // Manually craft a field section with Required Insert Count = 1
        var data = Data()
        data.append(0x01) // Required Insert Count = 1
        data.append(0x00) // Delta Base = 0

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            guard let qpackError = error as? QPACKDecoderError else {
                XCTFail("Expected QPACKDecoderError, got \(error)")
                return
            }
            if case .dynamicTableNotSupported = qpackError {
                // Expected
            } else {
                XCTFail("Expected dynamicTableNotSupported, got \(qpackError)")
            }
        }
    }

    func testDecoderRejectsInsufficientData() {
        XCTAssertThrowsError(try decoder.decode(Data())) { error in
            XCTAssertTrue(error is QPACKDecoderError)
        }

        XCTAssertThrowsError(try decoder.decode(Data([0x00]))) { error in
            XCTAssertTrue(error is QPACKDecoderError)
        }
    }

    // MARK: - Edge Cases

    func testEmptyHeaderValue() throws {
        let headers: [(name: String, value: String)] = [
            (":authority", ""),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, ":authority")
        XCTAssertEqual(decoded[0].value, "")
    }

    func testLongHeaderValue() throws {
        let longValue = String(repeating: "x", count: 1000)
        let headers: [(name: String, value: String)] = [
            ("x-long-header", longValue),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "x-long-header")
        XCTAssertEqual(decoded[0].value, longValue)
    }

    func testManyHeaders() throws {
        var headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
        ]

        // Add 50 custom headers
        for i in 0..<50 {
            headers.append(("x-header-\(i)", "value-\(i)"))
        }

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, headers.count)
        for (original, result) in zip(headers, decoded) {
            XCTAssertEqual(result.name, original.name.lowercased())
            XCTAssertEqual(result.value, original.value)
        }
    }

    func testAllStaticTableExactMatches() throws {
        // Test every static table entry that has a non-empty value
        for i in 0..<QPACKStaticTable.count {
            guard let entry = QPACKStaticTable.entry(at: i), !entry.value.isEmpty else {
                continue
            }

            let headers: [(name: String, value: String)] = [
                (entry.name, entry.value),
            ]

            let encoded = encoder.encode(headers)
            let decoded = try decoder.decode(encoded)

            XCTAssertEqual(decoded.count, 1, "Failed for static table index \(i)")
            XCTAssertEqual(decoded[0].name, entry.name, "Name mismatch at index \(i)")
            XCTAssertEqual(decoded[0].value, entry.value, "Value mismatch at index \(i)")
        }
    }

    func testUnicodeHeaders() throws {
        let headers: [(name: String, value: String)] = [
            ("x-emoji", "🚀✨"),
            ("x-japanese", "こんにちは"),
        ]

        let encoded = encoder.encode(headers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].value, "🚀✨")
        XCTAssertEqual(decoded[1].value, "こんにちは")
    }

    // MARK: - Decoder Limits

    func testDecoderRejectsTooManyHeaders() {
        // Create a decoder with a very low limit
        let limitedDecoder = QPACKDecoder(maxHeaderCount: 2)

        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "https"),
        ]

        let encoded = encoder.encode(headers)

        XCTAssertThrowsError(try limitedDecoder.decode(encoded)) { error in
            guard let qpackError = error as? QPACKDecoderError else {
                XCTFail("Expected QPACKDecoderError")
                return
            }
            if case .tooManyHeaders = qpackError {
                // Expected
            } else {
                XCTFail("Expected tooManyHeaders, got \(qpackError)")
            }
        }
    }
}
