/// QUICRecovery Benchmark Tests
///
/// Performance benchmarks for AckManager and LossDetector optimizations.

import Testing
import Foundation
@testable import QUICRecovery
@testable import QUICCore

@Suite("Recovery Performance Benchmarks")
struct RecoveryBenchmarkTests {

    // MARK: - AckManager Benchmarks

    @Test("AckManager: Sequential packet recording performance")
    func ackManagerSequentialRecording() {
        let manager = AckManager()
        let iterations = 10_000
        let baseTime = ContinuousClock.Instant.now

        let start = ContinuousClock.now
        for i in 0..<iterations {
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: i % 2 == 0,
                receiveTime: baseTime
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Sequential packet recording: \(Int(opsPerSec)) ops/sec")

        // With interval-based tracking, sequential packets should merge into 1 range
        #expect(manager.rangeCount == 1, "Sequential packets should merge into 1 range")
        #expect(manager.receivedPacketCount == iterations)
    }

    @Test("AckManager: Packet recording with small gaps")
    func ackManagerSmallGaps() {
        let manager = AckManager()
        let iterations = 5_000
        let baseTime = ContinuousClock.Instant.now

        // Every other packet (creates many ranges initially, then merges)
        let start = ContinuousClock.now
        for i in stride(from: 0, to: iterations * 2, by: 2) {
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: true,
                receiveTime: baseTime
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Packet recording with gaps: \(Int(opsPerSec)) ops/sec, ranges: \(manager.rangeCount)")

        #expect(opsPerSec > 1_000, "Should handle >1K packets/sec with gaps")
    }

    @Test("AckManager: ACK frame generation performance")
    func ackManagerAckGeneration() {
        let manager = AckManager()
        let baseTime = ContinuousClock.Instant.now

        // Record packets with some gaps (realistic scenario: 10% loss)
        for i in 0..<1000 {
            if i % 10 != 5 {
                manager.recordReceivedPacket(
                    packetNumber: UInt64(i),
                    isAckEliciting: true,
                    receiveTime: baseTime
                )
            }
        }

        let iterations = 10_000
        let start = ContinuousClock.now
        for i in 0..<iterations {
            _ = manager.generateAckFrame(now: .now, ackDelayExponent: 3)
            // Add next sequential packet to re-enable ACK
            manager.recordReceivedPacket(
                packetNumber: UInt64(1000 + i),
                isAckEliciting: true,
                receiveTime: baseTime
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("ACK frame generation: \(Int(opsPerSec)) ops/sec")

        #expect(opsPerSec > 5_000, "ACK generation should be fast")
    }

    @Test("AckManager: Memory efficiency with sequential packets")
    func ackManagerMemoryEfficiency() {
        let manager = AckManager()
        let baseTime = ContinuousClock.Instant.now

        // Record 10K sequential packets
        for i in 0..<10_000 {
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: true,
                receiveTime: baseTime
            )
        }

        // Should be stored in just 1 range
        #expect(manager.rangeCount == 1, "10K sequential packets should be 1 range")
        #expect(manager.receivedPacketCount == 10_000)
    }

    // MARK: - LossDetector Benchmarks

    @Test("LossDetector: Packet send recording performance")
    func lossDetectorSendRecording() {
        let detector = LossDetector()
        let iterations = 10_000

        let start = ContinuousClock.now
        for i in 0..<iterations {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: .now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Packet send recording: \(Int(opsPerSec)) ops/sec")

        #expect(opsPerSec > 50_000, "Should handle >50K packet sends/sec")
    }

    @Test("LossDetector: ACK processing performance")
    func lossDetectorAckProcessing() {
        let rttEstimator = RTTEstimator()
        let iterations = 1_000

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            let detector = LossDetector()
            let basePN = UInt64(iter * 100)

            // Send 100 packets
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: basePN + UInt64(i),
                    encryptionLevel: .application,
                    timeSent: .now,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }

            // ACK all packets
            let ack = AckFrame(
                largestAcknowledged: basePN + 99,
                ackDelay: 1000,
                ackRanges: [AckRange(gap: 0, rangeLength: 99)],
                ecnCounts: nil
            )
            _ = detector.onAckReceived(
                ackFrame: ack,
                ackReceivedTime: .now,
                rttEstimator: rttEstimator
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("ACK processing (100 packets each): \(Int(opsPerSec)) ops/sec")

        #expect(opsPerSec > 500, "ACK processing should be efficient")
    }

    @Test("LossDetector: Loss detection performance")
    func lossDetectorLossDetection() {
        let rttEstimator = RTTEstimator()
        let iterations = 1_000
        var totalLost = 0

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            let detector = LossDetector()

            // Send 100 packets
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: UInt64(i),
                    encryptionLevel: .application,
                    timeSent: .now,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }

            // ACK only packets 50-99 (packets 0-46 should be detected as lost due to packet threshold)
            let ackFrame = AckFrame(
                largestAcknowledged: 99,
                ackDelay: 1000,
                ackRanges: [AckRange(gap: 0, rangeLength: 49)],
                ecnCounts: nil
            )

            let result = detector.onAckReceived(
                ackFrame: ackFrame,
                ackReceivedTime: .now,
                rttEstimator: rttEstimator
            )
            totalLost += result.lostPackets.count
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Loss detection: \(Int(opsPerSec)) ops/sec, avg lost: \(totalLost / iterations)")

        #expect(opsPerSec > 500, "Loss detection should be efficient")
        #expect(totalLost / iterations > 40, "Should detect ~47 lost packets per iteration")
    }

    @Test("LossDetector: Multi-range ACK processing")
    func lossDetectorMultiRangeAck() {
        let detector = LossDetector()
        let rttEstimator = RTTEstimator()

        // Send 500 packets
        for i in 0..<500 {
            let packet = SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: .now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            detector.onPacketSent(packet)
        }

        // Create ACK with multiple ranges (simulating packet loss)
        // ACK: 490-499, 470-479, 450-459, ... (gaps of 10)
        var ranges: [AckRange] = []
        ranges.append(AckRange(gap: 0, rangeLength: 9)) // 490-499
        for _ in 1..<25 {
            ranges.append(AckRange(gap: 8, rangeLength: 9)) // gap=8 means 10 missing
        }

        let ackFrame = AckFrame(
            largestAcknowledged: 499,
            ackDelay: 1000,
            ackRanges: ranges,
            ecnCounts: nil
        )

        let iterations = 1_000
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            // Reset and resend
            detector.clear()
            for i in 0..<500 {
                let packet = SentPacket(
                    packetNumber: UInt64(i),
                    encryptionLevel: .application,
                    timeSent: .now,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }

            _ = detector.onAckReceived(
                ackFrame: ackFrame,
                ackReceivedTime: .now,
                rttEstimator: rttEstimator
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Multi-range ACK (25 ranges, 500 packets): \(Int(opsPerSec)) ops/sec")

        #expect(opsPerSec > 200, "Multi-range ACK processing should be reasonable")
    }

    // MARK: - Combined Benchmarks

    @Test("End-to-end: Full ACK cycle performance")
    func endToEndAckCycle() {
        let ackManager = AckManager()
        let lossDetector = LossDetector()
        let rttEstimator = RTTEstimator()
        let baseTime = ContinuousClock.Instant.now

        let iterations = 1_000
        let packetsPerIteration = 50

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            let basePN = UInt64(iter * packetsPerIteration)

            // Simulate receiving packets
            for i in 0..<packetsPerIteration {
                ackManager.recordReceivedPacket(
                    packetNumber: basePN + UInt64(i),
                    isAckEliciting: true,
                    receiveTime: baseTime
                )
            }

            // Generate ACK
            if let ackFrame = ackManager.generateAckFrame(now: .now, ackDelayExponent: 3) {
                // Simulate sending packets and receiving ACK
                for i in 0..<packetsPerIteration {
                    let packet = SentPacket(
                        packetNumber: basePN + UInt64(i),
                        encryptionLevel: .application,
                        timeSent: .now,
                        ackEliciting: true,
                        inFlight: true,
                        sentBytes: 1200
                    )
                    lossDetector.onPacketSent(packet)
                }

                // Process ACK
                _ = lossDetector.onAckReceived(
                    ackFrame: ackFrame,
                    ackReceivedTime: .now,
                    rttEstimator: rttEstimator
                )
            }
        }
        let elapsed = ContinuousClock.now - start

        let cyclesPerSec = Double(iterations) / elapsed.asSeconds
        let packetsPerSec = Double(iterations * packetsPerIteration) / elapsed.asSeconds
        print("Full ACK cycle: \(Int(cyclesPerSec)) cycles/sec (\(Int(packetsPerSec)) packets/sec)")

        #expect(cyclesPerSec > 100, "Full ACK cycle should be efficient")
    }

    @Test("Realistic: Simulated QUIC stream")
    func realisticQUICStream() {
        let ackManager = AckManager()
        let lossDetector = LossDetector()
        let rttEstimator = RTTEstimator()

        // Simulate realistic QUIC traffic:
        // - 1000 packets sent
        // - 1% packet loss
        // - ACK every 2 packets
        let totalPackets = 1_000
        let lossRate = 0.01

        var sentPN: UInt64 = 0
        var receivedCount = 0
        var lostCount = 0

        let start = ContinuousClock.now

        for _ in 0..<totalPackets {
            // Send packet
            let packet = SentPacket(
                packetNumber: sentPN,
                encryptionLevel: .application,
                timeSent: .now,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
            lossDetector.onPacketSent(packet)

            // Receive packet (with simulated loss)
            if Double.random(in: 0...1) > lossRate {
                ackManager.recordReceivedPacket(
                    packetNumber: sentPN,
                    isAckEliciting: true,
                    receiveTime: .now
                )
                receivedCount += 1
            }

            sentPN += 1

            // Generate and process ACK every 2 packets
            if sentPN % 2 == 0 {
                if let ackFrame = ackManager.generateAckFrame(now: .now, ackDelayExponent: 3) {
                    let result = lossDetector.onAckReceived(
                        ackFrame: ackFrame,
                        ackReceivedTime: .now,
                        rttEstimator: rttEstimator
                    )
                    lostCount += result.lostPackets.count
                }
            }
        }

        let elapsed = ContinuousClock.now - start
        let packetsPerSec = Double(totalPackets) / elapsed.asSeconds

        print("Realistic QUIC: \(Int(packetsPerSec)) packets/sec")
        print("  Sent: \(totalPackets), Received: \(receivedCount), Lost detected: \(lostCount)")
        print("  AckManager ranges: \(ackManager.rangeCount)")

        #expect(packetsPerSec > 3_000, "Should handle >3K packets/sec")
    }
}

// MARK: - Duration Extension

extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
