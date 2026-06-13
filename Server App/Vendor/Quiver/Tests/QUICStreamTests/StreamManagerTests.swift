/// StreamManager Unit Tests
///
/// Tests for stream management across a QUIC connection.

import Testing
import Foundation
@testable import QUICStream
@testable import QUICCore

@Suite("StreamManager Tests")
struct StreamManagerTests {

    // MARK: - Stream Creation Tests

    @Test("Open client-initiated bidirectional stream")
    func openClientBidiStream() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)

        #expect(streamID == 0)  // Client bidi: 0, 4, 8, ...
        #expect(manager.hasStream(id: streamID))
        #expect(manager.activeStreamCount == 1)
    }

    @Test("Open client-initiated unidirectional stream")
    func openClientUniStream() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataUni: 1000,
            peerInitialMaxStreamsUni: 10
        )

        let streamID = try manager.openStream(bidirectional: false)

        #expect(streamID == 2)  // Client uni: 2, 6, 10, ...
        #expect(manager.hasStream(id: streamID))
    }

    @Test("Open server-initiated bidirectional stream")
    func openServerBidiStream() throws {
        let manager = StreamManager(
            isClient: false,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)

        #expect(streamID == 1)  // Server bidi: 1, 5, 9, ...
    }

    @Test("Open multiple streams")
    func openMultipleStreams() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let id1 = try manager.openStream(bidirectional: true)
        let id2 = try manager.openStream(bidirectional: true)
        let id3 = try manager.openStream(bidirectional: true)

        #expect(id1 == 0)
        #expect(id2 == 4)
        #expect(id3 == 8)
        #expect(manager.activeStreamCount == 3)
    }

    @Test("Stream limit enforced")
    func streamLimitEnforced() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 2
        )

        _ = try manager.openStream(bidirectional: true)
        _ = try manager.openStream(bidirectional: true)

        #expect(throws: StreamManagerError.self) {
            _ = try manager.openStream(bidirectional: true)
        }
    }

    // MARK: - Remote Stream Creation Tests

    @Test("Accept remote stream")
    func acceptRemoteStream() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            initialMaxStreamsBidi: 10
        )

        // Server-initiated bidi stream
        let streamID = try manager.getOrCreateStream(id: 1)

        #expect(streamID == 1)
        #expect(manager.hasStream(id: 1))
    }

    @Test("Reject invalid stream ID")
    func rejectInvalidStreamID() {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamsBidi: 10
        )

        // Client trying to "receive" from a client-initiated stream ID
        #expect(throws: StreamManagerError.self) {
            _ = try manager.getOrCreateStream(id: 0)
        }
    }

    // MARK: - Frame Processing Tests

    @Test("Receive STREAM frame")
    func receiveStreamFrame() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxData: 10000,
            initialMaxStreamDataBidiRemote: 1000
        )

        let frame = StreamFrame(
            streamID: 1,  // Server-initiated
            offset: 0,
            data: Data([1, 2, 3, 4, 5]),
            fin: false
        )

        try manager.receive(frame: frame)

        #expect(manager.hasStream(id: 1))
        #expect(manager.hasDataToRead(streamID: 1))
    }

    @Test("Read received data")
    func readReceivedData() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxData: 10000,
            initialMaxStreamDataBidiRemote: 1000
        )

        let frame = StreamFrame(
            streamID: 1,
            offset: 0,
            data: Data([1, 2, 3, 4, 5]),
            fin: false
        )

        try manager.receive(frame: frame)
        let data = manager.read(streamID: 1)

        #expect(data == Data([1, 2, 3, 4, 5]))
        #expect(!manager.hasDataToRead(streamID: 1))
    }

    @Test("Handle MAX_DATA frame")
    func handleMaxDataFrame() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 100,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 50))

        // Peer sends MAX_DATA to increase limit
        manager.handleMaxData(MaxDataFrame(maxData: 500))

        // Should be able to write more now
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 100))

        #expect(manager.hasDataToSend(streamID: streamID))
    }

    @Test("Handle MAX_STREAM_DATA frame")
    func handleMaxStreamDataFrame() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 10000,
            peerInitialMaxStreamDataBidiLocal: 100,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 50))

        // Peer sends MAX_STREAM_DATA
        manager.handleMaxStreamData(MaxStreamDataFrame(streamID: streamID, maxStreamData: 500))

        // Verify we can now send more
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 100))
    }

    @Test("Handle MAX_STREAMS frame")
    func handleMaxStreamsFrame() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 1
        )

        _ = try manager.openStream(bidirectional: true)

        // At limit
        #expect(throws: StreamManagerError.self) {
            _ = try manager.openStream(bidirectional: true)
        }

        // Peer increases limit
        manager.handleMaxStreams(MaxStreamsFrame(maxStreams: 5, isBidirectional: true))

        // Now can open more
        let id2 = try manager.openStream(bidirectional: true)
        #expect(id2 == 4)
    }

    @Test("Handle RESET_STREAM frame")
    func handleResetStreamFrame() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            initialMaxStreamsBidi: 10
        )

        // First receive some data
        let dataFrame = StreamFrame(streamID: 1, offset: 0, data: Data([1, 2, 3]), fin: false)
        try manager.receive(frame: dataFrame)

        // Then receive RESET_STREAM
        let resetFrame = ResetStreamFrame(streamID: 1, applicationErrorCode: 42, finalSize: 100)
        try manager.handleResetStream(resetFrame)

        // Data should be cleared
        #expect(!manager.hasDataToRead(streamID: 1))
    }

    @Test("Handle STOP_SENDING frame")
    func handleStopSendingFrame() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data([1, 2, 3, 4, 5]))

        // Peer sends STOP_SENDING
        let stopFrame = StopSendingFrame(streamID: streamID, applicationErrorCode: 42)
        manager.handleStopSending(stopFrame)

        // Send buffer should be cleared
        #expect(!manager.hasDataToSend(streamID: streamID))
    }

    // MARK: - Write and Send Tests

    @Test("Write data to stream")
    func writeDataToStream() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 10000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data([1, 2, 3, 4, 5]))

        #expect(manager.hasDataToSend(streamID: streamID))
    }

    @Test("Generate stream frames")
    func generateStreamFrames() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 10000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data([1, 2, 3, 4, 5]))

        let frames = manager.generateStreamFrames(maxBytes: 1000)

        #expect(frames.count == 1)
        #expect(frames[0].streamID == streamID)
        #expect(frames[0].data == Data([1, 2, 3, 4, 5]))
    }

    @Test("Finish stream sends FIN")
    func finishStreamSendsFin() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 10000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data([1, 2, 3]))
        try manager.finish(streamID: streamID)

        let frames = manager.generateStreamFrames(maxBytes: 1000)

        #expect(frames.count == 1)
        #expect(frames[0].fin)
    }

    // MARK: - Flow Control Frame Generation Tests

    @Test("Generate flow control frames")
    func generateFlowControlFrames() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxData: 100,
            initialMaxStreamDataBidiRemote: 100,
            initialMaxStreamsBidi: 10
        )

        // Receive enough data to trigger MAX_DATA
        let frame = StreamFrame(
            streamID: 1,
            offset: 0,
            data: Data(repeating: 0, count: 60),
            fin: false
        )
        try manager.receive(frame: frame)

        let flowFrames = manager.generateFlowControlFrames()

        // Should have at least MAX_DATA
        #expect(!flowFrames.isEmpty)
    }

    // MARK: - Stream Lifecycle Tests

    @Test("Close stream")
    func closeStream() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        #expect(manager.hasStream(id: streamID))

        manager.closeStream(id: streamID)

        #expect(!manager.hasStream(id: streamID))
        #expect(manager.activeStreamCount == 0)
    }

    @Test("Closed stream frees stream limit")
    func closedStreamFreesLimit() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 2
        )

        let id1 = try manager.openStream(bidirectional: true)
        _ = try manager.openStream(bidirectional: true)

        // At limit
        #expect(throws: StreamManagerError.self) {
            _ = try manager.openStream(bidirectional: true)
        }

        // Close one
        manager.closeStream(id: id1)

        // Can now open another
        let id3 = try manager.openStream(bidirectional: true)
        #expect(id3 == 8)  // Third client bidi stream ID
    }

    @Test("Active stream IDs")
    func activeStreamIDs() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        let id1 = try manager.openStream(bidirectional: true)
        let id2 = try manager.openStream(bidirectional: true)

        let activeIDs = manager.activeStreamIDs

        #expect(activeIDs.contains(id1))
        #expect(activeIDs.contains(id2))
        #expect(activeIDs.count == 2)
    }

    // MARK: - Edge Cases

    @Test("Write to nonexistent stream fails")
    func writeToNonexistentStream() {
        let manager = StreamManager(isClient: true)

        #expect(throws: StreamManagerError.self) {
            try manager.write(streamID: 999, data: Data([1, 2, 3]))
        }
    }

    @Test("Read from nonexistent stream returns nil")
    func readFromNonexistentStream() {
        let manager = StreamManager(isClient: true)

        let data = manager.read(streamID: 999)
        #expect(data == nil)
    }

    @Test("Finish nonexistent stream fails")
    func finishNonexistentStream() {
        let manager = StreamManager(isClient: true)

        #expect(throws: StreamManagerError.self) {
            try manager.finish(streamID: 999)
        }
    }

    // MARK: - Flow Control Fix Tests

    @Test("generateStreamFrames respects connection window")
    func connectionWindowEnforced() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 50,  // Small connection window
            peerInitialMaxStreamDataBidiLocal: 1000,  // Large stream window
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 200))

        // Generate frames - should be limited by connection window (50), not stream (1000)
        let frames = manager.generateStreamFrames(maxBytes: 1000)

        let totalBytes = frames.reduce(0) { $0 + $1.data.count }
        #expect(totalBytes <= 50, "Total bytes \(totalBytes) should not exceed connection window 50")
    }

    @Test("generateStreamFrames respects stream window when smaller than connection")
    func streamWindowEnforcedWhenSmaller() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 1000,  // Large connection window
            peerInitialMaxStreamDataBidiLocal: 30,  // Small stream window
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        try manager.write(streamID: streamID, data: Data(repeating: 0, count: 200))

        // Generate frames - should be limited by stream window (30)
        let frames = manager.generateStreamFrames(maxBytes: 1000)

        let totalBytes = frames.reduce(0) { $0 + $1.data.count }
        #expect(totalBytes <= 30, "Total bytes \(totalBytes) should not exceed stream window 30")
    }

    // MARK: - Cleanup Tests

    @Test("closeAllStreams removes all streams")
    func closeAllStreamsRemovesAll() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        // Open multiple streams
        let id1 = try manager.openStream(bidirectional: true)
        let id2 = try manager.openStream(bidirectional: true)
        let id3 = try manager.openStream(bidirectional: true)

        #expect(manager.activeStreamCount == 3)

        // Close all without error code
        let resetFrames = manager.closeAllStreams()

        #expect(manager.activeStreamCount == 0)
        #expect(!manager.hasStream(id: id1))
        #expect(!manager.hasStream(id: id2))
        #expect(!manager.hasStream(id: id3))
        #expect(resetFrames.isEmpty)  // No RESET_STREAM when no error code
    }

    @Test("closeAllStreams generates RESET_STREAM frames with error code")
    func closeAllStreamsGeneratesResetFrames() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        // Open streams and write data
        let id1 = try manager.openStream(bidirectional: true)
        let id2 = try manager.openStream(bidirectional: true)
        try manager.write(streamID: id1, data: Data([1, 2, 3]))
        try manager.write(streamID: id2, data: Data([4, 5, 6]))

        // Close all with error code
        let resetFrames = manager.closeAllStreams(errorCode: 42)

        #expect(manager.activeStreamCount == 0)
        #expect(resetFrames.count == 2)

        // Verify reset frames have correct error code
        for frame in resetFrames {
            #expect(frame.applicationErrorCode == 42)
        }
    }

    @Test("closeAllStreams cleans up flow controller tracking")
    func closeAllStreamsCleansFlowController() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        // Open local stream
        _ = try manager.openStream(bidirectional: true)

        // Receive data on remote stream (creates stream 1)
        let frame = StreamFrame(streamID: 1, offset: 0, data: Data([1, 2, 3]), fin: false)
        try manager.receive(frame: frame)

        #expect(manager.activeStreamCount == 2)

        // Close all
        _ = manager.closeAllStreams()

        #expect(manager.activeStreamCount == 0)

        // Can open new streams (limits freed)
        let newID = try manager.openStream(bidirectional: true)
        #expect(newID == 4)  // Next client bidi ID
    }

    @Test("closeAllStreams with buffered receive data")
    func closeAllStreamsWithBufferedData() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        // Receive data on remote stream
        let frame = StreamFrame(streamID: 1, offset: 0, data: Data(repeating: 0xAB, count: 100), fin: false)
        try manager.receive(frame: frame)

        #expect(manager.hasDataToRead(streamID: 1))

        // Close all - should discard buffered data
        _ = manager.closeAllStreams()

        #expect(manager.activeStreamCount == 0)
        #expect(!manager.hasStream(id: 1))
    }

    @Test("closeAllStreams is idempotent")
    func closeAllStreamsIdempotent() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 10
        )

        _ = try manager.openStream(bidirectional: true)
        #expect(manager.activeStreamCount == 1)

        // First close
        let frames1 = manager.closeAllStreams(errorCode: 1)
        #expect(manager.activeStreamCount == 0)

        // Second close (should be no-op)
        let frames2 = manager.closeAllStreams(errorCode: 1)
        #expect(manager.activeStreamCount == 0)
        #expect(frames2.isEmpty)  // No frames since no streams

        // streams.count check
        #expect(frames1.count == 1)
    }

    @Test("Individual stream cleanup releases resources")
    func individualStreamCleanup() throws {
        let manager = StreamManager(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            peerInitialMaxStreamDataBidiLocal: 1000,
            peerInitialMaxStreamsBidi: 2
        )

        // Open max streams
        let id1 = try manager.openStream(bidirectional: true)
        let id2 = try manager.openStream(bidirectional: true)

        // At limit
        #expect(throws: StreamManagerError.self) {
            _ = try manager.openStream(bidirectional: true)
        }

        // Write and receive data
        try manager.write(streamID: id1, data: Data([1, 2, 3]))
        _ = StreamFrame(streamID: id2, offset: 0, data: Data([4, 5, 6]), fin: true)
        try manager.receive(frame: StreamFrame(streamID: id1, offset: 0, data: Data([7, 8, 9]), fin: false))

        // Close first stream
        manager.closeStream(id: id1)

        #expect(manager.activeStreamCount == 1)
        #expect(!manager.hasStream(id: id1))
        #expect(manager.hasStream(id: id2))

        // Can open new stream (limit freed)
        let id3 = try manager.openStream(bidirectional: true)
        #expect(id3 == 8)

        // Close remaining
        manager.closeStream(id: id2)
        manager.closeStream(id: id3)

        #expect(manager.activeStreamCount == 0)
    }
}
