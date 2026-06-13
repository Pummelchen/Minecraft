/// QUIC Coalesced Packets Tests
///
/// Tests for CoalescedPacketBuilder and CoalescedPacketParser.

import Testing
import Foundation
@testable import QUICCore

// MARK: - Coalesced Packet Builder Tests

@Suite("Coalesced Packet Builder Tests")
struct CoalescedPacketBuilderTests {

    @Test("Build single packet")
    func buildSinglePacket() {
        var builder = CoalescedPacketBuilder(maxDatagramSize: 1200)

        let packet = Data([0x01, 0x02, 0x03, 0x04])
        let added = builder.addPacket(packet)

        #expect(added == true)
        #expect(builder.packetCount == 1)
        #expect(builder.totalSize == 4)

        let result = builder.build()
        #expect(result == packet)
    }

    @Test("Build multiple packets")
    func buildMultiplePackets() {
        var builder = CoalescedPacketBuilder(maxDatagramSize: 1200)

        let packet1 = Data([0x01, 0x02])
        let packet2 = Data([0x03, 0x04, 0x05])
        let packet3 = Data([0x06])

        #expect(builder.addPacket(packet1) == true)
        #expect(builder.addPacket(packet2) == true)
        #expect(builder.addPacket(packet3) == true)

        #expect(builder.packetCount == 3)
        #expect(builder.totalSize == 6)

        let result = builder.build()
        #expect(result == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
    }

    @Test("Reject packet exceeding max size")
    func rejectOversizedPacket() {
        var builder = CoalescedPacketBuilder(maxDatagramSize: 10)

        let packet1 = Data(repeating: 0xAA, count: 8)
        let packet2 = Data(repeating: 0xBB, count: 5)

        #expect(builder.addPacket(packet1) == true)
        #expect(builder.addPacket(packet2) == false)

        #expect(builder.packetCount == 1)
        #expect(builder.totalSize == 8)
        #expect(builder.remainingSpace == 2)
    }

    @Test("Remaining space calculation")
    func remainingSpaceCalculation() {
        var builder = CoalescedPacketBuilder(maxDatagramSize: 100)

        #expect(builder.remainingSpace == 100)

        _ = builder.addPacket(Data(count: 30))
        #expect(builder.remainingSpace == 70)

        _ = builder.addPacket(Data(count: 50))
        #expect(builder.remainingSpace == 20)
    }

    @Test("Clear builder")
    func clearBuilder() {
        var builder = CoalescedPacketBuilder(maxDatagramSize: 100)

        _ = builder.addPacket(Data([0x01, 0x02, 0x03]))
        #expect(builder.packetCount == 1)
        #expect(builder.isEmpty == false)

        builder.clear()

        #expect(builder.packetCount == 0)
        #expect(builder.totalSize == 0)
        #expect(builder.isEmpty == true)
    }

    @Test("Static coalesce method")
    func staticCoalesceMethod() {
        let packets = [
            Data([0x01, 0x02]),
            Data([0x03, 0x04]),
            Data([0x05, 0x06, 0x07]),
        ]

        let result = CoalescedPacketBuilder.coalesce(packets: packets, maxDatagramSize: 1200)

        #expect(result == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
    }

    @Test("Static coalesce with size limit")
    func staticCoalesceWithSizeLimit() {
        let packets = [
            Data([0x01, 0x02]),
            Data([0x03, 0x04]),
            Data([0x05, 0x06, 0x07, 0x08, 0x09]),
        ]

        // Only first two packets should fit
        let result = CoalescedPacketBuilder.coalesce(packets: packets, maxDatagramSize: 5)

        #expect(result == Data([0x01, 0x02, 0x03, 0x04]))
    }
}

// MARK: - Coalesced Packet Parser Tests

@Suite("Coalesced Packet Parser Tests")
struct CoalescedPacketParserTests {

    @Test("Parse single long header packet")
    func parseSingleLongHeaderPacket() throws {
        // Construct a minimal Initial packet
        var packet = Data()

        // First byte: long header, Initial type, 2-byte PN
        packet.append(0xC0 | 0x01)

        // Version
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        // DCID length + DCID
        packet.append(4)
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])

        // SCID length + SCID
        packet.append(4)
        packet.append(contentsOf: [0x05, 0x06, 0x07, 0x08])

        // Token length (0)
        packet.append(0x00)

        // Length (varint) - 24 bytes for PN + payload
        packet.append(0x18)

        // Packet number + encrypted payload (24 bytes)
        packet.append(contentsOf: Data(repeating: 0xAB, count: 24))

        let packets = try CoalescedPacketParser.parse(datagram: packet, dcidLength: 4)

        #expect(packets.count == 1)
        #expect(packets[0].isLongHeader == true)
        #expect(packets[0].offset == 0)
        #expect(packets[0].data == packet)
    }

    @Test("Parse coalesced long header packets")
    func parseCoalescedLongHeaderPackets() throws {
        var datagram = Data()

        // First packet: Initial
        var packet1 = Data()
        packet1.append(0xC0 | 0x01)  // Initial, 2-byte PN
        packet1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version
        packet1.append(2)  // DCID length
        packet1.append(contentsOf: [0x01, 0x02])  // DCID
        packet1.append(2)  // SCID length
        packet1.append(contentsOf: [0x03, 0x04])  // SCID
        packet1.append(0x00)  // Token length
        packet1.append(0x10)  // Length: 16 bytes
        packet1.append(contentsOf: Data(repeating: 0xAA, count: 16))

        // Second packet: Handshake
        var packet2 = Data()
        packet2.append(0xC0 | 0x21)  // Handshake type (0x02 << 4 = 0x20), 2-byte PN
        packet2.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version
        packet2.append(2)  // DCID length
        packet2.append(contentsOf: [0x01, 0x02])  // DCID
        packet2.append(2)  // SCID length
        packet2.append(contentsOf: [0x03, 0x04])  // SCID
        packet2.append(0x10)  // Length: 16 bytes
        packet2.append(contentsOf: Data(repeating: 0xBB, count: 16))

        datagram.append(packet1)
        datagram.append(packet2)

        let packets = try CoalescedPacketParser.parse(datagram: datagram, dcidLength: 2)

        #expect(packets.count == 2)
        #expect(packets[0].isLongHeader == true)
        #expect(packets[0].offset == 0)
        #expect(packets[0].data == packet1)

        #expect(packets[1].isLongHeader == true)
        #expect(packets[1].offset == packet1.count)
        #expect(packets[1].data == packet2)
    }

    @Test("Parse long header followed by short header")
    func parseLongThenShortHeader() throws {
        var datagram = Data()

        // First packet: Initial
        var packet1 = Data()
        packet1.append(0xC0 | 0x01)  // Initial, 2-byte PN
        packet1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Version
        packet1.append(2)  // DCID length
        packet1.append(contentsOf: [0x01, 0x02])  // DCID
        packet1.append(2)  // SCID length
        packet1.append(contentsOf: [0x03, 0x04])  // SCID
        packet1.append(0x00)  // Token length
        packet1.append(0x10)  // Length: 16 bytes
        packet1.append(contentsOf: Data(repeating: 0xAA, count: 16))

        // Second packet: 1-RTT (short header)
        var packet2 = Data()
        packet2.append(0x40 | 0x01)  // Short header, 2-byte PN
        packet2.append(contentsOf: [0x01, 0x02])  // DCID
        packet2.append(contentsOf: Data(repeating: 0xBB, count: 20))  // PN + payload

        datagram.append(packet1)
        datagram.append(packet2)

        let packets = try CoalescedPacketParser.parse(datagram: datagram, dcidLength: 2)

        #expect(packets.count == 2)
        #expect(packets[0].isLongHeader == true)
        #expect(packets[1].isLongHeader == false)
        #expect(packets[1].data == packet2)
    }

    @Test("Parse single short header packet")
    func parseSingleShortHeaderPacket() throws {
        var packet = Data()
        packet.append(0x40 | 0x01)  // Short header, 2-byte PN
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // DCID
        packet.append(contentsOf: Data(repeating: 0xCC, count: 20))

        let packets = try CoalescedPacketParser.parse(datagram: packet, dcidLength: 4)

        #expect(packets.count == 1)
        #expect(packets[0].isLongHeader == false)
        #expect(packets[0].data == packet)
    }

    @Test("Split packets convenience method")
    func splitPacketsConvenience() throws {
        var datagram = Data()

        // First packet: Initial
        var packet1 = Data()
        packet1.append(0xC0 | 0x00)
        packet1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet1.append(2)
        packet1.append(contentsOf: [0x01, 0x02])
        packet1.append(2)
        packet1.append(contentsOf: [0x03, 0x04])
        packet1.append(0x00)
        packet1.append(0x08)
        packet1.append(contentsOf: Data(repeating: 0xAA, count: 8))

        // Second packet: Short header
        var packet2 = Data()
        packet2.append(0x40)
        packet2.append(contentsOf: [0x01, 0x02])
        packet2.append(contentsOf: Data(repeating: 0xBB, count: 10))

        datagram.append(packet1)
        datagram.append(packet2)

        let packetDatas = try CoalescedPacketParser.splitPackets(datagram: datagram, dcidLength: 2)

        #expect(packetDatas.count == 2)
        #expect(packetDatas[0] == packet1)
        #expect(packetDatas[1] == packet2)
    }

    @Test("Empty datagram throws error")
    func emptyDatagramError() throws {
        #expect(throws: CoalescedPacketParser.ParseError.self) {
            _ = try CoalescedPacketParser.parse(datagram: Data(), dcidLength: 4)
        }
    }
}

// MARK: - Packet Ordering Tests

@Suite("Coalesced Packet Order Tests")
struct CoalescedPacketOrderTests {

    @Test("Sort order values")
    func sortOrderValues() {
        #expect(CoalescedPacketOrder.sortOrder(for: .initial) == 0)
        #expect(CoalescedPacketOrder.sortOrder(for: .handshake) == 1)
        #expect(CoalescedPacketOrder.sortOrder(for: .zeroRTT) == 2)
        #expect(CoalescedPacketOrder.sortOrder(for: .oneRTT) == 3)
        #expect(CoalescedPacketOrder.sortOrder(for: .retry) == 4)
        #expect(CoalescedPacketOrder.sortOrder(for: .versionNegotiation) == 5)
    }

    @Test("Sort packets by type")
    func sortPacketsByType() {
        let packets: [(packetType: PacketType, data: Data)] = [
            (.oneRTT, Data([0x01])),
            (.initial, Data([0x02])),
            (.handshake, Data([0x03])),
            (.zeroRTT, Data([0x04])),
        ]

        let sorted = CoalescedPacketOrder.sort(packets: packets)

        #expect(sorted[0].packetType == .initial)
        #expect(sorted[1].packetType == .handshake)
        #expect(sorted[2].packetType == .zeroRTT)
        #expect(sorted[3].packetType == .oneRTT)
    }
}

// MARK: - Integration Tests

@Suite("Coalesced Packets Integration Tests")
struct CoalescedPacketsIntegrationTests {

    @Test("Build and parse roundtrip")
    func buildAndParseRoundtrip() throws {
        // Create Initial packet
        var packet1 = Data()
        packet1.append(0xC0 | 0x00)
        packet1.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet1.append(4)
        packet1.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet1.append(4)
        packet1.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet1.append(0x00)
        packet1.append(0x10)
        packet1.append(contentsOf: Data(repeating: 0xAA, count: 16))

        // Create Handshake packet
        var packet2 = Data()
        packet2.append(0xC0 | 0x20)
        packet2.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        packet2.append(4)
        packet2.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        packet2.append(4)
        packet2.append(contentsOf: [0x05, 0x06, 0x07, 0x08])
        packet2.append(0x10)
        packet2.append(contentsOf: Data(repeating: 0xBB, count: 16))

        // Build coalesced packet
        var builder = CoalescedPacketBuilder(maxDatagramSize: 1200)
        _ = builder.addPacket(packet1)
        _ = builder.addPacket(packet2)
        let datagram = builder.build()

        // Parse it back
        let parsed = try CoalescedPacketParser.parse(datagram: datagram, dcidLength: 4)

        #expect(parsed.count == 2)
        #expect(parsed[0].data == packet1)
        #expect(parsed[1].data == packet2)
    }
}
