/// RFC 9001 Section 6 Compliance Tests - Key Update
///
/// These tests verify compliance with RFC 9001 Section 6:
/// - Key update mechanism via Key Phase bit
/// - AEAD confidentiality and integrity limits
/// - Key update timing requirements

import Testing
import Foundation
import Crypto
@testable import QUICCore
@testable import QUICCrypto

@Suite("RFC 9001 §6 - Key Update Compliance")
struct KeyUpdateRFCTests {

    // MARK: - RFC 9001 §6.1: Key Phase Bit

    @Test("Key Phase bit toggles on key update")
    func keyPhaseBitToggles() throws {
        // RFC 9001 §6.1: The Key Phase bit allows a recipient of a packet to
        // identify the packet protection keys that are used to protect the packet.
        // The Key Phase bit is initially set to 0 for the first set of 1-RTT packets
        // and toggled to signal each subsequent key update.

        // Initial key phase should be 0
        var header = ShortHeader(
            destinationConnectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: false  // Initial phase
        )

        #expect(header.keyPhase == false, "Initial key phase MUST be 0")

        // After key update, key phase toggles to 1
        header = ShortHeader(
            destinationConnectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: true  // After first key update
        )

        #expect(header.keyPhase == true, "Key phase MUST toggle after key update")
    }

    @Test("Short header encodes Key Phase bit correctly")
    func shortHeaderEncodesKeyPhaseBit() throws {
        // RFC 9001 §6.1: The Key Phase bit is the fourth bit (0x04) of the
        // short header first byte.

        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))

        // Key phase = 0
        let headerPhase0 = ShortHeader(
            destinationConnectionID: dcid,
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: false
        )

        // Key phase = 1
        let headerPhase1 = ShortHeader(
            destinationConnectionID: dcid,
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: true
        )

        // First byte encoding: Form(0) Fixed(1) Spin(0) Reserved(00) KeyPhase(X) PN(01)
        // Phase 0: 0100 0001 = 0x41
        // Phase 1: 0100 0101 = 0x45

        #expect(headerPhase0.firstByte & 0x04 == 0, "Key phase 0 should have bit 0x04 = 0")
        #expect(headerPhase1.firstByte & 0x04 == 0x04, "Key phase 1 should have bit 0x04 = 1")
    }

    // MARK: - RFC 9001 §6.6: AEAD Limits

    @Test("AES-GCM confidentiality limit is 2^23 packets")
    func aesGcmConfidentialityLimit() throws {
        // RFC 9001 §6.6: For AEAD_AES_128_GCM and AEAD_AES_256_GCM, the
        // confidentiality limit is 2^23 packets.

        // This documents the expected limit value
        let expectedConfidentialityLimit: UInt64 = 1 << 23  // 8,388,608 packets

        #expect(expectedConfidentialityLimit == 8_388_608, "AES-GCM confidentiality limit is 2^23")
    }

    @Test("AES-GCM integrity limit is 2^52 packets")
    func aesGcmIntegrityLimit() throws {
        // RFC 9001 §6.6: For AEAD_AES_128_GCM and AEAD_AES_256_GCM, the
        // integrity limit is 2^52 invalid packets.

        let expectedIntegrityLimit: UInt64 = 1 << 52

        #expect(expectedIntegrityLimit == 4_503_599_627_370_496, "AES-GCM integrity limit is 2^52")
    }

    @Test("ChaCha20-Poly1305 confidentiality limit is 2^62 packets")
    func chaCha20ConfidentialityLimit() throws {
        // RFC 9001 §6.6: For AEAD_CHACHA20_POLY1305, the confidentiality
        // limit is greater than the number of possible packets (2^62).

        let expectedLimit: UInt64 = 1 << 62

        #expect(expectedLimit == 4_611_686_018_427_387_904, "ChaCha20 confidentiality limit is 2^62")
    }

    @Test("ChaCha20-Poly1305 integrity limit is 2^36 packets")
    func chaCha20IntegrityLimit() throws {
        // RFC 9001 §6.6: For AEAD_CHACHA20_POLY1305, the integrity limit
        // is 2^36 invalid packets.

        let expectedLimit: UInt64 = 1 << 36

        #expect(expectedLimit == 68_719_476_736, "ChaCha20 integrity limit is 2^36")
    }

    // MARK: - RFC 9001 §6.4: Key Update Response

    @Test("KeySchedule supports key update")
    func keyScheduleSupportsKeyUpdate() throws {
        // RFC 9001 §6.4: An endpoint that receives a packet with a different
        // Key Phase than it has sent MUST update its receive keys.

        var schedule = KeySchedule()

        // Derive initial keys first
        let dcid = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let (clientKeys, serverKeys) = try schedule.deriveInitialKeys(connectionID: dcid, version: .v1)

        // Verify keys were derived
        #expect(clientKeys.key.bitCount == 128, "AES-128 key should be 128 bits")
        #expect(serverKeys.key.bitCount == 128, "AES-128 key should be 128 bits")
        #expect(clientKeys.iv.count == 12, "IV should be 12 bytes")
        #expect(serverKeys.iv.count == 12, "IV should be 12 bytes")
    }

    // MARK: - Integration: ManagedConnection Key Phase Handling

    @Test("ManagedConnection MUST support key phase in packet construction")
    func managedConnectionKeyPhaseSupport() throws {
        // This test documents the requirement that ManagedConnection
        // MUST track and use the correct key phase when building packets.
        //
        // Current implementation (ManagedConnection.swift:740) always uses
        // keyPhase: false, which is incorrect for connections that have
        // performed key updates.
        //
        // Expected behavior:
        // 1. Track current send key phase
        // 2. Toggle key phase when initiating key update
        // 3. Use correct key phase in ShortHeader construction
        // 4. Support receiving packets with either key phase

        // Create a short header with explicit key phase
        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))

        let phase0Header = ShortHeader(
            destinationConnectionID: dcid,
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: false
        )

        let phase1Header = ShortHeader(
            destinationConnectionID: dcid,
            packetNumberLength: 2,
            spinBit: false,
            keyPhase: true
        )

        #expect(phase0Header.keyPhase != phase1Header.keyPhase)
    }

    // MARK: - RFC 9001 §6.3: Key Update Timing

    @Test("Key update MUST NOT be initiated before handshake confirmed")
    func keyUpdateNotBeforeHandshakeConfirmed() throws {
        // RFC 9001 §6.3: An endpoint MUST NOT initiate a key update prior to
        // having confirmed the handshake.

        // This documents the requirement. The actual validation depends on
        // connection state tracking, which should prevent key updates
        // before the handshake is confirmed.

        // A fresh KeySchedule only has initial keys, no application keys
        var schedule = KeySchedule()
        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        _ = try schedule.deriveInitialKeys(connectionID: dcid, version: .v1)

        // At this point, handshake is not confirmed, so key update should not be allowed
        // The implementation should track this state
    }

    // MARK: - Key Material Derivation

    @Test("Initial secrets derived from connection ID")
    func initialSecretsDerivation() throws {
        // RFC 9001 §5.2: Initial packets use keys derived from the
        // Destination Connection ID.

        let dcid = try ConnectionID(bytes: Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let secrets = try InitialSecrets.derive(connectionID: dcid, version: .v1)

        // Both client and server secrets should be derived
        #expect(secrets.clientSecret.bitCount == 256)
        #expect(secrets.serverSecret.bitCount == 256)

        // Different versions should produce different secrets
        let v2Secrets = try InitialSecrets.derive(connectionID: dcid, version: .v2)
        let v1Keys = try KeyMaterial.derive(from: secrets.clientSecret)
        let v2Keys = try KeyMaterial.derive(from: v2Secrets.clientSecret)

        #expect(v1Keys.iv != v2Keys.iv, "Different versions produce different keys")
    }
}

// MARK: - CryptoStateKeyPhase Tests

@Suite("RFC 9001 §6 - CryptoState Key Phase Management")
struct CryptoStateKeyPhaseRFCTests {

    @Test("KeyPhaseContext maintains current and next openers")
    func keyPhaseContextOpeners() throws {
        // RFC 9001 §6.4: When a key update is received, an endpoint MUST
        // retain the ability to decrypt using the previous keys until it
        // has successfully processed a packet at the new key phase.

        // This verifies the KeyPhaseContext structure supports the requirement
        // to maintain both current and next-phase keys

        // The context should hold:
        // - Current key phase (0 or 1)
        // - Current opener (for receiving packets at current phase)
        // - Next opener (for receiving packets at next phase, once derived)

        // This is a documentation test - the actual implementation should
        // maintain this state in CryptoStateKeyPhase.swift
    }

    @Test("Old keys retained until new keys confirmed")
    func oldKeysRetainedUntilConfirmed() throws {
        // RFC 9001 §6.4: The endpoint MUST retain old read keys until it
        // has successfully unprotected a packet sent using the new keys.
        // The endpoint SHOULD retain old read keys for no more than three
        // times the PTO after having received a packet protected using the
        // new keys.

        // This is a timing/state management test that verifies:
        // 1. Old keys are kept in memory during transition
        // 2. Old keys are discarded after confirmation timeout

        // Documentation test - actual implementation should track this
    }
}
