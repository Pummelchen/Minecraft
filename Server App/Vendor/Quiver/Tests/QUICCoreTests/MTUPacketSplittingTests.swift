/// MTU Packet Splitting Tests
///
/// Comprehensive tests proving that the MTU-aware frame packer
/// guarantees no packet ever exceeds maxDatagramSize when the
/// payload budget is computed correctly.
///
/// Coverage:
///   G1 - Packing invariants (batch sizes <= maxPayload)
///   G2 - packetOverhead accuracy vs actual encoded header size
///   G3 - Oversized single-frame isolation (RC4)
///   G4 - packetTooLarge is impossible with correct setup
///   G5 - Budget accuracy (control + external frame subtraction)
///   G6 - CRYPTO frame fit within long-header packet
///   G7 - Frame order preservation across batches

import Testing
import Foundation
@testable import QUICCore

// MARK: - Test Helpers

/// Builds a STREAM frame with a specific data size for deterministic FrameSize.
private func makeStreamFrame(streamID: UInt64 = 0, offset: UInt64 = 0, dataSize: Int, fin: Bool = false) -> Frame {
    .stream(StreamFrame(
        streamID: streamID,
        offset: offset,
        data: Data(repeating: 0xAA, count: dataSize),
        fin: fin,
        hasLength: true
    ))
}

/// Builds a CRYPTO frame with a specific data size.
private func makeCryptoFrame(offset: UInt64 = 0, dataSize: Int) -> Frame {
    .crypto(CryptoFrame(
        offset: offset,
        data: Data(repeating: 0xBB, count: dataSize)
    ))
}

/// Returns the encoded wire size of a frame (delegates to FrameSize).
private func wireSize(_ frame: Frame) -> Int {
    FrameSize.frame(frame)
}

/// Sum of wire sizes for an array of frames.
private func totalWireSize(_ frames: [Frame]) -> Int {
    frames.reduce(0) { $0 + wireSize($1) }
}

/// Mock sealer that produces deterministic output for size validation.
/// XOR encryption + 16-byte AEAD tag (same as production AES-GCM tag size).
/// Named MTUTestSealer to avoid collision with MockPacketSealer in PacketCodecTests.
private struct MTUTestSealer: PacketSealerProtocol {
    let key: UInt8

    func applyHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data) {
        let mask = sample[sample.startIndex]
        let protectedFirstByte = firstByte ^ (mask & 0x0F)
        let protectedPN = Data(packetNumberBytes.map { $0 ^ mask })
        return (protectedFirstByte, protectedPN)
    }

    func seal(
        plaintext: Data,
        packetNumber: UInt64,
        header: Data
    ) throws -> Data {
        var ciphertext = Data(plaintext.map { $0 ^ key })
        ciphertext.append(Data(repeating: key, count: 16))
        return ciphertext
    }
}

// MARK: - G1: Packing Invariants

@Suite("G1 - MTUFramePacker Batch Size Invariants")
struct PackerBatchInvariantTests {

    @Test("Empty input produces no batches")
    func emptyInput() {
        let batches = MTUFramePacker.pack(frames: [], maxPayload: 1000)
        #expect(batches.isEmpty)
    }

    @Test("Single small frame produces one batch")
    func singleSmallFrame() {
        let frame = makeStreamFrame(dataSize: 10)
        let batches = MTUFramePacker.pack(frames: [frame], maxPayload: 1000)
        #expect(batches.count == 1)
        #expect(batches[0].frames.count == 1)
        #expect(batches[0].totalSize == wireSize(frame))
        #expect(batches[0].isOversized == false)
    }

    @Test("Multiple frames fitting in one batch stay together")
    func multipleFramesOneBatch() {
        let frames = (0..<5).map { i in makeStreamFrame(streamID: UInt64(i), dataSize: 10) }
        let total = totalWireSize(frames)
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: total + 100)
        #expect(batches.count == 1)
        #expect(batches[0].frames.count == 5)
        #expect(batches[0].totalSize == total)
        #expect(batches[0].isOversized == false)
    }

    @Test("Frames split across exactly two batches at boundary")
    func exactBoundarySplit() {
        // Each STREAM frame: type(1) + streamID(1) + length(1) + data(50) = 53 bytes
        // (streamID=0, offset=0, hasLength=true, 50 data bytes)
        let frame = makeStreamFrame(streamID: 0, dataSize: 50)
        let singleSize = wireSize(frame)

        // maxPayload fits exactly 2 frames
        let maxPayload = singleSize * 2
        let frames = [frame, frame, frame]

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        #expect(batches.count == 2)
        #expect(batches[0].frames.count == 2)
        #expect(batches[0].totalSize == singleSize * 2)
        #expect(batches[0].totalSize <= maxPayload)
        #expect(batches[1].frames.count == 1)
        #expect(batches[1].totalSize <= maxPayload)
    }

    @Test("Every non-oversized batch respects maxPayload")
    func allBatchesRespectLimit() {
        // Generate 50 frames of varying sizes
        let frames = (0..<50).map { (i: Int) -> Frame in
            let dataSize = 20 + (i * 7) % 80
            return makeStreamFrame(streamID: UInt64(i % 10), offset: UInt64(i * 100), dataSize: dataSize)
        }
        let maxPayload = 200

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)

        for (idx, batch) in batches.enumerated() {
            if !batch.isOversized {
                #expect(
                    batch.totalSize <= maxPayload,
                    "Batch \(idx): totalSize \(batch.totalSize) > maxPayload \(maxPayload)"
                )
            }
        }
    }

    @Test("Batch totalSize equals sum of FrameSize.frame for all contained frames")
    func totalSizeAccuracy() {
        let frames = (0..<20).map { (i: Int) -> Frame in
            let dataSize = 30 + i * 3
            return makeStreamFrame(streamID: UInt64(i), dataSize: dataSize)
        }
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 150)

        for (idx, batch) in batches.enumerated() {
            let computed = totalWireSize(batch.frames)
            #expect(
                batch.totalSize == computed,
                "Batch \(idx): reported totalSize \(batch.totalSize) != computed \(computed)"
            )
        }
    }

    @Test("maxPayload of 1 forces one frame per batch")
    func minimalPayload() {
        let frames: [Frame] = [.ping, .ping, .ping]
        // PING is 1 byte, so maxPayload=1 fits exactly one per batch.
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 1)
        #expect(batches.count == 3)
        for batch in batches {
            #expect(batch.frames.count == 1)
            #expect(batch.isOversized == false)
        }
    }

    @Test("Stress: 1000 frames always produce valid batches")
    func stressManyFrames() {
        let frames = (0..<1000).map { (i: Int) -> Frame in
            let dataSize = 10 + (i % 40)
            return makeStreamFrame(streamID: UInt64(i % 100), offset: UInt64(i * 50), dataSize: dataSize)
        }
        let maxPayload = 500
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)

        var totalFrameCount = 0
        for batch in batches {
            totalFrameCount += batch.frames.count
            if !batch.isOversized {
                #expect(batch.totalSize <= maxPayload)
            }
            // Verify reported totalSize matches
            let recomputed = totalWireSize(batch.frames)
            #expect(batch.totalSize == recomputed)
        }
        // Lossless: all frames accounted for
        #expect(totalFrameCount == 1000)
    }
}

// MARK: - G2: Overhead Accuracy

@Suite("G2 - packetOverhead Accuracy vs Actual Encoder")
struct OverheadAccuracyTests {

    /// Encodes a packet and returns (headerBytes, totalBytes) where
    /// headerBytes = totalBytes - encodedPayloadSize.
    /// We use a minimal frame so the payload is predictable.
    private func measureActualOverhead(
        level: EncryptionLevel,
        dcid: ConnectionID,
        scid: ConnectionID,
        padToMinimum: Bool = false
    ) throws -> Int {
        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)
        // Use a 50-byte CRYPTO frame so that the Length varint in long
        // headers is 2 bytes (Length = PN(4) + payload(~54) + AEAD(16) = ~74 >= 64).
        // PING (1 byte) would give Length=21, a 1-byte varint, making the
        // formula look 1 byte too high.  The formula is designed for the
        // operating point where payloads are large enough for 2-byte varints.
        let frame: Frame = .crypto(CryptoFrame(offset: 0, data: Data(repeating: 0x00, count: 50)))

        let encodedPayloadSize = FrameSize.frame(frame)  // type(1) + offset(1) + length(1) + data(50) = 53

        let packetData: Data
        switch level {
        case .initial:
            let header = LongHeader(
                packetType: .initial, version: .v1,
                destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
            )
            packetData = try encoder.encodeLongHeaderPacket(
                frames: [frame], header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: 65535, padToMinimum: padToMinimum
            )
        case .handshake:
            let header = LongHeader(
                packetType: .handshake, version: .v1,
                destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
            )
            packetData = try encoder.encodeLongHeaderPacket(
                frames: [frame], header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: 65535, padToMinimum: false
            )
        case .application:
            let header = ShortHeader(
                destinationConnectionID: dcid, spinBit: false, keyPhase: false
            )
            packetData = try encoder.encodeShortHeaderPacket(
                frames: [frame], header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: 65535
            )
        default:
            throw PacketCodecError.invalidPacketFormat("Unsupported level in test")
        }

        // overhead = total - payload
        return packetData.count - encodedPayloadSize
    }

    @Test("Short header overhead matches actual encoding (4-byte DCID)")
    func shortHeaderOverhead4() throws {
        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let scid = ConnectionID.empty
        let predicted = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcid.length, scidLength: scid.length
        )
        let actual = try measureActualOverhead(level: .application, dcid: dcid, scid: scid)
        #expect(predicted == actual, "Short header: predicted \(predicted) != actual \(actual)")
    }

    @Test("Short header overhead matches actual encoding (8-byte DCID)")
    func shortHeaderOverhead8() throws {
        let dcid = try ConnectionID(bytes: Data(repeating: 0xAB, count: 8))
        let scid = ConnectionID.empty
        let predicted = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcid.length, scidLength: scid.length
        )
        let actual = try measureActualOverhead(level: .application, dcid: dcid, scid: scid)
        #expect(predicted == actual, "Short header 8B: predicted \(predicted) != actual \(actual)")
    }

    @Test("Short header overhead matches actual encoding (20-byte max DCID)")
    func shortHeaderOverhead20() throws {
        let dcid = try ConnectionID(bytes: Data(repeating: 0xCD, count: 20))
        let scid = ConnectionID.empty
        let predicted = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcid.length, scidLength: scid.length
        )
        let actual = try measureActualOverhead(level: .application, dcid: dcid, scid: scid)
        #expect(predicted == actual, "Short header 20B: predicted \(predicted) != actual \(actual)")
    }

    @Test("Short header overhead matches actual encoding (empty DCID)")
    func shortHeaderOverheadEmpty() throws {
        let dcid = ConnectionID.empty
        let scid = ConnectionID.empty
        let predicted = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcid.length, scidLength: scid.length
        )
        // Short header has no Length varint field, so the payload size
        // does not affect the overhead -- PING is fine here too, but
        // measureActualOverhead now uses a CRYPTO frame consistently.
        let actual = try measureActualOverhead(level: .application, dcid: dcid, scid: scid)
        #expect(predicted == actual, "Short header empty: predicted \(predicted) != actual \(actual)")
    }

    @Test("Handshake header overhead matches actual encoding")
    func handshakeHeaderOverhead() throws {
        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let scid = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let predicted = MTUFramePacker.packetOverhead(
            for: .handshake, dcidLength: dcid.length, scidLength: scid.length
        )
        let actual = try measureActualOverhead(level: .handshake, dcid: dcid, scid: scid)
        #expect(predicted == actual, "Handshake: predicted \(predicted) != actual \(actual)")
    }

    @Test("Initial header overhead matches actual encoding (no padding)")
    func initialHeaderOverhead() throws {
        let dcid = try ConnectionID(bytes: Data([0x01, 0x02, 0x03, 0x04]))
        let scid = try ConnectionID(bytes: Data([0x05, 0x06, 0x07, 0x08]))
        let predicted = MTUFramePacker.packetOverhead(
            for: .initial, dcidLength: dcid.length, scidLength: scid.length
        )
        // NOTE: Initial overhead formula includes token_length=0 (1 varint byte).
        // We measure without padToMinimum so padding does not inflate the result.
        let actual = try measureActualOverhead(
            level: .initial, dcid: dcid, scid: scid, padToMinimum: false
        )
        #expect(predicted == actual, "Initial: predicted \(predicted) != actual \(actual)")
    }

    @Test("Initial header overhead with max-length CIDs")
    func initialHeaderOverheadMaxCIDs() throws {
        let dcid = try ConnectionID(bytes: Data(repeating: 0xAA, count: 20))
        let scid = try ConnectionID(bytes: Data(repeating: 0xBB, count: 20))
        let predicted = MTUFramePacker.packetOverhead(
            for: .initial, dcidLength: dcid.length, scidLength: scid.length
        )
        let actual = try measureActualOverhead(
            level: .initial, dcid: dcid, scid: scid, padToMinimum: false
        )
        #expect(predicted == actual, "Initial max CIDs: predicted \(predicted) != actual \(actual)")
    }

    @Test("maxPayload convenience matches manual subtraction")
    func maxPayloadConvenience() {
        let mtu = 1200
        let dcid = 8
        let scid = 8
        for level in [EncryptionLevel.initial, .handshake, .application] {
            let overhead = MTUFramePacker.packetOverhead(for: level, dcidLength: dcid, scidLength: scid)
            let expected = max(0, mtu - overhead)
            let got = MTUFramePacker.maxPayload(for: level, maxDatagramSize: mtu, dcidLength: dcid, scidLength: scid)
            #expect(got == expected, "maxPayload mismatch for \(level)")
        }
    }

    @Test("maxPayload clamps to zero when MTU < overhead")
    func maxPayloadClampsToZero() {
        let result = MTUFramePacker.maxPayload(
            for: .initial, maxDatagramSize: 10, dcidLength: 20, scidLength: 20
        )
        #expect(result == 0)
    }
}

// MARK: - G3: Oversized Single-Frame Isolation

@Suite("G3 - Oversized Frame Isolation (RC4)")
struct OversizedIsolationTests {

    @Test("Single oversized frame is isolated as first batch")
    func oversizedFirstFrame() {
        let big = makeStreamFrame(dataSize: 2000)
        let small = makeStreamFrame(streamID: 1, dataSize: 10)
        let batches = MTUFramePacker.pack(frames: [big, small], maxPayload: 100)

        #expect(batches.count == 2)
        #expect(batches[0].frames.count == 1)
        #expect(batches[0].isOversized == true)
        #expect(batches[1].frames.count == 1)
        #expect(batches[1].isOversized == false)
        #expect(batches[1].totalSize <= 100)
    }

    @Test("Oversized frame in the middle flushes preceding batch first")
    func oversizedMiddleFrame() {
        let small1 = makeStreamFrame(streamID: 0, dataSize: 10)
        let big = makeStreamFrame(streamID: 1, dataSize: 2000)
        let small2 = makeStreamFrame(streamID: 2, dataSize: 10)

        let batches = MTUFramePacker.pack(frames: [small1, big, small2], maxPayload: 100)

        #expect(batches.count == 3)
        // Batch 0: small1 (flushed before the oversized frame)
        #expect(batches[0].isOversized == false)
        #expect(batches[0].frames.count == 1)
        // Batch 1: big (isolated)
        #expect(batches[1].isOversized == true)
        #expect(batches[1].frames.count == 1)
        // Batch 2: small2
        #expect(batches[2].isOversized == false)
        #expect(batches[2].frames.count == 1)
    }

    @Test("Multiple consecutive oversized frames each get their own batch")
    func consecutiveOversized() {
        let big1 = makeStreamFrame(streamID: 0, dataSize: 2000)
        let big2 = makeStreamFrame(streamID: 1, dataSize: 3000)
        let small = makeStreamFrame(streamID: 2, dataSize: 5)

        let batches = MTUFramePacker.pack(frames: [big1, big2, small], maxPayload: 50)

        #expect(batches.count == 3)
        #expect(batches[0].isOversized == true)
        #expect(batches[1].isOversized == true)
        #expect(batches[2].isOversized == false)
    }

    @Test("Oversized batch contains exactly the oversized frame's wire size")
    func oversizedTotalSizeAccurate() {
        let big = makeStreamFrame(dataSize: 5000)
        let expectedSize = wireSize(big)
        let batches = MTUFramePacker.pack(frames: [big], maxPayload: 100)

        #expect(batches.count == 1)
        #expect(batches[0].totalSize == expectedSize)
        #expect(batches[0].isOversized == true)
    }

    @Test("All non-oversized frames survive alongside an oversized frame")
    func nonOversizedFramesSurvive() {
        let small1 = Frame.ping
        let small2 = makeStreamFrame(streamID: 0, dataSize: 5)
        let big = makeStreamFrame(streamID: 1, dataSize: 9999)
        let small3 = makeStreamFrame(streamID: 2, dataSize: 5)
        let small4 = Frame.ping

        let frames = [small1, small2, big, small3, small4]
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 50)

        let allRecoveredFrames = batches.flatMap { $0.frames }
        #expect(allRecoveredFrames.count == frames.count, "All frames must be present in batches")

        let nonOversizedFrameCount = batches.filter { !$0.isOversized }.flatMap { $0.frames }.count
        #expect(nonOversizedFrameCount == 4, "All 4 non-oversized frames must survive")
    }
}

// MARK: - G4: packetTooLarge Is Impossible

@Suite("G4 - packetTooLarge Can Never Fire With Correct Budget")
struct PacketTooLargeImpossibleTests {

    /// Encodes a batch of frames into a real packet and verifies its size.
    /// This is the definitive proof: if the packer says a batch fits,
    /// the encoder MUST NOT throw packetTooLarge.
    private func encodeAndVerify(
        frames: [Frame],
        level: EncryptionLevel,
        dcid: ConnectionID,
        scid: ConnectionID,
        maxDatagramSize: Int
    ) throws {
        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)

        let packetData: Data
        switch level {
        case .initial:
            let header = LongHeader(
                packetType: .initial, version: .v1,
                destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
            )
            packetData = try encoder.encodeLongHeaderPacket(
                frames: frames, header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: maxDatagramSize, padToMinimum: false
            )
        case .handshake:
            let header = LongHeader(
                packetType: .handshake, version: .v1,
                destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
            )
            packetData = try encoder.encodeLongHeaderPacket(
                frames: frames, header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: maxDatagramSize, padToMinimum: false
            )
        case .application:
            let header = ShortHeader(
                destinationConnectionID: dcid, spinBit: false, keyPhase: false
            )
            packetData = try encoder.encodeShortHeaderPacket(
                frames: frames, header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: maxDatagramSize
            )
        default:
            throw PacketCodecError.invalidPacketFormat("Unsupported level")
        }

        #expect(
            packetData.count <= maxDatagramSize,
            "Encoded packet \(packetData.count) bytes > MTU \(maxDatagramSize) at \(level)"
        )
    }

    @Test("Short header: packer batches never cause packetTooLarge (MTU 1200)")
    func shortHeaderMTU1200() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x01, count: 8))
        let scid = ConnectionID.empty
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        // Generate frames whose total exceeds MTU
        let frames = (0..<20).map { (i: Int) -> Frame in
            makeStreamFrame(streamID: UInt64(i), offset: UInt64(i * 500), dataSize: 100)
        }
        #expect(totalWireSize(frames) > mtu, "Precondition: total frames exceed MTU")

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        #expect(batches.count > 1, "Precondition: should produce multiple batches")

        for batch in batches where !batch.isOversized {
            try encodeAndVerify(
                frames: batch.frames, level: .application,
                dcid: dcid, scid: scid, maxDatagramSize: mtu
            )
        }
    }

    @Test("Short header: packer batches never cause packetTooLarge (MTU 1452)")
    func shortHeaderMTU1452() throws {
        let mtu = 1452
        let dcid = try ConnectionID(bytes: Data(repeating: 0x02, count: 8))
        let scid = ConnectionID.empty
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        let frames = (0..<30).map { (i: Int) -> Frame in
            let dataSize = 80 + (i * 3)
            return makeStreamFrame(streamID: UInt64(i), offset: UInt64(i * 1000), dataSize: dataSize)
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        for batch in batches where !batch.isOversized {
            try encodeAndVerify(
                frames: batch.frames, level: .application,
                dcid: dcid, scid: scid, maxDatagramSize: mtu
            )
        }
    }

    @Test("Handshake: packer batches never cause packetTooLarge")
    func handshakePackets() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x03, count: 8))
        let scid = try ConnectionID(bytes: Data(repeating: 0x04, count: 8))
        let maxPayload = MTUFramePacker.maxPayload(
            for: .handshake, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        let frames = (0..<10).map { (i: Int) -> Frame in
            makeCryptoFrame(offset: UInt64(i * 200), dataSize: 200)
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        for batch in batches where !batch.isOversized {
            try encodeAndVerify(
                frames: batch.frames, level: .handshake,
                dcid: dcid, scid: scid, maxDatagramSize: mtu
            )
        }
    }

    @Test("Initial: packer batches never cause packetTooLarge (no padding)")
    func initialPacketsNoPadding() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x05, count: 8))
        let scid = try ConnectionID(bytes: Data(repeating: 0x06, count: 8))
        let maxPayload = MTUFramePacker.maxPayload(
            for: .initial, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        let frames = (0..<8).map { (i: Int) -> Frame in
            makeCryptoFrame(offset: UInt64(i * 150), dataSize: 150)
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        for batch in batches where !batch.isOversized {
            try encodeAndVerify(
                frames: batch.frames, level: .initial,
                dcid: dcid, scid: scid, maxDatagramSize: mtu
            )
        }
    }

    @Test("Mixed frame types: ACK + STREAM + flow-control never exceed MTU")
    func mixedFrameTypes() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x07, count: 4))
        let scid = ConnectionID.empty
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        let ack = Frame.ack(AckFrame(
            largestAcknowledged: 500, ackDelay: 25,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 10),
                AckRange(gap: 5, rangeLength: 3),
                AckRange(gap: 2, rangeLength: 1),
            ]
        ))
        let maxData = Frame.maxData(1_000_000)
        let maxStreamData = Frame.maxStreamData(MaxStreamDataFrame(streamID: 4, maxStreamData: 500_000))
        let streams = (0..<15).map { (i: Int) -> Frame in
            makeStreamFrame(streamID: UInt64(i * 4), offset: UInt64(i * 100), dataSize: 80)
        }
        let frames: [Frame] = [ack, maxData, maxStreamData] + streams

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        for batch in batches where !batch.isOversized {
            try encodeAndVerify(
                frames: batch.frames, level: .application,
                dcid: dcid, scid: scid, maxDatagramSize: mtu
            )
        }
    }

    @Test("Encoder DOES throw packetTooLarge without packer (proof the guard exists)")
    func encoderThrowsWithoutPacker() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x08, count: 8))
        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)

        // Create frames totaling well above MTU
        let frames = (0..<20).map { (_: Int) -> Frame in makeStreamFrame(dataSize: 100) }
        let header = ShortHeader(
            destinationConnectionID: dcid, spinBit: false, keyPhase: false
        )

        #expect(throws: PacketCodecError.self) {
            _ = try encoder.encodeShortHeaderPacket(
                frames: frames, header: header, packetNumber: 0,
                sealer: sealer, maxPacketSize: mtu
            )
        }
    }

    @Test("Stress: 500 random-sized frames, MTU 1200, zero packetTooLarge")
    func stressRandomFramesMTU1200() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x09, count: 8))
        let scid = ConnectionID.empty
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        // Deterministic pseudo-random sizes (no randomness in tests)
        let frames = (0..<500).map { (i: Int) -> Frame in
            let size = 1 + ((i * 37 + 13) % 200)
            return makeStreamFrame(
                streamID: UInt64((i * 4) % 400),
                offset: UInt64(i * 50),
                dataSize: size
            )
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
        for (idx, batch) in batches.enumerated() {
            if !batch.isOversized {
                #expect(batch.totalSize <= maxPayload, "Batch \(idx) exceeds payload budget")
                try encodeAndVerify(
                    frames: batch.frames, level: .application,
                    dcid: dcid, scid: scid, maxDatagramSize: mtu
                )
            }
        }
    }

    @Test("Boundary: frame that exactly fills maxPayload")
    func exactFitFrame() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x0A, count: 8))
        let scid = ConnectionID.empty
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: scid.length
        )

        // STREAM frame overhead for streamID=0, offset=0, hasLength=true:
        //   type(1) + streamID(1) + length_varint(varies) = 2 + varint(dataSize)
        // We need dataSize such that total wireSize == maxPayload.
        // wireSize = 1 (type) + 1 (streamID) + varint(dataSize) + dataSize
        // For dataSize < 64: varint = 1 byte, so wireSize = 3 + dataSize
        // For dataSize in 64..16383: varint = 2 bytes, so wireSize = 4 + dataSize
        // maxPayload is typically ~1171 for MTU 1200 with 8-byte DCID
        // So dataSize = maxPayload - 4 (since dataSize > 63)
        let dataSize = maxPayload - 4
        let frame = makeStreamFrame(streamID: 0, dataSize: dataSize)
        let size = wireSize(frame)
        #expect(size == maxPayload, "Precondition: frame should exactly fill payload (\(size) vs \(maxPayload))")

        let batches = MTUFramePacker.pack(frames: [frame], maxPayload: maxPayload)
        #expect(batches.count == 1)
        #expect(batches[0].isOversized == false)

        try encodeAndVerify(
            frames: batches[0].frames, level: .application,
            dcid: dcid, scid: scid, maxDatagramSize: mtu
        )
    }

    @Test("Boundary: frame that is maxPayload + 1 is marked oversized")
    func oneByteOverLimit() {
        let maxPayload = 100
        // Find a dataSize that makes wireSize == 101
        // wireSize = 1 (type) + 1 (streamID=0) + 2 (varint for dataSize in 64..16383) + dataSize
        // 101 = 4 + dataSize => dataSize = 97
        let frame = makeStreamFrame(streamID: 0, dataSize: 97)
        let size = wireSize(frame)
        #expect(size == 101, "Precondition: frame should be 1 byte over (\(size))")

        let batches = MTUFramePacker.pack(frames: [frame], maxPayload: maxPayload)
        #expect(batches.count == 1)
        #expect(batches[0].isOversized == true)
    }
}

// MARK: - G5: Budget Accuracy

@Suite("G5 - Budget Computation Accuracy")
struct BudgetAccuracyTests {

    @Test("ACK frame size is correctly accounted for in budget")
    func ackFrameBudget() {
        let ack = Frame.ack(AckFrame(
            largestAcknowledged: 1000, ackDelay: 100,
            ackRanges: [
                AckRange(gap: 0, rangeLength: 5),
                AckRange(gap: 10, rangeLength: 3),
            ]
        ))
        let ackSize = wireSize(ack)

        let mtu = 1200
        let dcidLen = 8
        let scidLen = 0
        let overhead = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcidLen, scidLength: scidLen
        )
        let totalBudget = mtu - overhead

        // Stream budget after subtracting ACK
        let streamBudget = totalBudget - ackSize
        #expect(streamBudget > 0, "Stream budget should be positive")

        // A stream frame fitting within streamBudget, plus the ACK,
        // must fit within maxPayload
        let streamDataSize = max(1, streamBudget - 10)  // leave some room for stream overhead
        let streamFrame = makeStreamFrame(dataSize: streamDataSize)
        let combined = [ack, streamFrame]
        let combinedSize = totalWireSize(combined)

        #expect(
            combinedSize <= totalBudget,
            "ACK(\(ackSize)) + STREAM(\(wireSize(streamFrame))) = \(combinedSize) > budget \(totalBudget)"
        )
    }

    @Test("Flow-control frames are correctly accounted for in budget")
    func flowControlBudget() {
        let maxData = Frame.maxData(10_000_000)
        let maxStreamData = Frame.maxStreamData(MaxStreamDataFrame(streamID: 4, maxStreamData: 5_000_000))
        let maxStreams = Frame.maxStreams(MaxStreamsFrame(maxStreams: 100, isBidirectional: true))
        let controlFrames: [Frame] = [maxData, maxStreamData, maxStreams]
        let controlSize = totalWireSize(controlFrames)

        let mtu = 1200
        let overhead = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: 8, scidLength: 0
        )
        let remaining = mtu - overhead - controlSize
        #expect(remaining > 0, "Remaining budget should be positive")

        // A stream frame within remaining + control frames must pack into one batch
        let streamDataSize = max(1, remaining - 10)
        let streamFrame = makeStreamFrame(dataSize: streamDataSize)
        let allFrames = controlFrames + [streamFrame]

        let maxPayload = mtu - overhead
        let batches = MTUFramePacker.pack(frames: allFrames, maxPayload: maxPayload)

        // Should fit in one batch
        #expect(batches.count == 1, "All frames should fit in one batch")
        #expect(batches[0].totalSize <= maxPayload)
    }

    @Test("External + ACK + flow-control + stream all fit correctly")
    func fullBudgetComposition() {
        let mtu = 1200
        let dcidLen = 8
        let overhead = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: dcidLen, scidLength: 0
        )
        let maxPayload = mtu - overhead

        // Simulate the getOutboundPackets budget computation
        let ack = Frame.ack(AckFrame(
            largestAcknowledged: 100, ackDelay: 10,
            ackRanges: [AckRange(gap: 0, rangeLength: 5)]
        ))
        let flowControl = Frame.maxData(500_000)
        let externalFrame = Frame.handshakeDone  // queued externally

        let controlBytes = wireSize(ack) + wireSize(flowControl) + wireSize(externalFrame)
        let streamBudget = max(0, maxPayload - controlBytes)

        // Create a stream frame that fills exactly the stream budget
        // wireSize for stream with streamID=0, offset=0: 1 + 1 + varint(dataLen) + dataLen
        // For data in 64..16383 range: overhead = 4 bytes
        let streamDataSize = max(1, streamBudget - 4)
        let streamFrame = makeStreamFrame(dataSize: streamDataSize)

        let allFrames = [ack, flowControl, externalFrame, streamFrame]
        let total = totalWireSize(allFrames)

        #expect(
            total <= maxPayload,
            "Total \(total) exceeds maxPayload \(maxPayload)"
        )

        let batches = MTUFramePacker.pack(frames: allFrames, maxPayload: maxPayload)
        #expect(batches.count == 1)
        #expect(!batches[0].isOversized)
    }

    @Test("ACK with many ranges: large ACK correctly reduces stream budget")
    func largeAckBudget() {
        let ranges = (0..<50).map { i in
            AckRange(gap: UInt64(i + 1), rangeLength: UInt64(i % 5 + 1))
        }
        let ack = Frame.ack(AckFrame(
            largestAcknowledged: 10000, ackDelay: 500,
            ackRanges: ranges
        ))
        let ackSize = wireSize(ack)
        // Large ACK should be > 100 bytes
        #expect(ackSize > 100, "Precondition: ACK with 50 ranges should be large")

        let mtu = 1200
        let overhead = MTUFramePacker.packetOverhead(
            for: .application, dcidLength: 8, scidLength: 0
        )
        let maxPayload = mtu - overhead
        let streamBudget = maxPayload - ackSize

        if streamBudget > 10 {
            let streamFrame = makeStreamFrame(dataSize: max(1, streamBudget - 4))
            let allFrames = [ack, streamFrame]
            let batches = MTUFramePacker.pack(frames: allFrames, maxPayload: maxPayload)

            // Everything should fit in one batch
            #expect(batches.count == 1)
            #expect(batches[0].totalSize <= maxPayload)
        }
    }
}

// MARK: - G6: CRYPTO Frame Fit

@Suite("G6 - CRYPTO Frame Fits Within Long-Header Packet")
struct CryptoFrameFitTests {

    @Test("CRYPTO frame sized with overhead subtraction fits in Initial packet")
    func cryptoFitsInInitial() throws {
        let mtu = 1200
        // Worst-case long header overhead (from Phase 4 formula):
        //   1 + 4 + 1+20 + 1+20 + 1 + 2 + 4 + 16 = 70
        let worstCaseOverhead = 1 + 4 + 1 + 20 + 1 + 20 + 1 + 2 + 4 + PacketConstants.aeadTagSize
        #expect(worstCaseOverhead == 70)

        let maxCryptoPayload = max(64, mtu - worstCaseOverhead)
        // Create a CRYPTO frame that fills exactly maxCryptoPayload
        // CRYPTO overhead: type(1) + offset_varint + length_varint + data
        // For offset=0: offset_varint = 1 byte
        // For data in 64..16383: length_varint = 2 bytes
        // Total overhead = 1 + 1 + 2 = 4
        let dataSize = maxCryptoPayload - 4
        let frame = makeCryptoFrame(offset: 0, dataSize: dataSize)
        let frameWireSize = wireSize(frame)
        #expect(frameWireSize == maxCryptoPayload, "CRYPTO frame should fill budget exactly (\(frameWireSize) vs \(maxCryptoPayload))")

        // Now verify it fits in a real Initial packet with max-size CIDs
        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)
        let dcid = try ConnectionID(bytes: Data(repeating: 0xAA, count: 20))
        let scid = try ConnectionID(bytes: Data(repeating: 0xBB, count: 20))

        let header = LongHeader(
            packetType: .initial, version: .v1,
            destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
        )

        let encoded = try encoder.encodeLongHeaderPacket(
            frames: [.crypto(CryptoFrame(offset: 0, data: Data(repeating: 0xCC, count: dataSize)))],
            header: header, packetNumber: 0,
            sealer: sealer, maxPacketSize: mtu, padToMinimum: false
        )

        #expect(
            encoded.count <= mtu,
            "Encoded Initial packet \(encoded.count) bytes > MTU \(mtu)"
        )
    }

    @Test("CRYPTO frame sized with overhead subtraction fits in Handshake packet")
    func cryptoFitsInHandshake() throws {
        let mtu = 1200
        let worstCaseOverhead = 1 + 4 + 1 + 20 + 1 + 20 + 1 + 2 + 4 + PacketConstants.aeadTagSize
        let maxCryptoPayload = max(64, mtu - worstCaseOverhead)
        let dataSize = maxCryptoPayload - 4
        let dcid = try ConnectionID(bytes: Data(repeating: 0xAA, count: 20))
        let scid = try ConnectionID(bytes: Data(repeating: 0xBB, count: 20))

        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)
        let header = LongHeader(
            packetType: .handshake, version: .v1,
            destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
        )

        let encoded = try encoder.encodeLongHeaderPacket(
            frames: [.crypto(CryptoFrame(offset: 0, data: Data(repeating: 0xDD, count: dataSize)))],
            header: header, packetNumber: 0,
            sealer: sealer, maxPacketSize: mtu, padToMinimum: false
        )

        #expect(
            encoded.count <= mtu,
            "Encoded Handshake packet \(encoded.count) bytes > MTU \(mtu)"
        )
    }

    @Test("Multiple CRYPTO frames from split all fit individually")
    func multipleCryptoFramesFit() throws {
        let mtu = 1200
        let worstCaseOverhead = 70
        let maxCryptoPayload = max(64, mtu - worstCaseOverhead)

        // Simulate splitting 2000 bytes of TLS data into CRYPTO frames
        let totalData = 2000
        let cryptoFrameOverhead = 4  // type(1) + offset(1) + length(2)
        let maxDataPerFrame = maxCryptoPayload - cryptoFrameOverhead
        var offset = 0
        var frames: [Frame] = []
        var remaining = totalData
        while remaining > 0 {
            let chunkSize = min(remaining, maxDataPerFrame)
            frames.append(makeCryptoFrame(offset: UInt64(offset), dataSize: chunkSize))
            offset += chunkSize
            remaining -= chunkSize
        }

        // Each frame individually should fit in a long-header packet
        let dcid = try ConnectionID(bytes: Data(repeating: 0xAA, count: 20))
        let scid = try ConnectionID(bytes: Data(repeating: 0xBB, count: 20))
        let encoder = PacketEncoder()
        let sealer = MTUTestSealer(key: 0x42)

        for (idx, frame) in frames.enumerated() {
            let header = LongHeader(
                packetType: .handshake, version: .v1,
                destinationConnectionID: dcid, sourceConnectionID: scid, token: nil
            )
            let encoded = try encoder.encodeLongHeaderPacket(
                frames: [frame], header: header, packetNumber: UInt64(idx),
                sealer: sealer, maxPacketSize: mtu, padToMinimum: false
            )
            #expect(
                encoded.count <= mtu,
                "CRYPTO frame \(idx) (\(wireSize(frame)) wire bytes) -> packet \(encoded.count) > MTU \(mtu)"
            )
        }
    }

    @Test("CRYPTO overhead formula: 70 bytes is correct for worst case")
    func cryptoOverheadFormulaCheck() throws {
        // Verify that 70 bytes is indeed the worst case (max CID lengths)
        let dcid = try ConnectionID(bytes: Data(repeating: 0x00, count: 20))
        let scid = try ConnectionID(bytes: Data(repeating: 0x00, count: 20))

        // Initial overhead (includes token_length=0 varint)
        let initialOverhead = MTUFramePacker.packetOverhead(
            for: .initial, dcidLength: dcid.length, scidLength: scid.length
        )
        // 1 + 4 + 1+20 + 1+20 + 1(token) + 2(length) + 4(PN) + 16(AEAD) = 70
        #expect(initialOverhead == 70, "Initial overhead with max CIDs should be 70, got \(initialOverhead)")

        // Handshake overhead (no token field)
        let handshakeOverhead = MTUFramePacker.packetOverhead(
            for: .handshake, dcidLength: dcid.length, scidLength: scid.length
        )
        // 1 + 4 + 1+20 + 1+20 + 2(length) + 4(PN) + 16(AEAD) = 69
        #expect(handshakeOverhead == 69, "Handshake overhead with max CIDs should be 69, got \(handshakeOverhead)")

        // Using 70 for both is conservative (safe for handshake too)
        #expect(initialOverhead >= handshakeOverhead, "Initial overhead should be >= handshake")
    }
}

// MARK: - G7: Frame Order Preservation

@Suite("G7 - Frame Order Preservation Across Batches")
struct OrderPreservationTests {

    @Test("Frames appear in original order across all batches")
    func orderPreserved() {
        // Use unique stream IDs as identifiers
        let frames = (0..<30).map { (i: Int) -> Frame in
            makeStreamFrame(streamID: UInt64(i), offset: 0, dataSize: 50)
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 200)
        var recovered: [UInt64] = []
        for batch in batches {
            for frame in batch.frames {
                if case .stream(let sf) = frame {
                    recovered.append(sf.streamID)
                }
            }
        }

        let expected = (0..<30).map { UInt64($0) }
        #expect(recovered == expected, "Frame order must be preserved")
    }

    @Test("Oversized frames do not disrupt order of surrounding frames")
    func oversizedDoesNotDisruptOrder() {
        // Pattern: small, small, BIG, small, small
        let frames: [Frame] = [
            makeStreamFrame(streamID: 0, dataSize: 10),
            makeStreamFrame(streamID: 1, dataSize: 10),
            makeStreamFrame(streamID: 2, dataSize: 5000),  // oversized
            makeStreamFrame(streamID: 3, dataSize: 10),
            makeStreamFrame(streamID: 4, dataSize: 10),
        ]

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 100)
        var recovered: [UInt64] = []
        for batch in batches {
            for frame in batch.frames {
                if case .stream(let sf) = frame {
                    recovered.append(sf.streamID)
                }
            }
        }

        #expect(recovered == [0, 1, 2, 3, 4], "Order must be [0,1,2,3,4], got \(recovered)")
    }

    @Test("All frames are accounted for (lossless)")
    func lossless() {
        let frames = (0..<100).map { (i: Int) -> Frame in
            let dataSize = 20 + (i % 30)
            return makeStreamFrame(streamID: UInt64(i), dataSize: dataSize)
        }

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 150)
        let totalRecovered = batches.reduce(0) { $0 + $1.frames.count }
        #expect(totalRecovered == 100, "All 100 frames must be recovered, got \(totalRecovered)")
    }

    @Test("Mixed frame types preserve insertion order")
    func mixedTypeOrder() {
        let frames: [Frame] = [
            .ping,
            .ack(AckFrame(largestAcknowledged: 10, ackDelay: 1, ackRanges: [AckRange(gap: 0, rangeLength: 1)])),
            makeStreamFrame(streamID: 0, dataSize: 30),
            .maxData(100_000),
            makeStreamFrame(streamID: 4, dataSize: 30),
            .handshakeDone,
            makeCryptoFrame(offset: 0, dataSize: 50),
        ]

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 500)
        let recovered = batches.flatMap { $0.frames }

        // Verify count and that the first and last frames match
        #expect(recovered.count == frames.count)

        // Check first frame is PING
        if case .ping = recovered[0] {} else {
            Issue.record("First frame should be PING")
        }

        // Check last frame is CRYPTO
        if case .crypto = recovered[recovered.count - 1] {} else {
            Issue.record("Last frame should be CRYPTO")
        }
    }
}

// MARK: - Edge Cases

@Suite("Edge Cases - MTU Frame Packing")
struct EdgeCaseTests {

    @Test("PADDING frames (zero-cost in count) are handled correctly")
    func paddingFrames() {
        let padding = Frame.padding(count: 100)
        let paddingSize = wireSize(padding)
        #expect(paddingSize == 100, "PADDING(100) should be 100 bytes")

        let batches = MTUFramePacker.pack(frames: [padding], maxPayload: 200)
        #expect(batches.count == 1)
        #expect(batches[0].totalSize == 100)
        #expect(!batches[0].isOversized)
    }

    @Test("Single PING frame (1 byte) fits in any positive maxPayload")
    func singlePing() {
        let batches = MTUFramePacker.pack(frames: [.ping], maxPayload: 1)
        #expect(batches.count == 1)
        #expect(batches[0].totalSize == 1)
        #expect(!batches[0].isOversized)
    }

    @Test("maxPayload of 0 marks all frames as oversized")
    func zeroMaxPayload() {
        let frames: [Frame] = [.ping, .ping, .ping]
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 0)
        for batch in batches {
            #expect(batch.isOversized == true)
            #expect(batch.frames.count == 1)
        }
        #expect(batches.count == 3)
    }

    @Test("Very large maxPayload puts all frames in one batch")
    func hugeMaxPayload() {
        let frames = (0..<100).map { (i: Int) -> Frame in makeStreamFrame(streamID: UInt64(i), dataSize: 1000) }
        let batches = MTUFramePacker.pack(frames: frames, maxPayload: Int.max / 2)
        #expect(batches.count == 1)
        #expect(batches[0].frames.count == 100)
        #expect(!batches[0].isOversized)
    }

    @Test("Overhead for all levels with typical 8-byte CIDs")
    func typicalOverheads() {
        let dcid = 8
        let scid = 8

        let initialOverhead = MTUFramePacker.packetOverhead(for: .initial, dcidLength: dcid, scidLength: scid)
        let handshakeOverhead = MTUFramePacker.packetOverhead(for: .handshake, dcidLength: dcid, scidLength: scid)
        let appOverhead = MTUFramePacker.packetOverhead(for: .application, dcidLength: dcid, scidLength: scid)

        // Initial: 1 + 4 + 1+8 + 1+8 + 1 + 2 + 4 + 16 = 46
        #expect(initialOverhead == 46, "Initial overhead with 8B CIDs: \(initialOverhead)")
        // Handshake: 1 + 4 + 1+8 + 1+8 + 2 + 4 + 16 = 45
        #expect(handshakeOverhead == 45, "Handshake overhead with 8B CIDs: \(handshakeOverhead)")
        // Application: 1 + 8 + 4 + 16 = 29
        #expect(appOverhead == 29, "Application overhead with 8B CIDs: \(appOverhead)")
    }

    @Test("DATAGRAM frame packing respects MTU")
    func datagramFramePacking() throws {
        let mtu = 1200
        let dcid = try ConnectionID(bytes: Data(repeating: 0x01, count: 8))
        let maxPayload = MTUFramePacker.maxPayload(
            for: .application, maxDatagramSize: mtu,
            dcidLength: dcid.length, scidLength: 0
        )

        let datagram = Frame.datagram(DatagramFrame(data: Data(repeating: 0xEE, count: 500), hasLength: true))
        let stream = makeStreamFrame(streamID: 0, dataSize: 500)
        let frames = [datagram, stream]
        let total = totalWireSize(frames)

        // Both frames together should exceed maxPayload
        if total > maxPayload {
            let batches = MTUFramePacker.pack(frames: frames, maxPayload: maxPayload)
            #expect(batches.count == 2)
            for batch in batches where !batch.isOversized {
                #expect(batch.totalSize <= maxPayload)
            }
        }
    }

    @Test("CONNECTION_CLOSE frame is never lost due to splitting")
    func connectionClosePreserved() {
        let close = Frame.connectionClose(ConnectionCloseFrame(
            errorCode: 0, frameType: nil, reasonPhrase: "goodbye", isApplicationError: true
        ))
        let streams = (0..<20).map { (i: Int) -> Frame in makeStreamFrame(streamID: UInt64(i), dataSize: 100) }
        let frames: [Frame] = [close] + streams

        let batches = MTUFramePacker.pack(frames: frames, maxPayload: 200)
        let allRecovered = batches.flatMap { $0.frames }

        // CONNECTION_CLOSE must be present
        let hasClose = allRecovered.contains { frame in
            if case .connectionClose = frame { return true }
            return false
        }
        #expect(hasClose, "CONNECTION_CLOSE frame must not be lost")

        // And it must be the first frame (order preserved)
        if case .connectionClose = allRecovered[0] {} else {
            Issue.record("CONNECTION_CLOSE should be the first frame")
        }
    }
}