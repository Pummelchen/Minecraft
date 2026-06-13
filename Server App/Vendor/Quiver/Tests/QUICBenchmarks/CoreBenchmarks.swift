/// Performance Benchmarks for QUICCore
///
/// Run with: swift test --filter QUICBenchmarks
///
/// These benchmarks are separated from regular tests to avoid
/// running them during normal CI builds. Run them explicitly
/// when investigating performance bottlenecks.

import Testing
import Foundation

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

@Suite("QUICCore Performance Benchmarks")
struct CoreBenchmarks {

    // MARK: - Varint Benchmarks

    @Test("Varint encoding performance")
    func varintEncodingPerformance() throws {
        let values: [UInt64] = [0, 63, 16383, 1073741823, 4611686018427387903]
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for value in values {
                _ = Varint(value).encode()
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * values.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Varint encoding: \(Int(opsPerSecond)) ops/sec (\(elapsed * 1000 / Double(totalOps)) ms/op)")
        #expect(opsPerSecond > 500_000, "Expected > 500k ops/sec")
    }

    @Test("Varint decoding performance")
    func varintDecodingPerformance() throws {
        let encodedValues = [
            Varint(0).encode(),
            Varint(63).encode(),
            Varint(16383).encode(),
            Varint(1073741823).encode(),
            Varint(4611686018427387903).encode()
        ]
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for encoded in encodedValues {
                var reader = DataReader(encoded)
                _ = try reader.readVarint()
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * encodedValues.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Varint decoding: \(Int(opsPerSecond)) ops/sec (\(elapsed * 1000 / Double(totalOps)) ms/op)")
        #expect(opsPerSecond > 150_000, "Expected > 150k ops/sec")
    }

    @Test("Varint decoding fast path (readVarintValue)")
    func varintDecodingFastPath() throws {
        // Focus on 1-byte values which are the most common in QUIC
        let oneByteValues = (0..<64).map { Varint(UInt64($0)).encode() }
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for encoded in oneByteValues {
                var reader = DataReader(encoded)
                _ = try reader.readVarintValue()
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * oneByteValues.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Varint fast path (1-byte): \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 1_000_000, "Expected > 1M ops/sec for 1-byte varints")
    }

    // MARK: - ConnectionID Benchmarks

    @Test("ConnectionID creation performance")
    func connectionIDCreationPerformance() throws {
        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            let bytes = Data([UInt8(i & 0xFF), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
            _ = try ConnectionID(bytes: bytes)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ConnectionID creation: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 150_000, "Expected > 150k ops/sec")
    }

    @Test("ConnectionID equality performance")
    func connectionIDEqualityPerformance() throws {
        let cid1 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        let cid2 = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        let iterations = 1_000_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = cid1 == cid2
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ConnectionID equality: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 1_500_000, "Expected > 1.5M ops/sec")
    }

    // MARK: - Frame Encoding Benchmarks

    @Test("PING frame encoding performance")
    func pingFrameEncodingPerformance() throws {
        let codec = StandardFrameCodec()
        let frame = Frame.ping
        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try codec.encode(frame)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("PING frame encoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 250_000, "Expected > 250k ops/sec")
    }

    @Test("ACK frame encoding performance")
    func ackFrameEncodingPerformance() throws {
        let codec = StandardFrameCodec()
        let frame = Frame.ack(AckFrame(
            largestAcknowledged: 1000,
            ackDelay: 25,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)]
        ))
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try codec.encode(frame)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ACK frame encoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 100_000, "Expected > 100k ops/sec")
    }

    @Test("STREAM frame encoding performance")
    func streamFrameEncodingPerformance() throws {
        let codec = StandardFrameCodec()
        let data = Data(repeating: 0xAB, count: 1000)
        let frame = Frame.stream(StreamFrame(
            streamID: 4,
            offset: 0,
            data: data,
            fin: false
        ))
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try codec.encode(frame)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("STREAM frame encoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 25_000, "Expected > 25k ops/sec")
    }

    // MARK: - Frame Decoding Benchmarks

    @Test("PING frame decoding performance")
    func pingFrameDecodingPerformance() throws {
        let codec = StandardFrameCodec()
        let encoded = try codec.encode(.ping)
        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var reader = DataReader(encoded)
            _ = try codec.decode(from: &reader)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("PING frame decoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 250_000, "Expected > 250k ops/sec")
    }

    @Test("ACK frame decoding performance")
    func ackFrameDecodingPerformance() throws {
        let codec = StandardFrameCodec()
        let frame = Frame.ack(AckFrame(
            largestAcknowledged: 1000,
            ackDelay: 25,
            ackRanges: [AckRange(gap: 0, rangeLength: 10)]
        ))
        let encoded = try codec.encode(frame)
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var reader = DataReader(encoded)
            _ = try codec.decode(from: &reader)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ACK frame decoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 100_000, "Expected > 100k ops/sec")
    }

    // MARK: - Packet Header Benchmarks

    @Test("Long header parsing performance")
    func longHeaderParsingPerformance() throws {
        var packet = Data()
        packet.append(0xC0 | 0x01)
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet.append(4)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(4)
        packet.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet.append(0x00)
        packet.append(0x10)
        packet.append(contentsOf: Data(repeating: 0xAA, count: 16))

        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try ProtectedLongHeader.parse(from: packet)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("Long header parsing: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 50_000, "Expected > 50k ops/sec")
    }

    @Test("Short header parsing performance")
    func shortHeaderParsingPerformance() throws {
        var packet = Data()
        packet.append(0x40 | 0x01)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet.append(contentsOf: Data(repeating: 0xBB, count: 20))

        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try ProtectedShortHeader.parse(from: packet, dcidLength: 4)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("Short header parsing: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 100_000, "Expected > 100k ops/sec")
    }

    // MARK: - Packet Number Encoding Benchmarks

    @Test("Packet number encoding performance")
    func packetNumberEncodingPerformance() throws {
        let packetNumbers: [UInt64] = [0, 100, 10000, 1000000, 100000000]
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for pn in packetNumbers {
                _ = PacketNumberEncoding.encode(fullPacketNumber: pn, largestAcked: pn > 0 ? pn - 1 : nil)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * packetNumbers.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Packet number encoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 250_000, "Expected > 250k ops/sec")
    }

    @Test("Packet number decoding performance")
    func packetNumberDecodingPerformance() throws {
        let testCases: [(truncated: UInt64, length: Int, largestPN: UInt64)] = [
            (100, 1, 90),
            (10000 & 0xFFFF, 2, 9990),
            (1000000 & 0xFFFFFF, 3, 999990),
        ]
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for tc in testCases {
                _ = PacketNumberEncoding.decode(
                    truncated: tc.truncated,
                    length: tc.length,
                    largestPN: tc.largestPN
                )
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * testCases.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Packet number decoding: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 500_000, "Expected > 500k ops/sec")
    }

    // MARK: - Coalesced Packet Benchmarks

    @Test("Coalesced packet building performance")
    func coalescedPacketBuildingPerformance() throws {
        let packet1 = Data(repeating: 0xAA, count: 100)
        let packet2 = Data(repeating: 0xBB, count: 200)
        let packet3 = Data(repeating: 0xCC, count: 300)
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            var builder = CoalescedPacketBuilder(maxDatagramSize: 1200)
            _ = builder.addPacket(packet1)
            _ = builder.addPacket(packet2)
            _ = builder.addPacket(packet3)
            _ = builder.build()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("Coalesced packet building: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 50_000, "Expected > 50k ops/sec")
    }

    @Test("Coalesced packet parsing performance")
    func coalescedPacketParsingPerformance() throws {
        var datagram = Data()

        var packet1 = Data()
        packet1.append(0xC0 | 0x01)
        packet1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet1.append(2)
        packet1.append(contentsOf: [0x01, 0x02])
        packet1.append(2)
        packet1.append(contentsOf: [0x03, 0x04])
        packet1.append(0x00)
        packet1.append(0x10)
        packet1.append(contentsOf: Data(repeating: 0xAA, count: 16))

        var packet2 = Data()
        packet2.append(0xC0 | 0x21)
        packet2.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet2.append(2)
        packet2.append(contentsOf: [0x01, 0x02])
        packet2.append(2)
        packet2.append(contentsOf: [0x03, 0x04])
        packet2.append(0x10)
        packet2.append(contentsOf: Data(repeating: 0xBB, count: 16))

        datagram.append(packet1)
        datagram.append(packet2)

        let iterations = 20_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try CoalescedPacketParser.parse(datagram: datagram, dcidLength: 2)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("Coalesced packet parsing: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 25_000, "Expected > 25k ops/sec")
    }

    // MARK: - End-to-End Benchmarks

    @Test("Frame encode/decode roundtrip performance")
    func frameRoundtripPerformance() throws {
        let codec = StandardFrameCodec()
        let frames: [Frame] = [
            .ping,
            .ack(AckFrame(largestAcknowledged: 100, ackDelay: 10, ackRanges: [AckRange(gap: 0, rangeLength: 5)])),
            .stream(StreamFrame(streamID: 4, offset: 0, data: Data(repeating: 0xAB, count: 100), fin: false)),
            .crypto(CryptoFrame(offset: 0, data: Data(repeating: 0xCD, count: 50))),
        ]
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for frame in frames {
                let encoded = try codec.encode(frame)
                var reader = DataReader(encoded)
                _ = try codec.decode(from: &reader)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * frames.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Frame roundtrip: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 50_000, "Expected > 50k ops/sec")
    }
}
