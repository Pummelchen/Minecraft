/// FlowController Unit Tests
///
/// Tests for connection and stream-level flow control.

import Testing
import Foundation
@testable import QUICStream
@testable import QUICCore

@Suite("FlowController Tests")
struct FlowControllerTests {

    // MARK: - Connection-Level Receive Tests

    @Test("Check connection receive within limit")
    func connectionReceiveWithinLimit() {
        let fc = FlowController(isClient: true, initialMaxData: 1000)

        #expect(fc.canReceive(bytes: 500))
        #expect(fc.canReceive(bytes: 1000))
        #expect(!fc.canReceive(bytes: 1001))
    }

    @Test("Record bytes received")
    func recordBytesReceived() {
        var fc = FlowController(isClient: true, initialMaxData: 1000)

        fc.recordBytesReceived(500)
        #expect(fc.connectionBytesReceived == 500)
        #expect(fc.canReceive(bytes: 500))
        #expect(!fc.canReceive(bytes: 501))
    }

    @Test("Generate MAX_DATA when window depleted")
    func generateMaxDataWhenDepleted() {
        var fc = FlowController(
            isClient: true,
            initialMaxData: 1000,
            autoUpdateThreshold: 0.5
        )

        // Receive 600 bytes (60% of window)
        fc.recordBytesReceived(600)

        // Should generate MAX_DATA since remaining (400) < threshold (500)
        let maxData = fc.generateMaxData()
        #expect(maxData != nil)
        #expect(maxData!.maxData == 2000)  // 1000 + 1000
    }

    @Test("No MAX_DATA when window sufficient")
    func noMaxDataWhenSufficient() {
        var fc = FlowController(
            isClient: true,
            initialMaxData: 1000,
            autoUpdateThreshold: 0.5
        )

        // Receive 400 bytes (40% of window)
        fc.recordBytesReceived(400)

        // Should NOT generate MAX_DATA since remaining (600) >= threshold (500)
        let maxData = fc.generateMaxData()
        #expect(maxData == nil)
    }

    // MARK: - Connection-Level Send Tests

    @Test("Check connection send within limit")
    func connectionSendWithinLimit() {
        let fc = FlowController(isClient: true, peerMaxData: 1000)

        #expect(fc.canSend(bytes: 500))
        #expect(fc.canSend(bytes: 1000))
        #expect(!fc.canSend(bytes: 1001))
    }

    @Test("Record bytes sent and detect blocked")
    func recordBytesSentAndBlocked() {
        var fc = FlowController(isClient: true, peerMaxData: 1000)

        fc.recordBytesSent(800)
        #expect(!fc.connectionBlocked)

        fc.recordBytesSent(200)  // Now at limit
        #expect(fc.connectionBlocked)
    }

    @Test("Connection send window calculation")
    func connectionSendWindow() {
        var fc = FlowController(isClient: true, peerMaxData: 1000)

        #expect(fc.connectionSendWindow == 1000)

        fc.recordBytesSent(300)
        #expect(fc.connectionSendWindow == 700)

        fc.recordBytesSent(700)
        #expect(fc.connectionSendWindow == 0)
    }

    @Test("Update connection send limit")
    func updateConnectionSendLimit() {
        var fc = FlowController(isClient: true, peerMaxData: 1000)

        fc.recordBytesSent(1000)
        #expect(fc.connectionBlocked)

        fc.updateConnectionSendLimit(2000)
        #expect(!fc.connectionBlocked)
        #expect(fc.connectionSendWindow == 1000)
    }

    @Test("Generate DATA_BLOCKED when blocked")
    func generateDataBlocked() {
        var fc = FlowController(isClient: true, peerMaxData: 1000)

        fc.recordBytesSent(1000)
        let blocked = fc.generateDataBlocked()

        #expect(blocked != nil)
        #expect(blocked!.dataLimit == 1000)
    }

    @Test("No DATA_BLOCKED when not blocked")
    func noDataBlockedWhenNotBlocked() {
        let fc = FlowController(isClient: true, peerMaxData: 1000)

        let blocked = fc.generateDataBlocked()
        #expect(blocked == nil)
    }

    // MARK: - Stream-Level Flow Control Tests

    @Test("Initialize and track stream")
    func initializeAndTrackStream() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000
        )

        fc.initializeStream(1)  // Server-initiated bidi stream = remote for client

        #expect(fc.canReceiveOnStream(1, endOffset: 500))
        #expect(fc.canReceiveOnStream(1, endOffset: 1000))
        #expect(!fc.canReceiveOnStream(1, endOffset: 1001))
    }

    @Test("Record stream bytes received")
    func recordStreamBytesReceived() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000
        )

        fc.initializeStream(1)  // Server-initiated bidi stream = remote for client
        fc.recordStreamBytesReceived(1, endOffset: 500)

        // Can still receive more
        #expect(fc.canReceiveOnStream(1, endOffset: 1000))
    }

    @Test("Generate MAX_STREAM_DATA when window depleted")
    func generateMaxStreamData() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000,
            autoUpdateThreshold: 0.5
        )

        fc.initializeStream(1)  // Server-initiated bidi stream = remote for client
        fc.recordStreamBytesReceived(1, endOffset: 600)

        // Should generate MAX_STREAM_DATA
        let maxStreamData = fc.generateMaxStreamData(for: 1)
        #expect(maxStreamData != nil)
        #expect(maxStreamData!.streamID == 1)
        #expect(maxStreamData!.maxStreamData == 2000)
    }

    @Test("Remove stream from tracking")
    func removeStreamFromTracking() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiRemote: 1000
        )

        fc.initializeStream(1)  // Server-initiated bidi stream = remote for client
        fc.recordStreamBytesReceived(1, endOffset: 500)

        fc.removeStream(1)

        // After removal, should use initial limit for new check
        #expect(fc.canReceiveOnStream(1, endOffset: 1000))
    }

    // MARK: - Stream Concurrency Tests

    @Test("Check can open local stream")
    func canOpenLocalStream() {
        let fc = FlowController(
            isClient: true,
            peerMaxStreamsBidi: 10,
            peerMaxStreamsUni: 5
        )

        #expect(fc.canOpenStream(bidirectional: true))
        #expect(fc.canOpenStream(bidirectional: false))
    }

    @Test("Track local stream count")
    func trackLocalStreamCount() {
        var fc = FlowController(
            isClient: true,
            peerMaxStreamsBidi: 2,
            peerMaxStreamsUni: 2
        )

        #expect(fc.canOpenStream(bidirectional: true))

        fc.recordLocalStreamOpened(bidirectional: true)
        fc.recordLocalStreamOpened(bidirectional: true)

        #expect(!fc.canOpenStream(bidirectional: true))  // At limit

        fc.recordLocalStreamClosed(bidirectional: true)
        #expect(fc.canOpenStream(bidirectional: true))  // One closed
    }

    @Test("Accept remote stream")
    func acceptRemoteStream() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamsBidi: 10,
            initialMaxStreamsUni: 5
        )

        #expect(fc.canAcceptRemoteStream(bidirectional: true))
        #expect(fc.canAcceptRemoteStream(bidirectional: false))

        // Open max streams
        for _ in 0..<10 {
            fc.recordRemoteStreamOpened(bidirectional: true)
        }

        #expect(!fc.canAcceptRemoteStream(bidirectional: true))
    }

    @Test("Update remote stream limit")
    func updateRemoteStreamLimit() {
        var fc = FlowController(
            isClient: true,
            peerMaxStreamsBidi: 5
        )

        // Open max streams
        for _ in 0..<5 {
            fc.recordLocalStreamOpened(bidirectional: true)
        }

        #expect(!fc.canOpenStream(bidirectional: true))

        // Peer sends MAX_STREAMS
        fc.updateRemoteStreamLimit(10, bidirectional: true)

        #expect(fc.canOpenStream(bidirectional: true))
    }

    @Test("Generate MAX_STREAMS when threshold reached")
    func generateMaxStreams() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamsBidi: 10
        )

        // Open 5 streams (50% threshold)
        for _ in 0..<5 {
            fc.recordRemoteStreamOpened(bidirectional: true)
        }

        let maxStreams = fc.generateMaxStreams(bidirectional: true)
        #expect(maxStreams != nil)
        #expect(maxStreams!.isBidirectional)
        #expect(maxStreams!.maxStreams == 20)  // 10 + 10
    }

    @Test("Generate STREAMS_BLOCKED when at limit")
    func generateStreamsBlocked() {
        var fc = FlowController(
            isClient: true,
            peerMaxStreamsBidi: 5
        )

        for _ in 0..<5 {
            fc.recordLocalStreamOpened(bidirectional: true)
        }

        let blocked = fc.generateStreamsBlocked(bidirectional: true)
        #expect(blocked != nil)
        #expect(blocked!.isBidirectional)
        #expect(blocked!.streamLimit == 5)
    }

    @Test("No STREAMS_BLOCKED when not at limit")
    func noStreamsBlockedWhenNotAtLimit() {
        var fc = FlowController(
            isClient: true,
            peerMaxStreamsBidi: 10
        )

        fc.recordLocalStreamOpened(bidirectional: true)

        let blocked = fc.generateStreamsBlocked(bidirectional: true)
        #expect(blocked == nil)
    }

    // MARK: - Edge Cases

    @Test("Zero initial limits")
    func zeroInitialLimits() {
        let fc = FlowController(
            isClient: true,
            initialMaxData: 0,
            peerMaxData: 0,
            peerMaxStreamsBidi: 0,
            peerMaxStreamsUni: 0
        )

        #expect(!fc.canReceive(bytes: 1))
        #expect(!fc.canSend(bytes: 1))
        #expect(!fc.canOpenStream(bidirectional: true))
        #expect(!fc.canOpenStream(bidirectional: false))
    }

    @Test("Update limit only increases")
    func updateLimitOnlyIncreases() {
        var fc = FlowController(isClient: true, peerMaxData: 1000)

        fc.updateConnectionSendLimit(500)  // Lower than current
        #expect(fc.connectionSendWindow == 1000)  // Unchanged

        fc.updateConnectionSendLimit(2000)  // Higher
        #expect(fc.connectionSendWindow == 2000)
    }

    @Test("Unidirectional stream limit")
    func unidirectionalStreamLimit() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataUni: 500
        )

        fc.initializeStream(2)  // Client-initiated uni stream

        #expect(fc.canReceiveOnStream(2, endOffset: 500))
        #expect(!fc.canReceiveOnStream(2, endOffset: 501))
    }

    // MARK: - Local/Remote Stream Limit Distinction Tests

    @Test("Initialize local bidi stream uses local limit - client")
    func initializeLocalBidiStreamClient() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiLocal: 1000,
            initialMaxStreamDataBidiRemote: 2000
        )

        fc.initializeStream(0)  // Client bidi stream = local for client

        // Should use local limit (1000), not remote (2000)
        #expect(fc.canReceiveOnStream(0, endOffset: 1000))
        #expect(!fc.canReceiveOnStream(0, endOffset: 1001))
    }

    @Test("Initialize remote bidi stream uses remote limit - client")
    func initializeRemoteBidiStreamClient() {
        var fc = FlowController(
            isClient: true,
            initialMaxStreamDataBidiLocal: 1000,
            initialMaxStreamDataBidiRemote: 2000
        )

        fc.initializeStream(1)  // Server bidi stream = remote for client

        // Should use remote limit (2000), not local (1000)
        #expect(fc.canReceiveOnStream(1, endOffset: 2000))
        #expect(!fc.canReceiveOnStream(1, endOffset: 2001))
    }

    @Test("Initialize local bidi stream uses local limit - server")
    func initializeLocalBidiStreamServer() {
        var fc = FlowController(
            isClient: false,
            initialMaxStreamDataBidiLocal: 1000,
            initialMaxStreamDataBidiRemote: 2000
        )

        fc.initializeStream(1)  // Server bidi stream = local for server

        // Should use local limit (1000), not remote (2000)
        #expect(fc.canReceiveOnStream(1, endOffset: 1000))
        #expect(!fc.canReceiveOnStream(1, endOffset: 1001))
    }

    @Test("Initialize remote bidi stream uses remote limit - server")
    func initializeRemoteBidiStreamServer() {
        var fc = FlowController(
            isClient: false,
            initialMaxStreamDataBidiLocal: 1000,
            initialMaxStreamDataBidiRemote: 2000
        )

        fc.initializeStream(0)  // Client bidi stream = remote for server

        // Should use remote limit (2000), not local (1000)
        #expect(fc.canReceiveOnStream(0, endOffset: 2000))
        #expect(!fc.canReceiveOnStream(0, endOffset: 2001))
    }
}
