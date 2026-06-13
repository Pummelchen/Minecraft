/// QLOG Tests
///
/// Tests for QLOG logging functionality.

import Testing
import Foundation
import Synchronization
@testable import QUICCore

// MARK: - QLOG Event Tests

@Suite("QLOG Event Tests")
struct QLOGEventTests {

    @Test("ConnectionStartedEvent encodes correctly")
    func connectionStartedEventEncoding() throws {
        let event = ConnectionStartedEvent(
            time: 1000,
            role: "client",
            srcCID: "abcd1234",
            dstCID: "5678efgh",
            version: "0x00000001"
        )

        #expect(event.category == .connectivity)
        #expect(event.name == "connection_started")
        #expect(event.time == 1000)
        #expect(event.role == "client")

        // Verify it's encodable
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"connection_started\""))
        #expect(json.contains("\"client\""))
    }

    @Test("PacketSentEvent encodes correctly")
    func packetSentEventEncoding() throws {
        let header = QLOGPacketHeader(
            packetType: "initial",
            packetNumber: 0,
            dcid: "abcd1234",
            scid: "5678efgh"
        )

        let frames = [
            QLOGFrameInfo(frameType: "crypto", length: 100),
            QLOGFrameInfo(frameType: "padding", length: nil)
        ]

        let event = PacketSentEvent(
            time: 5000,
            header: header,
            frames: frames,
            rawLength: 1200,
            isCoalesced: false
        )

        #expect(event.category == .transport)
        #expect(event.name == "packet_sent")
        #expect(event.rawLength == 1200)

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"packet_sent\""))
        #expect(json.contains("\"initial\""))
    }

    @Test("RecoveryMetricsUpdatedEvent encodes correctly")
    func recoveryMetricsUpdatedEventEncoding() throws {
        let event = RecoveryMetricsUpdatedEvent(
            time: 10000,
            minRTT: 5000,
            smoothedRTT: 10000,
            latestRTT: 8000,
            rttVariance: 2000,
            congestionWindow: 14720,
            bytesInFlight: 5000,
            packetsInFlight: 5
        )

        #expect(event.category == .recovery)
        #expect(event.name == "metrics_updated")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"metrics_updated\""))
        #expect(json.contains("14720"))
    }

    @Test("KeyUpdatedEvent encodes correctly")
    func keyUpdatedEventEncoding() throws {
        let event = KeyUpdatedEvent(
            time: 20000,
            keyType: "client_handshake",
            generation: 0
        )

        #expect(event.category == .security)
        #expect(event.name == "key_updated")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"key_updated\""))
        #expect(json.contains("\"client_handshake\""))
    }
}

// MARK: - QLOG Logger Tests

@Suite("QLOG Logger Tests")
struct QLOGLoggerTests {

    @Test("Logger relative time increases monotonically")
    func relativeTimeIncreases() async throws {
        let logger = QLOGLogger(
            connectionID: "test",
            output: .callback { _ in }
        )

        let time1 = logger.relativeTime()
        try await Task.sleep(for: .milliseconds(10))
        let time2 = logger.relativeTime()

        #expect(time2 > time1)
    }

    @Test("Logger buffers and flushes events")
    func loggerBuffering() throws {
        let receivedEvents = Mutex<[String]>([])

        let logger = QLOGLogger(
            connectionID: "test",
            output: .callback { event in
                receivedEvents.withLock { $0.append(event.name) }
            },
            flushThreshold: 3
        )

        // Log 2 events (below threshold)
        logger.log(ConnectionStartedEvent(time: 0, role: "client", srcCID: "a", dstCID: "b", version: "v1"))
        logger.log(PacketSentEvent(time: 100, header: .init(packetType: "initial", packetNumber: 0, dcid: "a"), frames: [], rawLength: 100))

        // Should not have flushed yet
        #expect(receivedEvents.withLock { $0.isEmpty })

        // Log 3rd event (triggers flush)
        logger.log(KeyUpdatedEvent(time: 200, keyType: "client_initial", generation: 0))

        // Should have flushed all 3 events
        #expect(receivedEvents.withLock { $0.count } == 3)
    }

    @Test("Logger finalize flushes remaining events")
    func loggerFinalize() throws {
        let receivedEvents = Mutex<[String]>([])

        let logger = QLOGLogger(
            connectionID: "test",
            output: .callback { event in
                receivedEvents.withLock { $0.append(event.name) }
            },
            flushThreshold: 100  // High threshold
        )

        // Log some events (below threshold)
        logger.log(ConnectionStartedEvent(time: 0, role: "client", srcCID: "a", dstCID: "b", version: "v1"))
        logger.log(PacketSentEvent(time: 100, header: .init(packetType: "initial", packetNumber: 0, dcid: "a"), frames: [], rawLength: 100))

        // Should not have flushed yet
        #expect(receivedEvents.withLock { $0.isEmpty })

        // Finalize
        logger.finalize()

        // Should have flushed
        #expect(receivedEvents.withLock { $0.count } == 2)
    }

    @Test("Logger disabled does not log")
    func loggerDisabled() throws {
        let receivedEvents = Mutex<[String]>([])

        let logger = QLOGLogger(
            connectionID: "test",
            output: .callback { event in
                receivedEvents.withLock { $0.append(event.name) }
            },
            enabled: false
        )

        logger.log(ConnectionStartedEvent(time: 0, role: "client", srcCID: "a", dstCID: "b", version: "v1"))
        logger.finalize()

        #expect(receivedEvents.withLock { $0.isEmpty })
    }

    @Test("Logger writes to file in JSON Lines format")
    func loggerFileOutput() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("test_\(UUID()).qlog")

        defer {
            try? FileManager.default.removeItem(at: logFile)
        }

        let logger = QLOGLogger(
            connectionID: "test-conn",
            output: .file(logFile),
            flushThreshold: 1  // Flush immediately
        )

        logger.log(ConnectionStartedEvent(time: 0, role: "client", srcCID: "abc", dstCID: "def", version: "v1"))
        logger.log(PacketSentEvent(time: 100, header: .init(packetType: "initial", packetNumber: 0, dcid: "abc"), frames: [], rawLength: 1200))
        logger.finalize()

        // Read file
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].contains("connection_started"))
        #expect(lines[1].contains("packet_sent"))
    }
}

// MARK: - QLOG Helper Tests

@Suite("QLOG Helper Tests")
struct QLOGHelperTests {

    @Test("Encryption level QLOG names")
    func encryptionLevelQlogNames() {
        #expect(EncryptionLevel.initial.qlogName == "initial")
        #expect(EncryptionLevel.handshake.qlogName == "handshake")
        #expect(EncryptionLevel.zeroRTT.qlogName == "0rtt")
        #expect(EncryptionLevel.application.qlogName == "1rtt")
    }

    @Test("Frame type QLOG names")
    func frameTypeQlogNames() {
        #expect(FrameType.padding.qlogName == "padding")
        #expect(FrameType.ping.qlogName == "ping")
        #expect(FrameType.ack.qlogName == "ack")
        #expect(FrameType.ackECN.qlogName == "ack")
        #expect(FrameType.crypto.qlogName == "crypto")
        #expect(FrameType.stream.qlogName == "stream")
        #expect(FrameType.connectionClose.qlogName == "connection_close")
        #expect(FrameType.connectionCloseApp.qlogName == "connection_close")
    }

    @Test("Frame QLOG info")
    func frameQlogInfo() {
        let cryptoFrame = Frame.crypto(CryptoFrame(offset: 0, data: Data(repeating: 0, count: 100)))
        let info = cryptoFrame.qlogFrameInfo

        #expect(info.frameType == "crypto")
        #expect(info.length == 100)
    }

    @Test("Connection ID hex encoding")
    func connectionIDHexEncoding() throws {
        let cid = try ConnectionID(Data([0xab, 0xcd, 0x12, 0x34]))

        #expect(cid.qlogHex == "abcd1234")
    }

    @Test("Data hex encoding")
    func dataHexEncoding() {
        let data = Data([0x00, 0xff, 0x10, 0xef])

        #expect(data.qlogHex == "00ff10ef")
    }

    @Test("QUIC version QLOG string")
    func quicVersionQlogString() {
        #expect(QUICVersion.v1.qlogString == "0x00000001")
        #expect(QUICVersion.v2.qlogString == "0x6b3343cf")
    }
}
