/// LossDetector Unit Tests
///
/// Comprehensive tests for loss detection logic including edge cases.

import Testing
import Foundation
@testable import QUICRecovery
@testable import QUICCore

@Suite("LossDetector Tests")
struct LossDetectorTests {

    // MARK: - Basic ACK Processing Tests

    @Test("ACK single packet")
    func ackSinglePacket() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packet 0
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet)

        #expect(detector.bytesInFlight == 1200)
        #expect(detector.ackElicitingInFlight == 1)

        // ACK packet 0
        let ackFrame = AckFrame(
            largestAcknowledged: 0,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 0)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        #expect(result.ackedPackets.count == 1)
        #expect(result.ackedPackets[0].packetNumber == 0)
        #expect(result.lostPackets.isEmpty)
        #expect(detector.bytesInFlight == 0)
        #expect(detector.ackElicitingInFlight == 0)
    }

    @Test("ACK multiple consecutive packets")
    func ackMultipleConsecutivePackets() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 0-9
        for i: UInt64 in 0..<10 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        #expect(detector.bytesInFlight == 12000)

        // ACK packets 0-9
        let ackFrame = AckFrame(
            largestAcknowledged: 9,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 9)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        #expect(result.ackedPackets.count == 10)
        #expect(result.lostPackets.isEmpty)
        #expect(detector.bytesInFlight == 0)
    }

    @Test("ACK with gaps - loss detection by packet threshold")
    func ackWithGapsLossDetection() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 0-10
        for i: UInt64 in 0...10 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // ACK only packets 5-10 (packets 0-1 should be lost due to packet threshold of 3)
        let ackFrame = AckFrame(
            largestAcknowledged: 10,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 5)],  // ACK 5-10
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // Packets 5-10 acked (6 packets)
        #expect(result.ackedPackets.count == 6)

        // Packets 0-7 are candidates for loss (< largestAcked=10)
        // But only packets where largestAcked >= pn + 3 are lost
        // largestAcked=10 >= 0+3=3, so 0 is lost
        // largestAcked=10 >= 1+3=4, so 1 is lost
        // largestAcked=10 >= 2+3=5, so 2 is lost
        // largestAcked=10 >= 3+3=6, so 3 is lost
        // largestAcked=10 >= 4+3=7, so 4 is lost (still unacked)
        // Packets 5-10 were acked, so not in loss consideration
        // Remaining unacked: 0,1,2,3,4 -> all should be lost
        // Wait, 5-10 were acked. So remaining are 0-4.
        // largestAcked=10, packetThreshold=3
        // For pn=0: 10 >= 0+3=3 -> true, lost
        // For pn=1: 10 >= 1+3=4 -> true, lost
        // For pn=2: 10 >= 2+3=5 -> true, lost
        // For pn=3: 10 >= 3+3=6 -> true, lost
        // For pn=4: 10 >= 4+3=7 -> true, lost
        // All 5 packets (0-4) should be detected as lost
        #expect(result.lostPackets.count == 5)

        let lostPNs = Set(result.lostPackets.map { $0.packetNumber })
        #expect(lostPNs == Set([0, 1, 2, 3, 4]))
    }

    @Test("Multi-range ACK processing")
    func multiRangeAckProcessing() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 0-19
        for i: UInt64 in 0..<20 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 100
            )
            detector.onPacketSent(packet)
        }

        // ACK ranges: 15-19, 10-12, 5-7, 0-2
        // RFC 9000 Section 19.3.1: gap = smallest_prev - 1 - largest_current
        // Range 15-19: rangeLength=4 (5 packets: 19-4=15 to 19)
        // Range 10-12: largest=12, smallest_prev=15, gap = 15 - 1 - 12 = 2, rangeLength=2
        // Range 5-7: largest=7, smallest_prev=10, gap = 10 - 1 - 7 = 2, rangeLength=2
        // Range 0-2: largest=2, smallest_prev=5, gap = 5 - 1 - 2 = 2, rangeLength=2
        let ackFrame = AckFrame(
            largestAcknowledged: 19,
            ackDelay: 1000,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 4),   // 15-19
                AckRange(gap: 2, rangeLength: 2),   // 10-12
                AckRange(gap: 2, rangeLength: 2),   // 5-7
                AckRange(gap: 2, rangeLength: 2)    // 0-2
            ],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // Acked: 0-2 (3), 5-7 (3), 10-12 (3), 15-19 (5) = 14 packets
        #expect(result.ackedPackets.count == 14)

        let ackedPNs = Set(result.ackedPackets.map { $0.packetNumber })
        let expectedAcked: Set<UInt64> = Set([0,1,2,5,6,7,10,11,12,15,16,17,18,19])
        #expect(ackedPNs == expectedAcked)

        // Lost: 3,4,8,9,13,14 (unacked and largestAcked=19 >= pn+3)
        // pn=3: 19 >= 6 -> lost
        // pn=4: 19 >= 7 -> lost
        // pn=8: 19 >= 11 -> lost
        // pn=9: 19 >= 12 -> lost
        // pn=13: 19 >= 16 -> lost
        // pn=14: 19 >= 17 -> lost
        #expect(result.lostPackets.count == 6)

        let lostPNs = Set(result.lostPackets.map { $0.packetNumber })
        #expect(lostPNs == Set([3, 4, 8, 9, 13, 14]))
    }

    // MARK: - Edge Case Tests

    @Test("ACK for non-existent packet")
    func ackNonExistentPacket() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send only packet 5
        let packet = SentPacket(
            packetNumber: 5,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet)

        // ACK packets 0-10 (most don't exist)
        let ackFrame = AckFrame(
            largestAcknowledged: 10,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // Only packet 5 should be acked
        #expect(result.ackedPackets.count == 1)
        #expect(result.ackedPackets[0].packetNumber == 5)
        #expect(detector.bytesInFlight == 0)
    }

    @Test("Empty ACK range")
    func emptyAckRange() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packet 0
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet)

        // ACK with empty ranges (only largest acknowledged)
        let ackFrame = AckFrame(
            largestAcknowledged: 0,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 0)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        #expect(result.ackedPackets.count == 1)
    }

    @Test("Duplicate ACK handling")
    func duplicateAckHandling() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 0-4
        for i: UInt64 in 0..<5 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        let ackFrame = AckFrame(
            largestAcknowledged: 4,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 4)],
            ecnCounts: nil
        )

        // First ACK
        let result1 = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )
        #expect(result1.ackedPackets.count == 5)

        // Duplicate ACK (same packets)
        let result2 = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(20),
            rttEstimator: rttEstimator
        )
        // No packets should be acked (already removed)
        #expect(result2.ackedPackets.isEmpty)
    }

    @Test("RTT sample from largest acked ack-eliciting packet")
    func rttSampleFromLargestAcked() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let baseTime = ContinuousClock.Instant.now

        // Send packet 0 (ack-eliciting)
        let packet0 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: baseTime,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet0)

        // Send packet 1 (NOT ack-eliciting)
        let packet1 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: baseTime + .milliseconds(5),
            ackEliciting: false,
            inFlight: true,
            sentBytes: 100
        )
        detector.onPacketSent(packet1)

        // ACK both packets - RTT should come from packet 0 (ack-eliciting)
        // Wait, the largest acked is packet 1, but it's not ack-eliciting
        // So RTT sample should be nil since largest acked is not ack-eliciting
        let ackFrame = AckFrame(
            largestAcknowledged: 1,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 1)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: baseTime + .milliseconds(50),
            rttEstimator: rttEstimator
        )

        // RTT sample should be nil because largest (1) is not ack-eliciting
        #expect(result.rttSample == nil)
    }

    @Test("RTT sample when largest is ack-eliciting")
    func rttSampleWhenLargestIsAckEliciting() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let baseTime = ContinuousClock.Instant.now

        // Send packet 0 (ack-eliciting)
        let packet = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: baseTime,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet)

        let ackTime = baseTime + .milliseconds(50)
        let ackFrame = AckFrame(
            largestAcknowledged: 0,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 0)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: ackTime,
            rttEstimator: rttEstimator
        )

        // RTT sample should be ~50ms
        #expect(result.rttSample != nil)
        let rttMs = result.rttSample!.components.seconds * 1000 +
                    result.rttSample!.components.attoseconds / 1_000_000_000_000_000
        #expect(rttMs >= 49 && rttMs <= 51)
    }

    // MARK: - smallestUnacked Tests

    @Test("smallestUnacked tracking")
    func smallestUnackedTracking() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Initially nil
        #expect(detector.smallestUnacked == nil)

        // Send packet 5
        let packet5 = SentPacket(
            packetNumber: 5,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet5)
        #expect(detector.smallestUnacked == 5)

        // Send packet 3 (smaller)
        let packet3 = SentPacket(
            packetNumber: 3,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet3)
        #expect(detector.smallestUnacked == 3)

        // Send packet 7 (larger, shouldn't change smallest)
        let packet7 = SentPacket(
            packetNumber: 7,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet7)
        #expect(detector.smallestUnacked == 3)

        // ACK packet 3, smallest should update to 5
        let ackFrame = AckFrame(
            largestAcknowledged: 7,
            ackDelay: 1000,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 0),  // 7
                AckRange(gap: 2, rangeLength: 0)   // 3 (gap=2 means skip 5,6)
            ],
            ecnCounts: nil
        )

        _ = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // After ACKing 3 and 7, only 5 remains
        #expect(detector.smallestUnacked == 5)
    }

    // MARK: - Bytes in Flight Tests

    @Test("Bytes in flight tracking with non-in-flight packets")
    func bytesInFlightWithNonInFlight() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send in-flight packet
        let packet0 = SentPacket(
            packetNumber: 0,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: true,
            inFlight: true,
            sentBytes: 1200
        )
        detector.onPacketSent(packet0)

        // Send non-in-flight packet (e.g., ACK-only)
        let packet1 = SentPacket(
            packetNumber: 1,
            encryptionLevel: .application,
            timeSent: now,
            ackEliciting: false,
            inFlight: false,
            sentBytes: 50
        )
        detector.onPacketSent(packet1)

        // Only in-flight packet counts
        #expect(detector.bytesInFlight == 1200)
        #expect(detector.ackElicitingInFlight == 1)

        // ACK both
        let ackFrame = AckFrame(
            largestAcknowledged: 1,
            ackDelay: 1000,
            ackRanges: [AckRange(gap: 0, rangeLength: 1)],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        #expect(result.ackedPackets.count == 2)
        #expect(detector.bytesInFlight == 0)
        #expect(detector.ackElicitingInFlight == 0)
    }

    // MARK: - Clear Tests

    @Test("Clear resets all state")
    func clearResetsAllState() {
        let detector = LossDetector()
        let now = ContinuousClock.Instant.now

        // Send some packets
        for i: UInt64 in 0..<5 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        #expect(detector.bytesInFlight == 6000)
        #expect(detector.ackElicitingInFlight == 5)
        #expect(detector.smallestUnacked == 0)

        // Clear
        detector.clear()

        #expect(detector.bytesInFlight == 0)
        #expect(detector.ackElicitingInFlight == 0)
        #expect(detector.smallestUnacked == nil)
        #expect(detector.largestAckedPacket == nil)
    }

    // MARK: - DoS Protection Tests

    @Test("Malicious ACK with huge range does not cause CPU exhaustion", .timeLimit(.minutes(1)))
    func maliciousAckDoSProtection() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send only 10 packets
        for i: UInt64 in 0..<10 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // ATTACK: ACK frame with a massive range that would take forever to iterate
        // This simulates an attacker sending ACK with a huge range starting from
        // a large value down to 0 (which includes our packets 0-9)
        // With the old implementation, this would loop billions of times
        // With the fixed implementation, it only checks our 10 sent packets
        let maliciousAck = AckFrame(
            largestAcknowledged: 1_000_000_000,  // 1 billion
            ackDelay: 0,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 1_000_000_000)  // Huge range: 0 to 1 billion
            ],
            ecnCounts: nil
        )

        // This should complete quickly (within the 5 second time limit)
        // because we iterate over sentPackets (10 items), not the ACK range
        let clock = ContinuousClock()
        let startTime = clock.now
        let result = detector.onAckReceived(
            ackFrame: maliciousAck,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )
        let elapsed = clock.now - startTime

        // Should complete in under 1 second (actually much faster)
        #expect(elapsed < .seconds(1), "ACK processing took \(elapsed), expected < 1 second")

        // All 10 packets should be acknowledged (they're within the range)
        #expect(result.ackedPackets.count == 10)
        #expect(detector.bytesInFlight == 0)
    }

    @Test("ACK range outside sent packets does not match", .timeLimit(.minutes(1)))
    func ackRangeOutsideSentPackets() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 100-109
        for i: UInt64 in 100..<110 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // ACK a range that doesn't overlap with our sent packets
        let nonMatchingAck = AckFrame(
            largestAcknowledged: 50,
            ackDelay: 0,
            ackRanges: [AckRange(gap: 0, rangeLength: 50)],  // ACK packets 0-50
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: nonMatchingAck,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // No packets should be acknowledged
        #expect(result.ackedPackets.isEmpty)
        #expect(detector.bytesInFlight == 12000)  // All packets still in flight
    }

    @Test("Multiple ACK ranges with gaps correctly identify packets")
    func multipleAckRangesWithGaps() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()
        let now = ContinuousClock.Instant.now

        // Send packets 0-19
        for i: UInt64 in 0..<20 {
            let packet = SentPacket(
                packetNumber: i,
                encryptionLevel: .application,
                timeSent: now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // ACK with gaps (RFC 9000 Section 19.3.1):
        // Range 1: 15-19 (rangeLength=4 means 5 packets: largest - rangeLength to largest)
        // Gap: 5 (means 5 unacknowledged packets: 14, 13, 12, 11, 10)
        // Range 2: 5-9 (rangeLength=4 means 5 packets)
        let gappedAck = AckFrame(
            largestAcknowledged: 19,
            ackDelay: 0,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 4),   // 15-19
                AckRange(gap: 5, rangeLength: 4)    // 5-9
            ],
            ecnCounts: nil
        )

        let result = detector.onAckReceived(
            ackFrame: gappedAck,
            ackReceivedTime: now + .milliseconds(10),
            rttEstimator: rttEstimator
        )

        // Should ACK packets: 15,16,17,18,19 and 5,6,7,8,9 = 10 packets
        #expect(result.ackedPackets.count == 10)

        // Verify the correct packets were ACKed
        let ackedPNs = Set(result.ackedPackets.map { $0.packetNumber })
        let expectedAcked: Set<UInt64> = [5, 6, 7, 8, 9, 15, 16, 17, 18, 19]
        #expect(ackedPNs == expectedAcked)

        // RFC 9002 packet threshold loss detection:
        // Packets with largest_acked - pn > 3 are declared lost.
        // largest_acked = 19, so packets 0-15 (19 - 3 = 16) that weren't ACKed are lost.
        // That means: 0,1,2,3,4,10,11,12,13,14 = 10 packets lost
        let lostPNs = Set(result.lostPackets.map { $0.packetNumber })
        let expectedLost: Set<UInt64> = [0, 1, 2, 3, 4, 10, 11, 12, 13, 14]
        #expect(lostPNs == expectedLost, "Lost packets should be 0-4 and 10-14")

        // All packets are either ACKed or lost, so bytesInFlight = 0
        #expect(detector.bytesInFlight == 0)
    }
}
