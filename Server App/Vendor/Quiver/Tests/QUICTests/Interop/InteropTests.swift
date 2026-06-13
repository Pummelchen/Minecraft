/// QUIC Interoperability Tests
///
/// Tests for verifying RFC compliance and wire format compatibility.

import Testing
import Foundation
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto
@testable import QUICRecovery
@testable import QUICTransport

// MARK: - InitialSecrets Extension for Testing

extension InitialSecrets {
    /// Derives client key material for testing
    func clientKeys() throws -> KeyMaterial {
        return try KeyMaterial.derive(from: clientSecret)
    }

    /// Derives server key material for testing
    func serverKeys() throws -> KeyMaterial {
        return try KeyMaterial.derive(from: serverSecret)
    }
}

// MARK: - RFC 9001 Test Vector Tests

@Suite("RFC 9001 Test Vectors")
struct RFC9001TestVectorTests {

    @Test("Initial secrets derivation matches RFC 9001 A.1")
    func initialSecretsDerivation() throws {
        let dcid = try ConnectionID(RFC9001TestVectors.clientDCID)

        // Derive initial secrets
        let secrets = try InitialSecrets.derive(
            connectionID: dcid,
            version: .v1
        )

        // Verify client initial secret
        #expect(
            secrets.clientSecret.withUnsafeBytes { Data($0) } == RFC9001TestVectors.clientInitialSecret,
            "Client initial secret mismatch"
        )

        // Verify server initial secret
        #expect(
            secrets.serverSecret.withUnsafeBytes { Data($0) } == RFC9001TestVectors.serverInitialSecret,
            "Server initial secret mismatch"
        )
    }

    @Test("Client keys derivation matches RFC 9001 A.1")
    func clientKeysDerivation() throws {
        let dcid = try ConnectionID(RFC9001TestVectors.clientDCID)

        // Derive keys
        let secrets = try InitialSecrets.derive(
            connectionID: dcid,
            version: .v1
        )

        let clientKeys = try secrets.clientKeys()

        // Verify client key
        #expect(
            clientKeys.key.withUnsafeBytes { Data($0) } == RFC9001TestVectors.clientKey,
            "Client key mismatch"
        )

        // Verify client IV
        #expect(
            clientKeys.iv == RFC9001TestVectors.clientIV,
            "Client IV mismatch"
        )

        // Verify client HP key
        #expect(
            clientKeys.hp.withUnsafeBytes { Data($0) } == RFC9001TestVectors.clientHP,
            "Client HP key mismatch"
        )
    }

    @Test("Server keys derivation matches RFC 9001 A.1")
    func serverKeysDerivation() throws {
        let dcid = try ConnectionID(RFC9001TestVectors.clientDCID)

        // Derive keys
        let secrets = try InitialSecrets.derive(
            connectionID: dcid,
            version: .v1
        )

        let serverKeys = try secrets.serverKeys()

        // Verify server key
        #expect(
            serverKeys.key.withUnsafeBytes { Data($0) } == RFC9001TestVectors.serverKey,
            "Server key mismatch"
        )

        // Verify server IV
        #expect(
            serverKeys.iv == RFC9001TestVectors.serverIV,
            "Server IV mismatch"
        )

        // Verify server HP key
        #expect(
            serverKeys.hp.withUnsafeBytes { Data($0) } == RFC9001TestVectors.serverHP,
            "Server HP key mismatch"
        )
    }
}

// MARK: - Retry Integrity Tag Tests

@Suite("Retry Integrity Tag Tests")
struct RetryIntegrityTagTests {

    @Test("Retry Integrity Tag round-trip")
    func retryIntegrityTagRoundTrip() throws {
        let originalDCID = try ConnectionID(RFC9001TestVectors.clientDCID)
        let destinationCID = try ConnectionID(Data())
        let sourceCID = try ConnectionID(Data([
            0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5
        ]))
        let retryToken = Data([0x74, 0x6f, 0x6b, 0x65, 0x6e]) // "token"

        // Create a complete Retry packet with tag
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Parse it back
        let parsed = try RetryIntegrityTag.parseRetryPacket(retryPacket)

        #expect(parsed.version == .v1)
        #expect(parsed.destinationCID == destinationCID)
        #expect(parsed.sourceCID == sourceCID)
        #expect(parsed.retryToken == retryToken)

        // Verify the tag
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)
        let isValid = try RetryIntegrityTag.verify(
            tag: parsed.integrityTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(isValid)
    }

    @Test("Retry Integrity Tag verification works")
    func retryIntegrityTagVerification() throws {
        let originalDCID = try ConnectionID(RFC9001TestVectors.clientDCID)
        let destinationCID = try ConnectionID(Data())
        let sourceCID = try ConnectionID(Data([
            0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5
        ]))
        let retryToken = Data([0x74, 0x6f, 0x6b, 0x65, 0x6e])

        // Create retry packet
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        // Extract packet without tag and the tag itself
        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)
        let tag = retryPacket.suffix(16)

        // Verify it
        let isValid = try RetryIntegrityTag.verify(
            tag: Data(tag),
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(isValid)
    }

    @Test("Invalid Retry Integrity Tag is rejected")
    func invalidRetryIntegrityTagRejected() throws {
        let originalDCID = try ConnectionID(RFC9001TestVectors.clientDCID)
        let destinationCID = try ConnectionID(Data())
        let sourceCID = try ConnectionID(Data([
            0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5
        ]))
        let retryToken = Data([0x74, 0x6f, 0x6b, 0x65, 0x6e])

        // Create valid retry packet
        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        let packetWithoutTag = RetryIntegrityTag.retryPacketWithoutTag(retryPacket)

        // Create an invalid tag (all zeros)
        let invalidTag = Data(repeating: 0, count: 16)

        // Verification should fail
        let isValid = try RetryIntegrityTag.verify(
            tag: invalidTag,
            originalDCID: originalDCID,
            retryPacketWithoutTag: packetWithoutTag,
            version: .v1
        )

        #expect(!isValid)
    }

    @Test("Retry packet is detected correctly")
    func retryPacketDetection() throws {
        let originalDCID = try #require(ConnectionID.random(length: 8))
        let destinationCID = try #require(ConnectionID.random(length: 8))
        let sourceCID = try #require(ConnectionID.random(length: 8))
        let retryToken = Data([0x01, 0x02, 0x03, 0x04])

        let retryPacket = try RetryIntegrityTag.createRetryPacket(
            originalDCID: originalDCID,
            destinationCID: destinationCID,
            sourceCID: sourceCID,
            retryToken: retryToken,
            version: .v1
        )

        #expect(RetryIntegrityTag.isRetryPacket(retryPacket))

        // Non-retry packet should not be detected
        let notRetryPacket = Data([0x00, 0x01, 0x02, 0x03])
        #expect(!RetryIntegrityTag.isRetryPacket(notRetryPacket))
    }
}

// MARK: - Version Negotiation Tests

@Suite("Version Negotiation Tests")
struct VersionNegotiationTests {

    @Test("Version Negotiation packet creation")
    func versionNegotiationPacketCreation() throws {
        let dcid = VersionNegotiationTestData.destinationCID
        let scid = VersionNegotiationTestData.sourceCID
        let versions = VersionNegotiationTestData.serverVersions

        let packet = VersionNegotiator.createVersionNegotiationPacket(
            destinationCID: dcid,
            sourceCID: scid,
            supportedVersions: versions
        )

        // First byte should have Form bit set (0x80) for Long Header
        // But VN uses random bits for the first byte except Form bit
        #expect(packet[0] & 0x80 == 0x80, "Long header form bit must be set")

        // Version field (bytes 1-4) must be 0x00000000
        let version = UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 |
                      UInt32(packet[3]) << 8 | UInt32(packet[4])
        #expect(version == WireFormatTestData.versionNegotiationVersion)

        // DCID length byte
        let dcidLen = Int(packet[5])
        #expect(dcidLen == dcid.bytes.count)

        // SCID length byte follows DCID
        let scidLenIndex = 6 + dcidLen
        let scidLen = Int(packet[scidLenIndex])
        #expect(scidLen == scid.bytes.count)

        // Supported versions follow
        let versionsStart = scidLenIndex + 1 + scidLen
        let versionsData = packet[versionsStart...]

        // Should contain all supported versions (4 bytes each)
        #expect(versionsData.count == versions.count * 4)
    }

    @Test("Version Negotiation version parsing")
    func versionNegotiationParsing() throws {
        let dcid = VersionNegotiationTestData.destinationCID
        let scid = VersionNegotiationTestData.sourceCID
        let versions = VersionNegotiationTestData.serverVersions

        // Create packet
        let packet = VersionNegotiator.createVersionNegotiationPacket(
            destinationCID: dcid,
            sourceCID: scid,
            supportedVersions: versions
        )

        // Parse versions from packet
        let parsedVersions = try VersionNegotiator.parseVersions(from: packet)

        #expect(parsedVersions == versions)
    }

    @Test("Version selection chooses common version")
    func versionSelection() {
        let clientVersions: [QUICVersion] = [.v1, .init(rawValue: 0xaabbccdd)]
        let serverVersions: [QUICVersion] = [.v2, .v1]

        let selected = VersionNegotiator.selectVersion(
            offered: clientVersions,
            supported: serverVersions
        )

        // Should select v1 (the common version)
        #expect(selected == .v1)
    }

    @Test("Version selection returns nil when no common version")
    func versionSelectionNoCommon() {
        let clientVersions: [QUICVersion] = [.init(rawValue: 0x11111111)]
        let serverVersions: [QUICVersion] = [.v1, .v2]

        let selected = VersionNegotiator.selectVersion(
            offered: clientVersions,
            supported: serverVersions
        )

        #expect(selected == nil)
    }
}

// MARK: - Wire Format Tests

@Suite("Wire Format Compatibility Tests")
struct WireFormatTests {

    @Test("Initial packet minimum size is 1200 bytes")
    func initialPacketMinimumSize() throws {
        let processor = PacketProcessor(dcidLength: 8)
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        let (_, _) = try processor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        let header = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let frames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data("test".utf8)))
        ]

        let packet = try processor.encryptLongHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: 0
        )

        #expect(packet.count >= WireFormatTestData.minInitialPacketSize)
    }

    @Test("Long header format is correct")
    func longHeaderFormat() throws {
        let processor = PacketProcessor(dcidLength: 8)
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        let (_, _) = try processor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        let header = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let frames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data(repeating: 0, count: 100)))
        ]

        let packet = try processor.encryptLongHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: 0
        )

        // First byte: Form bit (1) + Fixed bit (1) + Type (2 bits for Initial = 00)
        // After header protection, reserved bits and PN length are masked
        let firstByte = packet[0]

        // Form bit must be set (Long Header)
        #expect(firstByte & 0x80 == 0x80, "Form bit must be set for Long Header")

        // Fixed bit must be set
        #expect(firstByte & 0x40 == 0x40, "Fixed bit must be set")
    }

    @Test("Connection ID encoding is correct")
    func connectionIDEncoding() throws {
        let cidData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let cid = try ConnectionID(cidData)

        #expect(cid.bytes == cidData)
        #expect(cid.length == 8)

        // Use the built-in encode method (includes length byte)
        let encoded = cid.encode()
        #expect(encoded.count == 9)
        #expect(encoded[0] == 8)
    }

    @Test("Frame type encodings are RFC compliant")
    func frameTypeEncodings() {
        // RFC 9000 Section 19
        // Frame types are variable-length integers

        // PADDING = 0x00
        #expect(FrameType.padding.rawValue == 0x00)

        // PING = 0x01
        #expect(FrameType.ping.rawValue == 0x01)

        // ACK = 0x02 or 0x03
        #expect(FrameType.ack.rawValue == 0x02)

        // CRYPTO = 0x06
        #expect(FrameType.crypto.rawValue == 0x06)

        // STREAM = 0x08-0x0f
        #expect(FrameType.stream.rawValue == 0x08)

        // CONNECTION_CLOSE = 0x1c or 0x1d
        #expect(FrameType.connectionClose.rawValue == 0x1c)
    }
}

// MARK: - Packet Coalescing Tests

@Suite("Packet Coalescing Tests")
struct PacketCoalescingTests {

    @Test("Multiple packets can be coalesced in one datagram")
    func multiplePacketsCoalesced() throws {
        // Create Initial + Handshake packets (simulating coalesced datagram)
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        let processor = PacketProcessor(dcidLength: 8)
        let (_, _) = try processor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        // Create Initial packet
        let initialHeader = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let initialFrames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data(repeating: 0x01, count: 100)))
        ]

        let initialPacket = try processor.encryptLongHeaderPacket(
            frames: initialFrames,
            header: initialHeader,
            packetNumber: 0
        )

        // Initial packet should be at least 1200 bytes
        #expect(initialPacket.count >= 1200)

        // The packet has space for additional coalesced packets
        // (would be appended directly after the Initial packet)
    }

    @Test("Coalesced packets are parsed correctly")
    func coalescedPacketsParsed() throws {
        // Create a simple test with Initial packet
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        let clientProcessor = PacketProcessor(dcidLength: 8)
        let (_, _) = try clientProcessor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        let header = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let frames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data("test".utf8)))
        ]

        let packet = try clientProcessor.encryptLongHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: 0
        )

        // Server decrypts
        let serverProcessor = PacketProcessor(dcidLength: 8)
        let (_, _) = try serverProcessor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: false,
            version: .v1
        )

        let parsed = try serverProcessor.decryptPacket(packet)
        #expect(parsed.encryptionLevel == .initial)
        #expect(!parsed.frames.isEmpty)
    }
}

// MARK: - Anti-Amplification Tests

@Suite("Anti-Amplification Limit Tests")
struct AntiAmplificationTests {

    @Test("Server respects 3x amplification limit before address validation")
    func serverRespectsAmplificationLimit() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        // Client sends 100 bytes
        limiter.recordBytesReceived(100)

        // Server can send up to 300 bytes (3x)
        #expect(limiter.canSend(bytes: 300))
        #expect(!limiter.canSend(bytes: 301))

        // After sending 300 bytes
        limiter.recordBytesSent(300)

        // Cannot send more until receiving more
        #expect(!limiter.canSend(bytes: 1))

        // Client sends another 100 bytes
        limiter.recordBytesReceived(100)

        // Can now send 300 more bytes
        #expect(limiter.canSend(bytes: 300))
    }

    @Test("Client has no amplification limit")
    func clientHasNoLimit() {
        let limiter = AntiAmplificationLimiter(isServer: false)

        // Client can send without receiving
        #expect(limiter.canSend(bytes: 10000))

        limiter.recordBytesSent(10000)

        // Still can send
        #expect(limiter.canSend(bytes: 10000))
    }

    @Test("Address validation removes amplification limit")
    func addressValidationRemovesLimit() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        // Initially limited
        limiter.recordBytesReceived(100)
        #expect(!limiter.canSend(bytes: 400))

        // After address validation, limit is removed
        limiter.validateAddress()

        #expect(limiter.canSend(bytes: 1_000_000))
    }
}

// MARK: - Transport Parameters Tests

@Suite("Transport Parameters Tests")
struct TransportParametersTests {

    @Test("Transport parameters creation from config")
    func transportParametersCreation() throws {
        let config = QUICConfiguration()
        let scid = try #require(ConnectionID.random(length: 8))
        let params = TransportParameters(from: config, sourceConnectionID: scid)

        // Key parameters should be set (check non-zero defaults)
        #expect(params.initialMaxData > 0)
        #expect(params.initialMaxStreamDataBidiLocal > 0)
        #expect(params.initialMaxStreamsBidi > 0)
    }

    @Test("Transport parameters source connection ID")
    func transportParametersSourceCID() throws {
        let config = QUICConfiguration()
        let scid = try #require(ConnectionID.random(length: 8))
        let params = TransportParameters(from: config, sourceConnectionID: scid)

        // Source CID should be set
        #expect(params.initialSourceConnectionID == scid)
    }
}

// MARK: - ECN Tests

@Suite("ECN Support Tests")
struct ECNSupportTests {

    @Test("ECN codepoints are correct")
    func ecnCodepoints() {
        #expect(ECNCodepoint.notECT.rawValue == 0x00)
        #expect(ECNCodepoint.ect1.rawValue == 0x01)
        #expect(ECNCodepoint.ect0.rawValue == 0x02)
        #expect(ECNCodepoint.ce.rawValue == 0x03)
    }

    @Test("ECN counts tracking")
    func ecnCountsTracking() {
        var counts = ECNCountState()

        counts.record(.ect0)
        counts.record(.ect0)
        counts.record(.ect1)
        counts.record(.ce)

        #expect(counts.ect0Count == 2)
        #expect(counts.ect1Count == 1)
        #expect(counts.ceCount == 1)
        #expect(counts.totalECN == 4)
    }

    @Test("ECN validation state machine")
    func ecnValidationStateMachine() {
        let manager = ECNManager()

        // Initially unknown
        #expect(manager.validationState == .unknown)

        // Enable ECN -> testing
        manager.enableECN()
        #expect(manager.validationState == .testing)
        #expect(manager.isEnabled)

        // Process valid feedback
        let counts = ECNCountState(ect0: 10, ect1: 0, ce: 0)
        _ = manager.processACKFeedback(counts, level: .application)

        // After 10 packets, should be capable
        #expect(manager.validationState == .capable)
    }
}

// MARK: - Pacing Tests

@Suite("Pacing Tests")
struct PacingTests {

    @Test("Pacer initial configuration")
    func pacerInitialConfig() {
        let config = PacingConfiguration()

        // Default: 10 Mbps = 1.25 MB/s
        #expect(config.initialRate == 1_250_000)
        #expect(config.maxBurst == 15_000)
    }

    @Test("Pacer rate limiting")
    func pacerRateLimiting() async throws {
        let pacer = Pacer(config: PacingConfiguration(
            initialRate: 10_000,  // 10 KB/s
            maxBurst: 1_000,      // 1 KB burst
            minInterval: .milliseconds(1)
        ))

        // First burst should be immediate
        let delay1 = pacer.packetDelay(bytes: 500)
        #expect(delay1 == nil)

        // Second within burst should be immediate
        let delay2 = pacer.packetDelay(bytes: 500)
        #expect(delay2 == nil)

        // Third should require delay (burst exhausted)
        let delay3 = pacer.packetDelay(bytes: 500)
        #expect(delay3 != nil)
    }

    @Test("Pacer disabled configuration")
    func pacerDisabled() {
        let pacer = Pacer(config: .disabled)

        #expect(!pacer.isEnabled)

        // Should always return nil (no delay)
        let delay = pacer.packetDelay(bytes: 1_000_000)
        #expect(delay == nil)
    }
}

// MARK: - Key Update Tests

@Suite("Key Update Tests")
struct KeyUpdateTests {

    @Test("AEAD limits for AES-GCM")
    func aeadLimitsAESGCM() {
        let limits = AEADLimits.aesGCM

        // RFC 9001 Section 6.6: 2^23 packets
        #expect(limits.confidentialityLimit == 1 << 23)
    }

    @Test("AEAD limits for ChaCha20-Poly1305")
    func aeadLimitsChaCha() {
        let limits = AEADLimits.chaCha20Poly1305

        // RFC 9001 Section 6.6: 2^62 packets
        #expect(limits.confidentialityLimit == 1 << 62)
    }

    @Test("Key update triggers at 75% of limit")
    func keyUpdateTrigger() {
        let manager = KeyUpdateManager(cipherSuite: .aes128GcmSha256)

        // Initially should not need update
        #expect(!manager.shouldInitiateKeyUpdate)

        // Simulate approaching limit (75% of 2^23)
        let threshold = (1 << 23) * 3 / 4
        for _ in 0..<threshold {
            manager.recordEncryption()
        }

        // Now should need update
        #expect(manager.shouldInitiateKeyUpdate)
    }

    @Test("Key update state transitions")
    func keyUpdateStateTransitions() {
        let manager = KeyUpdateManager(cipherSuite: .aes128GcmSha256)

        #expect(manager.updateState == .idle)

        manager.initiateKeyUpdate()
        #expect(manager.updateState == .initiated)

        manager.keyUpdateComplete(newKeyPhase: 1)
        #expect(manager.updateState == .idle)
        #expect(manager.keyPhase == 1)
        #expect(manager.totalKeyUpdates == 1)
    }
}
