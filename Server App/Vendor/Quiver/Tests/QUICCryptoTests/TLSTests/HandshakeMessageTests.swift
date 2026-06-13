/// TLS 1.3 Handshake Message Tests

import Testing
import Foundation
@testable import QUICCrypto

@Suite("Handshake Message Tests")
struct HandshakeMessageTests {

    // MARK: - TLSReader Tests

    @Test("TLSReader reads UInt8")
    func readUInt8() throws {
        var reader = TLSReader(data: Data([0x42, 0x00]))
        #expect(try reader.readUInt8() == 0x42)
        #expect(reader.remaining == 1)
    }

    @Test("TLSReader reads UInt16")
    func readUInt16() throws {
        var reader = TLSReader(data: Data([0x01, 0x02]))
        #expect(try reader.readUInt16() == 0x0102)
    }

    @Test("TLSReader reads UInt24")
    func readUInt24() throws {
        var reader = TLSReader(data: Data([0x01, 0x02, 0x03]))
        #expect(try reader.readUInt24() == 0x010203)
    }

    @Test("TLSReader reads UInt32")
    func readUInt32() throws {
        var reader = TLSReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        #expect(try reader.readUInt32() == 0x01020304)
    }

    @Test("TLSReader reads bytes")
    func readBytes() throws {
        var reader = TLSReader(data: Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let bytes = try reader.readBytes(3)
        #expect(bytes == Data([0x01, 0x02, 0x03]))
        #expect(reader.remaining == 2)
    }

    @Test("TLSReader reads vector8")
    func readVector8() throws {
        var reader = TLSReader(data: Data([0x03, 0x01, 0x02, 0x03, 0xFF]))
        let bytes = try reader.readVector8()
        #expect(bytes == Data([0x01, 0x02, 0x03]))
        #expect(reader.remaining == 1)
    }

    @Test("TLSReader reads vector16")
    func readVector16() throws {
        var reader = TLSReader(data: Data([0x00, 0x03, 0x01, 0x02, 0x03]))
        let bytes = try reader.readVector16()
        #expect(bytes == Data([0x01, 0x02, 0x03]))
    }

    @Test("TLSReader throws on underflow")
    func readUnderflow() throws {
        var reader = TLSReader(data: Data([0x01]))
        #expect(throws: TLSDecodeError.self) {
            _ = try reader.readUInt16()
        }
    }

    // MARK: - TLSWriter Tests

    @Test("TLSWriter writes UInt8")
    func writeUInt8() throws {
        var writer = TLSWriter()
        writer.writeUInt8(0x42)
        #expect(writer.finish() == Data([0x42]))
    }

    @Test("TLSWriter writes UInt16")
    func writeUInt16() throws {
        var writer = TLSWriter()
        writer.writeUInt16(0x0102)
        #expect(writer.finish() == Data([0x01, 0x02]))
    }

    @Test("TLSWriter writes UInt24")
    func writeUInt24() throws {
        var writer = TLSWriter()
        writer.writeUInt24(0x010203)
        #expect(writer.finish() == Data([0x01, 0x02, 0x03]))
    }

    @Test("TLSWriter writes UInt32")
    func writeUInt32() throws {
        var writer = TLSWriter()
        writer.writeUInt32(0x01020304)
        #expect(writer.finish() == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("TLSWriter writes vector16")
    func writeVector16() throws {
        var writer = TLSWriter()
        writer.writeVector16(Data([0x01, 0x02, 0x03]))
        #expect(writer.finish() == Data([0x00, 0x03, 0x01, 0x02, 0x03]))
    }

    // MARK: - HandshakeCodec Tests

    @Test("Encode and decode handshake header")
    func roundtripHandshakeHeader() throws {
        let content = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = HandshakeCodec.encode(type: .clientHello, content: content)

        #expect(encoded.count == 4 + content.count)
        #expect(encoded[0] == HandshakeType.clientHello.rawValue)

        let (decodedType, decodedLength) = try HandshakeCodec.decodeHeader(from: encoded)
        #expect(decodedType == .clientHello)
        #expect(decodedLength == content.count)
    }

    // MARK: - ClientHello Tests

    @Test("ClientHello encodes correctly")
    func encodeClientHello() throws {
        let random = Data(repeating: 0xAA, count: 32)
        let sessionID = Data(repeating: 0xBB, count: 32)

        let clientHello = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: [
                .supportedVersionsClient([TLSConstants.version13])
            ]
        )

        let message = clientHello.encodeAsHandshake()

        // First byte should be ClientHello type (1)
        #expect(message[0] == 0x01)

        // Should be able to decode
        let (type, length) = try HandshakeCodec.decodeHeader(from: message)
        #expect(type == .clientHello)
        #expect(length > 0)
    }

    @Test("ClientHello roundtrip")
    func roundtripClientHello() throws {
        let random = Data(repeating: 0xAA, count: 32)
        let sessionID = Data(repeating: 0xBB, count: 32)
        let transportParams = Data([0x00, 0x01, 0x02, 0x03])

        let original = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256, .tls_aes_256_gcm_sha384],
            extensions: [
                .supportedVersionsClient([TLSConstants.version13]),
                .quicTransportParameters(transportParams)
            ]
        )

        let encoded = original.encode()
        let decoded = try ClientHello.decode(from: encoded)

        #expect(decoded.random == original.random)
        #expect(decoded.legacySessionID == original.legacySessionID)
        #expect(decoded.cipherSuites == original.cipherSuites)
        #expect(decoded.extensions.count == original.extensions.count)
    }

    @Test("ClientHello supportedVersions property works after decode")
    func clientHelloSupportedVersionsProperty() throws {
        let random = Data(repeating: 0xAA, count: 32)
        let sessionID = Data(repeating: 0xBB, count: 32)

        let original = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: [
                .supportedVersionsClient([TLSConstants.version13]),
                .keyShareClient([KeyShareEntry(group: .x25519, keyExchange: Data(repeating: 0x11, count: 32))])
            ]
        )

        // Verify properties work before encoding
        #expect(original.supportedVersions != nil, "Original should have supportedVersions")
        #expect(original.supportedVersions?.supportsTLS13 == true, "Original should support TLS 1.3")
        #expect(original.keyShare != nil, "Original should have keyShare")

        // Encode and decode
        let encoded = original.encode()
        let decoded = try ClientHello.decode(from: encoded)

        // Verify properties work after decoding
        #expect(decoded.supportedVersions != nil, "Decoded should have supportedVersions")
        #expect(decoded.supportedVersions?.supportsTLS13 == true, "Decoded should support TLS 1.3")
        #expect(decoded.keyShare != nil, "Decoded should have keyShare")
    }

    @Test("ClientHello roundtrip through handshake message format")
    func clientHelloHandshakeMessageRoundtrip() throws {
        let random = Data(repeating: 0xAA, count: 32)
        let sessionID = Data(repeating: 0xBB, count: 32)

        let original = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: [
                .supportedVersionsClient([TLSConstants.version13]),
                .keyShareClient([KeyShareEntry(group: .x25519, keyExchange: Data(repeating: 0x11, count: 32))]),
                .alpnProtocols(["h3"]),
                .quicTransportParameters(Data([0x00, 0x01]))
            ]
        )

        // Encode as handshake message (with header)
        let handshakeMessage = original.encodeAsHandshake()

        // Verify handshake header
        let (messageType, contentLength) = try HandshakeCodec.decodeHeader(from: handshakeMessage)
        #expect(messageType == .clientHello)

        // Extract content (without header)
        let content = handshakeMessage.subdata(in: 4..<(4 + contentLength))

        // Decode content
        let decoded = try ClientHello.decode(from: content)

        // Verify properties work after decoding
        #expect(decoded.supportedVersions != nil, "Decoded should have supportedVersions")
        #expect(decoded.supportedVersions?.supportsTLS13 == true, "Decoded should support TLS 1.3")
        #expect(decoded.keyShare != nil, "Decoded should have keyShare")
        #expect(decoded.alpn != nil, "Decoded should have ALPN")
    }

    // MARK: - ServerHello Tests

    @Test("ServerHello encodes correctly")
    func encodeServerHello() throws {
        let sessionID = Data(repeating: 0xDD, count: 32)

        let serverHello = ServerHello(
            legacySessionIDEcho: sessionID,
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: [
                .supportedVersionsServer(TLSConstants.version13)
            ]
        )

        let message = serverHello.encodeAsHandshake()
        #expect(message[0] == 0x02) // ServerHello type
    }

    @Test("ServerHello HelloRetryRequest detection")
    func detectHelloRetryRequest() throws {
        let hrr = ServerHello(
            random: TLSConstants.helloRetryRequestRandom,
            legacySessionIDEcho: Data(count: 32),
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: []
        )

        #expect(hrr.isHelloRetryRequest == true)

        let normal = ServerHello(
            legacySessionIDEcho: Data(count: 32),
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: []
        )

        #expect(normal.isHelloRetryRequest == false)
    }

    // MARK: - Finished Tests

    @Test("Finished roundtrip")
    func roundtripFinished() throws {
        let verifyData = Data(repeating: 0xEE, count: 32)
        let original = Finished(verifyData: verifyData)

        let encoded = original.encode()
        let decoded = try Finished.decode(from: encoded)

        #expect(decoded.verifyData == original.verifyData)
        #expect(decoded.verify(expected: verifyData) == true)
        #expect(decoded.verify(expected: Data(repeating: 0xFF, count: 32)) == false)
    }

    // MARK: - Alert Tests

    @Test("Alert encoding and decoding")
    func alertRoundtrip() throws {
        let alert = TLSAlert(description: .handshakeFailure)

        #expect(alert.level == .fatal, "handshake_failure should be fatal")
        #expect(alert.alertDescription == .handshakeFailure)

        let encoded = alert.encode()
        #expect(encoded.count == 2)
        #expect(encoded[0] == 2)  // fatal level
        #expect(encoded[1] == 40) // handshake_failure

        let decoded = try TLSAlert.decode(from: encoded)
        #expect(decoded == alert)
    }

    @Test("Alert closeNotify is warning level")
    func alertCloseNotifyLevel() {
        let alert = TLSAlert(description: .closeNotify)
        #expect(alert.level == .warning, "close_notify should be warning")
        #expect(alert.alertDescription.isFatal == false)
    }

    @Test("Alert userCanceled is warning level")
    func alertUserCanceledLevel() {
        let alert = TLSAlert(description: .userCanceled)
        #expect(alert.level == .warning, "user_canceled should be warning")
        #expect(alert.alertDescription.isFatal == false)
    }

    @Test("Alert fatal descriptions")
    func alertFatalDescriptions() {
        let fatalAlerts: [AlertDescription] = [
            .unexpectedMessage,
            .badRecordMac,
            .handshakeFailure,
            .badCertificate,
            .decodeError,
            .internalError,
            .missingExtension,
            .noApplicationProtocol
        ]

        for desc in fatalAlerts {
            let alert = TLSAlert(description: desc)
            #expect(alert.level == .fatal, "\(desc.description) should be fatal")
            #expect(desc.isFatal == true)
        }
    }

    @Test("Alert QUIC error code conversion")
    func alertQUICErrorCode() {
        let alert = TLSAlert(description: .handshakeFailure)
        #expect(alert.quicErrorCode == 0x100 + 40)

        let alert2 = TLSAlert(description: .noApplicationProtocol)
        #expect(alert2.quicErrorCode == 0x100 + 120)

        // Convert back from QUIC error code
        let recovered = TLSAlert.fromQUICErrorCode(0x100 + 40)
        #expect(recovered != nil)
        #expect(recovered?.alertDescription == .handshakeFailure)

        // Invalid QUIC error code (not in crypto range)
        let invalid = TLSAlert.fromQUICErrorCode(0x50)
        #expect(invalid == nil)
    }

    @Test("Alert description strings")
    func alertDescriptionStrings() {
        #expect(AlertDescription.closeNotify.description == "close_notify")
        #expect(AlertDescription.handshakeFailure.description == "handshake_failure")
        #expect(AlertDescription.noApplicationProtocol.description == "no_application_protocol")
    }

    @Test("TLSHandshakeError to Alert mapping")
    func handshakeErrorToAlert() {
        let error1 = TLSHandshakeError.unsupportedVersion
        #expect(error1.toAlert.alertDescription == .protocolVersion)

        let error2 = TLSHandshakeError.noALPNMatch
        #expect(error2.toAlert.alertDescription == .noApplicationProtocol)

        let error3 = TLSHandshakeError.signatureVerificationFailed
        #expect(error3.toAlert.alertDescription == .decryptError)

        let error4 = TLSHandshakeError.missingExtension("key_share")
        #expect(error4.toAlert.alertDescription == .missingExtension)

        let error5 = TLSHandshakeError.certificateVerificationFailed("bad cert")
        #expect(error5.toAlert.alertDescription == .badCertificate)
    }

    @Test("TLSError to Alert mapping")
    func tlsErrorToAlert() {
        let error1 = TLSError.noALPNMatch
        #expect(error1.toAlert.alertDescription == .noApplicationProtocol)

        let error2 = TLSError.certificateVerificationFailed("test")
        #expect(error2.toAlert.alertDescription == .badCertificate)

        let error3 = TLSError.unexpectedMessage("test")
        #expect(error3.toAlert.alertDescription == .unexpectedMessage)

        let error4 = TLSError.internalError("test")
        #expect(error4.toAlert.alertDescription == .internalError)
    }
}
