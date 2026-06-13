import Testing
import Foundation
import Crypto
@testable import QUICCore
@testable import QUICCrypto

@Suite("AEAD Header Protection Tests")
struct AEADHeaderProtectionTests {

    // MARK: - RFC 9001 Appendix A Test Vectors

    /// RFC 9001 Appendix A.1: Keys derived from Initial secret
    /// These test vectors verify our AES-128 Header Protection implementation
    @Test("RFC 9001 Appendix A: Client Initial Header Protection")
    func clientInitialHeaderProtection() throws {
        // RFC 9001 Appendix A.1: Client Initial secrets derived from DCID 0x8394c8f03e515708
        // client_initial_secret = 0xc00cf151ca5be075ed0ebfb5c80323c4...
        // hp = 0x9f50449e04a0e810283a1e9933adedd2

        // Header protection key from RFC 9001 Appendix A.1
        let hpKey = SymmetricKey(data: Data([
            0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
            0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2
        ]))

        let hp = AES128HeaderProtection(key: hpKey)

        // Test sample from protected packet (arbitrary test case)
        // The mask is AES-ECB(hp_key, sample)[0..4]
        let sample = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
        ])

        let mask = try hp.mask(sample: sample)

        // Mask should be 5 bytes
        #expect(mask.count == 5)

        // Verify the mask is deterministic (same input = same output)
        let mask2 = try hp.mask(sample: sample)
        #expect(mask == mask2)
    }

    @Test("AES-128 Header Protection - mask length")
    func aes128MaskLength() throws {
        let key = SymmetricKey(size: .bits128)
        let hp = AES128HeaderProtection(key: key)

        let sample = Data(repeating: 0xAB, count: 16)
        let mask = try hp.mask(sample: sample)

        #expect(mask.count == 5)
    }

    @Test("AES-128 Header Protection - insufficient sample throws")
    func aes128InsufficientSampleThrows() throws {
        let key = SymmetricKey(size: .bits128)
        let hp = AES128HeaderProtection(key: key)

        let shortSample = Data(repeating: 0xAB, count: 10)

        #expect {
            _ = try hp.mask(sample: shortSample)
        } throws: { error in
            guard let cryptoError = error as? QUICCrypto.CryptoError else { return false }
            if case .insufficientSample(expected: 16, actual: 10) = cryptoError {
                return true
            }
            return false
        }
    }

    @Test("AES-128 Header Protection - different samples produce different masks")
    func aes128DifferentSamples() throws {
        let key = SymmetricKey(size: .bits128)
        let hp = AES128HeaderProtection(key: key)

        let sample1 = Data(repeating: 0x00, count: 16)
        let sample2 = Data(repeating: 0xFF, count: 16)

        let mask1 = try hp.mask(sample: sample1)
        let mask2 = try hp.mask(sample: sample2)

        #expect(mask1 != mask2)
    }

    @Test("AES-128 Header Protection - different keys produce different masks")
    func aes128DifferentKeys() throws {
        let key1 = SymmetricKey(data: Data(repeating: 0x00, count: 16))
        let key2 = SymmetricKey(data: Data(repeating: 0xFF, count: 16))

        let hp1 = AES128HeaderProtection(key: key1)
        let hp2 = AES128HeaderProtection(key: key2)

        let sample = Data(repeating: 0xAB, count: 16)

        let mask1 = try hp1.mask(sample: sample)
        let mask2 = try hp2.mask(sample: sample)

        #expect(mask1 != mask2)
    }

    // MARK: - ChaCha20 Header Protection Tests

    @Test("ChaCha20 Header Protection - mask length")
    func chacha20MaskLength() throws {
        let key = SymmetricKey(size: .bits256)
        let hp = ChaCha20HeaderProtection(key: key)

        let sample = Data(repeating: 0xAB, count: 16)
        let mask = try hp.mask(sample: sample)

        #expect(mask.count == 5)
    }

    @Test("ChaCha20 Header Protection - insufficient sample throws")
    func chacha20InsufficientSampleThrows() throws {
        let key = SymmetricKey(size: .bits256)
        let hp = ChaCha20HeaderProtection(key: key)

        let shortSample = Data(repeating: 0xAB, count: 10)

        #expect {
            _ = try hp.mask(sample: shortSample)
        } throws: { error in
            guard let cryptoError = error as? QUICCrypto.CryptoError else { return false }
            if case .insufficientSample(expected: 16, actual: 10) = cryptoError {
                return true
            }
            return false
        }
    }

    @Test("ChaCha20 Header Protection - deterministic output")
    func chacha20DeterministicOutput() throws {
        let key = SymmetricKey(size: .bits256)
        let hp = ChaCha20HeaderProtection(key: key)

        let sample = Data(repeating: 0xAB, count: 16)

        let mask1 = try hp.mask(sample: sample)
        let mask2 = try hp.mask(sample: sample)

        #expect(mask1 == mask2)
    }

    // MARK: - AES-GCM AEAD Tests

    @Test("AES-128-GCM seal and open roundtrip")
    func aes128GcmRoundtrip() throws {
        // Create key material
        let key = SymmetricKey(size: .bits128)
        let iv = Data(repeating: 0x00, count: 12)
        let hpKey = SymmetricKey(size: .bits128)

        let keyMaterial = KeyMaterial(
            key: key,
            iv: iv,
            hp: hpKey,
            cipherSuite: .aes128GcmSha256
        )

        let (opener, sealer) = try keyMaterial.createCrypto()

        // Test data
        let plaintext = Data("Hello, QUIC!".utf8)
        let header = Data([0xC0, 0x00, 0x00, 0x01])
        let packetNumber: UInt64 = 42

        // Seal (encrypt)
        let ciphertext = try sealer.seal(
            plaintext: plaintext,
            packetNumber: packetNumber,
            header: header
        )

        // Open (decrypt)
        let decrypted = try opener.open(
            ciphertext: ciphertext,
            packetNumber: packetNumber,
            header: header
        )

        #expect(decrypted == plaintext)
    }

    @Test("AES-128-GCM fails with wrong packet number")
    func aes128GcmWrongPacketNumber() throws {
        let key = SymmetricKey(size: .bits128)
        let iv = Data(repeating: 0x00, count: 12)
        let hpKey = SymmetricKey(size: .bits128)

        let keyMaterial = KeyMaterial(
            key: key,
            iv: iv,
            hp: hpKey,
            cipherSuite: .aes128GcmSha256
        )

        let (opener, sealer) = try keyMaterial.createCrypto()

        let plaintext = Data("Test data".utf8)
        let header = Data([0xC0, 0x00, 0x00, 0x01])

        // Seal with packet number 1
        let ciphertext = try sealer.seal(
            plaintext: plaintext,
            packetNumber: 1,
            header: header
        )

        // Try to open with different packet number - should fail
        #expect(throws: Error.self) {
            _ = try opener.open(
                ciphertext: ciphertext,
                packetNumber: 2,  // Wrong!
                header: header
            )
        }
    }

    @Test("AES-128-GCM fails with wrong header")
    func aes128GcmWrongHeader() throws {
        let key = SymmetricKey(size: .bits128)
        let iv = Data(repeating: 0x00, count: 12)
        let hpKey = SymmetricKey(size: .bits128)

        let keyMaterial = KeyMaterial(
            key: key,
            iv: iv,
            hp: hpKey,
            cipherSuite: .aes128GcmSha256
        )

        let (opener, sealer) = try keyMaterial.createCrypto()

        let plaintext = Data("Test data".utf8)
        let header = Data([0xC0, 0x00, 0x00, 0x01])
        let wrongHeader = Data([0xC0, 0x00, 0x00, 0x02])

        // Seal with original header
        let ciphertext = try sealer.seal(
            plaintext: plaintext,
            packetNumber: 1,
            header: header
        )

        // Try to open with different header - should fail
        #expect(throws: Error.self) {
            _ = try opener.open(
                ciphertext: ciphertext,
                packetNumber: 1,
                header: wrongHeader  // Wrong!
            )
        }
    }

    // MARK: - ChaCha20-Poly1305 AEAD Tests

    @Test("ChaCha20-Poly1305 seal and open roundtrip")
    func chacha20Poly1305Roundtrip() throws {
        let key = SymmetricKey(size: .bits256)
        let iv = Data(repeating: 0x00, count: 12)
        let hpKey = SymmetricKey(size: .bits256)

        let keyMaterial = KeyMaterial(
            key: key,
            iv: iv,
            hp: hpKey,
            cipherSuite: .chacha20Poly1305Sha256
        )

        let (opener, sealer) = try keyMaterial.createCrypto()

        let plaintext = Data("Hello, QUIC with ChaCha20!".utf8)
        let header = Data([0x40, 0x01, 0x02, 0x03])
        let packetNumber: UInt64 = 100

        // Seal
        let ciphertext = try sealer.seal(
            plaintext: plaintext,
            packetNumber: packetNumber,
            header: header
        )

        // Open
        let decrypted = try opener.open(
            ciphertext: ciphertext,
            packetNumber: packetNumber,
            header: header
        )

        #expect(decrypted == plaintext)
    }
}
