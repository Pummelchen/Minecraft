# RFC Compliance Documentation

This document maps the Quiver implementation to the QUIC specifications (RFC 9000, RFC 9001, RFC 9002).

## Summary

| RFC | Title | Compliance Status |
|-----|-------|-------------------|
| RFC 9000 | QUIC: A UDP-Based Multiplexed and Secure Transport | Compliant |
| RFC 9001 | Using TLS to Secure QUIC | Compliant |
| RFC 9002 | QUIC Loss Detection and Congestion Control | Compliant |
| RFC 9221 | DATAGRAM Extension | Compliant |
| RFC 9369 | QUIC Version 2 | Compliant |

---

## 2026-02-09 Audit Notes

- **WebTransport draft (Extended CONNECT, capsules):** `Sources/HTTP3/WebTransport/WebTransportSession.swift` now keeps sessions established when the peer half-closes the CONNECT stream (FIN) and awaits explicit CLOSE/DRAIN capsules. Previously the reader loop treated a FIN as a terminal close, immediately dropping the session and violating the draft’s requirement that session teardown be signaled by capsules. This also fixes `WebTransportServePathTests.testCreateSessionViaContextConnection`.
- **Pitfalls / dead code:** No unreachable code paths were found in the WebTransport control-plane. The prior FIN-triggered teardown was the main behavioral pitfall discovered during this review.
- **Memory-safety review:** The WebTransport capsule codec bounds parsing via varint lengths and QUIC flow control; the session actor avoids shared mutable state. No stack overflows or use-after-free risks were identified in the audited paths.

---

## RFC 9001: Using TLS to Secure QUIC

### Section 5.2: Initial Secrets

**RFC Requirement:**
```
initial_salt = 0x38762cf7f55934b34d179ae6a4c80cadccbb7f0a (QUIC v1)
initial_salt = 0x0dede3def700a6db819381be6e269dcbf9bd2ed9 (QUIC v2)
initial_secret = HKDF-Extract(initial_salt, client_dst_connection_id)
client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)
server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", 32)
```

**Implementation:** `Sources/QUICCore/Packet/Version.swift:47-66`
```swift
public var initialSalt: Data? {
    switch self {
    case .v1:
        return Data([
            0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
            0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
            0xcc, 0xbb, 0x7f, 0x0a
        ])
    case .v2:
        return Data([
            0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb,
            0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb,
            0xf9, 0xbd, 0x2e, 0xd9
        ])
    default:
        return nil
    }
}
```

**Implementation:** `Sources/QUICCrypto/InitialSecrets.swift:25-58`
```swift
public static func derive(connectionID: ConnectionID, version: QUICVersion) throws -> InitialSecrets {
    let initialSecret = deriveInitialSecret(connectionID: connectionID, salt: salt)
    let clientSecret = try hkdfExpandLabel(secret: initialSecret, label: "client in", context: Data(), length: 32)
    let serverSecret = try hkdfExpandLabel(secret: initialSecret, label: "server in", context: Data(), length: 32)
    // ...
}
```

**Compliance:** COMPLIANT

---

### Section 5.1: Key Derivation (HKDF-Expand-Label)

**RFC Requirement:**
```
HKDF-Expand-Label(Secret, Label, Context, Length) =
    HKDF-Expand(Secret, HkdfLabel, Length)

struct {
    uint16 length = Length;
    opaque label<7..255> = "tls13 " + Label;
    opaque context<0..255> = Context;
} HkdfLabel;
```

**Implementation:** `Sources/QUICCrypto/InitialSecrets.swift:135-167`
```swift
func hkdfExpandLabel(secret: SymmetricKey, label: String, context: Data, length: Int) throws -> Data {
    let fullLabel = "tls13 " + label  // RFC 8446 prefix
    let labelBytes = Data(fullLabel.utf8)

    var hkdfLabel = Data()
    hkdfLabel.append(UInt8(length >> 8))      // uint16 length
    hkdfLabel.append(UInt8(length & 0xFF))
    hkdfLabel.append(UInt8(labelBytes.count)) // opaque label<7..255>
    hkdfLabel.append(labelBytes)
    hkdfLabel.append(UInt8(context.count))    // opaque context<0..255>
    hkdfLabel.append(context)

    let output = HKDF<SHA256>.expand(pseudoRandomKey: secret, info: hkdfLabel, outputByteCount: length)
    return output.withUnsafeBytes { Data($0) }
}
```

**Compliance:** COMPLIANT

---

### Section 5.1: Key Material Derivation

**RFC Requirement:**
```
key = HKDF-Expand-Label(secret, "quic key", "", key_length)
iv  = HKDF-Expand-Label(secret, "quic iv", "", 12)
hp  = HKDF-Expand-Label(secret, "quic hp", "", key_length)
```

For AES-128-GCM: key_length = 16

**Implementation:** `Sources/QUICCrypto/InitialSecrets.swift:87-119`
```swift
public static func derive(from secret: SymmetricKey) throws -> KeyMaterial {
    let key = try hkdfExpandLabel(secret: secret, label: "quic key", context: Data(), length: 16)
    let iv = try hkdfExpandLabel(secret: secret, label: "quic iv", context: Data(), length: 12)
    let hp = try hkdfExpandLabel(secret: secret, label: "quic hp", context: Data(), length: 16)
    return KeyMaterial(key: SymmetricKey(data: key), iv: iv, hp: SymmetricKey(data: hp))
}
```

**Compliance:** COMPLIANT

---

### Section 5.3: AEAD Usage

**RFC Requirement:**
- AES-128-GCM with 16-byte authentication tag
- Nonce = IV XOR packet_number (packet number left-padded to 12 bytes)
- AAD = Header up to and including the unprotected packet number

**Implementation:** `Sources/QUICCrypto/AEAD.swift:66-87` (Opener)
```swift
public func open(ciphertext: Data, packetNumber: UInt64, header: Data) throws -> Data {
    let nonce = constructNonce(iv: iv, packetNumber: packetNumber)
    let encryptedData = ciphertext.prefix(ciphertext.count - 16)
    let tag = ciphertext.suffix(16)
    let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: encryptedData, tag: tag)
    let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: header)
    return plaintext
}
```

**Implementation:** `Sources/QUICCrypto/AEAD.swift:146-160` (Sealer)
```swift
public func seal(plaintext: Data, packetNumber: UInt64, header: Data) throws -> Data {
    let nonce = constructNonce(iv: iv, packetNumber: packetNumber)
    let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
    return sealedBox.ciphertext + sealedBox.tag
}
```

**Implementation:** `Sources/QUICCrypto/AEAD.swift:194-214` (Nonce Construction)
```swift
private func constructNonce(iv: Data, packetNumber: UInt64) -> Data {
    var nonce = iv
    nonce.withUnsafeMutableBytes { buffer in
        let ptr = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let offset = buffer.count - 8
        ptr[offset + 0] ^= UInt8(truncatingIfNeeded: packetNumber >> 56)
        ptr[offset + 1] ^= UInt8(truncatingIfNeeded: packetNumber >> 48)
        // ... remaining bytes
        ptr[offset + 7] ^= UInt8(truncatingIfNeeded: packetNumber)
    }
    return nonce
}
```

**Compliance:** COMPLIANT

---

### Section 5.4: Header Protection

**RFC Requirement:**
- Sample: 16 bytes starting at `pn_offset + 4`
- Mask: AES-ECB(hp_key, sample) for AES-based ciphers
- Long header: mask lower 4 bits of first byte
- Short header: mask lower 5 bits of first byte
- Packet number bytes: XOR with mask[1..pn_length+1]

**Implementation:** `Sources/QUICCrypto/AEAD.swift:26-32` (Mask Generation)
```swift
public func mask(sample: Data) throws -> Data {
    guard sample.count >= 16 else {
        throw CryptoError.insufficientSample(expected: 16, actual: sample.count)
    }
    return try aesECBEncrypt(key: key, block: sample.prefix(16))
}
```

**Implementation:** `Sources/QUICCrypto/AEAD.swift:89-111` (Header Protection Removal)
```swift
public func removeHeaderProtection(sample: Data, firstByte: UInt8, packetNumberBytes: Data) throws -> (UInt8, Data) {
    let mask = try headerProtection.mask(sample: sample)
    let isLongHeader = (firstByte & 0x80) != 0
    let firstByteMask: UInt8 = isLongHeader ? 0x0F : 0x1F
    let unprotectedFirstByte = firstByte ^ (mask[0] & firstByteMask)
    var unprotectedPN = Data(capacity: packetNumberBytes.count)
    for i in 0..<packetNumberBytes.count {
        unprotectedPN.append(packetNumberBytes[i] ^ mask[i + 1])
    }
    return (unprotectedFirstByte, unprotectedPN)
}
```

**Implementation:** `Sources/QUICCore/Packet/PacketCodec.swift:177-180` (Sample Offset)
```swift
let pnOffset = headerWithLength.count
let sampleOffset = pnOffset + 4  // Sample starts at PN offset + 4 bytes
let sample = packet[sampleOffset..<(sampleOffset + 16)]
```

**Compliance:** COMPLIANT

---

### Section 5.8: Retry Integrity

**RFC Requirement:**
- QUIC v1: Key = `0xbe0c690b9f66575a1d766b54e368c84e`, Nonce = `0x461599d35d632bf2239825bb`
- QUIC v2: Key = `0x8fb4b01b56ac48e260fbcbcead7ccc92`, Nonce = `0xd86969bc2d7c6d9990efb04a`

**Implementation:** `Sources/QUICCore/Packet/Version.swift:70-104`
```swift
public var retryIntegrityKey: Data? {
    switch self {
    case .v1:
        return Data([0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a,
                     0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e])
    case .v2:
        return Data([0x8f, 0xb4, 0xb0, 0x1b, 0x56, 0xac, 0x48, 0xe2,
                     0x60, 0xfb, 0xcb, 0xce, 0xad, 0x7c, 0xcc, 0x92])
    // ...
    }
}

public var retryIntegrityNonce: Data? {
    switch self {
    case .v1:
        return Data([0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2,
                     0x23, 0x98, 0x25, 0xbb])
    case .v2:
        return Data([0xd8, 0x69, 0x69, 0xbc, 0x2d, 0x7c, 0x6d, 0x99,
                     0x90, 0xef, 0xb0, 0x4a])
    // ...
    }
}
```

**Compliance:** COMPLIANT

---

### Section 6: Key Update

**RFC Requirement:**
```
secret_<n+1> = HKDF-Expand-Label(secret_<n>, "quic ku", "", 32)
```

**Implementation:** `Sources/QUICCrypto/KeySchedule/KeySchedule.swift:132-171`
```swift
public mutating func updateKeys() throws -> (client: KeyMaterial, server: KeyMaterial) {
    let newClientSecretData = try hkdfExpandLabel(
        secret: clientAppSecret, label: "quic ku", context: Data(), length: 32)
    let newServerSecretData = try hkdfExpandLabel(
        secret: serverAppSecret, label: "quic ku", context: Data(), length: 32)
    // Update stored secrets and derive new key material
    keyPhase ^= 1
    keyUpdateCount += 1
    // ...
}
```

**Compliance:** COMPLIANT

---

## RFC 9000: QUIC Transport Protocol

### Section 8.1: Address Validation (Anti-Amplification)

**RFC Requirement:**
> Prior to validating the client address, servers MUST NOT send more than three times as many bytes as the number of bytes they have received.

**Implementation:** `Sources/QUICRecovery/AntiAmplificationLimiter.swift:36-68`
```swift
public final class AntiAmplificationLimiter: Sendable {
    private struct LimiterState: Sendable {
        var bytesReceived: UInt64 = 0
        var bytesSent: UInt64 = 0
        let amplificationFactor: UInt64 = 3
        var addressValidated: Bool = false
        let isServer: Bool

        /// Uses saturating multiplication to prevent overflow
        var sendLimit: UInt64 {
            let (result, overflow) = bytesReceived.multipliedReportingOverflow(by: amplificationFactor)
            return overflow ? UInt64.max : result
        }
    }

    public func canSend(bytes: UInt64) -> Bool {
        state.withLock { s in
            guard s.isServer else { return true }
            guard !s.addressValidated else { return true }
            let (total, overflow) = s.bytesSent.addingReportingOverflow(bytes)
            if overflow { return false }
            return total <= s.sendLimit
        }
    }
}
```

**Security Hardening:**
- Saturating multiplication prevents integer overflow when computing send limit
- Saturating addition prevents overflow in byte tracking
- Overflow check in `canSend()` prevents sending when arithmetic would overflow

**Compliance:** COMPLIANT

---

### Section 14.1: Initial Packet Size

**RFC Requirement:**
> A client MUST expand the payload of all UDP datagrams carrying Initial packets to at least the smallest allowed maximum datagram size of 1200 bytes.

**Implementation:** `Sources/QUICCore/Packet/PacketCodec.swift:111, 136-148`
```swift
public static let initialPacketMinSize = 1200

if padToMinimum && header.packetType == .initial {
    let estimatedHeaderSize = estimateLongHeaderSize(header)
    let currentSize = estimatedHeaderSize + header.packetNumberLength + payload.count + Self.aeadTagSize
    if currentSize < Self.initialPacketMinSize {
        let paddingNeeded = Self.initialPacketMinSize - currentSize
        payload.append(Data(count: paddingNeeded))  // PADDING frames (0x00 bytes)
    }
}
```

**Compliance:** COMPLIANT

---

### Section 16: Variable-Length Integer Encoding

**RFC Requirement:**
```
2MSB = 00: 6-bit value  (1 byte,  max 63)
2MSB = 01: 14-bit value (2 bytes, max 16383)
2MSB = 10: 30-bit value (4 bytes, max 1073741823)
2MSB = 11: 62-bit value (8 bytes, max 4611686018427387903)
```

**Implementation:** `Sources/QUICCore/Varint.swift:54-88`
```swift
public func encode(to data: inout Data) {
    if value <= 63 {
        data.append(UInt8(value))                           // 0b00xxxxxx
    } else if value <= 16383 {
        data.append(UInt8(0x40 | (value >> 8)))            // 0b01xxxxxx
        data.append(UInt8(value & 0xFF))
    } else if value <= 1_073_741_823 {
        data.append(UInt8(0x80 | (value >> 24)))           // 0b10xxxxxx
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    } else {
        data.append(UInt8(0xC0 | (value >> 56)))           // 0b11xxxxxx
        // ... remaining bytes
    }
}
```

**Compliance:** COMPLIANT

---

### Section 17.1: Packet Number Encoding and Decoding

**RFC Requirement:**
> The sender MUST use a packet number size able to represent more than twice as large a range as the difference between the largest acknowledged packet number and the current packet number.

**Implementation:** `Sources/QUICCore/Packet/PacketHeader.swift:472-539`
```swift
public static func encode(fullPacketNumber: UInt64, largestAcked: UInt64?) -> (bytes: Data, length: Int) {
    let numUnacked: UInt64
    if let acked = largestAcked, acked <= fullPacketNumber {
        numUnacked = fullPacketNumber - acked
    } else {
        numUnacked = fullPacketNumber + 1
    }

    let length: Int
    if numUnacked < (1 << 7) { length = 1 }
    else if numUnacked < (1 << 15) { length = 2 }
    else if numUnacked < (1 << 23) { length = 3 }
    else { length = 4 }
    // ...
}

public static func decode(truncated: UInt64, length: Int, largestPN: UInt64) -> UInt64 {
    let expectedPN = largestPN + 1
    let pnWin = UInt64(1) << (length * 8)
    let pnHwin = pnWin / 2
    let pnMask = pnWin - 1
    let candidatePN = (expectedPN & ~pnMask) | truncated
    // RFC 9000 Appendix A algorithm
    if candidatePN + pnHwin <= expectedPN && candidatePN < (1 << 62) - pnWin {
        return candidatePN + pnWin
    } else if candidatePN > expectedPN + pnHwin && candidatePN >= pnWin {
        return candidatePN - pnWin
    } else {
        return candidatePN
    }
}
```

**Compliance:** COMPLIANT

---

### Section 17.2: Long Header Packet Format

**RFC Requirement:**
```
Long Header Packet {
  Header Form (1) = 1,
  Fixed Bit (1) = 1,
  Long Packet Type (2),
  Type-Specific Bits (4),
  Version (32),
  Destination Connection ID Length (8),
  Destination Connection ID (0..160),
  Source Connection ID Length (8),
  Source Connection ID (0..160),
  Type-Specific Payload (..),
}
```

**Implementation:** `Sources/QUICCore/Packet/PacketHeader.swift:89-221`
```swift
public struct LongHeader: Sendable, Hashable {
    public var firstByte: UInt8
    public let version: QUICVersion
    public let destinationConnectionID: ConnectionID
    public let sourceConnectionID: ConnectionID
    public var token: Data?
    public var length: UInt64?
    public var packetNumber: UInt64
    public var packetNumberLength: Int

    public init(packetType: PacketType, ...) {
        var byte: UInt8
        switch packetType {
        case .initial:
            byte = 0xC0 | (0x00 << 4) | UInt8(packetNumberLength - 1) & 0x03
        case .zeroRTT:
            byte = 0xC0 | (0x01 << 4) | UInt8(packetNumberLength - 1) & 0x03
        case .handshake:
            byte = 0xC0 | (0x02 << 4) | UInt8(packetNumberLength - 1) & 0x03
        case .retry:
            byte = 0xC0 | (0x03 << 4)
        // ...
        }
        self.firstByte = byte
    }
}
```

**Compliance:** COMPLIANT

---

### Section 17.3: Short Header Packet Format

**RFC Requirement:**
```
1-RTT Packet {
  Header Form (1) = 0,
  Fixed Bit (1) = 1,
  Spin Bit (1),
  Reserved Bits (2),
  Key Phase (1),
  Packet Number Length (2),
  Destination Connection ID (0..160),
  Packet Number (8..32),
  Packet Payload (8..),
}
```

**Implementation:** `Sources/QUICCore/Packet/PacketHeader.swift:240-287`
```swift
public struct ShortHeader: Sendable, Hashable {
    public var firstByte: UInt8
    public let destinationConnectionID: ConnectionID
    public var packetNumber: UInt64
    public var packetNumberLength: Int

    public var spinBit: Bool { (firstByte & 0x20) != 0 }
    public var keyPhase: Bool { (firstByte & 0x04) != 0 }

    public init(...) {
        var byte: UInt8 = 0x40  // Header form = 0, Fixed bit = 1
        if spinBit { byte |= 0x20 }
        if keyPhase { byte |= 0x04 }
        byte |= UInt8(packetNumberLength - 1) & 0x03
        self.firstByte = byte
        // ...
    }
}
```

**Compliance:** COMPLIANT

---

### Section 18.2: Transport Parameter IDs

**RFC Requirement:**

| ID | Parameter |
|----|-----------|
| 0x00 | original_destination_connection_id |
| 0x01 | max_idle_timeout |
| 0x02 | stateless_reset_token |
| 0x03 | max_udp_payload_size |
| 0x04 | initial_max_data |
| 0x05 | initial_max_stream_data_bidi_local |
| 0x06 | initial_max_stream_data_bidi_remote |
| 0x07 | initial_max_stream_data_uni |
| 0x08 | initial_max_streams_bidi |
| 0x09 | initial_max_streams_uni |
| 0x0a | ack_delay_exponent |
| 0x0b | max_ack_delay |
| 0x0c | disable_active_migration |
| 0x0d | preferred_address |
| 0x0e | active_connection_id_limit |
| 0x0f | initial_source_connection_id |
| 0x10 | retry_source_connection_id |

**Implementation:** `Sources/QUICCrypto/TransportParameters/TransportParameterID.swift:8-59`
```swift
public enum TransportParameterID: UInt64, Sendable, CaseIterable {
    case originalDestinationConnectionID = 0x00
    case maxIdleTimeout = 0x01
    case statelessResetToken = 0x02
    case maxUDPPayloadSize = 0x03
    case initialMaxData = 0x04
    case initialMaxStreamDataBidiLocal = 0x05
    case initialMaxStreamDataBidiRemote = 0x06
    case initialMaxStreamDataUni = 0x07
    case initialMaxStreamsBidi = 0x08
    case initialMaxStreamsUni = 0x09
    case ackDelayExponent = 0x0a
    case maxAckDelay = 0x0b
    case disableActiveMigration = 0x0c
    case preferredAddress = 0x0d
    case activeConnectionIDLimit = 0x0e
    case initialSourceConnectionID = 0x0f
    case retrySourceConnectionID = 0x10
}
```

**Compliance:** COMPLIANT

---

### Section 12.4: Frame Types

**RFC Requirement:**

| Type | Name |
|------|------|
| 0x00 | PADDING |
| 0x01 | PING |
| 0x02-0x03 | ACK |
| 0x04 | RESET_STREAM |
| 0x05 | STOP_SENDING |
| 0x06 | CRYPTO |
| 0x07 | NEW_TOKEN |
| 0x08-0x0f | STREAM |
| 0x10 | MAX_DATA |
| 0x11 | MAX_STREAM_DATA |
| 0x12-0x13 | MAX_STREAMS |
| 0x14 | DATA_BLOCKED |
| 0x15 | STREAM_DATA_BLOCKED |
| 0x16-0x17 | STREAMS_BLOCKED |
| 0x18 | NEW_CONNECTION_ID |
| 0x19 | RETIRE_CONNECTION_ID |
| 0x1a | PATH_CHALLENGE |
| 0x1b | PATH_RESPONSE |
| 0x1c-0x1d | CONNECTION_CLOSE |
| 0x1e | HANDSHAKE_DONE |

**Implementation:** `Sources/QUICCore/Frame/Frame.swift:11-39`
```swift
public enum FrameType: UInt64, Sendable {
    case padding = 0x00
    case ping = 0x01
    case ack = 0x02
    case ackECN = 0x03
    case resetStream = 0x04
    case stopSending = 0x05
    case crypto = 0x06
    case newToken = 0x07
    case stream = 0x08
    case maxData = 0x10
    case maxStreamData = 0x11
    case maxStreamsBidi = 0x12
    case maxStreamsUni = 0x13
    case dataBlocked = 0x14
    case streamDataBlocked = 0x15
    case streamsBlockedBidi = 0x16
    case streamsBlockedUni = 0x17
    case newConnectionID = 0x18
    case retireConnectionID = 0x19
    case pathChallenge = 0x1a
    case pathResponse = 0x1b
    case connectionClose = 0x1c
    case connectionCloseApp = 0x1d
    case handshakeDone = 0x1e
    case datagram = 0x30
    case datagramWithLength = 0x31
}
```

**Compliance:** COMPLIANT

---

### Section 19.8: STREAM Frame

**RFC Requirement:**
```
STREAM Frame {
  Type (i) = 0x08..0x0f,
  Stream ID (i),
  [Offset (i)],
  [Length (i)],
  Stream Data (..),
}
```
- Bit 0x04: OFF bit (offset present)
- Bit 0x02: LEN bit (length present)
- Bit 0x01: FIN bit

**Implementation:** `Sources/QUICCore/Frame/FrameTypes.swift:67-108`
```swift
public struct StreamFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let offset: UInt64
    public let data: Data
    public let fin: Bool
    public let hasLength: Bool

    public var frameTypeByte: UInt8 {
        var byte: UInt8 = 0x08
        if offset > 0 { byte |= 0x04 }  // OFF bit
        if true { byte |= 0x02 }         // LEN bit
        if fin { byte |= 0x01 }          // FIN bit
        return byte
    }
}
```

**Compliance:** COMPLIANT

---

## RFC 9221: DATAGRAM Extension

**RFC Requirement:**
```
DATAGRAM Frame {
  Type (i) = 0x30..0x31,
  [Length (i)],
  Datagram Data (..),
}
```
- Type 0x30: No length field
- Type 0x31: Length field present

**Implementation:** `Sources/QUICCore/Frame/Frame.swift:37-38`
```swift
case datagram = 0x30
case datagramWithLength = 0x31
```

**Implementation:** `Sources/QUICCore/Frame/FrameTypes.swift:310-324`
```swift
public struct DatagramFrame: Sendable, Hashable {
    public let data: Data
    public let hasLength: Bool
}
```

**Compliance:** COMPLIANT

---

## RFC 9002: QUIC Loss Detection and Congestion Control

### Section 6: Loss Detection

**RFC Requirement:**
> A packet is declared lost if it meets all the following conditions:
> - The packet is unacknowledged, in-flight, and was sent prior to an acknowledged packet.
> - The packet was sent kPacketThreshold packets before an acknowledged packet, or it was sent long enough in the past.

**Implementation:** `Sources/QUICRecovery/LossDetector.swift:196-267`
```swift
private func detectLostPacketsInternal(
    _ state: inout LossState,
    now: ContinuousClock.Instant,
    rttEstimator: RTTEstimator
) -> [SentPacket] {
    guard let largestAcked = state.largestAckedPacket else { return [] }

    // Calculate loss delay threshold
    let baseRTT = max(rttEstimator.latestRTT, rttEstimator.smoothedRTT)
    let lossDelay = baseRTT * LossDetectionConstants.timeThresholdNumerator /
                    LossDetectionConstants.timeThresholdDenominator
    let lossDelayThreshold = max(lossDelay, LossDetectionConstants.granularity)

    for (pn, packet) in state.sentPackets {
        // Packet threshold loss: 3+ newer packets acknowledged
        let packetLost = largestAcked >= pn + LossDetectionConstants.packetThreshold
        // Time threshold loss
        let timeLost = (now - packet.timeSent) >= lossDelayThreshold

        if packetLost || timeLost {
            // Mark as lost
        }
    }
}
```

**Security Hardening:**
- ACK range validation prevents underflow attacks
- Guards against malformed ACK frames with invalid gap/range combinations

**Compliance:** COMPLIANT

---

### Section 7: Congestion Control

**RFC Requirement:**
> QUIC's default congestion controller is similar to TCP NewReno.

**Implementation:** `Sources/QUICRecovery/NewRenoCongestionController.swift`
- Slow start with exponential growth
- Congestion avoidance with AIMD
- Fast recovery on packet loss
- Persistent congestion detection
- ECN-CE response

**Compliance:** COMPLIANT

---

## Security Hardening

### Safe Integer Conversions

**Implementation:** `Sources/QUICCore/SafeConversions.swift`

All UInt64 → Int conversions from network data use centralized validation:

```swift
public enum SafeConversions {
    /// Safe UInt64 to Int conversion with overflow check
    public static func toInt(_ value: UInt64) throws -> Int

    /// Safe conversion with protocol limit enforcement
    public static func toInt(_ value: UInt64, maxAllowed: Int, context: String) throws -> Int

    /// Safe subtraction with underflow check
    public static func subtract(_ a: Int, _ b: Int) throws -> Int
}
```

### Protocol Limits

**Implementation:** `Sources/QUICCore/ProtocolLimits.swift`

RFC-compliant limits enforced throughout the codebase:

| Limit | Value | RFC Reference |
|-------|-------|---------------|
| Max Connection ID Length | 20 bytes | RFC 9000 Section 17.2 |
| Max Initial Token Length | 1200 bytes | UDP MTU constraint |
| Max Frame Payload Length | 65535 bytes | Single packet constraint |
| Max ACK Ranges | 256 | Memory exhaustion prevention |
| Stateless Reset Token Length | 16 bytes | RFC 9000 Section 10.3 |

### Integer Overflow Protection

All arithmetic operations that could overflow use saturating arithmetic:

| Component | Protection |
|-----------|------------|
| SafeConversions | `toInt()` validates UInt64 <= Int.max |
| SafeConversions | `subtract()` validates a >= b |
| AntiAmplificationLimiter | `multipliedReportingOverflow`, `addingReportingOverflow` |
| FlowController | Overflow checks before credit operations |
| LossDetector | ACK range validation before subtraction |
| FrameCodec | All length fields use SafeConversions |
| PacketCodec | Payload length calculations use SafeConversions |

### ACK Range Validation

**Implementation:** `Sources/QUICRecovery/LossDetector.swift:144-166`
```swift
for (index, range) in ackFrame.ackRanges.enumerated() {
    if index == 0 {
        // Validate: rangeLength must not exceed current to prevent underflow
        guard range.rangeLength <= current else { continue }
        rangeStart = current - range.rangeLength
    } else {
        // Validate: gap + 2 must not exceed current to prevent underflow
        let gapOffset = range.gap + 2
        guard gapOffset <= current else { break }
        current = current - gapOffset
        guard range.rangeLength <= current else { continue }
        rangeStart = current - range.rangeLength
    }
}
```

### Connection ID Validation

**Implementation:** `Sources/QUICCore/Packet/ConnectionID.swift`

```swift
public init(bytes: Data) throws {
    guard bytes.count <= Self.maxLength else {
        throw ConnectionIDError.tooLong(length: bytes.count, maxAllowed: Self.maxLength)
    }
    self.bytes = bytes
}
```

- DCID length enforced to 0-20 bytes per RFC 9000 Section 17.2
- Throwing initializer prevents invalid ConnectionID construction
- `random(length:)` returns nil for invalid lengths
- Prevents buffer over-read attacks

### Race Condition Prevention

**Implementation:** `Sources/QUIC/ManagedConnection.swift`
- `shutdown()` guards against concurrent calls
- `start()` / `startWith0RTT()` atomic state transition prevents double-start
- AsyncStream continuation properly finished on shutdown

---

## Verification Checklist

### Cryptographic Operations

| Item | RFC Section | Status |
|------|-------------|--------|
| Initial salt (v1) | RFC 9001 5.2 | ✅ Verified: `0x38762cf7f55934b34d179ae6a4c80cadccbb7f0a` |
| Initial salt (v2) | RFC 9369 | ✅ Verified: `0x0dede3def700a6db819381be6e269dcbf9bd2ed9` |
| HKDF-Expand-Label prefix | RFC 8446 7.1 | ✅ Verified: `"tls13 "` |
| Client initial label | RFC 9001 5.2 | ✅ Verified: `"client in"` |
| Server initial label | RFC 9001 5.2 | ✅ Verified: `"server in"` |
| Key label | RFC 9001 5.1 | ✅ Verified: `"quic key"` |
| IV label | RFC 9001 5.1 | ✅ Verified: `"quic iv"` |
| HP label | RFC 9001 5.1 | ✅ Verified: `"quic hp"` |
| Key update label | RFC 9001 6 | ✅ Verified: `"quic ku"` |
| AES-128-GCM key length | RFC 9001 | ✅ Verified: 16 bytes |
| AES-128-GCM IV length | RFC 9001 | ✅ Verified: 12 bytes |
| AES-128-GCM tag length | RFC 9001 | ✅ Verified: 16 bytes |
| HP sample offset | RFC 9001 5.4.2 | ✅ Verified: pn_offset + 4 |
| HP sample length | RFC 9001 5.4.2 | ✅ Verified: 16 bytes |
| Long header first byte mask | RFC 9001 5.4.1 | ✅ Verified: 0x0F (lower 4 bits) |
| Short header first byte mask | RFC 9001 5.4.1 | ✅ Verified: 0x1F (lower 5 bits) |
| Nonce construction | RFC 9001 5.3 | ✅ Verified: IV XOR left-padded PN |

### Packet Format

| Item | RFC Section | Status |
|------|-------------|--------|
| Long header form bit | RFC 9000 17.2 | ✅ Verified: 0x80 |
| Fixed bit | RFC 9000 17.2 | ✅ Verified: 0x40 |
| Initial packet type | RFC 9000 17.2.2 | ✅ Verified: 0x00 |
| 0-RTT packet type | RFC 9000 17.2.3 | ✅ Verified: 0x01 |
| Handshake packet type | RFC 9000 17.2.4 | ✅ Verified: 0x02 |
| Retry packet type | RFC 9000 17.2.5 | ✅ Verified: 0x03 |
| Short header form bit | RFC 9000 17.3 | ✅ Verified: 0x00 |
| Spin bit position | RFC 9000 17.3.1 | ✅ Verified: 0x20 |
| Key phase position | RFC 9000 17.3.1 | ✅ Verified: 0x04 |
| PN length position | RFC 9000 17.3.1 | ✅ Verified: 0x03 |
| Initial packet minimum size | RFC 9000 14.1 | ✅ Verified: 1200 bytes |

### Varint Encoding

| Item | RFC Section | Status |
|------|-------------|--------|
| 1-byte prefix | RFC 9000 16 | ✅ Verified: 0b00 |
| 2-byte prefix | RFC 9000 16 | ✅ Verified: 0b01 |
| 4-byte prefix | RFC 9000 16 | ✅ Verified: 0b10 |
| 8-byte prefix | RFC 9000 16 | ✅ Verified: 0b11 |
| Max value | RFC 9000 16 | ✅ Verified: 2^62 - 1 |

---

## Notes

1. **TLS 1.3 Integration**: The implementation includes a native TLS 1.3 handshake state machine (`TLS13Handler`) with certificate validation support. A `MockTLSProvider` is also available for testing.

2. **Cipher Suites**: Both AES-128-GCM and ChaCha20-Poly1305 are supported per RFC 9001.

3. **Platform Support**: AES-ECB for header protection uses CommonCrypto on Apple platforms. Linux support would require an alternative implementation.

4. **0-RTT Support**: Early data transmission is supported with replay protection. Session tickets are managed via `SessionTicketStore` (server) and `ClientSessionCache` (client).

---

## References

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 - Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 - QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9221 - An Unreliable Datagram Extension to QUIC](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9369 - QUIC Version 2](https://www.rfc-editor.org/rfc/rfc9369)
- [RFC 8446 - The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc8446)
