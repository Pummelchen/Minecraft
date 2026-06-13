import Testing
import Foundation
@testable import QUICCrypto

@Suite("ChaCha20 Tests")
struct ChaCha20Tests {

    // MARK: - RFC 8439 Section 2.3.2 Test Vector

    @Test("ChaCha20 block function - RFC 8439 Section 2.3.2")
    func testChaCha20BlockRFC8439() throws {
        // Test vector from RFC 8439 Section 2.3.2
        let key = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
            0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
        ])

        let nonce = Data([
            0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a,
            0x00, 0x00, 0x00, 0x00
        ])

        let counter: UInt32 = 1

        let output = try chaCha20Block(key: key, counter: counter, nonce: nonce)

        // Expected output from RFC 8439 Section 2.3.2
        let expected = Data([
            0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15,
            0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
            0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03,
            0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
            0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09,
            0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
            0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9,
            0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e
        ])

        #expect(output == expected)
    }

    // MARK: - RFC 9001 Appendix A.5 Test Vector

    @Test("ChaCha20 header protection - RFC 9001 Appendix A.5")
    func testChaCha20HeaderProtectionRFC9001() throws {
        // Test vector from RFC 9001 Appendix A.5
        // ChaCha20-Poly1305 Short Header Packet

        // Header protection key (hp)
        let hpKey = Data([
            0x25, 0xa2, 0x82, 0xb9, 0xe8, 0x2f, 0x06, 0xf2,
            0x1f, 0x48, 0x89, 0x17, 0xa4, 0xfc, 0x8f, 0x1b,
            0x73, 0x57, 0x36, 0x85, 0x60, 0x85, 0x97, 0xd0,
            0xef, 0xcb, 0x07, 0x6b, 0x0a, 0xb7, 0xa7, 0xa4
        ])

        // Sample from the encrypted packet
        let sample = Data([
            0x5e, 0x5c, 0xd5, 0x5c, 0x41, 0xf6, 0x90, 0x80,
            0x57, 0x5d, 0x79, 0x99, 0xc2, 0x5a, 0x5b, 0xfb
        ])

        let mask = try chaCha20HeaderProtectionMask(key: hpKey, sample: sample)

        // Expected mask (first 5 bytes of keystream)
        let expectedMask = Data([0xae, 0xfe, 0xfe, 0x7d, 0x03])

        #expect(mask == expectedMask)
    }

    // MARK: - Error Handling Tests

    @Test("ChaCha20 block rejects invalid key length")
    func testInvalidKeyLength() {
        let shortKey = Data(count: 16)  // Should be 32
        let nonce = Data(count: 12)

        #expect(throws: ChaCha20Error.self) {
            _ = try chaCha20Block(key: shortKey, counter: 0, nonce: nonce)
        }
    }

    @Test("ChaCha20 block rejects invalid nonce length")
    func testInvalidNonceLength() {
        let key = Data(count: 32)
        let shortNonce = Data(count: 8)  // Should be 12

        #expect(throws: ChaCha20Error.self) {
            _ = try chaCha20Block(key: key, counter: 0, nonce: shortNonce)
        }
    }

    @Test("ChaCha20 header protection rejects short sample")
    func testInvalidSampleLength() {
        let key = Data(count: 32)
        let shortSample = Data(count: 8)  // Should be at least 16

        #expect(throws: ChaCha20Error.self) {
            _ = try chaCha20HeaderProtectionMask(key: key, sample: shortSample)
        }
    }

    // MARK: - Determinism Test

    @Test("ChaCha20 produces deterministic output")
    func testDeterminism() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 12)
        let counter: UInt32 = 12345

        let output1 = try chaCha20Block(key: key, counter: counter, nonce: nonce)
        let output2 = try chaCha20Block(key: key, counter: counter, nonce: nonce)

        #expect(output1 == output2)
        #expect(output1.count == 64)
    }

    // MARK: - Counter Variation Test

    @Test("Different counters produce different output")
    func testCounterVariation() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 12)

        let output0 = try chaCha20Block(key: key, counter: 0, nonce: nonce)
        let output1 = try chaCha20Block(key: key, counter: 1, nonce: nonce)

        #expect(output0 != output1)
    }
}
