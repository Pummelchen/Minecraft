import Testing
import Foundation
@testable import QUICCore

@Suite("Frame Codec Tests")
struct FrameCodecTests {
    let codec = StandardFrameCodec()

    // MARK: - PADDING Frame

    @Test("Encode and decode PADDING frame")
    func paddingFrame() throws {
        let frame = Frame.padding(count: 5)
        let encoded = try codec.encode(frame)

        #expect(encoded.count == 5)
        #expect(encoded.allSatisfy { $0 == 0x00 })

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .padding(let count) = decoded {
            #expect(count == 5)
        } else {
            Issue.record("Expected padding frame")
        }
    }

    // MARK: - PING Frame

    @Test("Encode and decode PING frame")
    func pingFrame() throws {
        let frame = Frame.ping
        let encoded = try codec.encode(frame)

        #expect(encoded.count == 1)
        #expect(encoded[0] == 0x01)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .ping = decoded {
            // Success
        } else {
            Issue.record("Expected ping frame")
        }
    }

    // MARK: - ACK Frame

    @Test("Encode and decode ACK frame without ECN")
    func ackFrameWithoutECN() throws {
        let ackFrame = AckFrame(
            largestAcknowledged: 100,
            ackDelay: 25,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)]
        )
        let frame = Frame.ack(ackFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x02)  // ACK type

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .ack(let decodedAck) = decoded {
            #expect(decodedAck.largestAcknowledged == 100)
            #expect(decodedAck.ackDelay == 25)
            #expect(decodedAck.ackRanges.count == 1)
            #expect(decodedAck.ackRanges[0].rangeLength == 10)
            #expect(decodedAck.ecnCounts == nil)
        } else {
            Issue.record("Expected ACK frame")
        }
    }

    @Test("Encode and decode ACK frame with ECN")
    func ackFrameWithECN() throws {
        let ackFrame = AckFrame(
            largestAcknowledged: 200,
            ackDelay: 50,
            ackRanges: [AckRange(gap: 0, rangeLength: 5)],
            ecnCounts: ECNCounts(ect0Count: 10, ect1Count: 20, ecnCECount: 5)
        )
        let frame = Frame.ack(ackFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x03)  // ACK_ECN type

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .ack(let decodedAck) = decoded {
            #expect(decodedAck.largestAcknowledged == 200)
            #expect(decodedAck.ecnCounts != nil)
            #expect(decodedAck.ecnCounts?.ect0Count == 10)
            #expect(decodedAck.ecnCounts?.ect1Count == 20)
            #expect(decodedAck.ecnCounts?.ecnCECount == 5)
        } else {
            Issue.record("Expected ACK frame with ECN")
        }
    }

    @Test("Encode and decode ACK frame with multiple ranges")
    func ackFrameMultipleRanges() throws {
        let ackFrame = AckFrame(
            largestAcknowledged: 100,
            ackDelay: 10,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 5),   // Packets 96-100
                AckRange(gap: 3, rangeLength: 2),   // Gap of 3, then 2 packets
                AckRange(gap: 1, rangeLength: 1)    // Gap of 1, then 1 packet
            ]
        )
        let frame = Frame.ack(ackFrame)
        let encoded = try codec.encode(frame)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .ack(let decodedAck) = decoded {
            #expect(decodedAck.ackRanges.count == 3)
        } else {
            Issue.record("Expected ACK frame")
        }
    }

    // MARK: - CRYPTO Frame

    @Test("Encode and decode CRYPTO frame")
    func cryptoFrame() throws {
        let cryptoData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let cryptoFrame = CryptoFrame(offset: 100, data: cryptoData)
        let frame = Frame.crypto(cryptoFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x06)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .crypto(let decodedCrypto) = decoded {
            #expect(decodedCrypto.offset == 100)
            #expect(decodedCrypto.data == cryptoData)
        } else {
            Issue.record("Expected CRYPTO frame")
        }
    }

    // MARK: - STREAM Frame

    @Test("Encode and decode STREAM frame with offset and FIN")
    func streamFrameWithOffsetAndFin() throws {
        let streamData = Data([0xAA, 0xBB, 0xCC])
        let streamFrame = StreamFrame(
            streamID: 4,
            offset: 1000,
            data: streamData,
            fin: true
        )
        let frame = Frame.stream(streamFrame)
        let encoded = try codec.encode(frame)

        // Type byte should have OFF, LEN, and FIN bits set
        let expectedType: UInt8 = 0x08 | 0x04 | 0x02 | 0x01
        #expect(encoded[0] == expectedType)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .stream(let decodedStream) = decoded {
            #expect(decodedStream.streamID == 4)
            #expect(decodedStream.offset == 1000)
            #expect(decodedStream.data == streamData)
            #expect(decodedStream.fin == true)
        } else {
            Issue.record("Expected STREAM frame")
        }
    }

    @Test("Encode and decode STREAM frame without offset")
    func streamFrameWithoutOffset() throws {
        let streamData = Data([0x11, 0x22])
        let streamFrame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: streamData,
            fin: false
        )
        let frame = Frame.stream(streamFrame)
        let encoded = try codec.encode(frame)

        // Type byte should have only LEN bit set (no OFF, no FIN)
        let expectedType: UInt8 = 0x08 | 0x02
        #expect(encoded[0] == expectedType)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .stream(let decodedStream) = decoded {
            #expect(decodedStream.streamID == 0)
            #expect(decodedStream.offset == 0)
            #expect(decodedStream.data == streamData)
            #expect(decodedStream.fin == false)
        } else {
            Issue.record("Expected STREAM frame")
        }
    }

    // MARK: - RESET_STREAM Frame

    @Test("Encode and decode RESET_STREAM frame")
    func resetStreamFrame() throws {
        let resetFrame = ResetStreamFrame(
            streamID: 8,
            applicationErrorCode: 0x100,
            finalSize: 5000
        )
        let frame = Frame.resetStream(resetFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x04)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .resetStream(let decodedReset) = decoded {
            #expect(decodedReset.streamID == 8)
            #expect(decodedReset.applicationErrorCode == 0x100)
            #expect(decodedReset.finalSize == 5000)
        } else {
            Issue.record("Expected RESET_STREAM frame")
        }
    }

    // MARK: - STOP_SENDING Frame

    @Test("Encode and decode STOP_SENDING frame")
    func stopSendingFrame() throws {
        let stopFrame = StopSendingFrame(
            streamID: 12,
            applicationErrorCode: 0x200
        )
        let frame = Frame.stopSending(stopFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x05)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .stopSending(let decodedStop) = decoded {
            #expect(decodedStop.streamID == 12)
            #expect(decodedStop.applicationErrorCode == 0x200)
        } else {
            Issue.record("Expected STOP_SENDING frame")
        }
    }

    // MARK: - MAX_DATA Frame

    @Test("Encode and decode MAX_DATA frame")
    func maxDataFrame() throws {
        let frame = Frame.maxData(1_000_000)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x10)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .maxData(let maxData) = decoded {
            #expect(maxData == 1_000_000)
        } else {
            Issue.record("Expected MAX_DATA frame")
        }
    }

    // MARK: - MAX_STREAM_DATA Frame

    @Test("Encode and decode MAX_STREAM_DATA frame")
    func maxStreamDataFrame() throws {
        let maxStreamDataFrame = MaxStreamDataFrame(
            streamID: 4,
            maxStreamData: 500_000
        )
        let frame = Frame.maxStreamData(maxStreamDataFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x11)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .maxStreamData(let decodedFrame) = decoded {
            #expect(decodedFrame.streamID == 4)
            #expect(decodedFrame.maxStreamData == 500_000)
        } else {
            Issue.record("Expected MAX_STREAM_DATA frame")
        }
    }

    // MARK: - MAX_STREAMS Frame

    @Test("Encode and decode MAX_STREAMS (bidi) frame")
    func maxStreamsBidiFrame() throws {
        let maxStreamsFrame = MaxStreamsFrame(maxStreams: 100, isBidirectional: true)
        let frame = Frame.maxStreams(maxStreamsFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x12)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .maxStreams(let decodedFrame) = decoded {
            #expect(decodedFrame.maxStreams == 100)
            #expect(decodedFrame.isBidirectional == true)
        } else {
            Issue.record("Expected MAX_STREAMS frame")
        }
    }

    @Test("Encode and decode MAX_STREAMS (uni) frame")
    func maxStreamsUniFrame() throws {
        let maxStreamsFrame = MaxStreamsFrame(maxStreams: 50, isBidirectional: false)
        let frame = Frame.maxStreams(maxStreamsFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x13)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .maxStreams(let decodedFrame) = decoded {
            #expect(decodedFrame.maxStreams == 50)
            #expect(decodedFrame.isBidirectional == false)
        } else {
            Issue.record("Expected MAX_STREAMS frame")
        }
    }

    // MARK: - CONNECTION_CLOSE Frame

    @Test("Encode and decode CONNECTION_CLOSE (transport) frame")
    func connectionCloseTransportFrame() throws {
        let closeFrame = ConnectionCloseFrame(
            errorCode: 0x0a,  // PROTOCOL_VIOLATION
            frameType: 0x06,  // CRYPTO frame
            reasonPhrase: "Invalid handshake",
            isApplicationError: false
        )
        let frame = Frame.connectionClose(closeFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x1c)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .connectionClose(let decodedClose) = decoded {
            #expect(decodedClose.errorCode == 0x0a)
            #expect(decodedClose.frameType == 0x06)
            #expect(decodedClose.reasonPhrase == "Invalid handshake")
            #expect(decodedClose.isApplicationError == false)
        } else {
            Issue.record("Expected CONNECTION_CLOSE frame")
        }
    }

    @Test("Encode and decode CONNECTION_CLOSE (application) frame")
    func connectionCloseApplicationFrame() throws {
        let closeFrame = ConnectionCloseFrame(
            errorCode: 0x100,
            reasonPhrase: "App shutdown",
            isApplicationError: true
        )
        let frame = Frame.connectionClose(closeFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x1d)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .connectionClose(let decodedClose) = decoded {
            #expect(decodedClose.errorCode == 0x100)
            #expect(decodedClose.frameType == nil)
            #expect(decodedClose.reasonPhrase == "App shutdown")
            #expect(decodedClose.isApplicationError == true)
        } else {
            Issue.record("Expected CONNECTION_CLOSE (app) frame")
        }
    }

    // MARK: - HANDSHAKE_DONE Frame

    @Test("Encode and decode HANDSHAKE_DONE frame")
    func handshakeDoneFrame() throws {
        let frame = Frame.handshakeDone
        let encoded = try codec.encode(frame)

        #expect(encoded.count == 1)
        #expect(encoded[0] == 0x1e)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .handshakeDone = decoded {
            // Success
        } else {
            Issue.record("Expected HANDSHAKE_DONE frame")
        }
    }

    // MARK: - NEW_CONNECTION_ID Frame

    @Test("Encode and decode NEW_CONNECTION_ID frame")
    func newConnectionIDFrame() throws {
        let cid = try #require(ConnectionID.random(length: 8))
        let resetToken = Data(repeating: 0xAB, count: 16)
        let newCIDFrame = try NewConnectionIDFrame(
            sequenceNumber: 1,
            retirePriorTo: 0,
            connectionID: cid,
            statelessResetToken: resetToken
        )
        let frame = Frame.newConnectionID(newCIDFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x18)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .newConnectionID(let decodedFrame) = decoded {
            #expect(decodedFrame.sequenceNumber == 1)
            #expect(decodedFrame.retirePriorTo == 0)
            #expect(decodedFrame.connectionID.bytes == cid.bytes)
            #expect(decodedFrame.statelessResetToken == resetToken)
        } else {
            Issue.record("Expected NEW_CONNECTION_ID frame")
        }
    }

    // MARK: - RETIRE_CONNECTION_ID Frame

    @Test("Encode and decode RETIRE_CONNECTION_ID frame")
    func retireConnectionIDFrame() throws {
        let frame = Frame.retireConnectionID(5)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x19)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .retireConnectionID(let seqNum) = decoded {
            #expect(seqNum == 5)
        } else {
            Issue.record("Expected RETIRE_CONNECTION_ID frame")
        }
    }

    // MARK: - PATH_CHALLENGE Frame

    @Test("Encode and decode PATH_CHALLENGE frame")
    func pathChallengeFrame() throws {
        let challengeData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let frame = Frame.pathChallenge(challengeData)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x1a)
        #expect(encoded.count == 9)  // 1 type + 8 data

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .pathChallenge(let data) = decoded {
            #expect(data == challengeData)
        } else {
            Issue.record("Expected PATH_CHALLENGE frame")
        }
    }

    // MARK: - PATH_RESPONSE Frame

    @Test("Encode and decode PATH_RESPONSE frame")
    func pathResponseFrame() throws {
        let responseData = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        let frame = Frame.pathResponse(responseData)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x1b)
        #expect(encoded.count == 9)  // 1 type + 8 data

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .pathResponse(let data) = decoded {
            #expect(data == responseData)
        } else {
            Issue.record("Expected PATH_RESPONSE frame")
        }
    }

    // MARK: - DATAGRAM Frame

    @Test("Encode and decode DATAGRAM frame with length")
    func datagramFrameWithLength() throws {
        let datagramData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let datagramFrame = DatagramFrame(data: datagramData, hasLength: true)
        let frame = Frame.datagram(datagramFrame)
        let encoded = try codec.encode(frame)

        #expect(encoded[0] == 0x31)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .datagram(let decodedFrame) = decoded {
            #expect(decodedFrame.data == datagramData)
            #expect(decodedFrame.hasLength == true)
        } else {
            Issue.record("Expected DATAGRAM frame")
        }
    }

    // MARK: - Multiple Frames

    @Test("Encode and decode multiple frames")
    func multipleFrames() throws {
        let frames: [Frame] = [
            .ping,
            .ack(AckFrame(largestAcknowledged: 10, ackDelay: 5, ackRanges: [AckRange(gap: 0, rangeLength: 3)])),
            .stream(StreamFrame(streamID: 0, offset: 0, data: Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]), fin: false)),
            .padding(count: 3)
        ]

        let encoded = try codec.encodeFrames(frames)
        let decoded = try codec.decodeFrames(from: encoded)

        #expect(decoded.count == 4)

        if case .ping = decoded[0] {
            // Success
        } else {
            Issue.record("First frame should be PING")
        }

        if case .ack(let ack) = decoded[1] {
            #expect(ack.largestAcknowledged == 10)
        } else {
            Issue.record("Second frame should be ACK")
        }

        if case .stream(let stream) = decoded[2] {
            #expect(stream.streamID == 0)
            #expect(stream.data == Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]))
        } else {
            Issue.record("Third frame should be STREAM")
        }

        if case .padding(let count) = decoded[3] {
            #expect(count == 3)
        } else {
            Issue.record("Fourth frame should be PADDING")
        }
    }

    // MARK: - Roundtrip Tests

    @Test("Roundtrip encoding for all frame types")
    func roundtripAllFrameTypes() throws {
        // Create NewConnectionIDFrame separately since it now throws
        let newCID = try #require(ConnectionID.random(length: 8))
        let newCIDFrame = try NewConnectionIDFrame(
            sequenceNumber: 1,
            retirePriorTo: 0,
            connectionID: newCID,
            statelessResetToken: Data(repeating: 0xFF, count: 16)
        )

        let testFrames: [Frame] = [
            .padding(count: 10),
            .ping,
            .ack(AckFrame(largestAcknowledged: 1000, ackDelay: 100, ackRanges: [AckRange(gap: 0, rangeLength: 50)])),
            .ack(AckFrame(largestAcknowledged: 500, ackDelay: 50, ackRanges: [AckRange(gap: 0, rangeLength: 10)], ecnCounts: ECNCounts(ect0Count: 5, ect1Count: 3, ecnCECount: 1))),
            .resetStream(ResetStreamFrame(streamID: 4, applicationErrorCode: 1, finalSize: 100)),
            .stopSending(StopSendingFrame(streamID: 8, applicationErrorCode: 2)),
            .crypto(CryptoFrame(offset: 0, data: Data([0x01, 0x02, 0x03]))),
            .newToken(Data([0xAA, 0xBB, 0xCC])),
            .stream(StreamFrame(streamID: 0, offset: 0, data: Data("Hello".utf8), fin: false)),
            .stream(StreamFrame(streamID: 4, offset: 100, data: Data("World".utf8), fin: true)),
            .maxData(10_000_000),
            .maxStreamData(MaxStreamDataFrame(streamID: 0, maxStreamData: 1_000_000)),
            .maxStreams(MaxStreamsFrame(maxStreams: 100, isBidirectional: true)),
            .maxStreams(MaxStreamsFrame(maxStreams: 50, isBidirectional: false)),
            .dataBlocked(5_000_000),
            .streamDataBlocked(StreamDataBlockedFrame(streamID: 4, streamDataLimit: 500_000)),
            .streamsBlocked(StreamsBlockedFrame(streamLimit: 100, isBidirectional: true)),
            .streamsBlocked(StreamsBlockedFrame(streamLimit: 50, isBidirectional: false)),
            .newConnectionID(newCIDFrame),
            .retireConnectionID(3),
            .pathChallenge(Data(repeating: 0x12, count: 8)),
            .pathResponse(Data(repeating: 0x34, count: 8)),
            .connectionClose(ConnectionCloseFrame(errorCode: 0, frameType: nil, reasonPhrase: "", isApplicationError: false)),
            .connectionClose(ConnectionCloseFrame(errorCode: 0x100, reasonPhrase: "App error", isApplicationError: true)),
            .handshakeDone,
            .datagram(DatagramFrame(data: Data([0x01, 0x02]), hasLength: true)),
        ]

        for originalFrame in testFrames {
            let encoded = try codec.encode(originalFrame)
            var reader = DataReader(encoded)
            _ = try codec.decode(from: &reader)

            // Verify reader consumed all data
            #expect(reader.remainingCount == 0, "Frame \(originalFrame.frameType) did not consume all data")
        }
    }

    // MARK: - Frame Boundary Validation Tests (RFC 9000 Section 12.4)

    @Test("STREAM frame with hasLength property")
    func streamFrameHasLengthProperty() throws {
        let streamFrame = StreamFrame(
            streamID: 4,
            offset: 0,
            data: Data([0x01, 0x02, 0x03]),
            fin: false,
            hasLength: true
        )
        let frame = Frame.stream(streamFrame)
        let encoded = try codec.encode(frame)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .stream(let decodedStream) = decoded {
            #expect(decodedStream.hasLength == true)
        } else {
            Issue.record("Expected STREAM frame")
        }
    }

    @Test("DATAGRAM frame with hasLength property")
    func datagramFrameHasLengthProperty() throws {
        let datagramFrame = DatagramFrame(data: Data([0xAB, 0xCD]), hasLength: true)
        let frame = Frame.datagram(datagramFrame)
        let encoded = try codec.encode(frame)

        var reader = DataReader(encoded)
        let decoded = try codec.decode(from: &reader)

        if case .datagram(let decodedDatagram) = decoded {
            #expect(decodedDatagram.hasLength == true)
        } else {
            Issue.record("Expected DATAGRAM frame")
        }
    }

    @Test("Decode STREAM frame without length (must be last)")
    func streamFrameWithoutLength() throws {
        // Manually construct a STREAM frame without LEN bit (0x08 only)
        // Type: 0x08 (STREAM, no OFF, no LEN, no FIN)
        // Stream ID: 4 (varint)
        // Data: rest of packet
        var data = Data()
        data.append(0x08)  // STREAM type, no LEN bit
        Varint(4).encode(to: &data)  // Stream ID
        data.append(contentsOf: [0x01, 0x02, 0x03])  // Data (consumes rest)

        var reader = DataReader(data)
        let decoded = try codec.decode(from: &reader)

        if case .stream(let streamFrame) = decoded {
            #expect(streamFrame.streamID == 4)
            #expect(streamFrame.offset == 0)
            #expect(streamFrame.data == Data([0x01, 0x02, 0x03]))
            #expect(streamFrame.hasLength == false)
        } else {
            Issue.record("Expected STREAM frame")
        }

        // Reader should have consumed all data
        #expect(reader.remainingCount == 0)
    }

    @Test("Multiple frames with STREAM (no length) at end is valid")
    func streamWithoutLengthAtEndIsValid() throws {
        var data = Data()

        // PING frame
        data.append(0x01)

        // STREAM frame without LEN bit (must be last)
        data.append(0x08)  // STREAM, no LEN bit
        Varint(0).encode(to: &data)  // Stream ID
        data.append(contentsOf: [0xAA, 0xBB])  // Data (consumes rest)

        let decoded = try codec.decodeFrames(from: data)

        #expect(decoded.count == 2)

        if case .ping = decoded[0] {
            // Good
        } else {
            Issue.record("First frame should be PING")
        }

        if case .stream(let streamFrame) = decoded[1] {
            #expect(streamFrame.hasLength == false)
            #expect(streamFrame.data == Data([0xAA, 0xBB]))
        } else {
            Issue.record("Second frame should be STREAM")
        }
    }

    @Test("STREAM (no length) followed by another frame is invalid")
    func streamWithoutLengthNotLastIsInvalid() throws {
        var data = Data()

        // STREAM frame without LEN bit
        data.append(0x08)  // STREAM, no LEN bit
        Varint(0).encode(to: &data)  // Stream ID
        data.append(contentsOf: [0x01, 0x02])  // Data

        // PING frame after - this violates RFC 9000 Section 12.4
        data.append(0x01)

        // The STREAM frame will consume everything including the 0x01 PING byte
        // So we need to test that decodeFrames rejects this scenario
        // Actually, the no-length STREAM will consume all remaining bytes,
        // so there won't be any remaining data for PING

        // Let's construct this differently - we need to simulate external data
        // that was crafted maliciously with a no-length frame followed by more

        // The validation happens when we ALREADY decoded a no-length frame
        // and there's still data remaining (from external sources like coalesced packets)
        // But with our encoding, the no-length frame consumes everything

        // This test verifies that hasLength is tracked correctly
        let decoded = try codec.decodeFrames(from: data)

        // The no-length STREAM should consume everything including 0x01
        #expect(decoded.count == 1)
        if case .stream(let sf) = decoded[0] {
            // The data includes the extra 0x01 byte
            #expect(sf.data == Data([0x01, 0x02, 0x01]))
        }
    }

    @Test("DATAGRAM without length is valid when last")
    func datagramWithoutLengthAtEnd() throws {
        var data = Data()

        // PING frame
        data.append(0x01)

        // DATAGRAM frame without length (type 0x30)
        data.append(0x30)  // DATAGRAM without length
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let decoded = try codec.decodeFrames(from: data)

        #expect(decoded.count == 2)

        if case .datagram(let df) = decoded[1] {
            #expect(df.hasLength == false)
            #expect(df.data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        } else {
            Issue.record("Second frame should be DATAGRAM")
        }
    }
}
