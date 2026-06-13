/// TLS 1.3 Key Exchange Tests

import Testing
import Foundation
import Crypto
@testable import QUICCrypto

@Suite("Key Exchange Tests")
struct KeyExchangeTests {

    // MARK: - X25519 Tests

    @Test("Generate X25519 key pair")
    func generateX25519() throws {
        let keyExchange = try KeyExchange.generate(for: .x25519)

        #expect(keyExchange.group == .x25519)
        #expect(keyExchange.publicKeyBytes.count == 32)
    }

    @Test("X25519 key agreement")
    func x25519KeyAgreement() throws {
        let alice = try KeyExchange.generate(for: .x25519)
        let bob = try KeyExchange.generate(for: .x25519)

        let aliceShared = try alice.sharedSecret(with: bob.publicKeyBytes)
        let bobShared = try bob.sharedSecret(with: alice.publicKeyBytes)

        #expect(aliceShared.rawRepresentation == bobShared.rawRepresentation)
    }

    @Test("X25519 KeyShareEntry")
    func x25519KeyShareEntry() throws {
        let keyExchange = try KeyExchange.generate(for: .x25519)
        let entry = keyExchange.keyShareEntry()

        #expect(entry.group == .x25519)
        #expect(entry.keyExchange == keyExchange.publicKeyBytes)
    }

    // MARK: - P-256 Tests

    @Test("Generate P-256 key pair")
    func generateP256() throws {
        let keyExchange = try KeyExchange.generate(for: .secp256r1)

        #expect(keyExchange.group == .secp256r1)
        #expect(keyExchange.publicKeyBytes.count == 65) // Uncompressed point
        #expect(keyExchange.publicKeyBytes[0] == 0x04) // Uncompressed point prefix
    }

    @Test("P-256 key agreement")
    func p256KeyAgreement() throws {
        let alice = try KeyExchange.generate(for: .secp256r1)
        let bob = try KeyExchange.generate(for: .secp256r1)

        let aliceShared = try alice.sharedSecret(with: bob.publicKeyBytes)
        let bobShared = try bob.sharedSecret(with: alice.publicKeyBytes)

        #expect(aliceShared.rawRepresentation == bobShared.rawRepresentation)
    }

    @Test("P-256 KeyShareEntry")
    func p256KeyShareEntry() throws {
        let keyExchange = try KeyExchange.generate(for: .secp256r1)
        let entry = keyExchange.keyShareEntry()

        #expect(entry.group == .secp256r1)
        #expect(entry.keyExchange == keyExchange.publicKeyBytes)
    }

    // MARK: - Static Key Agreement

    @Test("Perform key agreement with peer public key")
    func performKeyAgreement() throws {
        // Generate peer's key pair
        let peerKeyExchange = try KeyExchange.generate(for: .x25519)
        let peerPublicKey = peerKeyExchange.publicKeyBytes

        // Perform key agreement
        let (sharedSecret, ourPublicKey) = try KeyExchange.performKeyAgreement(
            group: .x25519,
            peerPublicKeyBytes: peerPublicKey
        )

        // Verify by having peer compute the same shared secret
        let peerSharedSecret = try peerKeyExchange.sharedSecret(with: ourPublicKey)

        #expect(sharedSecret.rawRepresentation == peerSharedSecret.rawRepresentation)
    }

    // MARK: - Error Cases

    @Test("Unsupported group throws error")
    func unsupportedGroup() throws {
        #expect(throws: KeyExchangeError.self) {
            _ = try KeyExchange.generate(for: .secp384r1)
        }
    }

    @Test("Invalid X25519 public key throws error")
    func invalidX25519PublicKey() throws {
        let keyExchange = try KeyExchange.generate(for: .x25519)

        // Wrong length
        #expect(throws: KeyExchangeError.self) {
            _ = try keyExchange.sharedSecret(with: Data(repeating: 0x42, count: 16))
        }
    }

    // MARK: - SharedSecret Extension

    @Test("SharedSecret raw representation")
    func sharedSecretRawRepresentation() throws {
        let alice = try KeyExchange.generate(for: .x25519)
        let bob = try KeyExchange.generate(for: .x25519)

        let sharedSecret = try alice.sharedSecret(with: bob.publicKeyBytes)
        let rawData = sharedSecret.rawRepresentation

        #expect(rawData.count == 32) // X25519 shared secret is 32 bytes
    }
}

// MARK: - Signature Tests

@Suite("Signature Tests")
struct SignatureTests {

    @Test("Generate P-256 signing key")
    func generateSigningKey() throws {
        let signingKey = SigningKey.generateP256()

        #expect(signingKey.scheme == .ecdsa_secp256r1_sha256)
        #expect(signingKey.publicKeyBytes.count == 65) // x963 representation
    }

    @Test("Sign and verify")
    func signAndVerify() throws {
        let signingKey = SigningKey.generateP256()
        let data = Data("Hello, TLS 1.3!".utf8)

        let signature = try signingKey.sign(data)

        // Create verification key from public key bytes
        let verificationKey = try VerificationKey(
            publicKeyBytes: signingKey.publicKeyBytes,
            scheme: signingKey.scheme
        )

        let isValid = try verificationKey.verify(signature: signature, for: data)
        #expect(isValid == true)
    }

    @Test("Verification fails for wrong data")
    func verificationFails() throws {
        let signingKey = SigningKey.generateP256()
        let data = Data("Original data".utf8)
        let wrongData = Data("Wrong data".utf8)

        let signature = try signingKey.sign(data)

        let verificationKey = try VerificationKey(
            publicKeyBytes: signingKey.publicKeyBytes,
            scheme: signingKey.scheme
        )

        let isValid = try verificationKey.verify(signature: signature, for: wrongData)
        #expect(isValid == false)
    }

    @Test("CertificateVerify content construction")
    func certificateVerifyContent() throws {
        let transcriptHash = Data(repeating: 0xAA, count: 32)

        let serverContent = TLSSignature.certificateVerifyContent(
            transcriptHash: transcriptHash,
            isServer: true
        )

        let clientContent = TLSSignature.certificateVerifyContent(
            transcriptHash: transcriptHash,
            isServer: false
        )

        // Content should start with 64 spaces
        #expect(serverContent.prefix(64) == Data(repeating: 0x20, count: 64))
        #expect(clientContent.prefix(64) == Data(repeating: 0x20, count: 64))

        // Server and client content should be different (different context strings)
        #expect(serverContent != clientContent)

        // Both should end with the transcript hash
        #expect(serverContent.suffix(32) == transcriptHash)
        #expect(clientContent.suffix(32) == transcriptHash)
    }
}
