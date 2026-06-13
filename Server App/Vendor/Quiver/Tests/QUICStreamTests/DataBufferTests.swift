/// DataBuffer Unit Tests
///
/// Tests for stream data buffer with offset-based reassembly.

import Testing
import Foundation
@testable import QUICStream

@Suite("DataBuffer Tests")
struct DataBufferTests {

    // MARK: - Basic Insertion Tests

    @Test("Insert single segment")
    func insertSingleSegment() throws {
        var buffer = DataBuffer()
        let data = Data([0x01, 0x02, 0x03, 0x04])

        try buffer.insert(offset: 0, data: data, fin: false)

        #expect(buffer.totalBytes == 4)
        #expect(buffer.segmentCount == 1)
        #expect(!buffer.hasGap)
    }

    @Test("Insert sequential segments - merges")
    func insertSequentialSegments() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02]), fin: false)
        try buffer.insert(offset: 2, data: Data([0x03, 0x04]), fin: false)

        #expect(buffer.totalBytes == 4)
        #expect(buffer.segmentCount == 1)  // Should merge
        #expect(!buffer.hasGap)
    }

    @Test("Insert with gap - creates multiple segments")
    func insertWithGap() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02]), fin: false)
        try buffer.insert(offset: 5, data: Data([0x06, 0x07]), fin: false)

        #expect(buffer.totalBytes == 4)
        #expect(buffer.segmentCount == 2)
        #expect(!buffer.hasGap)  // No gap at readOffset (0)
    }

    @Test("Insert out of order - fills gap")
    func insertOutOfOrder() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02]), fin: false)
        try buffer.insert(offset: 5, data: Data([0x06, 0x07]), fin: false)
        try buffer.insert(offset: 2, data: Data([0x03, 0x04, 0x05]), fin: false)

        #expect(buffer.totalBytes == 7)
        #expect(buffer.segmentCount == 1)  // All merged
    }

    // MARK: - Overlapping Segment Tests

    @Test("Insert overlapping segment - deduplicates")
    func insertOverlappingSegment() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03, 0x04]), fin: false)
        try buffer.insert(offset: 2, data: Data([0x03, 0x04, 0x05, 0x06]), fin: false)

        #expect(buffer.totalBytes == 6)  // 0-5, no duplicate
        #expect(buffer.segmentCount == 1)
    }

    @Test("Insert completely contained segment - ignored")
    func insertContainedSegment() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03, 0x04]), fin: false)
        try buffer.insert(offset: 1, data: Data([0x02, 0x03]), fin: false)

        #expect(buffer.totalBytes == 4)  // No change
        #expect(buffer.segmentCount == 1)
    }

    @Test("Insert duplicate segment - no double counting")
    func insertDuplicateSegment() throws {
        var buffer = DataBuffer()
        let data = Data([0x01, 0x02, 0x03])

        try buffer.insert(offset: 0, data: data, fin: false)
        try buffer.insert(offset: 0, data: data, fin: false)

        #expect(buffer.totalBytes == 3)
        #expect(buffer.segmentCount == 1)
    }

    // MARK: - Read Tests

    @Test("Read contiguous data")
    func readContiguousData() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)

        let data = buffer.readContiguous()

        #expect(data == Data([0x01, 0x02, 0x03]))
        #expect(buffer.readOffset == 3)
        #expect(buffer.isEmpty)
    }

    @Test("Read returns nil when gap exists")
    func readReturnsNilWithGap() throws {
        var buffer = DataBuffer()

        // Insert data starting at offset 5 (gap at 0-4)
        try buffer.insert(offset: 5, data: Data([0x06, 0x07]), fin: false)

        let data = buffer.readContiguous()

        #expect(data == nil)
        #expect(buffer.readOffset == 0)
        #expect(buffer.hasGap)
    }

    @Test("Read all contiguous spans multiple segments")
    func readAllContiguous() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02]), fin: false)
        try buffer.insert(offset: 2, data: Data([0x03, 0x04]), fin: false)

        let data = buffer.readAllContiguous()

        #expect(data == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(buffer.readOffset == 4)
        #expect(buffer.isEmpty)
    }

    @Test("Peek does not consume data")
    func peekDoesNotConsume() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)

        let peeked = buffer.peekContiguous()
        let read = buffer.readContiguous()

        #expect(peeked == read)
        #expect(read == Data([0x01, 0x02, 0x03]))
    }

    // MARK: - FIN Tests

    @Test("FIN sets final size")
    func finSetsFinalSize() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: true)

        #expect(buffer.finalSize == 3)
        #expect(buffer.finalSizeKnown)
    }

    @Test("Empty data with FIN is valid")
    func emptyDataWithFin() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)
        try buffer.insert(offset: 3, data: Data(), fin: true)

        #expect(buffer.finalSize == 3)
        #expect(buffer.totalBytes == 3)
    }

    @Test("FIN mismatch throws error")
    func finMismatchThrows() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: true)

        #expect(throws: DataBufferError.self) {
            try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03, 0x04]), fin: true)
        }
    }

    @Test("Data exceeding final size throws error")
    func dataExceedsFinalSizeThrows() throws {
        var buffer = DataBuffer()

        // Set final size to 3
        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: true)

        // Try to insert data beyond final size
        #expect(throws: DataBufferError.self) {
            try buffer.insert(offset: 2, data: Data([0x03, 0x04, 0x05]), fin: false)
        }
    }

    @Test("isComplete when all data received")
    func isCompleteWhenAllDataReceived() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: true)

        #expect(!buffer.isComplete)  // Not read yet

        _ = buffer.readContiguous()

        #expect(buffer.isComplete)  // Now complete
    }

    // MARK: - Buffer Overflow Tests

    @Test("Buffer overflow throws error")
    func bufferOverflowThrows() throws {
        var buffer = DataBuffer(maxBufferSize: 10)

        try buffer.insert(offset: 0, data: Data(repeating: 0x00, count: 5), fin: false)

        #expect(throws: DataBufferError.self) {
            try buffer.insert(offset: 5, data: Data(repeating: 0x01, count: 10), fin: false)
        }
    }

    // MARK: - Already Read Data Tests

    @Test("Insert already-read data is ignored")
    func insertAlreadyReadDataIgnored() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)
        _ = buffer.readContiguous()

        // Try to insert data that was already read
        try buffer.insert(offset: 0, data: Data([0x01, 0x02]), fin: false)

        #expect(buffer.totalBytes == 0)
        #expect(buffer.readOffset == 3)
    }

    @Test("Insert partially-read data is trimmed")
    func insertPartiallyReadDataTrimmed() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)
        _ = buffer.readContiguous()  // readOffset = 3

        // Insert data that overlaps with already-read portion
        try buffer.insert(offset: 2, data: Data([0x03, 0x04, 0x05]), fin: false)

        #expect(buffer.totalBytes == 2)  // Only 0x04, 0x05
        #expect(buffer.contiguousBytesAvailable == 2)
    }

    // MARK: - Edge Cases

    @Test("Empty buffer state")
    func emptyBufferState() {
        let buffer = DataBuffer()

        #expect(buffer.isEmpty)
        #expect(buffer.totalBytes == 0)
        #expect(buffer.segmentCount == 0)
        #expect(buffer.readOffset == 0)
        #expect(buffer.finalSize == nil)
        #expect(!buffer.finalSizeKnown)
        #expect(!buffer.isComplete)
        #expect(!buffer.hasGap)
    }

    @Test("Insert empty data without FIN - no effect")
    func insertEmptyDataNoEffect() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data(), fin: false)

        #expect(buffer.isEmpty)
        #expect(buffer.totalBytes == 0)
    }

    @Test("Reset clears all state")
    func resetClearsState() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: true)
        _ = buffer.readContiguous()

        buffer.reset()

        #expect(buffer.isEmpty)
        #expect(buffer.totalBytes == 0)
        #expect(buffer.readOffset == 0)
        #expect(buffer.finalSize == nil)
    }

    @Test("Remaining bytes calculation")
    func remainingBytesCalculation() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03, 0x04, 0x05]), fin: true)

        #expect(buffer.remainingBytes == 5)

        _ = buffer.readContiguous()

        #expect(buffer.remainingBytes == 0)
    }

    @Test("Remaining bytes nil when final size unknown")
    func remainingBytesNilWhenUnknown() throws {
        var buffer = DataBuffer()

        try buffer.insert(offset: 0, data: Data([0x01, 0x02, 0x03]), fin: false)

        #expect(buffer.remainingBytes == nil)
    }

    // MARK: - Complex Reassembly Tests

    @Test("Complex out-of-order reassembly")
    func complexOutOfOrderReassembly() throws {
        var buffer = DataBuffer()

        // Insert in random order: 10-15, 0-5, 20-25, 5-10, 15-20
        try buffer.insert(offset: 10, data: Data([10, 11, 12, 13, 14]), fin: false)
        try buffer.insert(offset: 0, data: Data([0, 1, 2, 3, 4]), fin: false)
        try buffer.insert(offset: 20, data: Data([20, 21, 22, 23, 24]), fin: true)
        try buffer.insert(offset: 5, data: Data([5, 6, 7, 8, 9]), fin: false)
        try buffer.insert(offset: 15, data: Data([15, 16, 17, 18, 19]), fin: false)

        #expect(buffer.segmentCount == 1)  // All merged
        #expect(buffer.totalBytes == 25)
        #expect(buffer.finalSize == 25)

        let data = buffer.readAllContiguous()
        #expect(data?.count == 25)
        #expect(buffer.isComplete)
    }

    @Test("Multiple reads with gaps filling")
    func multipleReadsWithGapsFilling() throws {
        var buffer = DataBuffer()

        // First batch: 0-3, 10-13
        try buffer.insert(offset: 0, data: Data([0, 1, 2]), fin: false)
        try buffer.insert(offset: 10, data: Data([10, 11, 12]), fin: false)

        // Read first segment
        let first = buffer.readContiguous()
        #expect(first == Data([0, 1, 2]))
        #expect(buffer.hasGap)  // Gap at 3-9

        // Fill gap
        try buffer.insert(offset: 3, data: Data([3, 4, 5, 6, 7, 8, 9]), fin: false)

        // Now should be able to read everything
        let rest = buffer.readAllContiguous()
        #expect(rest == Data([3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
    }

    // MARK: - FIN Validation Tests (Issue A)

    @Test("FIN received after out-of-order data beyond final size throws error")
    func finAfterDataBeyondFinalSize() throws {
        var buffer = DataBuffer()

        // First receive data at offset 100
        try buffer.insert(offset: 100, data: Data(repeating: 0, count: 50), fin: false)

        // Then receive FIN at offset 50 - should fail because buffered data exceeds it
        #expect(throws: DataBufferError.self) {
            try buffer.insert(offset: 0, data: Data(repeating: 0, count: 50), fin: true)
        }
    }

    @Test("FIN with data that matches buffered segments succeeds")
    func finMatchingBufferedData() throws {
        var buffer = DataBuffer()

        // First receive data at offset 50
        try buffer.insert(offset: 50, data: Data(repeating: 0, count: 50), fin: false)

        // Then receive FIN at offset 100 - should succeed
        try buffer.insert(offset: 0, data: Data(repeating: 0, count: 50), fin: false)
        try buffer.insert(offset: 100, data: Data(), fin: true)

        #expect(buffer.finalSize == 100)
        #expect(buffer.totalBytes == 100)
    }

    // MARK: - Buffer Overflow with Overlaps Tests (Issue B)

    @Test("Duplicate data does not trigger false buffer overflow")
    func duplicateDataNoFalseOverflow() throws {
        var buffer = DataBuffer(maxBufferSize: 100)

        // Fill to 90 bytes
        try buffer.insert(offset: 0, data: Data(repeating: 0, count: 90), fin: false)

        // Insert 20 bytes that completely overlap - should NOT overflow
        try buffer.insert(offset: 0, data: Data(repeating: 0, count: 20), fin: false)

        #expect(buffer.totalBytes == 90)
    }

    @Test("Partially overlapping data calculates correct overflow")
    func partialOverlapCorrectOverflow() throws {
        var buffer = DataBuffer(maxBufferSize: 100)

        // Fill to 90 bytes (offset 0-90)
        try buffer.insert(offset: 0, data: Data(repeating: 0, count: 90), fin: false)

        // Insert 20 bytes at offset 80 (10 overlap, 10 new) - total 100, should succeed
        try buffer.insert(offset: 80, data: Data(repeating: 0, count: 20), fin: false)

        #expect(buffer.totalBytes == 100)

        // Insert 1 more byte - should overflow
        #expect(throws: DataBufferError.self) {
            try buffer.insert(offset: 100, data: Data([1]), fin: false)
        }
    }

    @Test("Large overlapping insert at buffer limit succeeds")
    func largeOverlappingInsertAtLimit() throws {
        var buffer = DataBuffer(maxBufferSize: 100)

        // Fill to 100 bytes
        try buffer.insert(offset: 0, data: Data(repeating: 0, count: 100), fin: false)

        // Insert 50 bytes that completely overlap - should succeed (no new bytes)
        try buffer.insert(offset: 25, data: Data(repeating: 0, count: 50), fin: false)

        #expect(buffer.totalBytes == 100)
    }
}
