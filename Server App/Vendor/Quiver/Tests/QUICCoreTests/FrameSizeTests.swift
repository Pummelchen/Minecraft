/// Frame Size Calculator Tests

import Testing
import Foundation
@testable import QUICCore

@Suite("FrameSize Tests")
struct FrameSizeTests {

    // MARK: - STREAM Frame Tests

    @Test("STREAM frame size matches actual encoding - minimal")
    func streamFrameSizeMinimal() throws {
        let codec = StandardFrameCodec()
        let frame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data([1, 2, 3]),
            fin: false,
            hasLength: true
        )

        let predicted = FrameSize.streamFrame(
            streamID: 0,
            offset: 0,
            dataLength: 3,
            hasLength: true
        )
        let actual = try codec.encode(.stream(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("STREAM frame size matches actual encoding - with offset")
    func streamFrameSizeWithOffset() throws {
        let codec = StandardFrameCodec()
        let frame = StreamFrame(
            streamID: 63,  // 1-byte varint
            offset: 1000,  // 2-byte varint
            data: Data(repeating: 0x42, count: 100),
            fin: false,
            hasLength: true
        )

        let predicted = FrameSize.streamFrame(
            streamID: 63,
            offset: 1000,
            dataLength: 100,
            hasLength: true
        )
        let actual = try codec.encode(.stream(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("STREAM frame size matches actual encoding - large values")
    func streamFrameSizeLargeValues() throws {
        let codec = StandardFrameCodec()
        let frame = StreamFrame(
            streamID: 1_000_000,  // 4-byte varint
            offset: 1_000_000_000,  // 4-byte varint
            data: Data(repeating: 0x42, count: 10000),
            fin: true,
            hasLength: true
        )

        let predicted = FrameSize.streamFrame(
            streamID: 1_000_000,
            offset: 1_000_000_000,
            dataLength: 10000,
            hasLength: true
        )
        let actual = try codec.encode(.stream(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("STREAM frame size matches actual encoding - no length field")
    func streamFrameSizeNoLength() throws {
        let codec = StandardFrameCodec()
        let frame = StreamFrame(
            streamID: 4,
            offset: 0,
            data: Data([1, 2, 3, 4, 5]),
            fin: false,
            hasLength: false
        )

        let predicted = FrameSize.streamFrame(
            streamID: 4,
            offset: 0,
            dataLength: 5,
            hasLength: false
        )
        let actual = try codec.encode(.stream(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("STREAM frame overhead calculation")
    func streamFrameOverhead() {
        // Minimal overhead: type (1) + streamID (1) = 2
        let minOverhead = FrameSize.streamFrameOverhead(
            streamID: 0,
            offset: 0,
            dataLength: 100,
            hasLength: false
        )
        #expect(minOverhead == 2)

        // With length: type (1) + streamID (1) + length (2 for 100) = 4
        let withLength = FrameSize.streamFrameOverhead(
            streamID: 0,
            offset: 0,
            dataLength: 100,
            hasLength: true
        )
        #expect(withLength == 4)

        // With offset: type (1) + streamID (1) + offset (2) + length (2) = 6
        let withOffset = FrameSize.streamFrameOverhead(
            streamID: 0,
            offset: 1000,
            dataLength: 100,
            hasLength: true
        )
        #expect(withOffset == 6)
    }

    @Test("Max STREAM frame overhead constant is correct")
    func maxStreamFrameOverheadConstant() {
        // Worst case: type (1) + streamID (8) + offset (8) + length (8) = 25
        let maxOverhead = FrameSize.streamFrameOverhead(
            streamID: Varint.maxValue,
            offset: Varint.maxValue,
            dataLength: Int(Varint.maxValue),
            hasLength: true
        )
        #expect(maxOverhead == FrameSize.maxStreamFrameOverhead)
        #expect(FrameSize.maxStreamFrameOverhead == 25)
    }

    // MARK: - ACK Frame Tests

    @Test("ACK frame size matches actual encoding - single range")
    func ackFrameSizeSingleRange() throws {
        let codec = StandardFrameCodec()
        let frame = AckFrame(
            largestAcknowledged: 100,
            ackDelay: 50,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)]
        )

        let predicted = FrameSize.ackFrame(frame)
        let actual = try codec.encode(.ack(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("ACK frame size matches actual encoding - multiple ranges")
    func ackFrameSizeMultipleRanges() throws {
        let codec = StandardFrameCodec()
        let frame = AckFrame(
            largestAcknowledged: 1000,
            ackDelay: 100,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 5),
                AckRange(gap: 10, rangeLength: 3),
                AckRange(gap: 5, rangeLength: 2)
            ]
        )

        let predicted = FrameSize.ackFrame(frame)
        let actual = try codec.encode(.ack(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    @Test("ACK frame size matches actual encoding - with ECN")
    func ackFrameSizeWithECN() throws {
        let codec = StandardFrameCodec()
        let frame = AckFrame(
            largestAcknowledged: 500,
            ackDelay: 25,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)],
            ecnCounts: ECNCounts(ect0Count: 100, ect1Count: 50, ecnCECount: 5)
        )

        let predicted = FrameSize.ackFrame(frame)
        let actual = try codec.encode(.ack(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    // MARK: - CRYPTO Frame Tests

    @Test("CRYPTO frame size matches actual encoding")
    func cryptoFrameSize() throws {
        let codec = StandardFrameCodec()
        let frame = CryptoFrame(
            offset: 1000,
            data: Data(repeating: 0x00, count: 500)
        )

        let predicted = FrameSize.cryptoFrame(offset: 1000, dataLength: 500)
        let actual = try codec.encode(.crypto(frame)).count

        #expect(predicted == actual, "Predicted \(predicted) != actual \(actual)")
    }

    // MARK: - Control Frame Tests

    @Test("Fixed-size frame constants are correct")
    func fixedSizeFrames() throws {
        let codec = StandardFrameCodec()

        // PING
        let pingSize = try codec.encode(.ping).count
        #expect(pingSize == FrameSize.pingFrame)

        // HANDSHAKE_DONE
        let handshakeDoneSize = try codec.encode(.handshakeDone).count
        #expect(handshakeDoneSize == FrameSize.handshakeDoneFrame)

        // PATH_CHALLENGE
        let pathChallengeSize = try codec.encode(.pathChallenge(Data(repeating: 0, count: 8))).count
        #expect(pathChallengeSize == FrameSize.pathChallengeFrame)

        // PATH_RESPONSE
        let pathResponseSize = try codec.encode(.pathResponse(Data(repeating: 0, count: 8))).count
        #expect(pathResponseSize == FrameSize.pathResponseFrame)
    }

    @Test("MAX_DATA frame size matches actual encoding")
    func maxDataFrameSize() throws {
        let codec = StandardFrameCodec()
        let testValues: [UInt64] = [0, 63, 16383, 1_073_741_823, 4_611_686_018_427_387_903]

        for value in testValues {
            let predicted = FrameSize.maxDataFrame(maxData: value)
            let actual = try codec.encode(.maxData(value)).count
            #expect(predicted == actual, "For value \(value): predicted \(predicted) != actual \(actual)")
        }
    }

    // MARK: - Varint.encodedLength Tests

    @Test("Varint.encodedLength matches actual encoding")
    func varintEncodedLength() {
        let testCases: [(UInt64, Int)] = [
            (0, 1),
            (63, 1),
            (64, 2),
            (16383, 2),
            (16384, 4),
            (1_073_741_823, 4),
            (1_073_741_824, 8),
            (Varint.maxValue, 8)
        ]

        for (value, expectedLength) in testCases {
            let staticLength = Varint.encodedLength(for: value)
            let instanceLength = Varint(value).encodedLength
            let actualLength = Varint(value).encode().count

            #expect(staticLength == expectedLength, "Static: \(value) -> \(staticLength), expected \(expectedLength)")
            #expect(instanceLength == expectedLength, "Instance: \(value) -> \(instanceLength), expected \(expectedLength)")
            #expect(actualLength == expectedLength, "Actual: \(value) -> \(actualLength), expected \(expectedLength)")
        }
    }

    // MARK: - Generic Frame Size Tests

    @Test("FrameSize.frame matches actual encoding for all frame types")
    func genericFrameSize() throws {
        let codec = StandardFrameCodec()

        let frames: [Frame] = [
            .padding(count: 10),
            .ping,
            .ack(AckFrame(largestAcknowledged: 100, ackDelay: 50, ackRanges: [AckRange(gap: 0, rangeLength: 5)])),
            .resetStream(ResetStreamFrame(streamID: 4, applicationErrorCode: 0, finalSize: 1000)),
            .stopSending(StopSendingFrame(streamID: 4, applicationErrorCode: 0)),
            .crypto(CryptoFrame(offset: 0, data: Data(repeating: 0, count: 100))),
            .newToken(Data(repeating: 0xAB, count: 32)),
            .stream(StreamFrame(streamID: 4, offset: 0, data: Data([1, 2, 3]), fin: false, hasLength: true)),
            .maxData(1_000_000),
            .maxStreamData(MaxStreamDataFrame(streamID: 4, maxStreamData: 500_000)),
            .maxStreams(MaxStreamsFrame(maxStreams: 100, isBidirectional: true)),
            .dataBlocked(1_000_000),
            .streamDataBlocked(StreamDataBlockedFrame(streamID: 4, streamDataLimit: 500_000)),
            .streamsBlocked(StreamsBlockedFrame(streamLimit: 100, isBidirectional: true)),
            .retireConnectionID(5),
            .pathChallenge(Data(repeating: 0, count: 8)),
            .pathResponse(Data(repeating: 0, count: 8)),
            .connectionClose(ConnectionCloseFrame(errorCode: 0, frameType: nil, reasonPhrase: "test", isApplicationError: true)),
            .handshakeDone,
            .datagram(DatagramFrame(data: Data([1, 2, 3]), hasLength: true))
        ]

        for frame in frames {
            let predicted = FrameSize.frame(frame)
            let actual = try codec.encode(frame).count
            #expect(predicted == actual, "Frame \(frame): predicted \(predicted) != actual \(actual)")
        }
    }
}
