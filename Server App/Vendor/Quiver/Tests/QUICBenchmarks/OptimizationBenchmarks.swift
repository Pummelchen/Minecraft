/// Optimization Validation Benchmarks
///
/// Benchmarks for the runtime optimizations applied in the sweep:
/// - AEAD seal/open (nonce inline struct + pre-alloc concat)
/// - DataBuffer mergeSegments (append instead of +)
/// - StreamScheduler scheduleStreams (index-offset iteration, no temp arrays)
///
/// Run with: swift test --filter QUICBenchmarks

import Testing
import Foundation
import Crypto

#if canImport(CoreFoundation)
import CoreFoundation
#else
private func CFAbsoluteTimeGetCurrent() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
#endif

@testable import QUICCore
@testable import QUICCrypto
@testable import QUICStream

// MARK: - AEAD Benchmarks

@Suite("AEAD Optimization Benchmarks")
struct AEADBenchmarks {

    /// Baseline: AES-128-GCM seal hot path (nonce construction + ciphertext concat)
    @Test("AES-128-GCM seal throughput")
    func aes128gcmSealThroughput() throws {
        let secretData = Data(repeating: 0xAB, count: 32)
        let secret = SymmetricKey(data: secretData)
        let keyMaterial = try KeyMaterial.derive(from: secret)
        let sealer = try AES128GCMSealer(keyMaterial: keyMaterial)

        let plaintext = Data(repeating: 0xCC, count: 1200)
        let header = Data(repeating: 0xDD, count: 20)
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for pn in UInt64(0)..<UInt64(iterations) {
            _ = try sealer.seal(plaintext: plaintext, packetNumber: pn, header: header)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("AES-128-GCM seal: \(Int(opsPerSecond)) ops/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(iterations))) us/op)")
        #expect(opsPerSecond > 10_000, "Expected > 10k seals/sec")
    }

    /// Baseline: AES-128-GCM open hot path
    @Test("AES-128-GCM open throughput")
    func aes128gcmOpenThroughput() throws {
        let secretData = Data(repeating: 0xAB, count: 32)
        let secret = SymmetricKey(data: secretData)
        let keyMaterial = try KeyMaterial.derive(from: secret)
        let sealer = try AES128GCMSealer(keyMaterial: keyMaterial)
        let opener = try AES128GCMOpener(keyMaterial: keyMaterial)

        let plaintext = Data(repeating: 0xCC, count: 1200)
        let header = Data(repeating: 0xDD, count: 20)

        // Pre-seal packets for opening
        let count = 50_000
        var ciphertexts: [Data] = []
        ciphertexts.reserveCapacity(count)
        for pn in UInt64(0)..<UInt64(count) {
            ciphertexts.append(try sealer.seal(plaintext: plaintext, packetNumber: pn, header: header))
        }

        let start = CFAbsoluteTimeGetCurrent()
        for pn in UInt64(0)..<UInt64(count) {
            _ = try opener.open(ciphertext: ciphertexts[Int(pn)], packetNumber: pn, header: header)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(count) / elapsed
        print("AES-128-GCM open: \(Int(opsPerSecond)) ops/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(count))) us/op)")
        #expect(opsPerSecond > 10_000, "Expected > 10k opens/sec")
    }

    /// ChaCha20-Poly1305 seal hot path
    @Test("ChaCha20-Poly1305 seal throughput")
    func chacha20SealThroughput() throws {
        let keyData = Data(repeating: 0x42, count: 32)
        let ivData = Data(repeating: 0x13, count: 12)
        let hpData = Data(repeating: 0x77, count: 32)
        let sealer = try ChaCha20Poly1305Sealer(
            key: SymmetricKey(data: keyData),
            iv: ivData,
            hp: SymmetricKey(data: hpData)
        )

        let plaintext = Data(repeating: 0xCC, count: 1200)
        let header = Data(repeating: 0xDD, count: 20)
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for pn in UInt64(0)..<UInt64(iterations) {
            _ = try sealer.seal(plaintext: plaintext, packetNumber: pn, header: header)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ChaCha20 seal: \(Int(opsPerSecond)) ops/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(iterations))) us/op)")
        #expect(opsPerSecond > 10_000, "Expected > 10k seals/sec")
    }

    /// Small packet seal (worst-case ratio of overhead vs payload)
    @Test("AES-128-GCM seal small packet (40B)")
    func aes128gcmSealSmallPacket() throws {
        let secretData = Data(repeating: 0xAB, count: 32)
        let secret = SymmetricKey(data: secretData)
        let keyMaterial = try KeyMaterial.derive(from: secret)
        let sealer = try AES128GCMSealer(keyMaterial: keyMaterial)

        let plaintext = Data(repeating: 0xCC, count: 40)
        let header = Data(repeating: 0xDD, count: 12)
        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for pn in UInt64(0)..<UInt64(iterations) {
            _ = try sealer.seal(plaintext: plaintext, packetNumber: pn, header: header)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("AES-128-GCM seal (40B): \(Int(opsPerSecond)) ops/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(iterations))) us/op)")
        #expect(opsPerSecond > 25_000, "Expected > 25k seals/sec for small packets")
    }
}

// MARK: - DataBuffer Merge Benchmarks

@Suite("DataBuffer Optimization Benchmarks")
struct DataBufferBenchmarks {

    /// Merge-heavy workload: many adjacent small segments
    @Test("DataBuffer merge adjacent segments throughput")
    func mergeAdjacentSegments() throws {
        let segmentSize = 100
        let segmentCount = 1000
        let iterations = 100

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var buffer = DataBuffer()
            for i in 0..<segmentCount {
                let offset = UInt64(i * segmentSize)
                let data = Data(repeating: UInt8(i & 0xFF), count: segmentSize)
                try buffer.insert(offset: offset, data: data, fin: i == segmentCount - 1)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalInserts = iterations * segmentCount
        let opsPerSecond = Double(totalInserts) / elapsed
        print("DataBuffer adjacent merge: \(Int(opsPerSecond)) inserts/sec (\(segmentCount) segments x \(iterations) rounds)")
        #expect(opsPerSecond > 50_000, "Expected > 50k inserts/sec")
    }

    /// Overlapping segment merge workload
    @Test("DataBuffer merge overlapping segments throughput")
    func mergeOverlappingSegments() throws {
        let iterations = 200

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var buffer = DataBuffer()
            // Insert 500 overlapping segments (offset step = 50, size = 100)
            for i in 0..<500 {
                let offset = UInt64(i * 50)
                let data = Data(repeating: UInt8(i & 0xFF), count: 100)
                try buffer.insert(offset: offset, data: data, fin: false)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalInserts = iterations * 500
        let opsPerSecond = Double(totalInserts) / elapsed
        print("DataBuffer overlapping merge: \(Int(opsPerSecond)) inserts/sec")
        #expect(opsPerSecond > 20_000, "Expected > 20k inserts/sec for overlapping")
    }

    /// Read-after-insert throughput (insert + consume loop)
    @Test("DataBuffer insert-then-read throughput")
    func insertThenRead() throws {
        let segmentSize = 1200
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        var buffer = DataBuffer()
        for i in 0..<iterations {
            let offset = UInt64(i * segmentSize)
            let data = Data(repeating: UInt8(i & 0xFF), count: segmentSize)
            try buffer.insert(offset: offset, data: data, fin: false)
            _ = buffer.readContiguous()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("DataBuffer insert+read: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 100_000, "Expected > 100k ops/sec for sequential insert+read")
    }

    /// Out-of-order insertion (worst case for merge)
    @Test("DataBuffer out-of-order insert throughput")
    func outOfOrderInsert() throws {
        let segmentSize = 100
        let segmentCount = 500
        let iterations = 100

        // Pre-generate reversed offsets
        let offsets: [Int] = (0..<segmentCount).reversed().map { $0 }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var buffer = DataBuffer()
            for i in offsets {
                let offset = UInt64(i * segmentSize)
                let data = Data(repeating: UInt8(i & 0xFF), count: segmentSize)
                try buffer.insert(offset: offset, data: data, fin: false)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalInserts = iterations * segmentCount
        let opsPerSecond = Double(totalInserts) / elapsed
        print("DataBuffer out-of-order: \(Int(opsPerSecond)) inserts/sec")
        #expect(opsPerSecond > 10_000, "Expected > 10k inserts/sec for reversed order")
    }
}

// MARK: - StreamScheduler Benchmarks

@Suite("StreamScheduler Optimization Benchmarks")
struct StreamSchedulerBenchmarks {

    /// Many streams, single urgency, incremental scheduling
    @Test("StreamScheduler incremental scheduling throughput")
    func incrementalSchedulingThroughput() throws {
        var scheduler = StreamScheduler()
        scheduler.useIncrementalScheduling = true

        // Create 50 streams across urgencies 0-3, mix of incremental/non-incremental
        var streams: [UInt64: DataStream] = [:]
        for i in 0..<50 {
            let streamID = UInt64(i * 4) // client-initiated bidi
            let urgency = UInt8(i % 4)
            let incremental = (i % 3) != 0
            let stream = DataStream(
                id: streamID,
                isClient: true,
                initialSendMaxData: 65535,
                initialRecvMaxData: 65535,
                priority: StreamPriority(urgency: urgency, incremental: incremental)
            )
            streams[streamID] = stream
        }

        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = scheduler.scheduleStreams(streams)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("StreamScheduler incremental (50 streams): \(Int(opsPerSecond)) schedules/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(iterations))) us/op)")
        #expect(opsPerSecond > 5_000, "Expected > 5k schedules/sec with 50 streams")
    }

    /// Round-robin scheduling (legacy mode)
    @Test("StreamScheduler round-robin scheduling throughput")
    func roundRobinSchedulingThroughput() throws {
        var scheduler = StreamScheduler()
        scheduler.useIncrementalScheduling = false

        var streams: [UInt64: DataStream] = [:]
        for i in 0..<50 {
            let streamID = UInt64(i * 4)
            let stream = DataStream(
                id: streamID,
                isClient: true,
                initialSendMaxData: 65535,
                initialRecvMaxData: 65535,
                priority: StreamPriority(urgency: UInt8(i % 8), incremental: true)
            )
            streams[streamID] = stream
        }

        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = scheduler.scheduleStreams(streams)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("StreamScheduler round-robin (50 streams): \(Int(opsPerSecond)) schedules/sec")
        #expect(opsPerSecond > 5_000, "Expected > 5k schedules/sec")
    }

    /// Small stream count (common case: 1-5 active streams)
    @Test("StreamScheduler small stream count throughput")
    func smallStreamCountThroughput() throws {
        var scheduler = StreamScheduler()
        scheduler.useIncrementalScheduling = true

        var streams: [UInt64: DataStream] = [:]
        for i in 0..<4 {
            let streamID = UInt64(i * 4)
            let stream = DataStream(
                id: streamID,
                isClient: true,
                initialSendMaxData: 65535,
                initialRecvMaxData: 65535,
                priority: StreamPriority(urgency: 3, incremental: i > 0)
            )
            streams[streamID] = stream
        }

        let iterations = 200_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = scheduler.scheduleStreams(streams)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("StreamScheduler small (4 streams): \(Int(opsPerSecond)) schedules/sec")
        #expect(opsPerSecond > 50_000, "Expected > 50k schedules/sec for 4 streams")
    }

    /// Large stream count stress test
    @Test("StreamScheduler large stream count (200 streams)")
    func largeStreamCountThroughput() throws {
        var scheduler = StreamScheduler()
        scheduler.useIncrementalScheduling = true

        var streams: [UInt64: DataStream] = [:]
        for i in 0..<200 {
            let streamID = UInt64(i * 4)
            let urgency = UInt8(i % 8)
            let incremental = (i % 2) == 0
            let stream = DataStream(
                id: streamID,
                isClient: true,
                initialSendMaxData: 65535,
                initialRecvMaxData: 65535,
                priority: StreamPriority(urgency: urgency, incremental: incremental)
            )
            streams[streamID] = stream
        }

        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = scheduler.scheduleStreams(streams)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("StreamScheduler large (200 streams): \(Int(opsPerSecond)) schedules/sec (\(String(format: "%.3f", elapsed * 1_000_000 / Double(iterations))) us/op)")
        #expect(opsPerSecond > 500, "Expected > 500 schedules/sec with 200 streams")
    }

    /// Schedule + advance cursor cycle (realistic hot loop)
    @Test("StreamScheduler schedule+advance cycle")
    func scheduleAdvanceCycle() throws {
        var scheduler = StreamScheduler()
        scheduler.useIncrementalScheduling = true

        var streams: [UInt64: DataStream] = [:]
        for i in 0..<20 {
            let streamID = UInt64(i * 4)
            let urgency = UInt8(i % 4)
            let stream = DataStream(
                id: streamID,
                isClient: true,
                initialSendMaxData: 65535,
                initialRecvMaxData: 65535,
                priority: StreamPriority(urgency: urgency, incremental: i % 2 == 0)
            )
            streams[streamID] = stream
        }

        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            let scheduled = scheduler.scheduleStreams(streams)
            if let first = scheduled.first {
                let urgency = first.stream.priority.urgency
                scheduler.advanceCursor(for: urgency, groupSize: scheduled.count)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("StreamScheduler schedule+advance (20 streams): \(Int(opsPerSecond)) cycles/sec")
        #expect(opsPerSecond > 10_000, "Expected > 10k cycles/sec")
    }
}