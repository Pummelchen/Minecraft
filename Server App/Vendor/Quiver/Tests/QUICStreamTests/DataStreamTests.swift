/// DataStream Unit Tests
///
/// Tests for single QUIC stream management.

import Testing
import Foundation
@testable import QUICStream
@testable import QUICCore

@Suite("DataStream Tests")
struct DataStreamTests {

    // MARK: - Stream Creation Tests

    @Test("Create client-initiated bidirectional stream")
    func createClientBidiStream() {
        let streamID: UInt64 = 0  // Client-initiated bidi
        let stream = DataStream(
            id: streamID,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.id == 0)
        #expect(stream.isBidirectional)
        #expect(!stream.isUnidirectional)
        #expect(stream.isLocallyInitiated)
        #expect(stream.canSend)
        #expect(stream.canReceive)
    }

    @Test("Create server-initiated bidirectional stream")
    func createServerBidiStream() {
        let streamID: UInt64 = 1  // Server-initiated bidi
        let stream = DataStream(
            id: streamID,
            isClient: false,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.id == 1)
        #expect(stream.isBidirectional)
        #expect(stream.isLocallyInitiated)
        #expect(stream.canSend)
        #expect(stream.canReceive)
    }

    @Test("Create client-initiated unidirectional stream - client side")
    func createClientUniStreamClientSide() {
        let streamID: UInt64 = 2  // Client-initiated uni
        let stream = DataStream(
            id: streamID,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.isUnidirectional)
        #expect(stream.isLocallyInitiated)
        #expect(stream.canSend)  // Initiator can send
        #expect(!stream.canReceive)  // Initiator cannot receive
    }

    @Test("Create client-initiated unidirectional stream - server side")
    func createClientUniStreamServerSide() {
        let streamID: UInt64 = 2  // Client-initiated uni
        let stream = DataStream(
            id: streamID,
            isClient: false,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.isUnidirectional)
        #expect(!stream.isLocallyInitiated)
        #expect(!stream.canSend)  // Non-initiator cannot send
        #expect(stream.canReceive)  // Non-initiator can receive
    }

    // MARK: - Receive Tests

    @Test("Receive single frame")
    func receiveSingleFrame() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let frame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data([0x01, 0x02, 0x03]),
            fin: false
        )

        try stream.receive(frame)

        #expect(stream.hasDataToRead)
        #expect(stream.bufferedReadBytes == 3)
    }

    @Test("Receive and read data")
    func receiveAndReadData() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let frame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data([0x01, 0x02, 0x03]),
            fin: false
        )

        try stream.receive(frame)
        let data = stream.read()

        #expect(data == Data([0x01, 0x02, 0x03]))
        #expect(!stream.hasDataToRead)
    }

    @Test("Receive out-of-order frames")
    func receiveOutOfOrderFrames() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        // Receive frame at offset 5 first
        let frame2 = StreamFrame(streamID: 0, offset: 5, data: Data([6, 7, 8]), fin: false)
        try stream.receive(frame2)

        #expect(!stream.hasDataToRead)  // Gap at beginning

        // Receive frame at offset 0
        let frame1 = StreamFrame(streamID: 0, offset: 0, data: Data([1, 2, 3, 4, 5]), fin: false)
        try stream.receive(frame1)

        #expect(stream.hasDataToRead)  // Now contiguous

        let data = stream.read()
        #expect(data == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    @Test("Receive with FIN")
    func receiveWithFin() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let frame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data([0x01, 0x02, 0x03]),
            fin: true
        )

        try stream.receive(frame)

        #expect(stream.state.finReceived)
        #expect(stream.state.finalSize == 3)
        #expect(stream.state.recvState == .sizeKnown)
    }

    @Test("Receive flow control violation throws")
    func receiveFlowControlViolation() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 10  // Small limit
        )

        let frame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data(repeating: 0x00, count: 20),  // Exceeds limit
            fin: false
        )

        #expect(throws: StreamError.self) {
            try stream.receive(frame)
        }
    }

    @Test("Cannot receive on send-only unidirectional stream")
    func cannotReceiveOnSendOnlyStream() throws {
        let stream = DataStream(
            id: 2,  // Client-initiated uni
            isClient: true,  // We are the initiator
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let frame = StreamFrame(streamID: 2, offset: 0, data: Data([1, 2, 3]), fin: false)

        #expect(throws: StreamError.self) {
            try stream.receive(frame)
        }
    }

    // MARK: - Send Tests

    @Test("Write data to stream")
    func writeData() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.write(Data([0x01, 0x02, 0x03]))

        #expect(stream.hasDataToSend)
        #expect(stream.pendingSendBytes == 3)
        #expect(stream.state.sendState == .send)
    }

    @Test("Generate stream frames")
    func generateStreamFrames() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.write(Data([0x01, 0x02, 0x03, 0x04, 0x05]))

        let frames = stream.generateFrames(maxBytes: 1000)

        #expect(frames.count == 1)
        #expect(frames[0].streamID == 0)
        #expect(frames[0].offset == 0)
        #expect(frames[0].data == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        #expect(!frames[0].fin)
    }

    @Test("Generate frames with FIN")
    func generateFramesWithFin() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.write(Data([0x01, 0x02, 0x03]))
        try stream.finish()

        let frames = stream.generateFrames(maxBytes: 1000)

        #expect(frames.count == 1)
        #expect(frames[0].fin)
        #expect(stream.state.finSent)
        #expect(stream.state.sendState == .dataSent)
    }

    @Test("Generate FIN-only frame")
    func generateFinOnlyFrame() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.finish()

        let frames = stream.generateFrames(maxBytes: 1000)

        #expect(frames.count == 1)
        #expect(frames[0].data.isEmpty)
        #expect(frames[0].fin)
    }

    @Test("Flow control limits send")
    func flowControlLimitsSend() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 5,  // Small limit
            initialRecvMaxData: 1000
        )

        try stream.write(Data(repeating: 0x00, count: 10))

        let frames = stream.generateFrames(maxBytes: 1000)

        // Should only send up to flow control limit
        #expect(frames[0].data.count == 5)
        #expect(stream.pendingSendBytes == 5)  // 5 remaining
    }

    @Test("Cannot send on receive-only unidirectional stream")
    func cannotSendOnReceiveOnlyStream() throws {
        let stream = DataStream(
            id: 2,  // Client-initiated uni
            isClient: false,  // We are NOT the initiator
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(throws: StreamError.self) {
            try stream.write(Data([1, 2, 3]))
        }
    }

    // MARK: - Flow Control Update Tests

    @Test("Update send max data")
    func updateSendMaxData() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 5,
            initialRecvMaxData: 1000
        )

        try stream.write(Data(repeating: 0x00, count: 20))

        // Generate first batch (limited to 5)
        _ = stream.generateFrames(maxBytes: 1000)
        #expect(stream.sendWindow == 0)

        // Update limit
        stream.updateSendMaxData(15)
        #expect(stream.sendWindow == 10)

        // Generate more
        let frames = stream.generateFrames(maxBytes: 1000)
        #expect(frames[0].data.count == 10)
    }

    // MARK: - STOP_SENDING Tests

    @Test("Handle STOP_SENDING")
    func handleStopSending() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.write(Data([1, 2, 3]))

        stream.handleStopSending(errorCode: 42)

        #expect(!stream.hasDataToSend)  // Buffer cleared
        #expect(stream.needsResetStream)  // Needs to generate RESET_STREAM
        #expect(stream.stopSendingErrorCode == 42)

        // RFC 9000 Section 3.5: RESET_STREAM should be generated in response
        // State transitions to .resetSent only when RESET_STREAM is generated
        let resetFrame = stream.generateResetStream(errorCode: 42)
        #expect(resetFrame != nil)
        #expect(resetFrame?.applicationErrorCode == 42)
        #expect(stream.state.sendState == .resetSent)
        #expect(!stream.needsResetStream)  // No longer needs RESET_STREAM
    }

    @Test("Write after STOP_SENDING throws")
    func writeAfterStopSendingThrows() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        stream.handleStopSending(errorCode: 42)

        #expect(throws: StreamError.self) {
            try stream.write(Data([1, 2, 3]))
        }
    }

    // MARK: - RESET_STREAM Tests

    @Test("Handle RESET_STREAM from peer")
    func handleResetStream() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let frame = StreamFrame(streamID: 0, offset: 0, data: Data([1, 2, 3]), fin: false)
        try stream.receive(frame)

        try stream.handleResetStream(errorCode: 42, finalSize: 100)

        #expect(stream.state.recvState == .resetRecvd)
        #expect(stream.state.finalSize == 100)
        #expect(!stream.hasDataToRead)  // Buffer cleared
    }

    @Test("Generate RESET_STREAM")
    func generateResetStream() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        try stream.write(Data([1, 2, 3, 4, 5]))
        _ = stream.generateFrames(maxBytes: 1000)  // Send the data

        let resetFrame = stream.generateResetStream(errorCode: 42)

        #expect(resetFrame != nil)
        #expect(resetFrame!.streamID == 0)
        #expect(resetFrame!.applicationErrorCode == 42)
        #expect(resetFrame!.finalSize == 5)
        #expect(stream.state.sendState == .resetSent)
    }

    @Test("Generate STOP_SENDING")
    func generateStopSending() {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let stopFrame = stream.generateStopSending(errorCode: 42)

        #expect(stopFrame != nil)
        #expect(stopFrame!.streamID == 0)
        #expect(stopFrame!.applicationErrorCode == 42)
    }

    // MARK: - State Transition Tests

    @Test("Full receive state transition")
    func fullReceiveStateTransition() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.state.recvState == .recv)

        // Receive data with FIN
        let frame = StreamFrame(streamID: 0, offset: 0, data: Data([1, 2, 3]), fin: true)
        try stream.receive(frame)

        #expect(stream.state.recvState == .sizeKnown)

        // Read all data
        _ = stream.read()

        #expect(stream.state.recvState == .dataRead)
    }

    @Test("Full send state transition")
    func fullSendStateTransition() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        #expect(stream.state.sendState == .ready)

        // Write data
        try stream.write(Data([1, 2, 3]))
        #expect(stream.state.sendState == .send)

        // Queue FIN
        try stream.finish()

        // Generate and send
        _ = stream.generateFrames(maxBytes: 1000)
        #expect(stream.state.sendState == .dataSent)

        // Acknowledge
        stream.acknowledgeData(upTo: 3)
        #expect(stream.state.sendState == .dataRecvd)
    }

    // MARK: - RFC 9000 Section 4.5: Stream Final Size Tests

    /// RFC 9000 Section 4.5:
    /// "A receiver MUST close the connection with error FLOW_CONTROL_ERROR
    /// if a sender violates the advertised connection or stream data limits"
    @Test("RFC 9000 4.5: RESET_STREAM with final size exceeding flow control limit throws error")
    func resetStreamExceedsFlowControlLimit() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 100  // Stream receive limit = 100
        )

        // RESET_STREAM with finalSize > recvMaxData should throw
        #expect(throws: StreamError.self) {
            let mutableStream = stream
            try mutableStream.handleResetStream(errorCode: 0, finalSize: 150)
        }
    }

    /// RFC 9000 Section 4.5:
    /// "Once a final size for a stream is known, it cannot change"
    @Test("RFC 9000 4.5: RESET_STREAM with conflicting final size throws error")
    func resetStreamConflictingFinalSize() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        // First: Receive FIN with final size 50
        let finFrame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data(repeating: 0, count: 50),
            fin: true
        )
        try stream.receive(finFrame)
        #expect(stream.state.finalSize == 50)

        // Then: RESET_STREAM with different final size should throw
        #expect(throws: StreamError.self) {
            try stream.handleResetStream(errorCode: 0, finalSize: 100)
        }
    }

    /// RFC 9000 Section 4.5:
    /// "The final size is the amount of flow control credit that is consumed by a stream"
    @Test("RFC 9000 4.5: RESET_STREAM with matching final size succeeds")
    func resetStreamMatchingFinalSize() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        // First: Receive FIN with final size 50
        let finFrame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data(repeating: 0, count: 50),
            fin: true
        )
        let mutableStream = stream
        try mutableStream.receive(finFrame)

        // RESET_STREAM with same final size should succeed
        try mutableStream.handleResetStream(errorCode: 42, finalSize: 50)
        #expect(mutableStream.state.recvState == .resetRecvd)
    }

    /// RFC 9000 Section 4.5:
    /// "An endpoint that receives a RESET_STREAM frame for a send-only stream
    /// MUST terminate the connection with error STREAM_STATE_ERROR"
    @Test("RFC 9000 4.5: Final size from RESET_STREAM must not exceed stream limit")
    func resetStreamFinalSizeAtExactLimit() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 100
        )

        // RESET_STREAM with finalSize exactly at limit should succeed
        let mutableStream = stream
        try mutableStream.handleResetStream(errorCode: 0, finalSize: 100)
        #expect(mutableStream.state.finalSize == 100)
        #expect(mutableStream.state.recvState == .resetRecvd)
    }

    /// RFC 9000 Section 4.5:
    /// "Endpoints MUST NOT send data on a stream at or beyond the final size"
    @Test("RFC 9000 4.5: Data received beyond final size from FIN is rejected")
    func dataReceivedBeyondFinalSize() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        // First: Receive FIN with final size 50
        let finFrame = StreamFrame(
            streamID: 0,
            offset: 0,
            data: Data(repeating: 0, count: 50),
            fin: true
        )
        let mutableStream = stream
        try mutableStream.receive(finFrame)

        // Then: Data at offset 40 with length 20 (ends at 60 > 50) should throw
        let badFrame = StreamFrame(
            streamID: 0,
            offset: 40,
            data: Data(repeating: 0, count: 20),
            fin: false
        )
        #expect(throws: StreamError.self) {
            try mutableStream.receive(badFrame)
        }
    }

    // MARK: - Stream Closed Tests

    @Test("Bidirectional stream closed")
    func bidirectionalStreamClosed() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let mutableStream = stream
        #expect(!mutableStream.isClosed)

        // Close send side
        try mutableStream.write(Data([1, 2, 3]))
        try mutableStream.finish()
        _ = mutableStream.generateFrames(maxBytes: 1000)
        mutableStream.acknowledgeData(upTo: 3)

        #expect(!mutableStream.isClosed)  // Recv side still open

        // Close receive side
        let frame = StreamFrame(streamID: 0, offset: 0, data: Data([4, 5, 6]), fin: true)
        try mutableStream.receive(frame)
        _ = mutableStream.read()

        #expect(mutableStream.isClosed)
    }

    @Test("Unidirectional send-only stream closed")
    func unidirectionalSendOnlyStreamClosed() throws {
        let stream = DataStream(
            id: 2,  // Client-initiated uni
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let mutableStream = stream
        #expect(!mutableStream.isClosed)

        try mutableStream.write(Data([1, 2, 3]))
        try mutableStream.finish()
        _ = mutableStream.generateFrames(maxBytes: 1000)
        mutableStream.acknowledgeData(upTo: 3)

        #expect(mutableStream.isClosed)
    }

    // MARK: - Stream ID Mismatch Tests (Issue C)

    @Test("Stream ID mismatch throws error instead of crash")
    func streamIDMismatchThrows() throws {
        let stream = DataStream(
            id: 0,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        // Create a frame with wrong stream ID
        let wrongFrame = StreamFrame(streamID: 4, offset: 0, data: Data([1, 2, 3]), fin: false)

        #expect(throws: StreamError.self) {
            try stream.receive(wrongFrame)
        }
    }

    @Test("Stream ID mismatch error contains correct IDs")
    func streamIDMismatchErrorContainsIDs() throws {
        let stream = DataStream(
            id: 8,
            isClient: true,
            initialSendMaxData: 1000,
            initialRecvMaxData: 1000
        )

        let wrongFrame = StreamFrame(streamID: 12, offset: 0, data: Data([1]), fin: false)

        do {
            try stream.receive(wrongFrame)
            Issue.record("Expected StreamError.streamIDMismatch to be thrown")
        } catch let error as StreamError {
            if case .streamIDMismatch(let expected, let received) = error {
                #expect(expected == 8)
                #expect(received == 12)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }
}
