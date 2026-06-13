/// AckManager Unit Tests
///
/// Comprehensive tests for ACK management and range tracking.

import Testing
import Foundation
@testable import QUICRecovery
@testable import QUICCore

@Suite("AckManager Tests")
struct AckManagerTests {

    // MARK: - Basic Packet Recording Tests

    @Test("Record single packet")
    func recordSinglePacket() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(
            packetNumber: 0,
            isAckEliciting: true,
            receiveTime: now
        )

        #expect(manager.largestReceived == 0)
        #expect(manager.receivedPacketCount == 1)
        #expect(manager.rangeCount == 1)
    }

    @Test("Record sequential packets - merges into single range")
    func recordSequentialPackets() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        for i: UInt64 in 0..<100 {
            manager.recordReceivedPacket(
                packetNumber: i,
                isAckEliciting: true,
                receiveTime: now
            )
        }

        #expect(manager.largestReceived == 99)
        #expect(manager.receivedPacketCount == 100)
        // Sequential packets should merge into 1 range
        #expect(manager.rangeCount == 1)
    }

    @Test("Record packets with gaps - creates multiple ranges")
    func recordPacketsWithGaps() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Record 0, 2, 4, 6, 8 (gaps between each)
        for i in stride(from: 0, to: 10, by: 2) {
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: true,
                receiveTime: now
            )
        }

        #expect(manager.largestReceived == 8)
        #expect(manager.receivedPacketCount == 5)
        // Each packet is its own range (not adjacent)
        #expect(manager.rangeCount == 5)
    }

    @Test("Record out of order packets - ranges merge correctly")
    func recordOutOfOrderPackets() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Record 0, 2, then 1 (fills the gap)
        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 2, isAckEliciting: true, receiveTime: now)

        #expect(manager.rangeCount == 2)

        // Fill the gap
        manager.recordReceivedPacket(packetNumber: 1, isAckEliciting: true, receiveTime: now)

        // Should merge into single range 0-2
        #expect(manager.rangeCount == 1)
        #expect(manager.receivedPacketCount == 3)
    }

    @Test("Record duplicate packet - no double counting")
    func recordDuplicatePacket() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(packetNumber: 5, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 5, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 5, isAckEliciting: true, receiveTime: now)

        #expect(manager.receivedPacketCount == 1)
        #expect(manager.rangeCount == 1)
    }

    // MARK: - Range Merging Tests

    @Test("Extend range at end")
    func extendRangeAtEnd() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 1, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 2, isAckEliciting: true, receiveTime: now)

        #expect(manager.rangeCount == 1)
        #expect(manager.receivedPacketCount == 3)
    }

    @Test("Extend range at start")
    func extendRangeAtStart() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Record in reverse order
        manager.recordReceivedPacket(packetNumber: 5, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 4, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 3, isAckEliciting: true, receiveTime: now)

        #expect(manager.rangeCount == 1)
        #expect(manager.receivedPacketCount == 3)
    }

    @Test("Merge three ranges into one")
    func mergeThreeRangesIntoOne() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Create two separate ranges: [0-2] and [4-6]
        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 1, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 2, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 4, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 5, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 6, isAckEliciting: true, receiveTime: now)

        #expect(manager.rangeCount == 2)

        // Fill the gap with packet 3 - should merge into [0-6]
        manager.recordReceivedPacket(packetNumber: 3, isAckEliciting: true, receiveTime: now)

        #expect(manager.rangeCount == 1)
        #expect(manager.receivedPacketCount == 7)
    }

    // MARK: - ACK Frame Generation Tests

    @Test("Generate ACK frame for single packet")
    func generateAckFrameSinglePacket() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)

        let ackFrame = manager.generateAckFrame(now: now + .milliseconds(10), ackDelayExponent: 3)

        #expect(ackFrame != nil)
        #expect(ackFrame!.largestAcknowledged == 0)
        #expect(ackFrame!.ackRanges.count == 1)
        #expect(ackFrame!.ackRanges[0].rangeLength == 0)  // Single packet
    }

    @Test("Generate ACK frame for consecutive packets")
    func generateAckFrameConsecutivePackets() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        for i: UInt64 in 0..<10 {
            manager.recordReceivedPacket(packetNumber: i, isAckEliciting: true, receiveTime: now)
        }

        let ackFrame = manager.generateAckFrame(now: now + .milliseconds(10), ackDelayExponent: 3)

        #expect(ackFrame != nil)
        #expect(ackFrame!.largestAcknowledged == 9)
        #expect(ackFrame!.ackRanges.count == 1)
        #expect(ackFrame!.ackRanges[0].rangeLength == 9)  // 10 packets: 0-9
    }

    @Test("Generate ACK frame with gaps")
    func generateAckFrameWithGaps() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Record 0-2 and 5-7 (gap at 3,4)
        for i: UInt64 in 0...2 {
            manager.recordReceivedPacket(packetNumber: i, isAckEliciting: true, receiveTime: now)
        }
        for i: UInt64 in 5...7 {
            manager.recordReceivedPacket(packetNumber: i, isAckEliciting: true, receiveTime: now)
        }

        let ackFrame = manager.generateAckFrame(now: now + .milliseconds(10), ackDelayExponent: 3)

        #expect(ackFrame != nil)
        #expect(ackFrame!.largestAcknowledged == 7)
        #expect(ackFrame!.ackRanges.count == 2)

        // First range: 5-7 (rangeLength = 2)
        #expect(ackFrame!.ackRanges[0].rangeLength == 2)

        // Second range: 0-2 with gap
        // Gap = previousRangeStart - currentRange.end - 2 = 5 - 2 - 2 = 1
        #expect(ackFrame!.ackRanges[1].gap == 1)
        #expect(ackFrame!.ackRanges[1].rangeLength == 2)
    }

    @Test("ACK frame generation resets counters")
    func ackFrameGenerationResetsCounters() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)

        #expect(manager.shouldSendAckImmediately())

        // Generate ACK
        _ = manager.generateAckFrame(now: now + .milliseconds(10), ackDelayExponent: 3)

        // Counters should be reset
        #expect(!manager.shouldSendAckImmediately())
    }

    // MARK: - ACK Timing Tests

    @Test("First ack-eliciting packet triggers immediate ACK")
    func firstAckElicitingTriggersImmediateAck() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Not ack-eliciting - no immediate ACK needed
        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: false, receiveTime: now)
        #expect(!manager.shouldSendAckImmediately())

        // First ack-eliciting - immediate ACK
        manager.recordReceivedPacket(packetNumber: 1, isAckEliciting: true, receiveTime: now)
        #expect(manager.shouldSendAckImmediately())
    }

    @Test("Two ack-eliciting packets trigger immediate ACK")
    func twoAckElicitingTriggersImmediateAck() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        manager.recordReceivedPacket(packetNumber: 0, isAckEliciting: true, receiveTime: now)

        // Generate ACK to reset
        _ = manager.generateAckFrame(now: now, ackDelayExponent: 3)

        #expect(!manager.shouldSendAckImmediately())

        // First ack-eliciting after reset
        manager.recordReceivedPacket(packetNumber: 1, isAckEliciting: true, receiveTime: now)
        #expect(manager.shouldSendAckImmediately())

        // Reset again
        _ = manager.generateAckFrame(now: now, ackDelayExponent: 3)

        // Now two ack-eliciting in sequence should trigger
        manager.recordReceivedPacket(packetNumber: 2, isAckEliciting: true, receiveTime: now)
        _ = manager.generateAckFrame(now: now, ackDelayExponent: 3)

        manager.recordReceivedPacket(packetNumber: 3, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: 4, isAckEliciting: true, receiveTime: now)

        #expect(manager.shouldSendAckImmediately())
    }

    // MARK: - Clear Tests

    @Test("Clear resets all state")
    func clearResetsAllState() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        for i: UInt64 in 0..<10 {
            manager.recordReceivedPacket(packetNumber: i, isAckEliciting: true, receiveTime: now)
        }

        #expect(manager.largestReceived == 9)
        #expect(manager.receivedPacketCount == 10)
        #expect(manager.rangeCount == 1)

        manager.clear()

        #expect(manager.largestReceived == nil)
        #expect(manager.receivedPacketCount == 0)
        #expect(manager.rangeCount == 0)
    }

    // MARK: - Edge Cases

    @Test("Large packet numbers")
    func largePacketNumbers() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        let largePN: UInt64 = UInt64.max - 100

        manager.recordReceivedPacket(packetNumber: largePN, isAckEliciting: true, receiveTime: now)
        manager.recordReceivedPacket(packetNumber: largePN + 1, isAckEliciting: true, receiveTime: now)

        #expect(manager.largestReceived == largePN + 1)
        #expect(manager.rangeCount == 1)

        let ackFrame = manager.generateAckFrame(now: now, ackDelayExponent: 3)
        #expect(ackFrame != nil)
        #expect(ackFrame!.largestAcknowledged == largePN + 1)
    }

    @Test("Non-ack-eliciting packets don't trigger immediate ACK")
    func nonAckElicitingNoImmediateAck() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Record many non-ack-eliciting packets
        for i: UInt64 in 0..<10 {
            manager.recordReceivedPacket(packetNumber: i, isAckEliciting: false, receiveTime: now)
        }

        #expect(!manager.shouldSendAckImmediately())
    }

    @Test("Binary search finds correct position")
    func binarySearchCorrectPosition() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Create scattered ranges: 10-12, 20-22, 30-32, 40-42
        for base in stride(from: 10, through: 40, by: 10) {
            for offset in 0...2 {
                manager.recordReceivedPacket(
                    packetNumber: UInt64(base + offset),
                    isAckEliciting: true,
                    receiveTime: now
                )
            }
        }

        #expect(manager.rangeCount == 4)

        // Insert in the middle (should create new range)
        manager.recordReceivedPacket(packetNumber: 25, isAckEliciting: true, receiveTime: now)
        #expect(manager.rangeCount == 5)

        // Insert adjacent to merge
        manager.recordReceivedPacket(packetNumber: 23, isAckEliciting: true, receiveTime: now)
        #expect(manager.rangeCount == 5)  // 23 extends 20-22 to 20-23

        // Insert to connect ranges
        manager.recordReceivedPacket(packetNumber: 24, isAckEliciting: true, receiveTime: now)
        #expect(manager.rangeCount == 4)  // 20-23 + 24 + 25 = 20-25
    }

    @Test("Pruning removes oldest ranges when limit exceeded")
    func pruningRemovesOldestRanges() {
        let manager = AckManager()
        let now = ContinuousClock.Instant.now

        // Create more than 256 ranges (maxRanges)
        // Each packet with a gap creates a new range
        for i in stride(from: 0, to: 600, by: 2) {  // 300 ranges
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: true,
                receiveTime: now
            )
        }

        // Should have been pruned to stay under limit
        // With 25% removal, keeps 192 ranges (256 * 3/4)
        #expect(manager.rangeCount <= 256)
        #expect(manager.rangeCount >= 192)

        // Largest should still be trackable
        #expect(manager.largestReceived == 598)
    }
}
