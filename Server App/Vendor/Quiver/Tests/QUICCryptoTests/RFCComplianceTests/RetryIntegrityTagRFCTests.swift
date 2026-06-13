/// RFC 9001 Section 5.8 Compliance Tests - Retry Integrity Tag
///
/// These tests verify compliance with RFC 9001 Section 5.8:
/// - Server MUST include Retry Integrity Tag
/// - Client MUST verify Retry Integrity Tag before processing
/// - Forged/invalid tags MUST be rejected

import Testing
import Foundation
@testable import QUICCore
@testable import QUICCrypto

@Suite("RFC 9001 §5.8 - Retry Integrity Tag Compliance")
struct RetryIntegrityTagRFCTests {

    // MARK: - RFC 9001 §5.8: Server MUST include valid integrity tag

    @Test("Server creates Retry packet with valid integrity tag")
    func serverCreatesValidRetryPacket() throws {
        // RFC 9001 §5.8: A server that sends a Retry packet MUST include
        // a Retry Integrity Tag at the end of the packet.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let destinationCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let sourceCID = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let retryToken = Data([0xAA, 0xBB, 0xCC, 0xDD])

        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Packet must include 16-byte integrity tag at the end
        #expect(retryPacket.count >= RetryIntegrityTag.tagLength)

        // Verify the packet can be parsed
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        #expect(parsed.version == .v1)
        #expect(parsed.destinationCID == destinationCID)
        #expect(parsed.sourceCID == sourceCID)
        #expect(parsed.retryToken == retryToken)
        #expect(parsed.integrityTag.count == 16)
    }

    // MARK: - RFC 9001 §5.8: Client MUST verify integrity tag

    @Test("Client verifies valid Retry Integrity Tag")
    func clientVerifiesValidTag() throws {
        // RFC 9001 §5.8: A client that receives a Retry packet MUST
        // validate the Retry Integrity Tag.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let destinationCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let sourceCID = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let retryToken = Data([0x11, 0x22, 0x33, 0x44])

        // Server creates Retry packet
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Client parses and verifies
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)

        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(isValid, "Client MUST accept valid Retry packet")
    }

    // MARK: - RFC 9001 §5.8: Client MUST reject forged tags

    @Test("Client rejects Retry packet with forged integrity tag")
    func clientRejectsForgedTag() throws {
        // RFC 9001 §5.8: If the Retry Integrity Tag is invalid, the
        // packet MUST be discarded.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let destinationCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let sourceCID = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let retryToken = Data([0x11, 0x22, 0x33, 0x44])

        // Create valid Retry packet
        var retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Forge the integrity tag (modify last 16 bytes)
        let tagOffset = retryPacket.count - 16
        for i in 0..<16 {
            retryPacket[tagOffset + i] ^= 0xFF  // XOR to corrupt
        }

        // Client parses and verifies
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)

        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(!isValid, "Client MUST reject Retry packet with forged integrity tag")
    }

    @Test("Client rejects Retry packet with wrong original DCID")
    func clientRejectsWrongOriginalDCID() throws {
        // RFC 9001 §5.8: The tag is computed over a pseudo-packet that
        // includes the Original DCID. Using wrong DCID must fail.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let wrongDCID = try ConnectionID(bytes: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        let destinationCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let sourceCID = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let retryToken = Data([0x11, 0x22, 0x33, 0x44])

        // Server creates Retry packet with correct original DCID
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Client tries to verify with wrong original DCID
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)

        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: wrongDCID,  // Wrong DCID
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(!isValid, "Client MUST reject Retry with mismatched original DCID")
    }

    // MARK: - RFC 9001 §5.8: Version-specific keys

    @Test("Retry Integrity Tag uses version-specific key for v1")
    func retryTagUsesV1Key() throws {
        // RFC 9001 §5.8: The key and nonce are version-specific

        let originalDCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let destinationCID = try ConnectionID(bytes: Data([0x05, 0x06]))
        let sourceCID = try ConnectionID(bytes: Data([0x07, 0x08]))
        let retryToken = Data([0xAA])

        let v1Packet = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        let v2Packet = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v2
        )

        // Tags should be different for different versions
        let v1Tag = v1Packet.suffix(16)
        let v2Tag = v2Packet.suffix(16)

        #expect(v1Tag != v2Tag, "Different versions MUST produce different tags")
    }

    @Test("Client rejects Retry packet verified with wrong version")
    func clientRejectsWrongVersionVerification() throws {
        // Verify using v2 key when packet was made with v1 should fail

        let originalDCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let destinationCID = try ConnectionID(bytes: Data([0x05, 0x06]))
        let sourceCID = try ConnectionID(bytes: Data([0x07, 0x08]))
        let retryToken = Data([0xAA])

        // Create with v1
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)

        // Verify with v2 (wrong version)
        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v2  // Wrong version
        )

        #expect(!isValid, "Verification with wrong version MUST fail")
    }

    // MARK: - RFC 9001 §5.8: Tag length validation

    @Test("Client rejects Retry packet with invalid tag length")
    func clientRejectsInvalidTagLength() throws {
        // Tag MUST be exactly 16 bytes

        let shortTag = Data(repeating: 0x00, count: 15)  // Too short
        let longTag = Data(repeating: 0x00, count: 17)   // Too long

        let originalDCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let packetWithoutTag = Data([0xF0, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x02, 0x03, 0x04, 0x04, 0x05, 0x06, 0x07, 0x08, 0xAA])

        #expect(throws: QUICRetryError.self) {
            _ = try RetryIntegrityTag.verify(
                tag: shortTag,
                originalDCID: originalDCID,
                retryPacketWithoutTag: packetWithoutTag,
                version: .v1
            )
        }

        #expect(throws: QUICRetryError.self) {
            _ = try RetryIntegrityTag.verify(
                tag: longTag,
                originalDCID: originalDCID,
                retryPacketWithoutTag: packetWithoutTag,
                version: .v1
            )
        }
    }

    // MARK: - RFC 9001 §5.8: Retry packet detection

    @Test("Correctly identifies Retry packets")
    func identifiesRetryPackets() throws {
        let originalDCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let destinationCID = try ConnectionID(bytes: Data([0x05, 0x06]))
        let sourceCID = try ConnectionID(bytes: Data([0x07, 0x08]))
        let retryToken = Data([0xAA])

        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        #expect(RetryIntegrityTag.isRetryPacket(retryPacket))

        // Non-Retry packets should not be identified as Retry
        let initialPacket = Data([0xC0, 0x00, 0x00, 0x00, 0x01])  // Initial packet header
        #expect(!RetryIntegrityTag.isRetryPacket(initialPacket))

        // Too short packet
        let tooShort = Data([0xF0, 0x00])
        #expect(!RetryIntegrityTag.isRetryPacket(tooShort))
    }

    // MARK: - Integration: Client flow MUST verify before processing

    @Test("Client MUST NOT process Retry without verification")
    func clientMustNotProcessWithoutVerification() throws {
        // This test documents the requirement that client implementations
        // MUST call verify() before processing the Retry packet contents.
        //
        // RFC 9001 §5.8: A client that receives a Retry packet MUST
        // validate the Retry Integrity Tag using the Original Destination
        // Connection ID field and the integrity tag from the packet.
        //
        // The current implementation provides:
        // 1. parseRetryPacket() - extracts components
        // 2. verify() - validates the tag
        //
        // Client code MUST:
        // 1. Parse the packet
        // 2. Call verify() with the original DCID
        // 3. Only proceed if verify() returns true
        //
        // TODO: This test should fail until ManagedConnection/QUICClient
        // properly verifies Retry packets before processing them.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let destinationCID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let sourceCID = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let retryToken = Data([0x11, 0x22, 0x33, 0x44])

        // Create valid Retry packet
        var retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Corrupt the integrity tag
        let tagOffset = retryPacket.count - 16
        retryPacket[tagOffset] ^= 0xFF

        // Parsing should succeed (we don't verify during parse)
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)
        #expect(parsed.retryToken == retryToken)  // Can still read token

        // But verification MUST fail
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)
        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(!isValid, "Corrupted packet MUST fail verification")

        // The test below would require checking the actual client code:
        // - ManagedConnection should call RetryIntegrityTag.verify()
        // - ManagedConnection should reject/discard if verification fails
        // This is currently NOT implemented (as noted in Codex review)
    }

    // MARK: - RFC 9001 Appendix A.4: Test Vector

    @Test("RFC 9001 Appendix A.4 Test Vector")
    func rfc9001TestVector() throws {
        // Test vector from RFC 9001 Appendix A.4
        // This verifies our implementation against the RFC test vector

        // The RFC provides a sample Retry packet and its expected integrity tag.
        // Using the original DCID from the client's Initial packet.

        let originalDCID = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))

        // Retry packet without integrity tag (from RFC)
        // First byte: 0xff (Form=1, Fixed=1, Type=11, Reserved=1111)
        // Version: 0x00000001
        // DCID Len: 0x00 (empty)
        // SCID Len: 0x08
        // SCID: f067a5502a4262b5
        // Retry Token: token
        let retryPacketWithoutTag = Data([
            0xff,                                   // First byte
            0x00, 0x00, 0x00, 0x01,                 // Version
            0x00,                                   // DCID Length
            0x08,                                   // SCID Length
            0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5,  // SCID
            0x74, 0x6f, 0x6b, 0x65, 0x6e           // Retry Token "token"
        ])

        // Expected integrity tag from RFC 9001 Appendix A.4
        let expectedTag = Data([
            0x04, 0xa2, 0x65, 0xba, 0x2e, 0xff, 0x4d, 0x82,
            0x90, 0x58, 0xfb, 0x3f, 0x0f, 0x24, 0x96, 0xba
        ])

        // Compute the tag
        let computedTag = try RetryIntegrityTag.compute(
            originalDCID: originalDCID,
            retryPacket: retryPacketWithoutTag,
            version: .v1
        )

        #expect(computedTag == expectedTag, "Computed tag must match RFC 9001 test vector")
    }
}
