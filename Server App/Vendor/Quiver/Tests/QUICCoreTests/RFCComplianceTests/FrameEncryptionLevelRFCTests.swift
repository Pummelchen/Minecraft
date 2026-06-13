/// RFC 9000 Section 12.4 Compliance Tests - Frame by Encryption Level
///
/// These tests verify compliance with RFC 9000 Section 12.4:
/// Different frame types are permitted in different encryption levels.
/// Receiving an invalid frame at a given level MUST be treated as a
/// connection error of type PROTOCOL_VIOLATION.

import Testing
import Foundation
@testable import QUICCore

// MARK: - Frame Validation Protocol

/// Protocol for validating frames at encryption levels
/// This documents what SHOULD be implemented in QUICConnectionHandler
public protocol FrameLevelValidator {
    /// Validates if a frame is allowed at the given encryption level
    /// - Parameters:
    ///   - frame: The frame to validate
    ///   - level: The encryption level where the frame was received
    /// - Returns: true if the frame is allowed at this level
    /// - Throws: PROTOCOL_VIOLATION if the frame is not allowed
    func isFrameAllowed(_ frame: Frame, at level: EncryptionLevel) throws -> Bool
}

// Use QUICCore.EncryptionLevel instead of defining a local enum

// MARK: - RFC 9000 §12.4 Frame Level Matrix

/// Reference implementation of frame validation per RFC 9000 Section 12.4
/// Table 3: Frames and Packet Types
struct RFC9000FrameValidator: FrameLevelValidator {

    func isFrameAllowed(_ frame: Frame, at level: EncryptionLevel) throws -> Bool {
        switch frame {
        // PADDING, PING, CONNECTION_CLOSE: Allowed at all levels
        case .padding, .ping, .connectionClose:
            return true

        // ACK: Allowed at all levels EXCEPT 0-RTT
        case .ack:
            if level == .zeroRTT {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // CRYPTO: Allowed at Initial, Handshake, 1-RTT only (NOT 0-RTT)
        case .crypto:
            if level == .zeroRTT {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // NEW_TOKEN: Allowed ONLY at 1-RTT (application level)
        case .newToken:
            if level != .application {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // STREAM frames: Allowed at 0-RTT and 1-RTT only
        case .stream, .maxData, .maxStreamData, .maxStreams,
             .dataBlocked, .streamDataBlocked, .streamsBlocked,
             .resetStream, .stopSending:
            if level == .initial || level == .handshake {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // NEW_CONNECTION_ID, RETIRE_CONNECTION_ID: Allowed at 0-RTT and 1-RTT only
        case .newConnectionID, .retireConnectionID:
            if level == .initial || level == .handshake {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // PATH_CHALLENGE, PATH_RESPONSE: Allowed ONLY at 1-RTT
        case .pathChallenge, .pathResponse:
            if level != .application {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // HANDSHAKE_DONE: Allowed ONLY at 1-RTT
        case .handshakeDone:
            if level != .application {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true

        // DATAGRAM: Allowed at 0-RTT and 1-RTT only (if extension negotiated)
        case .datagram:
            if level == .initial || level == .handshake {
                throw ProtocolViolation.frameNotAllowed(frame.frameType, level)
            }
            return true
        }
    }
}

/// Protocol violation error for invalid frame at encryption level
enum ProtocolViolation: Error, Sendable {
    case frameNotAllowed(FrameType, EncryptionLevel)
}

// MARK: - Test Suite

@Suite("RFC 9000 §12.4 - Frame Encryption Level Compliance")
struct FrameEncryptionLevelRFCTests {

    let validator = RFC9000FrameValidator()

    // MARK: - Initial Packet Allowed Frames (RFC 9000 Table 3)

    @Test("PADDING frame allowed at Initial level")
    func paddingAllowedAtInitial() throws {
        let result = try validator.isFrameAllowed(.padding(count: 1), at: .initial)
        #expect(result)
    }

    @Test("PING frame allowed at Initial level")
    func pingAllowedAtInitial() throws {
        let result = try validator.isFrameAllowed(.ping, at: .initial)
        #expect(result)
    }

    @Test("ACK frame allowed at Initial level")
    func ackAllowedAtInitial() throws {
        let ackFrame = AckFrame(largestAcknowledged: 0, ackDelay: 0, ackRanges: [])
        let result = try validator.isFrameAllowed(.ack(ackFrame), at: .initial)
        #expect(result)
    }

    @Test("CRYPTO frame allowed at Initial level")
    func cryptoAllowedAtInitial() throws {
        let cryptoFrame = CryptoFrame(offset: 0, data: Data())
        let result = try validator.isFrameAllowed(.crypto(cryptoFrame), at: .initial)
        #expect(result)
    }

    @Test("CONNECTION_CLOSE frame allowed at Initial level")
    func connectionCloseAllowedAtInitial() throws {
        let closeFrame = ConnectionCloseFrame(
            errorCode: 0,
            frameType: nil,
            reasonPhrase: "",
            isApplicationError: false
        )
        let result = try validator.isFrameAllowed(.connectionClose(closeFrame), at: .initial)
        #expect(result)
    }

    // MARK: - Initial Packet Prohibited Frames

    @Test("STREAM frame NOT allowed at Initial level")
    func streamNotAllowedAtInitial() throws {
        let streamFrame = StreamFrame(streamID: 0, offset: 0, data: Data(), fin: false)
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.stream(streamFrame), at: .initial)
        }
    }

    @Test("NEW_CONNECTION_ID frame NOT allowed at Initial level")
    func newConnectionIDNotAllowedAtInitial() throws {
        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let frame = try NewConnectionIDFrame(
            sequenceNumber: 1,
            retirePriorTo: 0,
            connectionID: cid,
            statelessResetToken: Data(repeating: 0x00, count: 16)
        )
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newConnectionID(frame), at: .initial)
        }
    }

    @Test("HANDSHAKE_DONE frame NOT allowed at Initial level")
    func handshakeDoneNotAllowedAtInitial() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .initial)
        }
    }

    @Test("PATH_CHALLENGE frame NOT allowed at Initial level")
    func pathChallengeNotAllowedAtInitial() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.pathChallenge(Data(repeating: 0, count: 8)), at: .initial)
        }
    }

    @Test("NEW_TOKEN frame NOT allowed at Initial level")
    func newTokenNotAllowedAtInitial() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newToken(Data()), at: .initial)
        }
    }

    // MARK: - Handshake Packet Allowed Frames

    @Test("CRYPTO frame allowed at Handshake level")
    func cryptoAllowedAtHandshake() throws {
        let cryptoFrame = CryptoFrame(offset: 0, data: Data())
        let result = try validator.isFrameAllowed(.crypto(cryptoFrame), at: .handshake)
        #expect(result)
    }

    @Test("ACK frame allowed at Handshake level")
    func ackAllowedAtHandshake() throws {
        let ackFrame = AckFrame(largestAcknowledged: 0, ackDelay: 0, ackRanges: [])
        let result = try validator.isFrameAllowed(.ack(ackFrame), at: .handshake)
        #expect(result)
    }

    // MARK: - Handshake Packet Prohibited Frames

    @Test("STREAM frame NOT allowed at Handshake level")
    func streamNotAllowedAtHandshake() throws {
        let streamFrame = StreamFrame(streamID: 0, offset: 0, data: Data(), fin: false)
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.stream(streamFrame), at: .handshake)
        }
    }

    @Test("HANDSHAKE_DONE frame NOT allowed at Handshake level")
    func handshakeDoneNotAllowedAtHandshake() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .handshake)
        }
    }

    // MARK: - 0-RTT Packet Allowed Frames

    @Test("STREAM frame allowed at 0-RTT level")
    func streamAllowedAt0RTT() throws {
        let streamFrame = StreamFrame(streamID: 0, offset: 0, data: Data(), fin: false)
        let result = try validator.isFrameAllowed(.stream(streamFrame), at: .zeroRTT)
        #expect(result)
    }

    @Test("MAX_DATA frame allowed at 0-RTT level")
    func maxDataAllowedAt0RTT() throws {
        let result = try validator.isFrameAllowed(.maxData(1000), at: .zeroRTT)
        #expect(result)
    }

    // MARK: - 0-RTT Packet Prohibited Frames

    @Test("ACK frame NOT allowed at 0-RTT level")
    func ackNotAllowedAt0RTT() throws {
        // RFC 9000 §12.4: ACK frames are not allowed in 0-RTT packets
        let ackFrame = AckFrame(largestAcknowledged: 0, ackDelay: 0, ackRanges: [])
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.ack(ackFrame), at: .zeroRTT)
        }
    }

    @Test("CRYPTO frame NOT allowed at 0-RTT level")
    func cryptoNotAllowedAt0RTT() throws {
        // RFC 9000 §12.4: CRYPTO frames are not allowed in 0-RTT packets
        let cryptoFrame = CryptoFrame(offset: 0, data: Data())
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.crypto(cryptoFrame), at: .zeroRTT)
        }
    }

    @Test("HANDSHAKE_DONE frame NOT allowed at 0-RTT level")
    func handshakeDoneNotAllowedAt0RTT() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .zeroRTT)
        }
    }

    @Test("PATH_CHALLENGE frame NOT allowed at 0-RTT level")
    func pathChallengeNotAllowedAt0RTT() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.pathChallenge(Data(repeating: 0, count: 8)), at: .zeroRTT)
        }
    }

    @Test("NEW_TOKEN frame NOT allowed at 0-RTT level")
    func newTokenNotAllowedAt0RTT() throws {
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newToken(Data()), at: .zeroRTT)
        }
    }

    // MARK: - 1-RTT (Application) Packet - All Frames Allowed

    @Test("All frame types allowed at 1-RTT level")
    func allFramesAllowedAt1RTT() throws {
        // RFC 9000 §12.4: 1-RTT packets can carry any frame type

        let cid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let newCIDFrame = try NewConnectionIDFrame(
            sequenceNumber: 1,
            retirePriorTo: 0,
            connectionID: cid,
            statelessResetToken: Data(repeating: 0x00, count: 16)
        )
        let maxStreamDataFrame = MaxStreamDataFrame(streamID: 0, maxStreamData: 1000)

        let testFrames: [Frame] = [
            .padding(count: 1),
            .ping,
            .ack(AckFrame(largestAcknowledged: 0, ackDelay: 0, ackRanges: [])),
            .crypto(CryptoFrame(offset: 0, data: Data())),
            .newToken(Data([0x01, 0x02])),
            .stream(StreamFrame(streamID: 0, offset: 0, data: Data(), fin: false)),
            .maxData(1000),
            .maxStreamData(maxStreamDataFrame),
            .maxStreams(MaxStreamsFrame(maxStreams: 10, isBidirectional: true)),
            .dataBlocked(1000),
            .streamDataBlocked(StreamDataBlockedFrame(streamID: 0, streamDataLimit: 1000)),
            .streamsBlocked(StreamsBlockedFrame(streamLimit: 10, isBidirectional: true)),
            .newConnectionID(newCIDFrame),
            .retireConnectionID(0),
            .pathChallenge(Data(repeating: 0, count: 8)),
            .pathResponse(Data(repeating: 0, count: 8)),
            .connectionClose(ConnectionCloseFrame(errorCode: 0, frameType: nil, reasonPhrase: "", isApplicationError: false)),
            .handshakeDone,
            .resetStream(ResetStreamFrame(streamID: 0, applicationErrorCode: 0, finalSize: 0)),
            .stopSending(StopSendingFrame(streamID: 0, applicationErrorCode: 0)),
            .datagram(DatagramFrame(data: Data(), hasLength: true))
        ]

        for frame in testFrames {
            let result = try validator.isFrameAllowed(frame, at: .application)
            #expect(result, "Frame type \(frame.frameType) should be allowed at 1-RTT")
        }
    }

    // MARK: - Integration: QUICConnectionHandler MUST validate frames

    @Test("QUICConnectionHandler MUST validate frames by encryption level")
    func connectionHandlerMustValidateFrames() throws {
        // This test documents the requirement that QUICConnectionHandler.processFrames()
        // MUST validate each frame against the encryption level before processing.
        //
        // RFC 9000 §12.4: An endpoint MUST treat receipt of a frame in a packet
        // type that is not permitted as a connection error of type PROTOCOL_VIOLATION.
        //
        // Current implementation in QUICConnectionHandler.swift:210-313
        // processes frames without level validation.
        //
        // TODO: The implementation should be updated to call a validation function
        // like RFC9000FrameValidator.isFrameAllowed() before processing each frame.

        // Example attack: HANDSHAKE_DONE in Initial packet
        // This would allow an attacker to prematurely complete handshake
        let handshakeDone = Frame.handshakeDone

        // The validator correctly rejects this
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(handshakeDone, at: .initial)
        }

        // Example attack: STREAM in Handshake packet
        // This could allow data injection before handshake completes
        let streamFrame = StreamFrame(streamID: 0, offset: 0, data: Data([0x01]), fin: false)

        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.stream(streamFrame), at: .handshake)
        }
    }

    // MARK: - Server-Only Frames

    @Test("HANDSHAKE_DONE is server-only frame")
    func handshakeDoneIsServerOnly() throws {
        // RFC 9000 §19.20: The server uses a HANDSHAKE_DONE frame to signal
        // confirmation of the handshake to the client.
        //
        // Note: This is a semantic validation, not level validation.
        // A client receiving HANDSHAKE_DONE in its own 1-RTT packet would be
        // an error, but that's role-based, not level-based.

        // The frame is allowed at 1-RTT level
        let result = try validator.isFrameAllowed(.handshakeDone, at: .application)
        #expect(result)

        // But NOT at other levels
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .initial)
        }
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .handshake)
        }
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.handshakeDone, at: .zeroRTT)
        }
    }

    @Test("NEW_TOKEN is server-only frame at 1-RTT only")
    func newTokenIsServerOnlyAt1RTT() throws {
        // RFC 9000 §19.7: A server sends a NEW_TOKEN frame to provide the client
        // with a token to send in the Token field of an Initial packet.

        // Only allowed at 1-RTT
        let result = try validator.isFrameAllowed(.newToken(Data([0x01])), at: .application)
        #expect(result)

        // Not allowed at other levels
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newToken(Data()), at: .initial)
        }
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newToken(Data()), at: .handshake)
        }
        #expect(throws: ProtocolViolation.self) {
            _ = try validator.isFrameAllowed(.newToken(Data()), at: .zeroRTT)
        }
    }
}
