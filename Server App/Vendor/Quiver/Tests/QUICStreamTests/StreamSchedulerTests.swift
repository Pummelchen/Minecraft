/// StreamScheduler Unit Tests
///
/// Tests for priority-based stream scheduling with fair queuing.

import Testing
import Foundation
@testable import QUICStream

@Suite("StreamScheduler Tests")
struct StreamSchedulerTests {

    // Helper to create a DataStream with specific priority
    private func makeStream(
        id: UInt64,
        priority: StreamPriority = .default
    ) -> DataStream {
        DataStream(
            id: id,
            isClient: true,
            initialSendMaxData: 10000,
            initialRecvMaxData: 10000,
            priority: priority
        )
    }

    // MARK: - Basic Scheduling

    @Test("Empty streams returns empty result")
    func emptyStreamsReturnsEmpty() {
        var scheduler = StreamScheduler()
        let streams: [UInt64: DataStream] = [:]

        let result = scheduler.scheduleStreams(streams)

        #expect(result.isEmpty)
    }

    @Test("Single stream returns that stream")
    func singleStreamReturnsStream() {
        var scheduler = StreamScheduler()
        let stream = makeStream(id: 0, priority: .default)
        let streams: [UInt64: DataStream] = [0: stream]

        let result = scheduler.scheduleStreams(streams)

        #expect(result.count == 1)
        #expect(result[0].streamID == 0)
    }

    // MARK: - Priority Ordering

    @Test("Higher priority streams scheduled first")
    func higherPriorityFirst() {
        var scheduler = StreamScheduler()

        let lowPriority = makeStream(id: 0, priority: .lowest)     // urgency 7
        let highPriority = makeStream(id: 4, priority: .highest)   // urgency 0
        let mediumPriority = makeStream(id: 8, priority: .default) // urgency 3

        let streams: [UInt64: DataStream] = [
            0: lowPriority,
            4: highPriority,
            8: mediumPriority
        ]

        let result = scheduler.scheduleStreams(streams)

        #expect(result.count == 3)
        #expect(result[0].streamID == 4)  // Highest priority first
        #expect(result[1].streamID == 8)  // Default priority second
        #expect(result[2].streamID == 0)  // Lowest priority last
    }

    @Test("Streams sorted by priority urgency")
    func streamsSortedByUrgency() {
        var scheduler = StreamScheduler()

        let streams: [UInt64: DataStream] = [
            0: makeStream(id: 0, priority: StreamPriority(urgency: 5, incremental: false)),
            4: makeStream(id: 4, priority: StreamPriority(urgency: 1, incremental: false)),
            8: makeStream(id: 8, priority: StreamPriority(urgency: 3, incremental: false)),
            12: makeStream(id: 12, priority: StreamPriority(urgency: 7, incremental: false))
        ]

        let result = scheduler.scheduleStreams(streams)

        let urgencies = result.map { $0.stream.priority.urgency }
        #expect(urgencies == [1, 3, 5, 7])
    }

    // MARK: - Same Priority Ordering

    @Test("Same priority streams sorted by stream ID for determinism")
    func samePrioritySortedByID() {
        var scheduler = StreamScheduler()

        // All have default priority (urgency 3)
        let streams: [UInt64: DataStream] = [
            12: makeStream(id: 12, priority: .default),
            0: makeStream(id: 0, priority: .default),
            8: makeStream(id: 8, priority: .default),
            4: makeStream(id: 4, priority: .default)
        ]

        let result = scheduler.scheduleStreams(streams)

        let ids = result.map { $0.streamID }
        #expect(ids == [0, 4, 8, 12])  // Sorted by stream ID
    }

    // MARK: - Fair Queuing (Round-Robin)

    @Test("Cursor advances for fair queuing")
    func cursorAdvancesForFairQueuing() {
        var scheduler = StreamScheduler()

        // All same priority
        let streams: [UInt64: DataStream] = [
            0: makeStream(id: 0, priority: .default),
            4: makeStream(id: 4, priority: .default),
            8: makeStream(id: 8, priority: .default)
        ]

        // First call: cursor at 0, order is [0, 4, 8]
        let result1 = scheduler.scheduleStreams(streams)
        #expect(result1[0].streamID == 0)

        // Advance cursor (simulate stream 0 sent data)
        scheduler.advanceCursor(for: 3, groupSize: 3)

        // Second call: cursor at 1, order is [4, 8, 0]
        let result2 = scheduler.scheduleStreams(streams)
        #expect(result2[0].streamID == 4)

        // Advance cursor again
        scheduler.advanceCursor(for: 3, groupSize: 3)

        // Third call: cursor at 2, order is [8, 0, 4]
        let result3 = scheduler.scheduleStreams(streams)
        #expect(result3[0].streamID == 8)
    }

    @Test("Cursor wraps around")
    func cursorWrapsAround() {
        var scheduler = StreamScheduler()

        let streams: [UInt64: DataStream] = [
            0: makeStream(id: 0, priority: .default),
            4: makeStream(id: 4, priority: .default)
        ]

        // Advance cursor past end
        scheduler.advanceCursor(for: 3, groupSize: 2)
        scheduler.advanceCursor(for: 3, groupSize: 2)

        // Should wrap back to 0
        let result = scheduler.scheduleStreams(streams)
        #expect(result[0].streamID == 0)
    }

    // MARK: - Multiple Priority Groups

    @Test("Each priority group has independent cursor")
    func independentCursorsPerPriority() {
        var scheduler = StreamScheduler()

        let streams: [UInt64: DataStream] = [
            // High priority group (urgency 1)
            0: makeStream(id: 0, priority: .high),
            4: makeStream(id: 4, priority: .high),
            // Low priority group (urgency 5)
            8: makeStream(id: 8, priority: .low),
            12: makeStream(id: 12, priority: .low)
        ]

        // Advance high priority cursor
        scheduler.advanceCursor(for: 1, groupSize: 2)

        let result = scheduler.scheduleStreams(streams)

        // High priority group: cursor=1, so [4, 0]
        #expect(result[0].streamID == 4)
        #expect(result[1].streamID == 0)
        // Low priority group: cursor=0 (unchanged), so [8, 12]
        #expect(result[2].streamID == 8)
        #expect(result[3].streamID == 12)
    }

    // MARK: - Reset

    @Test("Reset clears all cursors")
    func resetClearsCursors() {
        var scheduler = StreamScheduler()

        let streams: [UInt64: DataStream] = [
            0: makeStream(id: 0, priority: .default),
            4: makeStream(id: 4, priority: .default)
        ]

        // Advance cursor
        scheduler.advanceCursor(for: 3, groupSize: 2)

        let result1 = scheduler.scheduleStreams(streams)
        #expect(result1[0].streamID == 4)

        // Reset
        scheduler.resetCursors()

        // Cursor back to 0
        let result2 = scheduler.scheduleStreams(streams)
        #expect(result2[0].streamID == 0)
    }

    @Test("Remove cursor for specific urgency")
    func removeCursorForUrgency() {
        var scheduler = StreamScheduler()

        // Advance cursors for multiple urgency levels
        scheduler.advanceCursor(for: 1, groupSize: 3)
        scheduler.advanceCursor(for: 3, groupSize: 2)

        // Remove only urgency 3 cursor
        scheduler.removeCursor(for: 3)

        #expect(scheduler.cursorPositions[1] == 1)  // Still set
        #expect(scheduler.cursorPositions[3] == nil)  // Removed
    }

    // MARK: - Edge Cases

    @Test("Cursor with single stream group")
    func cursorWithSingleStream() {
        var scheduler = StreamScheduler()

        let streams: [UInt64: DataStream] = [
            0: makeStream(id: 0, priority: .default)
        ]

        // Advancing cursor should wrap immediately
        scheduler.advanceCursor(for: 3, groupSize: 1)

        let result = scheduler.scheduleStreams(streams)
        #expect(result[0].streamID == 0)
    }

    @Test("Advance cursor with zero group size is no-op")
    func advanceCursorZeroGroupSize() {
        var scheduler = StreamScheduler()

        scheduler.advanceCursor(for: 3, groupSize: 0)

        #expect(scheduler.cursorPositions[3] == nil)
    }

    @Test("All urgency levels can coexist")
    func allUrgencyLevelsCoexist() {
        var scheduler = StreamScheduler()

        var streams: [UInt64: DataStream] = [:]
        for urgency: UInt8 in 0...7 {
            let id = UInt64(urgency * 4)
            streams[id] = makeStream(
                id: id,
                priority: StreamPriority(urgency: urgency, incremental: false)
            )
        }

        let result = scheduler.scheduleStreams(streams)

        #expect(result.count == 8)
        // Verify ordering by urgency
        for (index, item) in result.enumerated() {
            #expect(item.stream.priority.urgency == UInt8(index))
        }
    }
}

// MARK: - StreamManager Priority Integration Tests

@Suite("StreamManager Priority Integration Tests")
struct StreamManagerPriorityTests {

    // MARK: - Opening Streams with Priority

    @Test("Open stream with default priority")
    func openStreamDefaultPriority() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 10000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)
        let priority = try manager.priority(for: streamID)

        #expect(priority == .default)
    }

    @Test("Open stream with custom priority")
    func openStreamCustomPriority() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 10000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true, priority: .highest)
        let priority = try manager.priority(for: streamID)

        #expect(priority == .highest)
    }

    // MARK: - Setting Priority

    @Test("Set stream priority")
    func setStreamPriority() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxStreamDataBidiLocal: 10000,
            peerInitialMaxStreamsBidi: 10
        )

        let streamID = try manager.openStream(bidirectional: true)

        // Initially default
        #expect(try manager.priority(for: streamID) == .default)

        // Set to high
        try manager.setPriority(.high, for: streamID)
        #expect(try manager.priority(for: streamID) == .high)

        // Set to low
        try manager.setPriority(.low, for: streamID)
        #expect(try manager.priority(for: streamID) == .low)
    }

    @Test("Set priority for non-existent stream throws")
    func setPriorityNonExistentStreamThrows() throws {
        let manager = StreamManager(isClient: true)

        #expect(throws: StreamManagerError.self) {
            try manager.setPriority(.high, for: 9999)
        }
    }

    @Test("Get priority for non-existent stream throws")
    func getPriorityNonExistentStreamThrows() throws {
        let manager = StreamManager(isClient: true)

        #expect(throws: StreamManagerError.self) {
            _ = try manager.priority(for: 9999)
        }
    }

    // MARK: - Priority-Based Frame Generation

    @Test("High priority stream frames generated first")
    func highPriorityFramesFirst() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 100000,
            peerInitialMaxStreamDataBidiLocal: 10000,
            peerInitialMaxStreamsBidi: 10
        )

        // Create streams with different priorities
        let lowID = try manager.openStream(bidirectional: true, priority: .lowest)
        let highID = try manager.openStream(bidirectional: true, priority: .highest)
        let medID = try manager.openStream(bidirectional: true, priority: .default)

        // Write data to all streams
        try manager.write(streamID: lowID, data: Data(repeating: 0x01, count: 100))
        try manager.write(streamID: highID, data: Data(repeating: 0x02, count: 100))
        try manager.write(streamID: medID, data: Data(repeating: 0x03, count: 100))

        // Generate frames with enough space for all
        let frames = manager.generateStreamFrames(maxBytes: 1000)

        // First frame should be from high priority stream
        #expect(frames.count >= 1)
        #expect(frames[0].streamID == highID)

        // Verify ordering
        if frames.count >= 3 {
            let frameStreamIDs = frames.map { $0.streamID }
            // High -> Medium -> Low
            let highIndex = frameStreamIDs.firstIndex(of: highID)!
            let medIndex = frameStreamIDs.firstIndex(of: medID)!
            let lowIndex = frameStreamIDs.firstIndex(of: lowID)!

            #expect(highIndex < medIndex)
            #expect(medIndex < lowIndex)
        }
    }

    @Test("Limited bytes serves high priority only")
    func limitedBytesServesHighPriorityOnly() throws {
        let manager = StreamManager(
            isClient: true,
            peerInitialMaxData: 100000,
            peerInitialMaxStreamDataBidiLocal: 10000,
            peerInitialMaxStreamsBidi: 10
        )

        // Create high and low priority streams
        let lowID = try manager.openStream(bidirectional: true, priority: .lowest)
        let highID = try manager.openStream(bidirectional: true, priority: .highest)

        // Write data to both
        try manager.write(streamID: lowID, data: Data(repeating: 0x01, count: 100))
        try manager.write(streamID: highID, data: Data(repeating: 0x02, count: 100))

        // Generate with limited bytes (only enough for one stream)
        let frames = manager.generateStreamFrames(maxBytes: 50)

        // Should only have high priority stream
        #expect(frames.allSatisfy { $0.streamID == highID })
    }
}
