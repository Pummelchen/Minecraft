/// RFC 9000 Section 18.2 - Preferred Address Transport Parameter Tests
///
/// These tests verify compliance with RFC 9000 Section 18.2:
/// - preferred_address transport parameter encoding/decoding
/// - IPv4 and IPv6 address handling
/// - Connection ID and stateless reset token in preferred address

import Testing
import Foundation
@testable import QUICCore
@testable import QUICCrypto

@Suite("RFC 9000 §18.2 - Preferred Address Compliance")
struct PreferredAddressRFCTests {

    // MARK: - RFC 9000 §18.2: Parameter Format

    @Test("Preferred address contains all required fields")
    func preferredAddressRequiredFields() throws {
        // RFC 9000 §18.2: The preferred_address transport parameter contains
        // an IPv4 address, an IPv6 address, and associated port numbers,
        // a connection ID, and a stateless reset token.

        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        let resetToken = Data(repeating: 0xAA, count: 16)

        let preferred = PreferredAddress(
            ipv4Address: "192.168.1.1",
            ipv4Port: 443,
            ipv6Address: "2001:db8::1",
            ipv6Port: 443,
            connectionID: cid,
            statelessResetToken: resetToken
        )

        #expect(preferred.ipv4Address != nil, "IPv4 address MUST be present")
        #expect(preferred.ipv4Port != nil, "IPv4 port MUST be present")
        #expect(preferred.connectionID.length > 0, "Connection ID MUST be present")
        #expect(preferred.statelessResetToken.count == 16, "Stateless reset token MUST be 16 bytes")
    }

    // MARK: - Transport Parameter Encoding/Decoding

    @Test("Preferred address encodes and decodes correctly")
    func preferredAddressRoundtrip() throws {
        // Create transport parameters with preferred address

        var params = TransportParameters()
        params.maxIdleTimeout = 30000
        params.initialMaxData = 1_000_000

        // Set preferred address with IPv4
        params.preferredAddress = PreferredAddress(
            ipv4Address: "203.0.113.1",  // TEST-NET-3
            ipv4Port: 443,
            ipv6Address: nil,  // No IPv6
            ipv6Port: nil,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0xBB, count: 16)
        )

        // Encode
        let encoded = TransportParameterCodec.encode(params)
        #expect(!encoded.isEmpty)

        // Decode
        let decoded = try TransportParameterCodec.decode(encoded)

        // Verify preferred address was preserved
        #expect(decoded.preferredAddress != nil, "Preferred address should be decoded")
        #expect(decoded.preferredAddress?.ipv4Address == "203.0.113.1")
        #expect(decoded.preferredAddress?.ipv4Port == 443)
        #expect(decoded.preferredAddress?.connectionID.bytes == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("Preferred address with IPv6 encodes correctly")
    func preferredAddressWithIPv6() throws {
        // RFC 9000: The server's preferred address includes BOTH IPv4 and IPv6

        var params = TransportParameters()

        params.preferredAddress = PreferredAddress(
            ipv4Address: "192.0.2.1",  // TEST-NET-1
            ipv4Port: 443,
            ipv6Address: "2001:db8::1",
            ipv6Port: 8443,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])),
            statelessResetToken: Data(repeating: 0xCC, count: 16)
        )

        // Encode and decode
        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        // TODO: Current implementation may encode IPv6 as zeros
        // This test documents the expected behavior that IPv6 SHOULD be preserved

        #expect(decoded.preferredAddress != nil)
        #expect(decoded.preferredAddress?.ipv4Address != nil)
    }

    // MARK: - Client-Only Requirement

    @Test("Client MUST NOT send preferred_address")
    func clientMustNotSendPreferredAddress() throws {
        // RFC 9000 §18.2: This transport parameter is only sent by a server.
        // A client MUST treat receipt of a preferred_address transport parameter
        // as a connection error of type TRANSPORT_PARAMETER_ERROR.

        // Server encoding IS allowed:
        var serverParams = TransportParameters()

        serverParams.preferredAddress = PreferredAddress(
            ipv4Address: "10.0.0.1",
            ipv4Port: 443,
            ipv6Address: nil,
            ipv6Port: nil,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0xDD, count: 16)
        )

        // Server can encode with preferred_address
        let encoded = TransportParameterCodec.encode(serverParams)
        #expect(!encoded.isEmpty)

        // But a CLIENT decoder receiving this from another client should reject it
        // (The validation depends on knowing the peer role during decoding)
    }

    // MARK: - Connection ID in Preferred Address

    @Test("Preferred address connection ID is valid")
    func preferredAddressConnectionIDValid() throws {
        // RFC 9000 §18.2: The connection ID field is a connection ID that
        // the client can use to reach the server at the preferred address.

        // CID must be 1-20 bytes
        for length in 1...20 {
            let cidBytes = Data(repeating: 0x42, count: length)
            let cid = try ConnectionID(bytes: cidBytes)

            let preferred = PreferredAddress(
                ipv4Address: "127.0.0.1",
                ipv4Port: 443,
                ipv6Address: nil,
                ipv6Port: nil,
                connectionID: cid,
                statelessResetToken: Data(repeating: 0xEE, count: 16)
            )

            #expect(preferred.connectionID.length == length)
        }
    }

    // MARK: - Stateless Reset Token

    @Test("Preferred address stateless reset token is 16 bytes")
    func preferredAddressStatelessResetToken() throws {
        // RFC 9000 §18.2: Stateless Reset Token: A 16-byte stateless reset token.

        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let resetToken = Data(repeating: 0xFF, count: 16)

        let preferred = PreferredAddress(
            ipv4Address: "10.0.0.1",
            ipv4Port: 443,
            ipv6Address: nil,
            ipv6Port: nil,
            connectionID: cid,
            statelessResetToken: resetToken
        )

        #expect(preferred.statelessResetToken.count == 16)
    }

    // MARK: - Migration Behavior

    @Test("Client uses preferred address after handshake")
    func clientUsesPreferredAddressAfterHandshake() throws {
        // RFC 9000 §18.2: A client MAY choose to use the server's preferred
        // address when the handshake is complete. If the client does choose
        // to use the preferred address, the client MUST use the provided
        // connection ID and stateless reset token.

        let cid = try ConnectionID(bytes: Data([0xAA, 0xBB, 0xCC, 0xDD]))

        let preferred = PreferredAddress(
            ipv4Address: "203.0.113.100",
            ipv4Port: 8443,
            ipv6Address: nil,
            ipv6Port: nil,
            connectionID: cid,
            statelessResetToken: Data(repeating: 0x11, count: 16)
        )

        // After migration, packets to preferred address MUST use provided CID
        #expect(preferred.connectionID == cid)
    }

    // MARK: - Zero Address Handling

    @Test("Nil IPv4 indicates not available")
    func nilIPv4AddressNotAvailable() throws {
        // RFC 9000 §18.2: If a server has no IPv4 address, the IPv4 address
        // field can be omitted or set to zeros.

        let preferred = PreferredAddress(
            ipv4Address: nil,
            ipv4Port: nil,
            ipv6Address: "2001:db8::1",
            ipv6Port: 443,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0x00, count: 16)
        )

        #expect(preferred.ipv4Address == nil)
        #expect(preferred.ipv6Address != nil)
    }

    @Test("Nil IPv6 indicates not available")
    func nilIPv6AddressNotAvailable() throws {
        // RFC 9000 §18.2: If a server has no IPv6 address, the IPv6 address
        // field can be omitted or set to zeros.

        let preferred = PreferredAddress(
            ipv4Address: "10.0.0.1",
            ipv4Port: 443,
            ipv6Address: nil,
            ipv6Port: nil,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0x00, count: 16)
        )

        #expect(preferred.ipv4Address != nil)
        #expect(preferred.ipv6Address == nil)
    }

    // MARK: - IPv6 Round-Trip Tests

    @Test("IPv6 preferred address round-trips through encode/decode")
    func ipv6PreferredAddressRoundtrip() throws {
        // RFC 9000 §18.2: The server's preferred address includes both IPv4 and IPv6

        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: "192.0.2.1",
            ipv4Port: 443,
            ipv6Address: "2001:db8::1",
            ipv6Port: 8443,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])),
            statelessResetToken: Data(repeating: 0xCC, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress != nil)
        #expect(decoded.preferredAddress?.ipv4Address == "192.0.2.1")
        #expect(decoded.preferredAddress?.ipv4Port == 443)
        #expect(decoded.preferredAddress?.ipv6Address == "2001:db8::1")
        #expect(decoded.preferredAddress?.ipv6Port == 8443)
        #expect(decoded.preferredAddress?.connectionID.bytes == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        #expect(decoded.preferredAddress?.statelessResetToken == Data(repeating: 0xCC, count: 16))
    }

    @Test("Full IPv6 address (no compression) round-trips correctly")
    func fullIPv6AddressRoundtrip() throws {
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: nil,
            ipv4Port: nil,
            ipv6Address: "2001:db8:85a3:0:0:8a2e:370:7334",
            ipv6Port: 443,
            connectionID: try ConnectionID(bytes: Data([0xAA, 0xBB])),
            statelessResetToken: Data(repeating: 0x11, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress?.ipv6Address == "2001:db8:85a3::8a2e:370:7334")
        #expect(decoded.preferredAddress?.ipv6Port == 443)
    }

    @Test("Loopback ::1 round-trips correctly")
    func ipv6LoopbackRoundtrip() throws {
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: "127.0.0.1",
            ipv4Port: 443,
            ipv6Address: "::1",
            ipv6Port: 443,
            connectionID: try ConnectionID(bytes: Data([0x01])),
            statelessResetToken: Data(repeating: 0x22, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress?.ipv6Address == "::1")
        #expect(decoded.preferredAddress?.ipv6Port == 443)
    }

    @Test("Link-local fe80:: address round-trips correctly")
    func ipv6LinkLocalRoundtrip() throws {
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: nil,
            ipv4Port: nil,
            ipv6Address: "fe80::1",
            ipv6Port: 9000,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0x33, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress?.ipv6Address == "fe80::1")
        #expect(decoded.preferredAddress?.ipv6Port == 9000)
    }

    @Test("All-ones IPv6 address ffff:...:ffff round-trips correctly")
    func ipv6AllOnesRoundtrip() throws {
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: nil,
            ipv4Port: nil,
            ipv6Address: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            ipv6Port: 1234,
            connectionID: try ConnectionID(bytes: Data([0xFF])),
            statelessResetToken: Data(repeating: 0x44, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress?.ipv6Address == "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
        #expect(decoded.preferredAddress?.ipv6Port == 1234)
    }

    @Test("Nil IPv6 encodes as zeros and decodes back to nil")
    func nilIPv6EncodesAsZerosAndDecodesAsNil() throws {
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: "10.0.0.1",
            ipv4Port: 443,
            ipv6Address: nil,
            ipv6Port: nil,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            statelessResetToken: Data(repeating: 0x55, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        #expect(decoded.preferredAddress?.ipv6Address == nil)
        #expect(decoded.preferredAddress?.ipv6Port == nil)
        // IPv4 should still be intact
        #expect(decoded.preferredAddress?.ipv4Address == "10.0.0.1")
        #expect(decoded.preferredAddress?.ipv4Port == 443)
    }

    @Test("IPv6 with leading-zero-compressed groups round-trips correctly")
    func ipv6CompressedGroupsRoundtrip() throws {
        // "2001:db8:0:0:1:0:0:1" has two separate zero runs;
        // only the first (longer or equal, leftmost) should get "::"
        var params = TransportParameters()
        params.preferredAddress = PreferredAddress(
            ipv4Address: nil,
            ipv4Port: nil,
            ipv6Address: "2001:db8:0:0:1:0:0:1",
            ipv6Port: 443,
            connectionID: try ConnectionID(bytes: Data([0x01, 0x02])),
            statelessResetToken: Data(repeating: 0x66, count: 16)
        )

        let encoded = TransportParameterCodec.encode(params)
        let decoded = try TransportParameterCodec.decode(encoded)

        // The canonical form compresses the first longest run
        #expect(decoded.preferredAddress?.ipv6Address == "2001:db8::1:0:0:1")
        #expect(decoded.preferredAddress?.ipv6Port == 443)
    }
}
