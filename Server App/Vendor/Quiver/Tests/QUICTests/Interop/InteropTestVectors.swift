/// QUIC Interoperability Test Vectors
///
/// Test vectors from RFC 9001 Appendix A for validating
/// QUIC implementation compatibility.

import Foundation
@testable import QUICCore
@testable import QUICCrypto

// MARK: - RFC 9001 Appendix A Test Vectors

/// Test vectors from RFC 9001 for Initial Secrets derivation
public struct RFC9001TestVectors {
    // MARK: - A.1 Keys

    /// Initial Client Destination Connection ID
    /// Used to derive initial secrets
    public static let clientDCID = Data([
        0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08
    ])

    /// Initial secret derived from DCID
    /// HKDF-Extract with salt = initial_salt
    public static let initialSecret = Data([
        0x7d, 0xb5, 0xdf, 0x06, 0xe7, 0xa6, 0x9e, 0x43,
        0x24, 0x96, 0xad, 0xed, 0xb0, 0x08, 0x51, 0x92,
        0x35, 0x95, 0x22, 0x15, 0x96, 0xae, 0x2a, 0xe9,
        0xfb, 0x81, 0x15, 0xc1, 0xe9, 0xed, 0x0a, 0x44
    ])

    /// Client initial secret
    public static let clientInitialSecret = Data([
        0xc0, 0x0c, 0xf1, 0x51, 0xca, 0x5b, 0xe0, 0x75,
        0xed, 0x0e, 0xbf, 0xb5, 0xc8, 0x03, 0x23, 0xc4,
        0x2d, 0x6b, 0x7d, 0xb6, 0x78, 0x81, 0x28, 0x9a,
        0xf4, 0x00, 0x8f, 0x1f, 0x6c, 0x35, 0x7a, 0xea
    ])

    /// Server initial secret
    public static let serverInitialSecret = Data([
        0x3c, 0x19, 0x98, 0x28, 0xfd, 0x13, 0x9e, 0xfd,
        0x21, 0x6c, 0x15, 0x5a, 0xd8, 0x44, 0xcc, 0x81,
        0xfb, 0x82, 0xfa, 0x8d, 0x74, 0x46, 0xfa, 0x7d,
        0x78, 0xbe, 0x80, 0x3a, 0xcd, 0xda, 0x95, 0x1b
    ])

    /// Client AEAD key (AES-128-GCM)
    public static let clientKey = Data([
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
        0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d
    ])

    /// Client IV
    public static let clientIV = Data([
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
        0x46, 0xfb, 0x25, 0x5c
    ])

    /// Client header protection key
    public static let clientHP = Data([
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
        0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2
    ])

    /// Server AEAD key
    public static let serverKey = Data([
        0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
        0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37
    ])

    /// Server IV
    public static let serverIV = Data([
        0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53,
        0xb0, 0xbb, 0xa0, 0x3e
    ])

    /// Server header protection key
    public static let serverHP = Data([
        0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
        0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14
    ])

    // MARK: - A.2 Client Initial

    /// Sample unprotected client Initial packet header
    /// (packet number = 2, includes payload length)
    public static let clientInitialUnprotectedHeader = Data([
        0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94,
        0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x00, 0x00,
        0x44, 0x9e, 0x00, 0x00, 0x00, 0x02
    ])

    /// First 16 bytes of payload CRYPTO frame (for header protection sample)
    public static let clientInitialPayloadSample = Data([
        0xd1, 0xb1, 0xc9, 0x8d, 0xd7, 0x68, 0x9f, 0xb8,
        0xec, 0x11, 0xd2, 0x42, 0xb1, 0x23, 0xdc, 0x9b
    ])

    // MARK: - A.4 Retry Integrity Tag

    /// Key used for Retry Integrity Tag (RFC 9001 Section 5.8)
    public static let retryIntegrityKey = Data([
        0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a,
        0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e
    ])

    /// Nonce for Retry Integrity Tag
    public static let retryIntegrityNonce = Data([
        0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2,
        0x23, 0x98, 0x25, 0xbb
    ])

    /// Sample Retry packet (without tag)
    public static let sampleRetryPseudoPacket = Data([
        // Original DCID length
        0x08,
        // Original DCID
        0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08,
        // Retry header and content
        0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0,
        0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5, 0x74,
        0x6f, 0x6b, 0x65, 0x6e
    ])

    /// Expected Retry Integrity Tag
    public static let expectedRetryIntegrityTag = Data([
        0xd1, 0x69, 0x26, 0xd8, 0x1f, 0x6f, 0x9c, 0xa2,
        0x95, 0x3a, 0x8a, 0xa4, 0x57, 0x5e, 0x1e, 0x49
    ])
}

// MARK: - Version Negotiation Test Data

/// Test data for Version Negotiation
public struct VersionNegotiationTestData {
    /// Client-sent version (unsupported)
    public static let clientVersion: QUICVersion = .init(rawValue: 0xff000000)

    /// Server supported versions
    public static let serverVersions: [QUICVersion] = [.v1, .v2]

    /// Sample destination CID for VN packet
    public static let destinationCID = try! ConnectionID(Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ]))

    /// Sample source CID for VN packet
    public static let sourceCID = try! ConnectionID(Data([
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18
    ]))
}

// MARK: - 0-RTT Test Data

/// Test data for 0-RTT (Early Data)
public struct ZeroRTTTestData {
    /// Sample Application-Layer Protocol Negotiation (ALPN)
    public static let alpn = "h3"

    /// Sample early data to send
    public static let earlyData = Data("GET / HTTP/3\r\n".utf8)

    /// Maximum early data size (from NewSessionTicket)
    public static let maxEarlyDataSize: UInt32 = 0xffffffff

    /// Frames NOT allowed in 0-RTT (RFC 9000 Section 19.2)
    public static let forbiddenIn0RTT: [String] = [
        "ACK",
        "CRYPTO",
        "HANDSHAKE_DONE",
        "NEW_TOKEN",
        "PATH_CHALLENGE",
        "PATH_RESPONSE",
        "RETIRE_CONNECTION_ID",
        "NEW_CONNECTION_ID"
    ]
}

// MARK: - Connection Migration Test Data

/// Test data for Connection Migration
public struct ConnectionMigrationTestData {
    /// Original path address (IP, port)
    public static let originalPath = (ipAddress: "192.168.1.100", port: UInt16(54321))

    /// New path address (after migration)
    public static let newPath = (ipAddress: "192.168.2.200", port: UInt16(54322))

    /// Sample PATH_CHALLENGE data (8 bytes random)
    public static let pathChallengeData = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])
}

// MARK: - Protocol Wire Formats

/// Expected packet formats for interoperability
public struct WireFormatTestData {
    /// Long Header first byte format: Form(1) | Fixed(1) | Type(2) | Reserved(2) | PN Length(2)
    /// Initial: 1 1 00 XX XX (0xC0-0xCF)
    public static let initialPacketTypeMask: UInt8 = 0xF0
    public static let initialPacketTypeValue: UInt8 = 0xC0

    /// Version Negotiation packet: version field = 0x00000000
    public static let versionNegotiationVersion: UInt32 = 0x00000000

    /// QUIC v1 version number
    public static let quicV1Version: UInt32 = 0x00000001

    /// QUIC v2 version number (RFC 9369)
    public static let quicV2Version: UInt32 = 0x6b3343cf

    /// Minimum Initial packet size (RFC 9000 Section 14.1)
    public static let minInitialPacketSize = 1200

    /// Maximum UDP payload size
    public static let maxUDPPayloadSize = 65527
}
