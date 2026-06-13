/// TLS 1.3 Extension Tests

import Testing
import Foundation
@testable import QUICCrypto

@Suite("TLS Extension Tests")
struct ExtensionTests {

    // MARK: - SupportedVersions Tests

    @Test("SupportedVersionsClientHello roundtrip")
    func roundtripSupportedVersionsClient() throws {
        let versions: [UInt16] = [TLSConstants.version13, 0x0302]
        let original = SupportedVersionsClientHello(versions: versions)

        let encoded = original.encode()
        let decoded = try SupportedVersionsClientHello.decode(from: encoded)

        #expect(decoded.versions == original.versions)
        #expect(decoded.supportsTLS13 == true)
    }

    @Test("SupportedVersionsServerHello roundtrip")
    func roundtripSupportedVersionsServer() throws {
        let original = SupportedVersionsServerHello(selectedVersion: TLSConstants.version13)

        let encoded = original.encode()
        let decoded = try SupportedVersionsServerHello.decode(from: encoded)

        #expect(decoded.selectedVersion == TLSConstants.version13)
        #expect(decoded.isTLS13 == true)
    }

    // MARK: - SupportedGroups Tests

    @Test("SupportedGroups roundtrip")
    func roundtripSupportedGroups() throws {
        let groups: [NamedGroup] = [.x25519, .secp256r1]
        let original = SupportedGroupsExtension(namedGroups: groups)

        let encoded = original.encode()
        let decoded = try SupportedGroupsExtension.decode(from: encoded)

        #expect(decoded.namedGroups == original.namedGroups)
    }

    // MARK: - SignatureAlgorithms Tests

    @Test("SignatureAlgorithms roundtrip")
    func roundtripSignatureAlgorithms() throws {
        let algorithms: [SignatureScheme] = [.ecdsa_secp256r1_sha256, .rsa_pss_rsae_sha256]
        let original = SignatureAlgorithmsExtension(supportedSignatureAlgorithms: algorithms)

        let encoded = original.encode()
        let decoded = try SignatureAlgorithmsExtension.decode(from: encoded)

        #expect(decoded.supportedSignatureAlgorithms == original.supportedSignatureAlgorithms)
    }

    // MARK: - KeyShare Tests

    @Test("KeyShareEntry roundtrip")
    func roundtripKeyShareEntry() throws {
        let keyData = Data(repeating: 0x42, count: 32)
        let original = KeyShareEntry(group: .x25519, keyExchange: keyData)

        let encoded = original.encode()
        var reader = TLSReader(data: encoded)
        let decoded = try KeyShareEntry.decode(from: &reader)

        #expect(decoded.group == original.group)
        #expect(decoded.keyExchange == original.keyExchange)
    }

    @Test("KeyShareClientHello roundtrip")
    func roundtripKeyShareClient() throws {
        let shares = [
            KeyShareEntry(group: .x25519, keyExchange: Data(repeating: 0x11, count: 32)),
            KeyShareEntry(group: .secp256r1, keyExchange: Data(repeating: 0x22, count: 65))
        ]
        let original = KeyShareClientHello(clientShares: shares)

        let encoded = original.encode()
        let decoded = try KeyShareClientHello.decode(from: encoded)

        #expect(decoded.clientShares.count == original.clientShares.count)
        #expect(decoded.clientShares[0].group == original.clientShares[0].group)
    }

    @Test("KeyShareServerHello roundtrip")
    func roundtripKeyShareServer() throws {
        let entry = KeyShareEntry(group: .x25519, keyExchange: Data(repeating: 0x33, count: 32))
        let original = KeyShareServerHello(serverShare: entry)

        let encoded = original.encode()
        let decoded = try KeyShareServerHello.decode(from: encoded)

        #expect(decoded.serverShare.group == original.serverShare.group)
        #expect(decoded.serverShare.keyExchange == original.serverShare.keyExchange)
    }

    // MARK: - ALPN Tests

    @Test("ALPN roundtrip")
    func roundtripALPN() throws {
        let protocols = ["h3", "h3-29", "hq-interop"]
        let original = ALPNExtension(protocols: protocols)

        let encoded = original.encode()
        let decoded = try ALPNExtension.decode(from: encoded)

        #expect(decoded.protocols == original.protocols)
    }

    @Test("ALPN negotiation")
    func alpnNegotiation() throws {
        let client = ALPNExtension(protocols: ["h3", "h3-29", "h2"])
        let server = ALPNExtension(protocols: ["h3-29", "h3"])

        let negotiated = client.negotiate(with: server)
        #expect(negotiated == "h3") // First common from client's preference
    }

    @Test("ALPN no common protocol")
    func alpnNoCommon() throws {
        let client = ALPNExtension(protocols: ["h3"])
        let server = ALPNExtension(protocols: ["h2"])

        let negotiated = client.negotiate(with: server)
        #expect(negotiated == nil)
    }

    // MARK: - ServerName Tests

    @Test("ServerName roundtrip")
    func roundtripServerName() throws {
        let original = ServerNameExtension(hostName: "example.com")

        let encoded = original.encode()
        let decoded = try ServerNameExtension.decode(from: encoded)

        #expect(decoded.hostName == "example.com")
    }

    @Test("ServerName with subdomain")
    func serverNameWithSubdomain() throws {
        let original = ServerNameExtension(hostName: "api.example.com")

        let encoded = original.encode()
        let decoded = try ServerNameExtension.decode(from: encoded)

        #expect(decoded.hostName == "api.example.com")
    }

    // MARK: - QUIC Transport Parameters Tests

    @Test("QUIC transport parameters in extension")
    func quicTransportParams() throws {
        let params = Data([0x00, 0x04, 0x01, 0x02, 0x03, 0x04])
        let ext = TLSExtension.quicTransportParameters(params)

        // Just verify it can be created
        let encoded = ext.encode()
        #expect(encoded.count > 0)
    }

    // MARK: - TLSExtension Encoding Tests

    @Test("TLSExtension encodes with type and length")
    func extensionEncodingFormat() throws {
        let ext = TLSExtension.supportedVersionsClient([TLSConstants.version13])
        let encoded = ext.encode()

        var reader = TLSReader(data: encoded)
        let typeID = try reader.readUInt16()
        let length = try reader.readUInt16()

        #expect(typeID == TLSExtensionType.supportedVersions.rawValue)
        #expect(length > 0)
        #expect(encoded.count == 4 + Int(length)) // 2 bytes type + 2 bytes length + data
    }
}
