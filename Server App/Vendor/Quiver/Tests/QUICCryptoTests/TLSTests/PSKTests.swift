/// Tests for TLS 1.3 PSK and Session Resumption
///
/// Tests cover:
/// - NewSessionTicket encoding/decoding
/// - PreSharedKey extension encoding/decoding
/// - PskKeyExchangeModes extension
/// - EarlyData extension
/// - PSK binder computation
/// - Key schedule with PSK
/// - Session ticket creation and usage

import Testing
import Foundation
import Crypto
@testable import QUICCrypto

// MARK: - NewSessionTicket Tests

@Suite("NewSessionTicket Tests")
struct NewSessionTicketTests {

    @Test("Encode and decode NewSessionTicket")
    func roundtripNewSessionTicket() throws {
        let ticket = NewSessionTicket(
            ticketLifetime: 3600,
            ticketAgeAdd: 0x12345678,
            ticketNonce: Data([0x01, 0x02, 0x03, 0x04]),
            ticket: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
            extensions: []
        )

        let encoded = ticket.encode()
        let decoded = try NewSessionTicket.decode(from: encoded)

        #expect(decoded.ticketLifetime == 3600)
        #expect(decoded.ticketAgeAdd == 0x12345678)
        #expect(decoded.ticketNonce == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(decoded.ticket == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        #expect(decoded.extensions.isEmpty)
    }

    @Test("NewSessionTicket lifetime clamped to max")
    func ticketLifetimeClamped() {
        let ticket = NewSessionTicket(
            ticketLifetime: 1_000_000, // More than 7 days
            ticketAgeAdd: 0,
            ticketNonce: Data(),
            ticket: Data([0x01]),
            extensions: []
        )

        #expect(ticket.ticketLifetime == NewSessionTicket.maxLifetime)
    }

    @Test("Decode NewSessionTicket with early_data extension")
    func decodeWithEarlyData() throws {
        // Build NewSessionTicket with early_data extension
        var writer = TLSWriter()

        // ticket_lifetime
        writer.writeUInt32(7200)

        // ticket_age_add
        writer.writeUInt32(0xAABBCCDD)

        // ticket_nonce
        writer.writeVector8(Data([0x00, 0x01]))

        // ticket
        writer.writeVector16(Data([0xFF, 0xEE, 0xDD]))

        // extensions with early_data (max_early_data_size = 0xFFFFFFFF)
        var extWriter = TLSWriter()
        extWriter.writeUInt16(42) // early_data extension type
        extWriter.writeUInt16(4)  // length
        extWriter.writeUInt32(0xFFFFFFFF) // max_early_data_size

        writer.writeVector16(extWriter.finish())

        let decoded = try NewSessionTicket.decode(from: writer.finish())
        #expect(decoded.ticketLifetime == 7200)
        #expect(decoded.ticketAgeAdd == 0xAABBCCDD)
    }

    @Test("Reject empty ticket")
    func rejectEmptyTicket() throws {
        var writer = TLSWriter()
        writer.writeUInt32(3600)  // lifetime
        writer.writeUInt32(0)     // age_add
        writer.writeVector8(Data()) // nonce
        writer.writeVector16(Data()) // empty ticket
        writer.writeVector16(Data()) // no extensions

        #expect(throws: TLSDecodeError.self) {
            _ = try NewSessionTicket.decode(from: writer.finish())
        }
    }
}

// MARK: - SessionTicketData Tests

@Suite("SessionTicketData Tests")
struct SessionTicketDataTests {

    @Test("Session ticket validity")
    func ticketValidity() {
        let ticket = SessionTicketData(
            ticket: Data([0x01, 0x02, 0x03]),
            resumptionPSK: Data(repeating: 0xAB, count: 32),
            maxEarlyDataSize: 0xFFFFFFFF,
            ticketAgeAdd: 0x12345678,
            receiveTime: Date(),
            lifetime: 3600, // 1 hour
            cipherSuite: .tls_aes_128_gcm_sha256,
            serverName: "example.com",
            alpn: "h3"
        )

        // Current time - should be valid
        #expect(ticket.isValid())

        // Far in the future - should be invalid
        #expect(!ticket.isValid(at: Date().addingTimeInterval(4000)))
    }

    @Test("Obfuscated ticket age computation")
    func obfuscatedTicketAge() {
        let now = Date()
        let ticket = SessionTicketData(
            ticket: Data([0x01]),
            resumptionPSK: Data(repeating: 0, count: 32),
            maxEarlyDataSize: 0,
            ticketAgeAdd: 0x12345678,
            receiveTime: now.addingTimeInterval(-10), // 10 seconds ago
            lifetime: 3600,
            cipherSuite: .tls_aes_128_gcm_sha256
        )

        let age = ticket.obfuscatedAge(at: now)
        // Age should be approximately 10000ms + 0x12345678
        // Due to timing, allow some variance
        let expectedBase = UInt32(10000) &+ 0x12345678
        #expect(age >= expectedBase - 100 && age <= expectedBase + 100)
    }
}

// MARK: - PreSharedKey Extension Tests

@Suite("PreSharedKey Extension Tests")
struct PreSharedKeyExtensionTests {

    @Test("Encode and decode PskIdentity")
    func roundtripPskIdentity() throws {
        let identity = PskIdentity(
            identity: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            obfuscatedTicketAge: 0xAABBCCDD
        )

        let encoded = identity.encode()
        var reader = TLSReader(data: encoded)
        let decoded = try PskIdentity.decode(from: &reader)

        #expect(decoded.identity == identity.identity)
        #expect(decoded.obfuscatedTicketAge == identity.obfuscatedTicketAge)
    }

    @Test("Encode and decode OfferedPsks")
    func roundtripOfferedPsks() throws {
        let identity1 = PskIdentity(identity: Data([0x01, 0x02]), obfuscatedTicketAge: 1000)
        let identity2 = PskIdentity(identity: Data([0x03, 0x04, 0x05]), obfuscatedTicketAge: 2000)

        let binder1 = Data(repeating: 0xAA, count: 32)
        let binder2 = Data(repeating: 0xBB, count: 32)

        let offered = OfferedPsks(
            identities: [identity1, identity2],
            binders: [binder1, binder2]
        )

        let encoded = offered.encode()
        let decoded = try OfferedPsks.decode(from: encoded)

        #expect(decoded.identities.count == 2)
        #expect(decoded.binders.count == 2)
        #expect(decoded.identities[0].identity == identity1.identity)
        #expect(decoded.identities[1].identity == identity2.identity)
        #expect(decoded.binders[0] == binder1)
        #expect(decoded.binders[1] == binder2)
    }

    @Test("Encode and decode SelectedPsk")
    func roundtripSelectedPsk() throws {
        let selected = SelectedPsk(selectedIdentity: 0)
        let encoded = selected.encode()
        let decoded = try SelectedPsk.decode(from: encoded)

        #expect(decoded.selectedIdentity == 0)
    }

    @Test("Reject mismatched identities and binders count")
    func rejectMismatchedCounts() throws {
        // Build data with 2 identities but 1 binder
        var writer = TLSWriter()

        // identities (2)
        var identitiesWriter = TLSWriter()
        identitiesWriter.writeVector16(Data([0x01, 0x02]))
        identitiesWriter.writeUInt32(1000)
        identitiesWriter.writeVector16(Data([0x03, 0x04]))
        identitiesWriter.writeUInt32(2000)
        writer.writeVector16(identitiesWriter.finish())

        // binders (1)
        var bindersWriter = TLSWriter()
        bindersWriter.writeVector8(Data(repeating: 0xAA, count: 32))
        writer.writeVector16(bindersWriter.finish())

        #expect(throws: TLSDecodeError.self) {
            _ = try OfferedPsks.decode(from: writer.finish())
        }
    }

    @Test("Binders size calculation")
    func bindersSize() {
        let binder1 = Data(repeating: 0xAA, count: 32)
        let binder2 = Data(repeating: 0xBB, count: 48)

        let offered = OfferedPsks(
            identities: [PskIdentity(identity: Data([0x01]), obfuscatedTicketAge: 0)],
            binders: [binder1, binder2]
        )

        // 2 bytes (vector length) + 1 + 32 + 1 + 48 = 84
        #expect(offered.bindersSize == 84)
    }
}

// MARK: - PskKeyExchangeModes Tests

@Suite("PskKeyExchangeModes Tests")
struct PskKeyExchangeModesTests {

    @Test("Encode and decode PskKeyExchangeModes")
    func roundtrip() throws {
        let modes = PskKeyExchangeModesExtension(keModes: [.psk_dhe_ke, .psk_ke])
        let encoded = modes.encode()
        let decoded = try PskKeyExchangeModesExtension.decode(from: encoded)

        #expect(decoded.keModes.count == 2)
        #expect(decoded.keModes.contains(.psk_dhe_ke))
        #expect(decoded.keModes.contains(.psk_ke))
    }

    @Test("QUIC default is psk_dhe_ke only")
    func quicDefault() {
        let modes = PskKeyExchangeModesExtension.quicDefault
        #expect(modes.keModes.count == 1)
        #expect(modes.keModes[0] == .psk_dhe_ke)
        #expect(modes.supportsPskDheKe)
        #expect(!modes.supportsPskKe)
    }

    @Test("Reject empty modes")
    func rejectEmpty() throws {
        var writer = TLSWriter()
        writer.writeVector8(Data())

        #expect(throws: TLSDecodeError.self) {
            _ = try PskKeyExchangeModesExtension.decode(from: writer.finish())
        }
    }
}

// MARK: - EarlyData Extension Tests

@Suite("EarlyData Extension Tests")
struct EarlyDataExtensionTests {

    @Test("Encode ClientHello early_data (empty)")
    func encodeClientHello() {
        let ext = EarlyDataExtension.clientHello
        let encoded = ext.encode()
        #expect(encoded.isEmpty)
    }

    @Test("Encode NewSessionTicket early_data with max size")
    func encodeNewSessionTicket() {
        let ext = EarlyDataExtension.newSessionTicket(maxEarlyDataSize: 0xFFFFFFFF)
        let encoded = ext.encode()
        #expect(encoded.count == 4)
        #expect(encoded == Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    @Test("Decode empty early_data")
    func decodeEmpty() throws {
        let decoded = try EarlyDataExtension.decodeEmpty(from: Data())
        if case .clientHello = decoded {
            // Success
        } else {
            Issue.record("Expected clientHello case")
        }
    }

    @Test("Decode NewSessionTicket early_data")
    func decodeNewSessionTicket() throws {
        let data = Data([0x00, 0x01, 0x00, 0x00]) // 65536
        let decoded = try EarlyDataExtension.decodeNewSessionTicket(from: data)

        if case .newSessionTicket(let size) = decoded {
            #expect(size == 65536)
        } else {
            Issue.record("Expected newSessionTicket case")
        }
    }

    @Test("QUIC max early data size constant")
    func quicConstant() {
        #expect(EarlyDataExtension.quicMaxEarlyDataSize == 0xFFFFFFFF)
    }
}

// MARK: - EarlyDataState Tests

@Suite("EarlyDataState Tests")
struct EarlyDataStateTests {

    @Test("Initial state")
    func initialState() {
        let state = EarlyDataState()
        #expect(!state.attemptingEarlyData)
        #expect(!state.earlyDataAccepted)
        #expect(state.maxEarlyDataSize == 0)
        #expect(state.earlyDataSent == 0)
        #expect(!state.canSendMoreEarlyData)
    }

    @Test("Can send more early data")
    func canSendMore() {
        var state = EarlyDataState()
        state.attemptingEarlyData = true
        state.maxEarlyDataSize = 1000

        #expect(state.canSendMoreEarlyData)

        state.recordEarlyData(size: 500)
        #expect(state.canSendMoreEarlyData)

        state.recordEarlyData(size: 500)
        #expect(!state.canSendMoreEarlyData)
    }
}

// MARK: - TLS Key Schedule PSK Tests

@Suite("TLS Key Schedule PSK Tests")
struct TLSKeySchedulePSKTests {

    @Test("Derive binder key")
    func deriveBinderKey() throws {
        var keySchedule = TLSKeySchedule(cipherSuite: .tls_aes_128_gcm_sha256)

        // Derive early secret with a test PSK
        let testPSK = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        keySchedule.deriveEarlySecret(psk: testPSK)

        // Derive binder key for resumption
        let binderKey = try keySchedule.deriveBinderKey(isResumption: true)

        // Just verify it's the correct length
        let keyData = binderKey.withUnsafeBytes { Data($0) }
        #expect(keyData.count == 32) // SHA-256 output
    }

    @Test("Derive early traffic secret")
    func deriveEarlyTrafficSecret() throws {
        var keySchedule = TLSKeySchedule(cipherSuite: .tls_aes_128_gcm_sha256)

        let testPSK = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        keySchedule.deriveEarlySecret(psk: testPSK)

        // Use a dummy transcript hash
        let transcriptHash = Data(SHA256.hash(data: Data([0x01, 0x02, 0x03])))

        let earlySecret = try keySchedule.deriveClientEarlyTrafficSecret(
            transcriptHash: transcriptHash
        )

        let secretData = earlySecret.withUnsafeBytes { Data($0) }
        #expect(secretData.count == 32)
    }

    @Test("Derive resumption master secret")
    func deriveResumptionMasterSecret() throws {
        var keySchedule = TLSKeySchedule(cipherSuite: .tls_aes_128_gcm_sha256)

        // Need to go through the full key schedule
        keySchedule.deriveEarlySecret(psk: nil)

        // Derive handshake secrets with a dummy shared secret
        let dummySharedSecret = try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PrivateKey().publicKey
        )
        let transcriptHash1 = Data(SHA256.hash(data: Data()))
        _ = try keySchedule.deriveHandshakeSecrets(
            sharedSecret: dummySharedSecret,
            transcriptHash: transcriptHash1
        )

        // Derive application secrets
        let transcriptHash2 = Data(SHA256.hash(data: Data([0x01])))
        _ = try keySchedule.deriveApplicationSecrets(transcriptHash: transcriptHash2)

        // Now we can derive resumption master secret
        let transcriptHash3 = Data(SHA256.hash(data: Data([0x01, 0x02])))
        let resumptionSecret = try keySchedule.deriveResumptionMasterSecret(
            transcriptHash: transcriptHash3
        )

        let secretData = resumptionSecret.withUnsafeBytes { Data($0) }
        #expect(secretData.count == 32)
    }

    @Test("Derive resumption PSK from ticket nonce")
    func deriveResumptionPSK() throws {
        var keySchedule = TLSKeySchedule(cipherSuite: .tls_aes_128_gcm_sha256)

        // Go through full key schedule
        keySchedule.deriveEarlySecret(psk: nil)

        let dummySharedSecret = try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PrivateKey().publicKey
        )
        _ = try keySchedule.deriveHandshakeSecrets(
            sharedSecret: dummySharedSecret,
            transcriptHash: Data(SHA256.hash(data: Data()))
        )
        _ = try keySchedule.deriveApplicationSecrets(
            transcriptHash: Data(SHA256.hash(data: Data([0x01])))
        )

        let resumptionMasterSecret = try keySchedule.deriveResumptionMasterSecret(
            transcriptHash: Data(SHA256.hash(data: Data([0x01, 0x02])))
        )

        // Derive PSK for ticket nonce
        let ticketNonce = Data([0x00, 0x01, 0x02, 0x03])
        let psk = keySchedule.deriveResumptionPSK(
            resumptionMasterSecret: resumptionMasterSecret,
            ticketNonce: ticketNonce
        )

        let pskData = psk.withUnsafeBytes { Data($0) }
        #expect(pskData.count == 32)
    }

    @Test("SHA-384 cipher suite uses correct hash length")
    func sha384CipherSuite() throws {
        var keySchedule = TLSKeySchedule(cipherSuite: .tls_aes_256_gcm_sha384)
        #expect(keySchedule.hashLength == 48)

        let testPSK = SymmetricKey(data: Data(repeating: 0x42, count: 48))
        keySchedule.deriveEarlySecret(psk: testPSK)

        let binderKey = try keySchedule.deriveBinderKey(isResumption: true)
        let keyData = binderKey.withUnsafeBytes { Data($0) }
        #expect(keyData.count == 48)
    }
}

// MARK: - PSK Binder Helper Tests

@Suite("PSK Binder Helper Tests")
struct PSKBinderHelperTests {

    @Test("Compute and verify binder")
    func computeAndVerifyBinder() {
        let helper = PSKBinderHelper(cipherSuite: .tls_aes_128_gcm_sha256)

        // Create a test early secret
        let earlySecretData = Data(SHA256.hash(data: Data([0x01, 0x02, 0x03])))

        // Derive binder key
        let binderKeyData = helper.binderKey(from: earlySecretData, isResumption: true)
        #expect(binderKeyData.count == 32)

        // Compute binder
        let transcriptHash = Data(SHA256.hash(data: Data([0xAA, 0xBB])))
        let binderValue = helper.binder(forKey: binderKeyData, transcriptHash: transcriptHash)
        #expect(binderValue.count == 32)

        // Verify should succeed with correct binder
        let verified = helper.isValidBinder(
            forKey: binderKeyData,
            transcriptHash: transcriptHash,
            expected: binderValue
        )
        #expect(verified)

        // Verify should fail with wrong binder
        let wrongBinder = Data(repeating: 0xFF, count: 32)
        let notVerified = helper.isValidBinder(
            forKey: binderKeyData,
            transcriptHash: transcriptHash,
            expected: wrongBinder
        )
        #expect(!notVerified)
    }

    @Test("Different label for external vs resumption PSK")
    func differentLabels() {
        let helper = PSKBinderHelper(cipherSuite: .tls_aes_128_gcm_sha256)
        let earlySecretData = Data(SHA256.hash(data: Data([0x01, 0x02, 0x03])))

        let resBinderKey = helper.binderKey(from: earlySecretData, isResumption: true)
        let extBinderKey = helper.binderKey(from: earlySecretData, isResumption: false)

        // Should be different due to different labels
        #expect(resBinderKey != extBinderKey)
    }
}

// MARK: - TLSExtension PSK Integration Tests

@Suite("TLSExtension PSK Integration Tests")
struct TLSExtensionPSKIntegrationTests {

    @Test("Create and encode pre_shared_key client extension")
    func preSharedKeyClient() throws {
        let identity = PskIdentity(identity: Data([0x01, 0x02, 0x03]), obfuscatedTicketAge: 1234)
        let binder = Data(repeating: 0xAA, count: 32)
        let offered = OfferedPsks(identities: [identity], binders: [binder])

        let ext = TLSExtension.preSharedKeyClient(offered)

        #expect(ext.extensionType == .preSharedKey)
        #expect(ext.rawType == 41)

        let encoded = ext.encode()
        #expect(!encoded.isEmpty)
    }

    @Test("Create and encode pre_shared_key server extension")
    func preSharedKeyServer() {
        let ext = TLSExtension.preSharedKeyServer(selectedIdentity: 0)

        #expect(ext.extensionType == .preSharedKey)

        let encoded = ext.encode()
        // 2 (type) + 2 (length) + 2 (selected_identity) = 6
        #expect(encoded.count == 6)
    }

    @Test("Create psk_key_exchange_modes extension")
    func pskKeyExchangeModes() {
        let ext = TLSExtension.pskKeyExchangeModesList([.psk_dhe_ke])

        #expect(ext.extensionType == .pskKeyExchangeModes)
        #expect(ext.rawType == 45)

        let encoded = ext.encode()
        #expect(!encoded.isEmpty)
    }

    @Test("Create early_data client extension")
    func earlyDataClient() {
        let ext = TLSExtension.earlyDataClient()

        #expect(ext.extensionType == .earlyData)
        #expect(ext.rawType == 42)

        let encoded = ext.encode()
        // Should be just type + length (empty content)
        #expect(encoded.count == 4)
    }
}

// MARK: - EndOfEarlyData Tests

@Suite("EndOfEarlyData Tests")
struct EndOfEarlyDataTests {

    @Test("Encode EndOfEarlyData")
    func encode() {
        let msg = EndOfEarlyData()
        let content = msg.encode()
        #expect(content.isEmpty)

        let message = msg.encodeMessage()
        // 1 byte type + 3 bytes length (00 00 00) = 4 bytes
        #expect(message.count == 4)
        #expect(message[0] == HandshakeType.endOfEarlyData.rawValue)
    }

    @Test("Decode EndOfEarlyData")
    func decode() throws {
        let _ = try EndOfEarlyData.decode(from: Data())
        // Should not throw
    }

    @Test("Reject non-empty EndOfEarlyData")
    func rejectNonEmpty() {
        #expect(throws: TLSDecodeError.self) {
            _ = try EndOfEarlyData.decode(from: Data([0x01]))
        }
    }
}
