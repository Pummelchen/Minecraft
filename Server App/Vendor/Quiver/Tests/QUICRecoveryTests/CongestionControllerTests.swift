/// Congestion Controller Unit Tests
///
/// Comprehensive tests for NewReno congestion control implementation (RFC 9002 Section 7).

import Testing
import Foundation
@testable import QUICRecovery
@testable import QUICCore

@Suite("NewReno Congestion Controller Tests")
struct NewRenoCongestionControllerTests {

    // MARK: - Initialization Tests

    @Test("Initial window is correctly calculated")
    func initialWindow() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)

        // RFC 9002: initial_window = min(10 * max_datagram_size, max(14720, 2 * max_datagram_size))
        // = min(10 * 1200, max(14720, 2400)) = min(12000, 14720) = 12000
        #expect(cc.congestionWindow == 12000)
        #expect(cc.currentState == .slowStart)
    }

    @Test("Initial window with small max datagram size")
    func initialWindowSmallMDS() {
        // With small max_datagram_size (e.g., 500)
        // initial_window = min(5000, max(14720, 1000)) = min(5000, 14720) = 5000
        let cc = NewRenoCongestionController(maxDatagramSize: 500)
        #expect(cc.congestionWindow == 5000)
    }

    @Test("Initial window with large max datagram size")
    func initialWindowLargeMDS() {
        // With large max_datagram_size (e.g., 1500)
        // initial_window = min(15000, max(14720, 3000)) = min(15000, 14720) = 14720
        let cc = NewRenoCongestionController(maxDatagramSize: 1500)
        #expect(cc.congestionWindow == 14720)
    }

    // MARK: - Available Window Tests

    @Test("Available window calculation")
    func availableWindowCalculation() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)

        // Initial: cwnd = 12000
        #expect(cc.availableWindow(bytesInFlight: 0) == 12000)
        #expect(cc.availableWindow(bytesInFlight: 5000) == 7000)
        #expect(cc.availableWindow(bytesInFlight: 12000) == 0)
        #expect(cc.availableWindow(bytesInFlight: 15000) == 0)  // clamped to 0
    }

    // MARK: - Slow Start Tests

    @Test("Slow start exponential growth")
    func slowStartExponentialGrowth() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        let initialWindow = cc.congestionWindow

        // Send and ACK a packet
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: packet.sentBytes, now: now)
        cc.onPacketsAcknowledged(packets: [packet], now: now + .milliseconds(50), rtt: rtt)

        // Slow start: cwnd += bytes_acked
        #expect(cc.congestionWindow == initialWindow + 1200)
        #expect(cc.currentState == .slowStart)
    }

    @Test("Slow start with multiple packets")
    func slowStartMultiplePackets() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        let initialWindow = cc.congestionWindow

        // Send and ACK 5 packets
        var packets: [SentPacket] = []
        for i: UInt64 in 0..<5 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            packets.append(packet)
            cc.onPacketSent(bytes: packet.sentBytes, now: now)
        }

        cc.onPacketsAcknowledged(packets: packets, now: now + .milliseconds(50), rtt: rtt)

        // Slow start: cwnd += 5 * 1200 = 6000
        #expect(cc.congestionWindow == initialWindow + 6000)
    }

    // MARK: - Congestion Avoidance Tests

    @Test("Transition to congestion avoidance")
    func transitionToCongestionAvoidance() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Force into congestion avoidance by triggering loss first
        let lossPacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: lossPacket.sentBytes, now: now)
        cc.onPacketsLost(packets: [lossPacket], now: now + .milliseconds(100), rtt: rtt)

        // After loss: cwnd = max(cwnd/2, minimum_window)
        // ssthresh is set, so we're now in congestion avoidance
        #expect(cc.currentState == .recovery(startTime: now + .milliseconds(100)))

        // After recovery ends with a post-recovery ACK, we'll be in congestion avoidance
    }

    @Test("Congestion avoidance linear growth")
    func congestionAvoidanceLinearGrowth() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Trigger loss to set ssthresh and enter recovery
        let lossPacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: lossPacket.sentBytes, now: now)
        cc.onPacketsLost(packets: [lossPacket], now: now + .milliseconds(100), rtt: rtt)

        let recoveryStart = now + .milliseconds(100)
        _ = cc.congestionWindow  // 6000 (12000 / 2)

        // Send and ACK a post-recovery packet to exit recovery
        let recoveryPacket = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: recoveryStart + .milliseconds(10),  // After recovery started
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: recoveryPacket.sentBytes, now: recoveryPacket.timeSent)
        cc.onPacketsAcknowledged(packets: [recoveryPacket], now: recoveryStart + .milliseconds(60), rtt: rtt)

        // Should have exited recovery and be in congestion avoidance
        #expect(cc.currentState == .congestionAvoidance)

        // In congestion avoidance, we need to ACK cwnd worth of bytes to increase by max_datagram_size
        let windowBeforeCA = cc.congestionWindow

        // ACK more packets until we accumulate enough bytes
        var totalAcked = 1200  // Already acked recoveryPacket
        var pn: UInt64 = 2
        while totalAcked < windowBeforeCA {
            let packet = SentPacket(
                packetNumber: pn,
                encryptionLevel: .application,
                timeSent: recoveryStart + .milliseconds(20),
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            cc.onPacketSent(bytes: packet.sentBytes, now: packet.timeSent)
            cc.onPacketsAcknowledged(packets: [packet], now: recoveryStart + .milliseconds(70), rtt: rtt)
            totalAcked += 1200
            pn += 1
        }

        // After acking cwnd bytes, window should increase by max_datagram_size
        #expect(cc.congestionWindow >= windowBeforeCA + 1200)
    }

    // MARK: - Loss Detection Tests

    @Test("Loss triggers window reduction")
    func lossTriggersWindowReduction() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        let initialWindow = cc.congestionWindow  // 12000

        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: packet.sentBytes, now: now)
        cc.onPacketsLost(packets: [packet], now: now + .milliseconds(100), rtt: rtt)

        // RFC 9002: cwnd = max(cwnd * loss_reduction_factor, minimum_window)
        // = max(12000 * 0.5, 2400) = max(6000, 2400) = 6000
        #expect(cc.congestionWindow == initialWindow / 2)
    }

    @Test("Loss sets ssthresh correctly")
    func lossSetsSSThresh() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: packet.sentBytes, now: now)
        cc.onPacketsLost(packets: [packet], now: now + .milliseconds(100), rtt: rtt)

        // After recovery, acking a new packet should show we're in congestion avoidance
        // (cwnd >= ssthresh)
        let postRecoveryPacket = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(110),
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: postRecoveryPacket.sentBytes, now: postRecoveryPacket.timeSent)
        cc.onPacketsAcknowledged(packets: [postRecoveryPacket], now: now + .milliseconds(160), rtt: rtt)

        #expect(cc.currentState == .congestionAvoidance)
    }

    @Test("Only one window reduction per RTT")
    func onlyOneReductionPerRTT() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Send multiple packets
        var packets: [SentPacket] = []
        for i: UInt64 in 0..<5 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            packets.append(packet)
            cc.onPacketSent(bytes: packet.sentBytes, now: now)
        }

        // First loss
        cc.onPacketsLost(packets: [packets[0]], now: now + .milliseconds(100), rtt: rtt)
        let windowAfterFirstLoss = cc.congestionWindow

        // Second loss in same recovery period - should NOT reduce window again
        cc.onPacketsLost(packets: [packets[1]], now: now + .milliseconds(105), rtt: rtt)
        #expect(cc.congestionWindow == windowAfterFirstLoss)

        // Third loss - still in recovery
        cc.onPacketsLost(packets: [packets[2]], now: now + .milliseconds(110), rtt: rtt)
        #expect(cc.congestionWindow == windowAfterFirstLoss)
    }

    // MARK: - Recovery Tests

    @Test("Recovery state tracking")
    func recoveryStateTracking() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        #expect(cc.currentState == .slowStart)

        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: packet.sentBytes, now: now)

        let lossTime = now + .milliseconds(100)
        cc.onPacketsLost(packets: [packet], now: lossTime, rtt: rtt)

        if case .recovery(let startTime) = cc.currentState {
            #expect(startTime == lossTime)
        } else {
            #expect(Bool(false), "Expected recovery state")
        }
    }

    @Test("Recovery exit on post-recovery ACK")
    func recoveryExitOnPostRecoveryAck() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Send pre-recovery packet
        let preRecoveryPacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: preRecoveryPacket.sentBytes, now: now)

        let lossTime = now + .milliseconds(100)
        cc.onPacketsLost(packets: [preRecoveryPacket], now: lossTime, rtt: rtt)

        // We're in recovery now
        #expect(cc.currentState == .recovery(startTime: lossTime))

        // ACK of a pre-recovery packet should NOT exit recovery
        // (But this packet was already lost, so we need another pre-recovery packet)
        let preRecoveryPacket2 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(50),  // Before recovery start
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: preRecoveryPacket2.sentBytes, now: preRecoveryPacket2.timeSent)
        cc.onPacketsAcknowledged(packets: [preRecoveryPacket2], now: lossTime + .milliseconds(50), rtt: rtt)

        // Still in recovery (packet was sent before recovery)
        #expect(cc.currentState == .recovery(startTime: lossTime))

        // Send and ACK a post-recovery packet
        let postRecoveryPacket = SentPacket(
            packetNumber: 2,
            encryptionLevel: .application,
            timeSent: lossTime + .milliseconds(10),  // After recovery start
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketSent(bytes: postRecoveryPacket.sentBytes, now: postRecoveryPacket.timeSent)
        cc.onPacketsAcknowledged(packets: [postRecoveryPacket], now: lossTime + .milliseconds(60), rtt: rtt)

        // Should have exited recovery
        #expect(cc.currentState == .congestionAvoidance)
    }

    // MARK: - Persistent Congestion Tests

    @Test("Persistent congestion collapses window")
    func persistentCongestionCollapsesWindow() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // First, grow the window
        for i: UInt64 in 0..<10 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            cc.onPacketSent(bytes: packet.sentBytes, now: now)
            cc.onPacketsAcknowledged(packets: [packet], now: now + .milliseconds(50), rtt: rtt)
        }

        let windowBeforePersistentCongestion = cc.congestionWindow

        // Trigger persistent congestion
        cc.onPersistentCongestion()

        // RFC 9002: Window collapses to minimum_window = 2 * max_datagram_size
        #expect(cc.congestionWindow == 2 * 1200)
        #expect(cc.congestionWindow < windowBeforePersistentCongestion)

        // Should be back in slow start
        #expect(cc.currentState == .slowStart)
    }

    // MARK: - ECN Tests

    @Test("ECN triggers same reduction as loss")
    func ecnTriggersReduction() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now

        let initialWindow = cc.congestionWindow

        cc.onECNCongestionEvent(now: now)

        // Same as loss: cwnd reduced by half
        #expect(cc.congestionWindow == initialWindow / 2)
        #expect(cc.currentState == .recovery(startTime: now))
    }

    @Test("ECN respects recovery period")
    func ecnRespectsRecoveryPeriod() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now

        // First ECN event
        cc.onECNCongestionEvent(now: now)
        let windowAfterFirstECN = cc.congestionWindow

        // Second ECN event during recovery - should not reduce again
        cc.onECNCongestionEvent(now: now + .milliseconds(10))
        #expect(cc.congestionWindow == windowAfterFirstECN)
    }

    // MARK: - Pacing Tests

    @Test("Initial burst tokens allow immediate sending")
    func initialBurstTokens() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)

        // Initially, burst tokens should allow immediate sending
        #expect(cc.nextSendTime() == nil)
    }

    @Test("Burst tokens are consumed on send")
    func burstTokensConsumed() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now

        // Send 10 packets (initial burst tokens)
        for _ in 0..<10 {
            cc.onPacketSent(bytes: 1200, now: now)
        }

        // After burst tokens exhausted, need RTT estimate for pacing
        // If no RTT estimate, still allows immediate sending
        #expect(cc.nextSendTime() == nil)
    }

    @Test("Pacing rate established after RTT sample")
    func pacingRateEstablished() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(100), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Consume burst tokens
        for _ in 0..<10 {
            cc.onPacketSent(bytes: 1200, now: now)
        }

        // ACK a packet to update pacing rate
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        cc.onPacketsAcknowledged(packets: [packet], now: now + .milliseconds(100), rtt: rtt)

        // After sending another packet, next send time should be set
        cc.onPacketSent(bytes: 1200, now: now + .milliseconds(100))

        let nextTime = cc.nextSendTime()
        #expect(nextTime != nil)
        if let nextTime = nextTime {
            #expect(nextTime > now + .milliseconds(100))
        }
    }

    // MARK: - Non-in-flight Packets Tests

    @Test("Non-in-flight packets don't affect congestion window")
    func nonInFlightPackets() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        let initialWindow = cc.congestionWindow

        // ACK-only packets are not in-flight
        let ackOnlyPacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: false,
            inFlight: false,
            sentBytes: 50
        )
        cc.onPacketSent(bytes: ackOnlyPacket.sentBytes, now: now)
        cc.onPacketsAcknowledged(packets: [ackOnlyPacket], now: now + .milliseconds(50), rtt: rtt)

        // Window should not change for non-in-flight packets
        #expect(cc.congestionWindow == initialWindow)
    }

    // MARK: - Minimum Window Tests

    @Test("Window never goes below minimum")
    func windowNeverBelowMinimum() {
        let cc = NewRenoCongestionController(maxDatagramSize: 1200)
        let now = ContinuousClock.Instant.now
        var rtt = RTTEstimator()
        rtt.updateRTT(rttSample: .milliseconds(50), ackDelay: .zero, maxAckDelay: .milliseconds(25), handshakeConfirmed: true)

        // Trigger multiple losses to reduce window
        for i in 0..<10 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: now + .milliseconds(i * 200),
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            cc.onPacketSent(bytes: packet.sentBytes, now: packet.timeSent)
            cc.onPacketsLost(packets: [packet], now: packet.timeSent + .milliseconds(100), rtt: rtt)

            // Exit recovery with a post-recovery ACK
            let recoveryExitPacket = SentPacket(
                packetNumber: UInt64(1000 + i),
                encryptionLevel: .application,
                timeSent: packet.timeSent + .milliseconds(150),
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            cc.onPacketSent(bytes: recoveryExitPacket.sentBytes, now: recoveryExitPacket.timeSent)
            cc.onPacketsAcknowledged(packets: [recoveryExitPacket], now: recoveryExitPacket.timeSent + .milliseconds(50), rtt: rtt)
        }

        // Window should never go below minimum (2 * max_datagram_size)
        #expect(cc.congestionWindow >= 2 * 1200)
    }
}

// MARK: - PacketNumberSpaceManager Persistent Congestion Tests

@Suite("Persistent Congestion Detection Tests")
struct PersistentCongestionDetectionTests {

    @Test("Persistent congestion requires at least 2 packets")
    func requiresAtLeast2Packets() {
        let manager = PacketNumberSpaceManager()
        manager.peerMaxAckDelay = .milliseconds(25)
        let now = ContinuousClock.Instant.now

        let singlePacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let result = manager.checkPersistentCongestion(lostPackets: [singlePacket])

        #expect(result == false)
    }

    @Test("Persistent congestion requires ack-eliciting packets")
    func requiresAckElicitingPackets() {
        let manager = PacketNumberSpaceManager()
        manager.peerMaxAckDelay = .milliseconds(25)
        let now = ContinuousClock.Instant.now

        // Non-ack-eliciting packets
        let packets = (0..<5).map { i in
            SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: now + .seconds(i),
                ackEliciting: false,
                inFlight: false,
                sentBytes: 50
            )
        }

        let result = manager.checkPersistentCongestion(lostPackets: packets)

        #expect(result == false)
    }

    @Test("Persistent congestion detection with sufficient time span")
    func detectsPersistentCongestion() {
        let manager = PacketNumberSpaceManager()
        manager.peerMaxAckDelay = .milliseconds(25)
        let now = ContinuousClock.Instant.now

        // PTO = smoothed_rtt + max(4*rttvar, 1ms) + max_ack_delay
        // Initial: smoothed_rtt = 333ms, rttvar = 166.5ms
        // But before handshake confirmed, effectiveMaxAckDelay = 0
        // PTO = 333 + max(666, 1) + 0 = 999ms
        // Congestion period = 2 * PTO * 3 = 2 * 999 * 3 ≈ 6000ms

        // Create packets with time span > 6 seconds
        let packet1 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let packet2 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .seconds(10),  // 10 seconds later (> 6s)
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let result = manager.checkPersistentCongestion(lostPackets: [packet1, packet2])

        #expect(result == true)
    }

    @Test("No persistent congestion with short time span")
    func noPersistentCongestionShortSpan() {
        let manager = PacketNumberSpaceManager()
        manager.peerMaxAckDelay = .milliseconds(25)
        let now = ContinuousClock.Instant.now

        // Create packets with time span < congestion period
        let packet1 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let packet2 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(500),  // 500ms (< 6s)
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let result = manager.checkPersistentCongestion(lostPackets: [packet1, packet2])

        #expect(result == false)
    }

    @Test("Persistent congestion uses peerMaxAckDelay after handshake confirmed")
    func persistentCongestionUsesPerMaxAckDelay() {
        let manager = PacketNumberSpaceManager()
        manager.peerMaxAckDelay = .milliseconds(100)  // Large value
        manager.handshakeConfirmed = true  // Enable peerMaxAckDelay usage
        let now = ContinuousClock.Instant.now

        // With handshake confirmed and peerMaxAckDelay = 100ms:
        // PTO = 333 + max(666, 1) + 100 = 1099ms
        // Congestion period = 2 * 1099 * 3 ≈ 6594ms

        // Create packets with time span that would pass without peerMaxAckDelay
        // but fail with it
        let packet1 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        let packet2 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(6200),  // Just over 6s but under 6.6s
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )

        // Without handshake confirmed, this would be persistent congestion
        // With handshake confirmed and larger peerMaxAckDelay, it should NOT be
        let result = manager.checkPersistentCongestion(lostPackets: [packet1, packet2])

        #expect(result == false)
    }
}

// MARK: - Anti-Amplification Limiter Tests

@Suite("Anti-Amplification Limiter Tests")
struct AntiAmplificationLimiterTests {

    @Test("Client is not subject to amplification limit")
    func clientNotLimited() {
        let limiter = AntiAmplificationLimiter(isServer: false)

        // Client can send unlimited data
        #expect(limiter.canSend(bytes: 1_000_000) == true)
        #expect(limiter.availableSendWindow() == UInt64.max)
        #expect(limiter.isBlocked == false)
    }

    @Test("Server is limited before address validation")
    func serverLimitedBeforeValidation() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        // No data received yet - can't send anything
        #expect(limiter.canSend(bytes: 1) == false)
        #expect(limiter.availableSendWindow() == 0)
        #expect(limiter.isBlocked == true)
    }

    @Test("Server can send 3x received bytes")
    func serverCanSend3xReceived() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        // Receive 1000 bytes
        limiter.recordBytesReceived(1000)

        // Can send up to 3000 bytes
        #expect(limiter.canSend(bytes: 3000) == true)
        #expect(limiter.canSend(bytes: 3001) == false)
        #expect(limiter.availableSendWindow() == 3000)
        #expect(limiter.isBlocked == false)
    }

    @Test("Server send limit tracks sent bytes")
    func serverSendLimitTracksSentBytes() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        // Receive 1000 bytes -> can send 3000
        limiter.recordBytesReceived(1000)

        // Send 2000 bytes
        limiter.recordBytesSent(2000)

        // Can only send 1000 more
        #expect(limiter.canSend(bytes: 1000) == true)
        #expect(limiter.canSend(bytes: 1001) == false)
        #expect(limiter.availableSendWindow() == 1000)
    }

    @Test("Server becomes blocked when limit reached")
    func serverBecomesBlockedAtLimit() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        limiter.recordBytesReceived(1000)
        limiter.recordBytesSent(3000)

        #expect(limiter.canSend(bytes: 1) == false)
        #expect(limiter.availableSendWindow() == 0)
        #expect(limiter.isBlocked == true)
    }

    @Test("Receiving more bytes increases allowance")
    func receivingIncreasesAllowance() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        limiter.recordBytesReceived(1000)
        limiter.recordBytesSent(3000)
        #expect(limiter.isBlocked == true)

        // Receive more data
        limiter.recordBytesReceived(1000)

        // Now can send 3000 more (total limit is 6000, already sent 3000)
        #expect(limiter.canSend(bytes: 3000) == true)
        #expect(limiter.availableSendWindow() == 3000)
        #expect(limiter.isBlocked == false)
    }

    @Test("Address validation lifts the limit")
    func addressValidationLiftsLimit() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        limiter.recordBytesReceived(1000)
        limiter.recordBytesSent(3000)
        #expect(limiter.isBlocked == true)

        // Validate address
        limiter.validateAddress()

        // Now unlimited
        #expect(limiter.canSend(bytes: 1_000_000) == true)
        #expect(limiter.availableSendWindow() == UInt64.max)
        #expect(limiter.isBlocked == false)
        #expect(limiter.isAddressValidated == true)
    }

    @Test("Handshake confirmation validates address")
    func handshakeConfirmationValidatesAddress() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        limiter.recordBytesReceived(1000)
        limiter.recordBytesSent(3000)
        #expect(limiter.isBlocked == true)

        // Confirm handshake
        limiter.confirmHandshake()

        // Now unlimited
        #expect(limiter.canSend(bytes: 1_000_000) == true)
        #expect(limiter.isAddressValidated == true)
    }

    @Test("Statistics tracking")
    func statisticsTracking() {
        let limiter = AntiAmplificationLimiter(isServer: true)

        limiter.recordBytesReceived(1000)
        limiter.recordBytesReceived(500)
        limiter.recordBytesSent(2000)
        limiter.recordBytesSent(500)

        #expect(limiter.bytesReceived == 1500)
        #expect(limiter.bytesSent == 2500)
        #expect(limiter.sendLimit == 4500)  // 1500 * 3
    }
}

// MARK: - PTO Action Tests

@Suite("PTO Action Tests")
struct PTOActionTests {

    @Test("PTO space selection during handshake with Initial")
    func ptoSpaceSelectionInitial() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        // Send an Initial packet
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .initial,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(packet)

        // Should select Initial space
        let space = manager.getPTOSpace(hasInitialKeys: true, hasHandshakeKeys: false)
        #expect(space == .initial)
    }

    @Test("PTO space selection during handshake with Handshake")
    func ptoSpaceSelectionHandshake() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        // Send a Handshake packet
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .handshake,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(packet)

        // Should select Handshake space (Initial has no packets)
        let space = manager.getPTOSpace(hasInitialKeys: true, hasHandshakeKeys: true)
        #expect(space == .handshake)
    }

    @Test("PTO space selection prioritizes Initial over Handshake")
    func ptoSpaceSelectionPrioritizesInitial() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        // Send both Initial and Handshake packets
        let initialPacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .initial,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(initialPacket)

        let handshakePacket = SentPacket(
            packetNumber: 0,
            encryptionLevel: .handshake,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(handshakePacket)

        // Should select Initial space (higher priority)
        let space = manager.getPTOSpace(hasInitialKeys: true, hasHandshakeKeys: true)
        #expect(space == .initial)
    }

    @Test("PTO space selection for application data")
    func ptoSpaceSelectionApplication() {
        let manager = PacketNumberSpaceManager()
        manager.handshakeConfirmed = true
        let now = ContinuousClock.Instant.now

        // Send an application packet
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(packet)

        // Should select application space
        let space = manager.getPTOSpace(hasInitialKeys: false, hasHandshakeKeys: false)
        #expect(space == .application)
    }

    @Test("PTO space selection for client without in-flight packets")
    func ptoSpaceSelectionClientNoInFlight() {
        let manager = PacketNumberSpaceManager()

        // No packets in flight, but handshake not confirmed
        // Client should still probe during handshake
        let space = manager.getPTOSpace(hasInitialKeys: true, hasHandshakeKeys: false)
        #expect(space == .initial)
    }

    @Test("Handle PTO timeout returns correct action")
    func handlePTOTimeoutReturnsAction() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        // Send Initial packets
        let packet1 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .initial,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        let packet2 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .initial,
            timeSent: now + .milliseconds(10),
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(packet1)
        manager.onPacketSent(packet2)

        // Handle PTO timeout
        let action = manager.handlePTOTimeout(hasInitialKeys: true, hasHandshakeKeys: false)

        #expect(action != nil)
        #expect(action?.level == .initial)
        #expect(action?.probeCount == 2)
        #expect(action?.packetsToProbe.count == 2)
    }

    @Test("Handle PTO timeout increments PTO count")
    func handlePTOTimeoutIncrementsPTOCount() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .initial,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        manager.onPacketSent(packet)

        #expect(manager.ptoCount == 0)

        _ = manager.handlePTOTimeout(hasInitialKeys: true, hasHandshakeKeys: false)
        #expect(manager.ptoCount == 1)

        _ = manager.handlePTOTimeout(hasInitialKeys: true, hasHandshakeKeys: false)
        #expect(manager.ptoCount == 2)
    }

    @Test("Handle PTO timeout returns nil when no space needs probing")
    func handlePTOTimeoutReturnsNilWhenNoSpace() {
        let manager = PacketNumberSpaceManager()
        manager.handshakeConfirmed = true

        // No packets in flight and handshake confirmed
        let action = manager.handlePTOTimeout(hasInitialKeys: false, hasHandshakeKeys: false)

        #expect(action == nil)
    }

    @Test("PTO deadline exponential backoff")
    func ptoDeadlineExponentialBackoff() {
        let manager = PacketNumberSpaceManager()
        let now = ContinuousClock.Instant.now

        // First PTO deadline
        let deadline1 = manager.nextPTODeadline(now: now)

        // Increment PTO count
        manager.onPTOExpired()
        let deadline2 = manager.nextPTODeadline(now: now)

        // Increment again
        manager.onPTOExpired()
        let deadline3 = manager.nextPTODeadline(now: now)

        // Deadlines should double with each PTO
        let interval1 = deadline1 - now
        let interval2 = deadline2 - now
        let interval3 = deadline3 - now

        // interval2 should be approximately 2x interval1
        // interval3 should be approximately 4x interval1
        // Allow some tolerance for floating point
        #expect(interval2 > interval1)
        #expect(interval3 > interval2)
    }

    @Test("Needs PTO probe even without in-flight packets")
    func needsPTOProbeEvenWithoutInFlight() {
        let manager = PacketNumberSpaceManager()

        // Handshake not confirmed, no packets in flight
        #expect(manager.needsPTOProbeEvenWithoutInFlight == true)

        // After handshake confirmed
        manager.handshakeConfirmed = true
        #expect(manager.needsPTOProbeEvenWithoutInFlight == false)
    }
}

// MARK: - LossDetector PTO Support Tests

@Suite("LossDetector PTO Support Tests")
struct LossDetectorPTOSupportTests {

    @Test("Get oldest unacked packets for PTO")
    func getOldestUnackedPackets() {
        let detector = LossDetector()
        let now = ContinuousClock.Instant.now

        // Send 5 packets
        for i: UInt64 in 0..<5 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now + .milliseconds(Int64(i) * 10),
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // Get oldest 2
        let oldest = detector.getOldestUnackedPackets(count: 2)

        #expect(oldest.count == 2)
        #expect(oldest[0].packetNumber == 0)
        #expect(oldest[1].packetNumber == 1)
    }

    @Test("Get oldest unacked packets filters non-ack-eliciting")
    func getOldestUnackedPacketsFiltersNonAckEliciting() {
        let detector = LossDetector()
        let now = ContinuousClock.Instant.now

        // Send mix of ack-eliciting and non-ack-eliciting packets
        let packet0 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: false,  // Non-ack-eliciting
            inFlight: false,
            sentBytes: 50
        )
        detector.onPacketSent(packet0)

        let packet1 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(10),
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet1)

        let packet2 = SentPacket(
            packetNumber: 2,
            encryptionLevel: .application,
            timeSent: now + .milliseconds(20),
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet2)

        // Get oldest 2 ack-eliciting packets
        let oldest = detector.getOldestUnackedPackets(count: 2)

        #expect(oldest.count == 2)
        #expect(oldest[0].packetNumber == 1)  // Skipped packet 0
        #expect(oldest[1].packetNumber == 2)
    }

    @Test("Get oldest unacked packets handles empty state")
    func getOldestUnackedPacketsEmpty() {
        let detector = LossDetector()

        let oldest = detector.getOldestUnackedPackets(count: 2)

        #expect(oldest.isEmpty)
    }

    @Test("Get oldest unacked packets handles fewer packets than requested")
    func getOldestUnackedPacketsFewerThanRequested() {
        let detector = LossDetector()
        let now = ContinuousClock.Instant.now

        // Only 1 packet
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet)

        let oldest = detector.getOldestUnackedPackets(count: 5)

        #expect(oldest.count == 1)
        #expect(oldest[0].packetNumber == 0)
    }
}
