/// Performance Benchmarks for QUIC module
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
import Crypto
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto

@Suite("QUIC Performance Benchmarks")
struct QUICBenchmarks {

    // MARK: - ConnectionRouter Benchmarks

    @Test("ConnectionRouter lookup performance")
    func connectionRouterLookupPerformance() throws {
        let router = ConnectionRouter(isServer: true, dcidLength: 8)

        // Pre-populate with connections
        // Note: We can't create real ManagedConnections easily, so we test the DCID extraction
        let iterations = 10_000

        // Create test packet data (Initial packet format)
        let testPacket = createInitialPacketData(
            dcid: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])),
            scid: try ConnectionID(bytes: Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]))
        )

        let remoteAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = router.route(data: testPacket, from: remoteAddress)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ConnectionRouter lookup: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 50_000, "Expected > 50k ops/sec")
    }

    @Test("ConnectionRouter DCID extraction performance")
    func dcidExtractionPerformance() throws {
        let processor = PacketProcessor(dcidLength: 8)

        // Short header packet (1-RTT)
        let shortHeaderPacket = Data([
            0x40,  // Short header, fixed bit
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,  // DCID
            0x00,  // Packet number (encrypted)
            0x00, 0x00, 0x00  // Payload (encrypted)
        ])

        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try processor.extractDestinationConnectionID(from: shortHeaderPacket)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("DCID extraction (short header): \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 250_000, "Expected > 250k ops/sec")
    }

    @Test("ConnectionRouter long header DCID extraction performance")
    func longHeaderDcidExtractionPerformance() throws {
        let processor = PacketProcessor(dcidLength: 8)

        let longHeaderPacket = createInitialPacketData(
            dcid: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])),
            scid: try ConnectionID(bytes: Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]))
        )

        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try processor.extractDestinationConnectionID(from: longHeaderPacket)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("DCID extraction (long header): \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 150_000, "Expected > 150k ops/sec")
    }

    // MARK: - PacketProcessor Benchmarks

    @Test("PacketProcessor initial key derivation performance")
    func initialKeyDerivationPerformance() throws {
        let connectionID = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        let iterations = 1_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            let processor = PacketProcessor(dcidLength: 8)
            _ = try processor.deriveAndInstallInitialKeys(
                connectionID: connectionID,
                isClient: true,
                version: .v1
            )
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("Initial key derivation: \(Int(opsPerSecond)) ops/sec (\(elapsed * 1000 / Double(iterations)) ms/op)")
        #expect(opsPerSecond > 250, "Expected > 250 ops/sec (key derivation is expensive)")
    }

    @Test("PacketProcessor packet type extraction performance")
    func packetTypeExtractionPerformance() throws {
        let processor = PacketProcessor(dcidLength: 8)

        let packets = [
            createInitialPacketData(
                dcid: try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])),
                scid: try ConnectionID(bytes: Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]))
            ),
            Data([0x40, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x00])  // Short header
        ]

        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for packet in packets {
                _ = try processor.extractPacketType(from: packet)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * packets.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("Packet type extraction: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 500_000, "Expected > 500k ops/sec")
    }

    // MARK: - Crypto Context Benchmarks

    @Test("AES-GCM key material derivation performance")
    func keyMaterialDerivationPerformance() throws {
        // Sample traffic secret (32 bytes for AES-128-GCM)
        let secretData = Data(repeating: 0xAB, count: 32)
        let secret = SymmetricKey(data: secretData)
        let iterations = 5_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try KeyMaterial.derive(from: secret)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("KeyMaterial derivation: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 500, "Expected > 500 ops/sec")
    }

    @Test("AES-GCM sealer creation performance")
    func sealerCreationPerformance() throws {
        let secretData = Data(repeating: 0xAB, count: 32)
        let secret = SymmetricKey(data: secretData)
        let keyMaterial = try KeyMaterial.derive(from: secret)
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try AES128GCMSealer(keyMaterial: keyMaterial)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("AES-GCM Sealer creation: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 2_500, "Expected > 2.5k ops/sec")
    }

    // MARK: - CID Management Benchmarks

    @Test("ConnectionID random generation performance")
    func connectionIDRandomGenerationPerformance() throws {
        let iterations = 50_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = ConnectionID.random(length: 8)!
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let opsPerSecond = Double(iterations) / elapsed
        print("ConnectionID random: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 25_000, "Expected > 25k ops/sec")
    }

    @Test("ConnectionID hash performance")
    func connectionIDHashPerformance() throws {
        let cids = try (0..<100).map { i in
            try ConnectionID(bytes: Data([UInt8(i), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
        }
        let iterations = 100_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for cid in cids {
                _ = cid.hashValue
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * cids.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("ConnectionID hash: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 4_000_000, "Expected > 4M ops/sec")
    }

    @Test("Dictionary lookup by ConnectionID performance")
    func connectionIDDictionaryLookupPerformance() throws {
        // Simulate ConnectionRouter's internal lookup
        var dict: [ConnectionID: Int] = [:]
        let cids = try (0..<1000).map { i in
            try ConnectionID(bytes: Data([
                UInt8((i >> 8) & 0xFF),
                UInt8(i & 0xFF),
                0x02, 0x03, 0x04, 0x05, 0x06, 0x07
            ]))
        }
        for (index, cid) in cids.enumerated() {
            dict[cid] = index
        }

        let lookupCids = cids.shuffled()
        let iterations = 10_000

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for cid in lookupCids {
                _ = dict[cid]
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let totalOps = iterations * lookupCids.count
        let opsPerSecond = Double(totalOps) / elapsed
        print("CID Dictionary lookup: \(Int(opsPerSecond)) ops/sec")
        #expect(opsPerSecond > 2_500_000, "Expected > 2.5M ops/sec")
    }

    // MARK: - Helpers

    /// Creates a minimal Initial packet for testing
    private func createInitialPacketData(dcid: ConnectionID, scid: ConnectionID) -> Data {
        var data = Data()

        // First byte: Long header (0x80) + Initial type (0x00) + reserved bits
        data.append(0xC0)  // 1100 0000 = Long header + Initial

        // Version (4 bytes) - QUIC v1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        // DCID length + DCID
        data.append(UInt8(dcid.bytes.count))
        data.append(contentsOf: dcid.bytes)

        // SCID length + SCID
        data.append(UInt8(scid.bytes.count))
        data.append(contentsOf: scid.bytes)

        // Token length (varint) + no token
        data.append(0x00)

        // Length (varint) - minimal payload
        data.append(0x10)  // 16 bytes

        // Packet number (will be encrypted) + payload
        data.append(contentsOf: Data(repeating: 0x00, count: 16))

        return data
    }
}
