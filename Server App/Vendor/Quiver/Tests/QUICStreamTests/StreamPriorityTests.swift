/// StreamPriority Unit Tests
///
/// Tests for RFC 9218-aligned stream priority parameters.

import Testing
import Foundation
@testable import QUICStream

@Suite("StreamPriority Tests")
struct StreamPriorityTests {

    // MARK: - Basic Properties

    @Test("Default priority is urgency 3")
    func defaultPriorityIsUrgency3() {
        let priority = StreamPriority.default
        #expect(priority.urgency == 3)
        #expect(priority.incremental == false)
    }

    @Test("Highest priority is urgency 0")
    func highestPriorityIsUrgency0() {
        let priority = StreamPriority.highest
        #expect(priority.urgency == 0)
        #expect(priority.incremental == false)
    }

    @Test("Lowest priority is urgency 7")
    func lowestPriorityIsUrgency7() {
        let priority = StreamPriority.lowest
        #expect(priority.urgency == 7)
        #expect(priority.incremental == false)
    }

    @Test("Background priority has incremental true")
    func backgroundPriorityHasIncremental() {
        let priority = StreamPriority.background
        #expect(priority.urgency == 7)
        #expect(priority.incremental == true)
    }

    // MARK: - Comparable

    @Test("Lower urgency value means higher priority")
    func lowerUrgencyIsHigherPriority() {
        let high = StreamPriority(urgency: 1, incremental: false)
        let low = StreamPriority(urgency: 5, incremental: false)

        #expect(high < low)
        #expect(!(low < high))
    }

    @Test("Urgency 0 is higher than urgency 7")
    func urgency0HigherThanUrgency7() {
        #expect(StreamPriority.highest < StreamPriority.lowest)
    }

    @Test("Same urgency: non-incremental before incremental")
    func sameUrgencyNonIncrementalFirst() {
        let nonIncremental = StreamPriority(urgency: 3, incremental: false)
        let incremental = StreamPriority(urgency: 3, incremental: true)

        #expect(nonIncremental < incremental)
        #expect(!(incremental < nonIncremental))
    }

    @Test("Same urgency and incremental: equal priority")
    func sameUrgencyAndIncrementalEqual() {
        let a = StreamPriority(urgency: 3, incremental: true)
        let b = StreamPriority(urgency: 3, incremental: true)

        #expect(!(a < b))
        #expect(!(b < a))
    }

    // MARK: - Sorting

    @Test("Priorities sort correctly")
    func prioritiesSortCorrectly() {
        let priorities: [StreamPriority] = [
            .lowest,
            .default,
            .highest,
            .low,
            .high
        ]

        let sorted = priorities.sorted()

        #expect(sorted[0] == .highest)
        #expect(sorted[1] == .high)
        #expect(sorted[2] == .default)
        #expect(sorted[3] == .low)
        #expect(sorted[4] == .lowest)
    }

    // MARK: - Urgency Clamping

    @Test("Urgency values above 7 are clamped to 7")
    func urgencyClampedTo7() {
        let priority = StreamPriority(urgency: 100, incremental: false)
        #expect(priority.urgency == 7)
    }

    @Test("Urgency values 0-7 are preserved")
    func urgencyValuesPreserved() {
        for urgency: UInt8 in 0...7 {
            let priority = StreamPriority(urgency: urgency, incremental: false)
            #expect(priority.urgency == urgency)
        }
    }

    // MARK: - Hashable

    @Test("Equal priorities have same hash")
    func equalPrioritiesSameHash() {
        let a = StreamPriority(urgency: 3, incremental: true)
        let b = StreamPriority(urgency: 3, incremental: true)

        #expect(a.hashValue == b.hashValue)
    }

    @Test("Can be used in Set")
    func canBeUsedInSet() {
        var set: Set<StreamPriority> = []
        set.insert(.highest)
        set.insert(.default)
        set.insert(.highest)  // Duplicate

        #expect(set.count == 2)
        #expect(set.contains(.highest))
        #expect(set.contains(.default))
    }

    @Test("Can be used as Dictionary key")
    func canBeUsedAsDictionaryKey() {
        var dict: [StreamPriority: String] = [:]
        dict[.highest] = "critical"
        dict[.default] = "normal"
        dict[.lowest] = "background"

        #expect(dict[.highest] == "critical")
        #expect(dict[.default] == "normal")
        #expect(dict[.lowest] == "background")
    }

    // MARK: - CustomStringConvertible

    @Test("Description is readable")
    func descriptionIsReadable() {
        let priority = StreamPriority(urgency: 3, incremental: true)
        #expect(priority.description.contains("u=3"))
        #expect(priority.description.contains("i=true"))
    }
}
