/// RFC 9000 Packet Header Compliance Tests
///
/// These tests verify compliance with RFC 9000 packet header requirements:
/// - Fixed bit MUST be 1
/// - Reserved bits MUST be 0
/// - Validation MUST happen after header protection removal (RFC 9001 §5.4.1)

import Testing
import Foundation
@testable import QUICCore

@Suite("RFC 9000 - Packet Header Validation Compliance")
struct PacketHeaderRFCTests {

    // MARK: - Two-Phase Architecture Tests

    @Test("Protected header parsing does NOT validate protected bits")
    func protectedHeaderParsingNoValidation() throws {
        // RFC 9001 §5.4.1: For long headers, bits 0-3 are protected
        // Parsing a protected header should succeed even if protected bits look invalid
        // because those bits have been XORed with a pseudo-random mask

        // Create a packet where protected bits appear "invalid" (reserved bits = 11)
        // This simulates a protected packet before header protection removal
        var protectedPacket = Data()
        protectedPacket.append(0xCF)  // Form=1, Fixed=1, Type=00, Reserved=11, PNLen=11
        protectedPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version 1
        protectedPacket.append(0x04)  // DCID length
        protectedPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        protectedPacket.append(0x04)  // SCID length
        protectedPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        protectedPacket.append(0x00)  // Token length
        protectedPacket.append(0x14)  // Length
        protectedPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        // ProtectedPacketHeader.parse() should succeed - no validation of protected bits
        let (protectedHeader, _) = try ProtectedPacketHeader.parse(from: protectedPacket)

        if case .long(let longHeader) = protectedHeader {
            // Packet type bits (5-4) are NOT protected, so we can read them
            #expect(longHeader.packetType == .initial)
            #expect(longHeader.version == QUICVersion.v1)
        } else {
            Issue.record("Expected long header")
        }
    }

    @Test("Short header protected parsing does NOT validate fixed bit")
    func shortHeaderProtectedParsingNoValidation() throws {
        // RFC 9001 §5.4.1: For short headers, bits 0-4 are protected
        // This includes the fixed bit (bit 6)! So even fixed bit validation
        // must wait until after header protection removal.

        // Create a packet where fixed bit = 0 (appears invalid while protected)
        var protectedPacket = Data()
        protectedPacket.append(0x00)  // Form=0, Fixed=0 (protected, so looks invalid)
        protectedPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // DCID
        protectedPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        // ProtectedShortHeader.parse() should succeed
        let (header, _) = try ProtectedShortHeader.parse(from: protectedPacket, dcidLength: 4)
        #expect(header.destinationConnectionID.bytes == Data([0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: - RFC 9000 §17.2: Long Header Validation After HP Removal

    @Test("Long header with valid bits passes unprotect() validation")
    func longHeaderValidBitsPassValidation() throws {
        var packet = Data()
        packet.append(0xC0)  // Form=1, Fixed=1, Type=00, Reserved=00
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version 1
        packet.append(0x04)  // DCID length
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(0x04)  // SCID length
        packet.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet.append(0x00)  // Token length
        packet.append(0x14)  // Length
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: packet)

        // Simulate header protection removal - unprotected first byte is valid
        let unprotectedFirstByte: UInt8 = 0xC0  // Valid: Fixed=1, Reserved=00
        let validatedHeader = try protectedHeader.unprotect(
            unprotectedFirstByte: unprotectedFirstByte,
            packetNumber: 0,
            packetNumberLength: 1
        )

        #expect(validatedHeader.packetType == .initial)
    }

    @Test("Long header with fixed bit = 0 fails unprotect() validation")
    func longHeaderFixedBitZeroFailsValidation() throws {
        var packet = Data()
        packet.append(0xC0)  // Protected first byte (doesn't matter for this test)
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version 1
        packet.append(0x04)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(0x04)
        packet.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet.append(0x00)
        packet.append(0x14)
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: packet)

        // After HP removal, if first byte has fixed bit = 0, validation MUST fail
        let unprotectedFirstByte: UInt8 = 0x80  // Fixed=0 (INVALID)

        #expect(throws: HeaderValidationError.self) {
            _ = try protectedHeader.unprotect(
                unprotectedFirstByte: unprotectedFirstByte,
                packetNumber: 0,
                packetNumberLength: 1
            )
        }
    }

    @Test("Long header with non-zero reserved bits fails unprotect() validation")
    func longHeaderReservedBitsFailValidation() throws {
        var packet = Data()
        packet.append(0xC0)  // Protected first byte
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version 1
        packet.append(0x04)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(0x04)
        packet.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet.append(0x00)
        packet.append(0x14)
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: packet)

        // After HP removal, reserved bits (3-2) are non-zero
        let unprotectedFirstByte: UInt8 = 0xCC  // Fixed=1, Reserved=11 (INVALID)

        #expect(throws: HeaderValidationError.self) {
            _ = try protectedHeader.unprotect(
                unprotectedFirstByte: unprotectedFirstByte,
                packetNumber: 0,
                packetNumberLength: 1
            )
        }
    }

    // MARK: - RFC 9000 §17.3: Short Header Validation After HP Removal

    @Test("Short header with valid bits passes unprotect() validation")
    func shortHeaderValidBitsPassValidation() throws {
        var packet = Data()
        packet.append(0x40)  // Form=0, (rest protected)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // DCID
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedShortHeader.parse(from: packet, dcidLength: 4)

        // After HP removal, unprotected byte has valid fixed bit and reserved bits
        let unprotectedFirstByte: UInt8 = 0x40  // Fixed=1, Reserved=00

        let validatedHeader = try protectedHeader.unprotect(
            unprotectedFirstByte: unprotectedFirstByte,
            packetNumber: 0,
            packetNumberLength: 1
        )

        #expect(validatedHeader.destinationConnectionID.bytes == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("Short header with fixed bit = 0 fails unprotect() validation")
    func shortHeaderFixedBitZeroFailsValidation() throws {
        var packet = Data()
        packet.append(0x40)  // Protected (doesn't matter)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedShortHeader.parse(from: packet, dcidLength: 4)

        // After HP removal, fixed bit = 0 (INVALID)
        let unprotectedFirstByte: UInt8 = 0x00  // Fixed=0 (INVALID)

        #expect(throws: HeaderValidationError.self) {
            _ = try protectedHeader.unprotect(
                unprotectedFirstByte: unprotectedFirstByte,
                packetNumber: 0,
                packetNumberLength: 1
            )
        }
    }

    @Test("Short header with non-zero reserved bits fails unprotect() validation")
    func shortHeaderReservedBitsFailValidation() throws {
        var packet = Data()
        packet.append(0x40)  // Protected
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (protectedHeader, _) = try ProtectedShortHeader.parse(from: packet, dcidLength: 4)

        // After HP removal, reserved bits (4-3) are non-zero
        let unprotectedFirstByte: UInt8 = 0x58  // Fixed=1, Reserved=11 (INVALID)

        #expect(throws: HeaderValidationError.self) {
            _ = try protectedHeader.unprotect(
                unprotectedFirstByte: unprotectedFirstByte,
                packetNumber: 0,
                packetNumberLength: 1
            )
        }
    }

    // MARK: - RFC 9000 §17.2: Version Negotiation Exemption

    @Test("Version Negotiation packet MAY have fixed bit = 0")
    func versionNegotiationFixedBitExemption() throws {
        // RFC 9000 §17.2.1: Version Negotiation packets do not use header protection
        // and have special rules about the fixed bit

        var vnPacket = Data()
        vnPacket.append(0x80)  // Form=1, Fixed=0 (OK for VN)
        vnPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Version = 0
        vnPacket.append(0x04)  // DCID length
        vnPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        vnPacket.append(0x04)  // SCID length
        vnPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        vnPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Supported version

        // Parse should succeed
        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: vnPacket)

        #expect(protectedHeader.packetType == .versionNegotiation)
        #expect(protectedHeader.version.rawValue == 0)
    }

    // MARK: - ProtectedPacketHeader enum tests

    @Test("ProtectedPacketHeader detects long vs short header")
    func protectedPacketHeaderTypeDetection() throws {
        // Long header packet
        var longPacket = Data()
        longPacket.append(0xC0)  // Form=1
        longPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        longPacket.append(0x04)
        longPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        longPacket.append(0x04)
        longPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        longPacket.append(0x00)
        longPacket.append(0x14)
        longPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (longHeader, _) = try ProtectedPacketHeader.parse(from: longPacket)
        #expect(longHeader.isLongHeader)

        // Short header packet
        var shortPacket = Data()
        shortPacket.append(0x40)  // Form=0
        shortPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        shortPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (shortHeader, _) = try ProtectedPacketHeader.parse(from: shortPacket, dcidLength: 4)
        #expect(!shortHeader.isLongHeader)
    }

    @Test("ProtectedPacketHeader.encryptionLevel returns correct level")
    func protectedPacketHeaderEncryptionLevel() throws {
        // Initial packet
        var initialPacket = Data()
        initialPacket.append(0xC0)  // Type=00 (Initial)
        initialPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        initialPacket.append(0x04)
        initialPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        initialPacket.append(0x04)
        initialPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        initialPacket.append(0x00)
        initialPacket.append(0x14)
        initialPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (initialHeader, _) = try ProtectedPacketHeader.parse(from: initialPacket)
        #expect(initialHeader.encryptionLevel == .initial)

        // Handshake packet
        var handshakePacket = Data()
        handshakePacket.append(0xE0)  // Type=10 (Handshake)
        handshakePacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        handshakePacket.append(0x04)
        handshakePacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        handshakePacket.append(0x04)
        handshakePacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        handshakePacket.append(0x14)  // Length
        handshakePacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (handshakeHeader, _) = try ProtectedPacketHeader.parse(from: handshakePacket)
        #expect(handshakeHeader.encryptionLevel == .handshake)

        // Short header (1-RTT) = application level
        var shortPacket = Data()
        shortPacket.append(0x40)
        shortPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        shortPacket.append(contentsOf: Data(repeating: 0x00, count: 20))

        let (shortHeader, _) = try ProtectedPacketHeader.parse(from: shortPacket, dcidLength: 4)
        #expect(shortHeader.encryptionLevel == .application)
    }
}

// MARK: - Retry Packet Header Tests

@Suite("RFC 9000 - Retry Packet Header Requirements")
struct RetryPacketHeaderRFCTests {

    @Test("Retry packet parses with integrity tag")
    func retryPacketWithIntegrityTag() throws {
        // RFC 9000 §17.2.5: Retry packets include a 16-byte Retry Integrity Tag

        var retryPacket = Data()
        retryPacket.append(0xF0)  // Form=1, Fixed=1, Type=11 (Retry)
        retryPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version
        retryPacket.append(0x04)  // DCID length
        retryPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // DCID
        retryPacket.append(0x04)  // SCID length
        retryPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])  // SCID
        retryPacket.append(contentsOf: [0xAA, 0xBB])  // Retry Token
        retryPacket.append(contentsOf: Data(repeating: 0xCC, count: 16))  // Integrity Tag

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: retryPacket)

        #expect(protectedHeader.packetType == .retry)
        #expect(protectedHeader.retryIntegrityTag?.count == 16)
        #expect(protectedHeader.token == Data([0xAA, 0xBB]))
    }

    @Test("Retry packet without integrity tag has nil tag")
    func retryPacketWithoutIntegrityTag() throws {
        // A Retry packet that is too short for an integrity tag
        // should parse but have nil retryIntegrityTag

        var shortRetryPacket = Data()
        shortRetryPacket.append(0xF0)  // Retry type
        shortRetryPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version
        shortRetryPacket.append(0x04)  // DCID length
        shortRetryPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        shortRetryPacket.append(0x04)  // SCID length
        shortRetryPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        // Only 10 bytes remaining - not enough for 16-byte integrity tag

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: shortRetryPacket)

        #expect(protectedHeader.packetType == .retry)
        // The parse succeeds but tag is nil (validation happens elsewhere)
        #expect(protectedHeader.retryIntegrityTag == nil)
    }

    @Test("Retry packet unprotect validates integrity tag presence")
    func retryPacketUnprotectValidatesTag() throws {
        // When unprotecting a Retry packet, missing integrity tag should fail

        var shortRetryPacket = Data()
        shortRetryPacket.append(0xF0)  // Retry type
        shortRetryPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        shortRetryPacket.append(0x04)
        shortRetryPacket.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        shortRetryPacket.append(0x04)
        shortRetryPacket.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        // Missing integrity tag

        let (protectedHeader, _) = try ProtectedLongHeader.parse(from: shortRetryPacket)

        // Retry packets don't use header protection, so unprotect() uses the protected byte
        // Validation should fail due to missing integrity tag
        #expect(throws: HeaderValidationError.self) {
            _ = try protectedHeader.unprotect(
                unprotectedFirstByte: protectedHeader.protectedFirstByte,
                packetNumber: 0,
                packetNumberLength: 0
            )
        }
    }
}
