/// QUICRecovery Profiling Tests
///
/// Identifies actual bottlenecks by measuring individual operations in isolation.

import Testing
import Foundation
import Synchronization
@testable import QUICRecovery
@testable import QUICCore

@Suite("Recovery Profiling Tests")
struct ProfilingTests {

    // MARK: - Configuration

    static let iterations = 10_000
    static let packetCount = 500

    // MARK: - Dictionary Operations

    @Test("Profile: Dictionary insert performance")
    func dictionaryInsert() {
        let iterations = Self.iterations

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            var dict: [UInt64: Int] = [:]
            for i in 0..<100 {
                dict[UInt64(iter * 100 + i)] = i
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Dictionary insert: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Dictionary insert with capacity")
    func dictionaryInsertWithCapacity() {
        let iterations = Self.iterations

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            var dict: [UInt64: Int] = Dictionary(minimumCapacity: 128)
            for i in 0..<100 {
                dict[UInt64(iter * 100 + i)] = i
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Dictionary insert (with capacity): \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Dictionary lookup performance")
    func dictionaryLookup() {
        var dict: [UInt64: Int] = Dictionary(minimumCapacity: 1024)
        for i in 0..<1000 {
            dict[UInt64(i)] = i
        }

        let iterations = Self.iterations * 10

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            for i in 0..<100 {
                _ = dict[UInt64(i)]
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Dictionary lookup: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Dictionary removeValue performance")
    func dictionaryRemove() {
        let iterations = Self.iterations

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            var dict: [UInt64: Int] = Dictionary(minimumCapacity: 128)
            for i in 0..<100 {
                dict[UInt64(i)] = i
            }
            for i in 0..<50 {
                _ = dict.removeValue(forKey: UInt64(i))
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Dictionary insert+remove cycle: \(formatNumber(opsPerSec)) cycles/sec")
    }

    @Test("Profile: Dictionary iteration performance")
    func dictionaryIteration() {
        var dict: [UInt64: Int] = Dictionary(minimumCapacity: 1024)
        for i in 0..<500 {
            dict[UInt64(i)] = i
        }

        let iterations = Self.iterations

        let start = ContinuousClock.now
        var sum = 0
        for _ in 0..<iterations {
            for (_, v) in dict {
                sum += v
            }
        }
        let elapsed = ContinuousClock.now - start
        _ = sum  // Prevent optimization

        let opsPerSec = Double(iterations * 500) / elapsed.asSeconds
        print("Dictionary iteration: \(formatNumber(opsPerSec)) elements/sec")
    }

    // MARK: - SentPacket Operations

    @Test("Profile: SentPacket creation")
    func sentPacketCreation() {
        let iterations = Self.iterations * 10
        let baseTime = ContinuousClock.Instant.now

        let start = ContinuousClock.now
        for i in 0..<iterations {
            _ = SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: baseTime,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("SentPacket creation: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: SentPacket in Dictionary")
    func sentPacketInDictionary() {
        let iterations = Self.iterations
        let baseTime = ContinuousClock.Instant.now

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            var dict: [UInt64: SentPacket] = Dictionary(minimumCapacity: 128)
            for i in 0..<100 {
                let pn = UInt64(iter * 100 + i)
                dict[pn] = SentPacket(
                    packetNumber: pn,
                    encryptionLevel: .application,
                    timeSent: baseTime,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("SentPacket in Dictionary: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - Duration Operations

    @Test("Profile: Duration arithmetic")
    func durationArithmetic() {
        let iterations = Self.iterations * 100
        let d = Duration.milliseconds(100)

        let start = ContinuousClock.now
        var result = d
        for _ in 0..<iterations {
            result = result * 7 / 8
            result = result + .milliseconds(1)
        }
        let elapsed = ContinuousClock.now - start
        _ = result  // Prevent optimization

        let opsPerSec = Double(iterations * 2) / elapsed.asSeconds
        print("Duration arithmetic: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Duration components access")
    func durationComponents() {
        let iterations = Self.iterations * 100
        let d = Duration.milliseconds(100)

        let start = ContinuousClock.now
        var sum: Int64 = 0
        for _ in 0..<iterations {
            let (seconds, attoseconds) = d.components
            sum += seconds + attoseconds / 1_000_000_000
        }
        let elapsed = ContinuousClock.now - start
        _ = sum  // Prevent optimization

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Duration.components access: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: ContinuousClock.now")
    func clockNow() {
        let iterations = Self.iterations * 100

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            _ = ContinuousClock.now
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("ContinuousClock.now: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Duration subtraction (time diff)")
    func durationSubtraction() {
        let iterations = Self.iterations * 100
        let t1 = ContinuousClock.Instant.now
        let t2 = t1 + .milliseconds(100)

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            _ = t2 - t1
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Duration subtraction: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - Mutex Operations

    @Test("Profile: Mutex lock/unlock")
    func mutexLockUnlock() {
        let iterations = Self.iterations * 100
        let mutex = Mutex(0)

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            mutex.withLock { $0 += 1 }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Mutex lock/unlock: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Mutex with struct state")
    func mutexWithStruct() {
        struct State {
            var a: Int = 0
            var b: Int = 0
            var c: Int = 0
        }

        let iterations = Self.iterations * 100
        let mutex = Mutex(State())

        let start = ContinuousClock.now
        for i in 0..<iterations {
            mutex.withLock { s in
                s.a += i
                s.b += i * 2
                s.c += i * 3
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Mutex with struct: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - Array Operations

    @Test("Profile: Array append")
    func arrayAppend() {
        let iterations = Self.iterations

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            var arr: [Int] = []
            for i in 0..<100 {
                arr.append(i)
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Array append: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Array append with reserveCapacity")
    func arrayAppendWithCapacity() {
        let iterations = Self.iterations

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            var arr: [Int] = []
            arr.reserveCapacity(128)
            for i in 0..<100 {
                arr.append(i)
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Array append (with capacity): \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Array insert at index")
    func arrayInsert() {
        let iterations = Self.iterations / 10

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            var arr: [Int] = []
            for i in 0..<100 {
                // Insert at random position (worst case: middle)
                let pos = arr.count / 2
                arr.insert(i, at: pos)
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("Array insert (middle): \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: Array binary search")
    func arrayBinarySearch() {
        let arr: [Int] = Array(0..<1000)
        let iterations = Self.iterations * 10

        let start = ContinuousClock.now
        var found = 0
        for i in 0..<iterations {
            let target = i % 1000
            // Manual binary search
            var low = 0
            var high = arr.count
            while low < high {
                let mid = (low + high) / 2
                if arr[mid] < target {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low < arr.count && arr[low] == target {
                found += 1
            }
        }
        let elapsed = ContinuousClock.now - start
        _ = found

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("Array binary search: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - LossDetector Component Profiling

    @Test("Profile: LossDetector.onPacketSent only")
    func lossDetectorOnPacketSent() {
        let iterations = Self.iterations
        let baseTime = ContinuousClock.Instant.now

        let start = ContinuousClock.now
        for iter in 0..<iterations {
            let detector = LossDetector()
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: UInt64(iter * 100 + i),
                    encryptionLevel: .application,
                    timeSent: baseTime,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("LossDetector.onPacketSent: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: LossDetector full cycle breakdown")
    func lossDetectorBreakdown() {
        let rttEstimator = RTTEstimator()
        let baseTime = ContinuousClock.Instant.now
        let iterations = 1_000

        // Phase 1: Packet sending
        var sendTime: Duration = .zero
        for _ in 0..<iterations {
            let detector = LossDetector()
            let start = ContinuousClock.now
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: UInt64(i),
                    encryptionLevel: .application,
                    timeSent: baseTime,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }
            sendTime += ContinuousClock.now - start
        }

        // Phase 2: ACK processing
        var ackTime: Duration = .zero
        for _ in 0..<iterations {
            let detector = LossDetector()
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: UInt64(i),
                    encryptionLevel: .application,
                    timeSent: baseTime,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }

            let ack = AckFrame(
                largestAcknowledged: 99,
                ackDelay: 1000,
                ackRanges: [AckRange(gap: 0, rangeLength: 99)],
                ecnCounts: nil
            )

            let start = ContinuousClock.now
            _ = detector.onAckReceived(
                ackFrame: ack,
                ackReceivedTime: .now,
                rttEstimator: rttEstimator
            )
            ackTime += ContinuousClock.now - start
        }

        // Phase 3: Loss detection only
        var lossTime: Duration = .zero
        for _ in 0..<iterations {
            let detector = LossDetector()
            for i in 0..<100 {
                let packet = SentPacket(
                    packetNumber: UInt64(i),
                    encryptionLevel: .application,
                    timeSent: baseTime,
                    ackEliciting: true,
                    inFlight: true,
                    sentBytes: 1200
                )
                detector.onPacketSent(packet)
            }

            // ACK only 50-99, leaving 0-49 as potentially lost
            let ack = AckFrame(
                largestAcknowledged: 99,
                ackDelay: 1000,
                ackRanges: [AckRange(gap: 0, rangeLength: 49)],
                ecnCounts: nil
            )

            let start = ContinuousClock.now
            _ = detector.onAckReceived(
                ackFrame: ack,
                ackReceivedTime: .now,
                rttEstimator: rttEstimator
            )
            lossTime += ContinuousClock.now - start
        }

        print("LossDetector breakdown (\(iterations) iterations, 100 packets each):")
        print("  - Send phase: \(formatDuration(sendTime)) (\(formatNumber(Double(iterations * 100) / sendTime.asSeconds)) pkt/sec)")
        print("  - ACK (no loss): \(formatDuration(ackTime)) (\(formatNumber(Double(iterations) / ackTime.asSeconds)) ack/sec)")
        print("  - ACK (with loss): \(formatDuration(lossTime)) (\(formatNumber(Double(iterations) / lossTime.asSeconds)) ack/sec)")
    }

    // MARK: - AckManager Component Profiling

    @Test("Profile: AckManager.recordReceivedPacket only")
    func ackManagerRecord() {
        let iterations = Self.iterations
        let baseTime = ContinuousClock.Instant.now

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            let manager = AckManager()
            for i in 0..<100 {
                manager.recordReceivedPacket(
                    packetNumber: UInt64(i),
                    isAckEliciting: true,
                    receiveTime: baseTime
                )
            }
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations * 100) / elapsed.asSeconds
        print("AckManager.recordReceivedPacket: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: AckManager.generateAckFrame only")
    func ackManagerGenerate() {
        let manager = AckManager()
        let baseTime = ContinuousClock.Instant.now

        // Setup: record 100 packets
        for i in 0..<100 {
            manager.recordReceivedPacket(
                packetNumber: UInt64(i),
                isAckEliciting: true,
                receiveTime: baseTime
            )
        }

        let iterations = Self.iterations * 10

        let start = ContinuousClock.now
        for i in 0..<iterations {
            _ = manager.generateAckFrame(now: .now, ackDelayExponent: 3)
            // Re-enable ACK generation
            manager.recordReceivedPacket(
                packetNumber: UInt64(100 + i),
                isAckEliciting: true,
                receiveTime: baseTime
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("AckManager.generateAckFrame: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - RTTEstimator Profiling

    @Test("Profile: RTTEstimator.updateRTT")
    func rttEstimatorUpdate() {
        let iterations = Self.iterations * 100

        let start = ContinuousClock.now
        var estimator = RTTEstimator()
        for i in 0..<iterations {
            estimator.updateRTT(
                rttSample: .milliseconds(Int64(50 + (i % 20))),
                ackDelay: .milliseconds(5),
                maxAckDelay: .milliseconds(25),
                handshakeConfirmed: true
            )
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("RTTEstimator.updateRTT: \(formatNumber(opsPerSec)) ops/sec")
    }

    @Test("Profile: RTTEstimator.probeTimeout")
    func rttEstimatorPTO() {
        var estimator = RTTEstimator()
        estimator.updateRTT(
            rttSample: .milliseconds(50),
            ackDelay: .milliseconds(5),
            maxAckDelay: .milliseconds(25),
            handshakeConfirmed: true
        )

        let iterations = Self.iterations * 100

        let start = ContinuousClock.now
        for _ in 0..<iterations {
            _ = estimator.probeTimeout(maxAckDelay: .milliseconds(25))
        }
        let elapsed = ContinuousClock.now - start

        let opsPerSec = Double(iterations) / elapsed.asSeconds
        print("RTTEstimator.probeTimeout: \(formatNumber(opsPerSec)) ops/sec")
    }

    // MARK: - NewRenoCongestionController Profiling

    @Test("Profile: NewRenoCongestionController operations")
    func congestionControllerOps() {
        let cc = NewRenoCongestionController()
        var rtt = RTTEstimator()
        rtt.updateRTT(
            rttSample: .milliseconds(50),
            ackDelay: .milliseconds(5),
            maxAckDelay: .milliseconds(25),
            handshakeConfirmed: true
        )

        let iterations = Self.iterations * 10
        let baseTime = ContinuousClock.Instant.now

        // Profile onPacketSent
        let start1 = ContinuousClock.now
        for i in 0..<iterations {
            cc.onPacketSent(bytes: 1200, now: baseTime + .microseconds(Int64(i)))
        }
        let sendTime = ContinuousClock.now - start1

        // Profile onPacketsAcknowledged
        let packets = (0..<10).map { i in
            SentPacket(
                packetNumber: UInt64(i),
                encryptionLevel: .application,
                timeSent: baseTime,
                ackEliciting: true,
                inFlight: true,
                sentBytes: 1200
            )
        }

        let start2 = ContinuousClock.now
        for _ in 0..<iterations {
            cc.onPacketsAcknowledged(packets: packets, now: .now, rtt: rtt)
        }
        let ackTime = ContinuousClock.now - start2

        print("NewRenoCongestionController:")
        print("  - onPacketSent: \(formatNumber(Double(iterations) / sendTime.asSeconds)) ops/sec")
        print("  - onPacketsAcknowledged (10 pkts): \(formatNumber(Double(iterations) / ackTime.asSeconds)) ops/sec")
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Double) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", n / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.2fK", n / 1_000)
        } else {
            return String(format: "%.0f", n)
        }
    }

    private func formatDuration(_ d: Duration) -> String {
        let ms = d.asSeconds * 1000
        return String(format: "%.2fms", ms)
    }
}
