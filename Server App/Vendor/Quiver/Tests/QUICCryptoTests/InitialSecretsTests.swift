import Testing
import Foundation
@testable import QUICCore
@testable import QUICCrypto

@Suite("Initial Secrets Tests")
struct InitialSecretsTests {

    @Test("Derive initial secrets from connection ID")
    func deriveInitialSecrets() throws {
        // Test vector from RFC 9001 Appendix A
        // Client DCID: 0x8394c8f03e515708
        let dcid = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))

        let secrets = try InitialSecrets.derive(connectionID: dcid, version: .v1)

        // The secrets should be derived successfully
        // Actual values can be verified against RFC 9001 test vectors
        #expect(secrets.clientSecret.bitCount == 256)
        #expect(secrets.serverSecret.bitCount == 256)
    }

    @Test("Derive key material from secret")
    func deriveKeyMaterial() throws {
        let dcid = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let secrets = try InitialSecrets.derive(connectionID: dcid, version: .v1)

        let clientKeys = try KeyMaterial.derive(from: secrets.clientSecret)

        // AES-128-GCM key is 16 bytes
        #expect(clientKeys.key.bitCount == 128)
        // IV is 12 bytes
        #expect(clientKeys.iv.count == 12)
        // Header protection key is 16 bytes
        #expect(clientKeys.hp.bitCount == 128)
    }

    @Test("Version 2 uses different salt")
    func version2Salt() throws {
        let dcid = try #require(ConnectionID.random(length: 8))

        let v1Secrets = try InitialSecrets.derive(connectionID: dcid, version: .v1)
        let v2Secrets = try InitialSecrets.derive(connectionID: dcid, version: .v2)

        // Different versions should produce different secrets
        // (comparing by deriving key material and checking they differ)
        let v1Keys = try KeyMaterial.derive(from: v1Secrets.clientSecret)
        let v2Keys = try KeyMaterial.derive(from: v2Secrets.clientSecret)

        #expect(v1Keys.iv != v2Keys.iv)
    }
}
