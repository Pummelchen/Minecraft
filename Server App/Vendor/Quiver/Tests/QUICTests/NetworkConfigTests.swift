/// Network Configuration Tests
///
/// Focused stress tests for the four network configuration features.
/// Each test targets a code path that involves unsafe memory, system
/// calls, or state-machine edge cases that are likely to break
/// under platform changes or refactoring.
///
/// Covered areas:
/// - PlatformSocket: ioctl pointer work, TOS helpers, constant sanity
/// - PMTUDiscovery: binary search convergence, black hole, retry exhaustion
/// - ECN: state machine transitions, IncomingPacket plumbing
/// - QUICConfiguration.validate(): boundary violations

import Testing
import Foundation
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto
@testable import QUICConnection
@testable import QUICTransport

// ============================================================
// MARK: - Platform Socket (pointer / system call safety)
// ============================================================

@Suite("PlatformSocket System-Level Tests")
struct PlatformSocketTests {

    // ----------------------------------------------------------
    // ioctl / getifaddrs pointer safety
    // ----------------------------------------------------------

    @Test("queryInterfaceMTU on loopback returns valid MTU")
    func loopbackMTUQuery() throws {
        // "lo" on Linux, "lo0" on macOS — one of them must exist
        let linuxMTU = queryInterfaceMTU("lo")
        let darwinMTU = queryInterfaceMTU("lo0")
        let mtu = linuxMTU ?? darwinMTU

        // Must get a value on any supported platform.
        // Loopback MTU is typically 65536 on Linux, 16384 on macOS.
        let resolved = try #require(mtu, "Expected loopback MTU on Linux (lo) or macOS (lo0)")
        #expect(resolved >= 1500, "Loopback MTU should be >= 1500, got \(resolved)")
        #expect(resolved <= 1_000_000, "Loopback MTU suspiciously large: \(resolved)")
    }

    @Test("queryInterfaceMTU rejects oversized interface name without memory corruption")
    func oversizedInterfaceNameDoesNotCrash() {
        // IFNAMSIZ = 16 (including NUL).  Passing a 17+ byte name must
        // return nil and NOT write past the ifreq.ifr_name buffer.
        let longName = String(repeating: "X", count: 64)
        let result = queryInterfaceMTU(longName)
        #expect(result == nil, "Oversized name must return nil")
    }

    @Test("queryInterfaceMTU returns nil for nonexistent interface")
    func nonexistentInterface() {
        let result = queryInterfaceMTU("__quic_test_no_such_iface__")
        #expect(result == nil)
    }

    @Test("queryDefaultInterfaceMTU returns a plausible value")
    func defaultInterfaceMTU() {
        // Should find at least one non-loopback UP interface on CI.
        // If not (bare container), nil is acceptable — but if it
        // returns a value it must be sane.
        if let mtu = queryDefaultInterfaceMTU() {
            #expect(mtu >= 68, "MTU below IPv4 minimum (68): \(mtu)")
            #expect(mtu <= 65536, "MTU above jumbo frame ceiling: \(mtu)")
        }
        // Reaching here without crashing is the real assertion:
        // the getifaddrs iteration and flag-mask pointer work survived.
    }

    // ----------------------------------------------------------
    // TOS / ECN byte manipulation (must be lossless for all 256)
    // ----------------------------------------------------------

    @Test("ecnFromTOS extracts correct 2-bit ECN field for all 256 byte values")
    func ecnFromTOS_exhaustive() {
        for tos: UInt8 in 0...255 {
            let ecn = ecnFromTOS(tos)
            #expect(ecn == tos & 0x03,
                    "ecnFromTOS(\(tos)) = \(ecn), expected \(tos & 0x03)")
        }
    }

    @Test("tosWithECN roundtrips DSCP and ECN independently")
    func tosWithECN_roundtrip() {
        // For every DSCP (upper 6 bits) and ECN (lower 2 bits),
        // composing then extracting must be identity.
        for dscp: UInt8 in stride(from: 0, through: 252, by: 4) {
            for ecn: UInt8 in 0...3 {
                let composed = tosWithECN(dscp: dscp, ecn: ecn)
                #expect(composed & 0xFC == dscp,
                        "DSCP corruption: dscp=\(dscp) ecn=\(ecn) -> \(composed)")
                #expect(composed & 0x03 == ecn,
                        "ECN corruption: dscp=\(dscp) ecn=\(ecn) -> \(composed)")
            }
        }
    }

    @Test("tosWithECN masks stray high bits in ecn parameter")
    func tosWithECN_masks_high_ecn_bits() {
        // ecn = 0xFF should behave the same as ecn = 0x03
        let a = tosWithECN(dscp: 0xA0, ecn: 0xFF)
        let b = tosWithECN(dscp: 0xA0, ecn: 0x03)
        #expect(a == b, "High bits in ecn must be masked: \(a) vs \(b)")
    }

    // ----------------------------------------------------------
    // Platform constants sanity
    // ----------------------------------------------------------

    @Test("Platform constants have non-zero values on supported OS")
    func platformConstantsSanity() {
        #expect(PlatformSocketConstants.isDFSupported == true)
        #expect(PlatformSocketConstants.isECNSupported == true)
        #expect(PlatformSocketConstants.isMTUQuerySupported == true)

        // IPPROTO_IP is legitimately 0, so only check option *names* > 0.
        // The level for IPv4 (IPPROTO_IP == 0) is valid; IPv6 level > 0.
        #expect(PlatformSocketConstants.ipv4DFOption > 0,
                "IPv4 DF option name must be a real setsockopt constant")
        #expect(PlatformSocketConstants.ipv6DFLevel > 0,
                "IPv6 DF level (IPPROTO_IPV6) must be > 0")
        #expect(PlatformSocketConstants.ipv6DFOption > 0)

        // ECN option names (not levels — ipv4ECNLevel == IPPROTO_IP == 0)
        #expect(PlatformSocketConstants.ipv4RecvTOS > 0)
        #expect(PlatformSocketConstants.ipv4TOS > 0)
        #expect(PlatformSocketConstants.ipv6RecvTClass > 0)
        #expect(PlatformSocketConstants.ipv6TClass > 0)
        #expect(PlatformSocketConstants.ipv6ECNLevel > 0,
                "IPv6 ECN level (IPPROTO_IPV6) must be > 0")
    }

    @Test("PlatformSocketOptions builder produces correct option count")
    func platformOptionsBuilder() {
        let ipv4 = PlatformSocketOptions.forQUIC(
            addressFamily: .ipv4, enableECN: true, enableDF: true
        )
        // DF(1) + RECVTOS(1) + TOS(1) = 3 options
        #expect(ipv4.options.count == 3,
                "IPv4 with ECN+DF should produce 3 options, got \(ipv4.options.count)")
        #expect(ipv4.dfEnabled == true)
        #expect(ipv4.ecnEnabled == true)

        let ipv6 = PlatformSocketOptions.forQUIC(
            addressFamily: .ipv6, enableECN: true, enableDF: true
        )
        #expect(ipv6.options.count == 3)

        let noECN = PlatformSocketOptions.forQUIC(
            addressFamily: .ipv4, enableECN: false, enableDF: true
        )
        // DF only = 1 option
        #expect(noECN.options.count == 1)
        #expect(noECN.ecnEnabled == false)
        #expect(noECN.dfEnabled == true)

        let nothing = PlatformSocketOptions.forQUIC(
            addressFamily: .ipv4, enableECN: false, enableDF: false
        )
        #expect(nothing.options.count == 0)
        #expect(nothing.dfEnabled == false)
        #expect(nothing.ecnEnabled == false)
    }
}

// ============================================================
// MARK: - DPLPMTUD State Machine
// ============================================================

@Suite("DPLPMTUD Binary Search & Edge Cases")
struct PMTUDiscoveryTests {

    // ----------------------------------------------------------
    // Full binary search convergence simulation
    // ----------------------------------------------------------

    @Test("Binary search converges to correct MTU when path supports 1400")
    func binarySearchConvergesToPathMTU() {
        let pathMTU = 1400
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1500,
            searchGranularity: 10,
            maxProbes: 3,
            probeTimeout: .seconds(1),
            raiseTimer: .seconds(600),
            reprobeInterval: nil  // disable reprobe for determinism
        )
        let mgr = PMTUDiscoveryManager(configuration: config)

        mgr.enable()
        #expect(mgr.state == .base)

        // Drive the binary search to convergence.
        // Each iteration: generate probe, ack if size <= pathMTU, timeout if larger.
        var iterations = 0
        let maxIterations = 30  // log2(300/10) ~ 5; generous bound
        while mgr.state != .searchComplete && iterations < maxIterations {
            iterations += 1
            guard let probe = mgr.generateProbe() else {
                // No probe and not complete = should not happen
                break
            }

            #expect(probe.packetSize >= config.basePLPMTU)
            #expect(probe.packetSize <= config.maxPLPMTU)

            if probe.packetSize <= pathMTU {
                let acked = mgr.probeAcknowledged(challengeData: probe.challengeData)
                #expect(acked != nil, "Ack for size \(probe.packetSize) must succeed")
            } else {
                // Exhaust retries to actually shrink the range
                for _ in 0..<config.maxProbes {
                    _ = mgr.probeTimedOut()
                    if mgr.state == .searchComplete { break }
                    // Re-generate probe at same size for retry
                    if let retry = mgr.generateProbe() {
                        // Timeout again
                        _ = retry
                    }
                }
                _ = mgr.probeTimedOut()
            }
        }

        #expect(mgr.state == .searchComplete,
                "Search must converge within \(maxIterations) iterations")

        // Converged MTU must be within searchGranularity of the real path MTU
        let discovered = mgr.currentPLPMTU
        #expect(discovered <= pathMTU,
                "Discovered MTU \(discovered) must be <= path MTU \(pathMTU)")
        #expect(discovered >= pathMTU - config.searchGranularity,
                "Discovered MTU \(discovered) too far below path MTU \(pathMTU)")
    }

    // ----------------------------------------------------------
    // Edge: base == max (no search possible)
    // ----------------------------------------------------------

    @Test("No search when basePLPMTU == maxPLPMTU")
    func baseEqualsMax() {
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1200,
            searchGranularity: 10
        )
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        // Range is 0, which is <= granularity, so first generateProbe
        // should transition directly to searchComplete.
        let probe = mgr.generateProbe()
        #expect(probe == nil, "No probe needed when base == max")
        #expect(mgr.state == .searchComplete)
        #expect(mgr.currentPLPMTU == 1200)
    }

    // ----------------------------------------------------------
    // Edge: narrow range within granularity
    // ----------------------------------------------------------

    @Test("Immediate convergence when range < granularity")
    func narrowRange() {
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1205,
            searchGranularity: 10
        )
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        let probe = mgr.generateProbe()
        #expect(probe == nil)
        #expect(mgr.state == .searchComplete)
    }

    // ----------------------------------------------------------
    // Black hole detection and recovery
    // ----------------------------------------------------------

    @Test("Black hole falls back to base, then recovers")
    func blackHoleRecovery() {
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1452,
            searchGranularity: 10,
            raiseTimer: .milliseconds(1),  // very short for test
            reprobeInterval: nil
        )
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        // Start a search
        let probe1 = mgr.generateProbe()
        #expect(probe1 != nil)
        _ = mgr.probeAcknowledged(challengeData: probe1!.challengeData)
        #expect(mgr.currentPLPMTU > 1200)

        // Black hole detected
        let fallback = mgr.blackHoleDetected()
        #expect(fallback == 1200, "Must fall back to base")
        #expect(mgr.state == .error)
        #expect(mgr.currentPLPMTU == 1200)

        // No probes while in error state
        #expect(mgr.generateProbe() == nil)

        // Wait for raise timer (1ms)
        Thread.sleep(forTimeInterval: 0.005)
        let action = mgr.onTimerFired()
        #expect(action == .raiseTimerExpired)
        #expect(mgr.state == .base, "Must re-enter base after raise timer")

        // Can probe again
        let probe2 = mgr.generateProbe()
        #expect(probe2 != nil, "Must be able to probe after recovery")
    }

    // ----------------------------------------------------------
    // Probe disambiguation: PMTUD vs migration
    // ----------------------------------------------------------

    @Test("isProbeResponse correctly distinguishes PMTUD from migration data")
    func probeDisambiguation() throws {
        let config = PMTUConfiguration(basePLPMTU: 1200, maxPLPMTU: 1452)
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        let probe = try #require(mgr.generateProbe())
        let fakeData = Data(repeating: 0xAB, count: 8)

        #expect(mgr.isProbeResponse(probe.challengeData) == true)
        #expect(mgr.isProbeResponse(fakeData) == false)
        #expect(mgr.isProbeResponse(Data()) == false)

        // After ack, no longer a probe response
        _ = mgr.probeAcknowledged(challengeData: probe.challengeData)
        #expect(mgr.isProbeResponse(probe.challengeData) == false)
    }

    // ----------------------------------------------------------
    // Retry exhaustion shrinks range correctly
    // ----------------------------------------------------------

    @Test("Exhausting maxProbes shrinks searchHigh to probeSize - 1")
    func retryExhaustion() throws {
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1500,
            searchGranularity: 10,
            maxProbes: 2,
            reprobeInterval: nil
        )
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        // First probe: midpoint of [1200, 1500] = 1350 or 1351
        let probe1 = try #require(mgr.generateProbe())
        let firstProbeSize = probe1.packetSize
        #expect(firstProbeSize > 1200)
        #expect(firstProbeSize <= 1500)

        // Timeout attempt 1 (probeAttempts was incremented to 1 in makeProbe)
        _ = mgr.probeTimedOut()
        // Attempt 1 < maxProbes(2), so generate retry at same logical step
        let probe2 = mgr.generateProbe()
        #expect(probe2 != nil, "Should retry after first timeout")

        // Timeout attempt 2 — now probeAttempts == maxProbes
        _ = mgr.probeTimedOut()

        // Range should have shrunk: currentPLPMTU stays at 1200
        #expect(mgr.currentPLPMTU == 1200)

        // Next probe should target a smaller size (new midpoint of shrunk range)
        if mgr.state == .searching {
            let probe3 = mgr.generateProbe()
            if let p3 = probe3 {
                #expect(p3.packetSize < firstProbeSize,
                        "After timeout, next probe \(p3.packetSize) must be < failed size \(firstProbeSize)")
            }
        }
    }

    // ----------------------------------------------------------
    // Disable mid-search must not leave dangling state
    // ----------------------------------------------------------

    @Test("Disabling mid-search clears probe and reverts to base")
    func disableMidSearch() throws {
        let config = PMTUConfiguration(basePLPMTU: 1200, maxPLPMTU: 1452)
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        let probe = mgr.generateProbe()
        #expect(probe != nil)
        #expect(mgr.isProbing == true)

        mgr.disable()
        #expect(mgr.state == .disabled)
        #expect(mgr.currentPLPMTU == 1200)
        #expect(mgr.isProbing == false)
        #expect(mgr.generateProbe() == nil)

        // Re-enable should start fresh
        mgr.enable()
        #expect(mgr.state == .base)
        let probe2 = mgr.generateProbe()
        #expect(probe2 != nil, "Re-enable must allow probing again")
    }

    // ----------------------------------------------------------
    // Path change resets mid-search
    // ----------------------------------------------------------

    @Test("Path change resets discovered MTU and restarts search")
    func pathChangeReset() throws {
        let config = PMTUConfiguration(
            basePLPMTU: 1200,
            maxPLPMTU: 1452,
            searchGranularity: 10,
            reprobeInterval: nil
        )
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        // Discover something
        let probe = try #require(mgr.generateProbe())
        _ = mgr.probeAcknowledged(challengeData: probe.challengeData)
        let mtuBefore = mgr.currentPLPMTU
        #expect(mtuBefore > 1200)

        // Simulate path change
        mgr.resetForPathChange()
        #expect(mgr.state == .base)
        #expect(mgr.currentPLPMTU == 1200,
                "Path change must revert to base MTU")
        #expect(mgr.isProbing == false)
    }

    // ----------------------------------------------------------
    // Double-enable is a no-op
    // ----------------------------------------------------------

    @Test("Double enable does not reset in-progress search")
    func doubleEnable() throws {
        let config = PMTUConfiguration(basePLPMTU: 1200, maxPLPMTU: 1452)
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        let probe = try #require(mgr.generateProbe())
        _ = mgr.probeAcknowledged(challengeData: probe.challengeData)
        let mtu = mgr.currentPLPMTU

        // Second enable must be ignored (guard checks phase != .disabled)
        mgr.enable()
        #expect(mgr.currentPLPMTU == mtu,
                "Double enable must not reset discovered MTU")
    }

    // ----------------------------------------------------------
    // paddingNeeded returns sane values
    // ----------------------------------------------------------

    @Test("paddingNeeded returns correct delta for probe packet")
    func paddingNeeded() throws {
        let config = PMTUConfiguration(basePLPMTU: 1200, maxPLPMTU: 1452)
        let mgr = PMTUDiscoveryManager(configuration: config)
        mgr.enable()

        let probe = try #require(mgr.generateProbe())

        let needed = mgr.paddingNeeded(currentPacketSize: 100)
        #expect(needed == probe.packetSize - 100)

        let excess = mgr.paddingNeeded(currentPacketSize: probe.packetSize + 50)
        #expect(excess == 0, "No negative padding")

        // After ack, no padding needed
        _ = mgr.probeAcknowledged(challengeData: probe.challengeData)
        #expect(mgr.paddingNeeded(currentPacketSize: 100) == 0)
    }
}

// ============================================================
// MARK: - ECN State Machine + IncomingPacket Wiring
// ============================================================

@Suite("ECN Manager & IncomingPacket Integration")
struct ECNIntegrationTests {

    @Test("ECN codepoint values match RFC 3168")
    func ecnCodepointRawValues() {
        #expect(ECNCodepoint.notECT.rawValue == 0x00)
        #expect(ECNCodepoint.ect1.rawValue == 0x01)
        #expect(ECNCodepoint.ect0.rawValue == 0x02)
        #expect(ECNCodepoint.ce.rawValue == 0x03)
    }

    @Test("ECNManager tracks incoming counts per encryption level accurately")
    func ecnCountTracking() throws {
        let mgr = ECNManager()
        mgr.enableECN()

        // Simulate 5 ECT(0) + 3 ECT(1) + 2 CE at initial level
        for _ in 0..<5 { mgr.recordIncoming(.ect0, level: .initial) }
        for _ in 0..<3 { mgr.recordIncoming(.ect1, level: .initial) }
        for _ in 0..<2 { mgr.recordIncoming(.ce, level: .initial) }

        // notECT should not count
        mgr.recordIncoming(.notECT, level: .initial)

        let counts = try #require(mgr.countsForACK(level: .initial))
        #expect(counts.ect0Count == 5)
        #expect(counts.ect1Count == 3)
        #expect(counts.ceCount == 2)
        #expect(counts.totalECN == 10)

        // Separate level must be independent
        let handshakeCounts = mgr.countsForACK(level: .handshake)
        #expect(handshakeCounts == nil, "No packets recorded at handshake level")
    }

    @Test("ECN validation fails when peer ECN counts decrease (RFC 9000 §13.4.2.1)")
    func ecnValidationFailsOnDecreasingCounts() {
        let mgr = ECNManager()
        mgr.enableECN()

        // First ACK with valid counts
        let initial = ECNCountState(ect0: 10, ect1: 0, ce: 1)
        _ = mgr.processACKFeedback(initial, level: .application)

        // Second ACK with ect0 decreased — MUST fail
        let decreased = ECNCountState(ect0: 9, ect1: 0, ce: 1)
        let newCE = mgr.processACKFeedback(decreased, level: .application)
        #expect(newCE == 0, "Decreased counts must not report new CE marks")
        #expect(mgr.validationState == .failed,
                "ECN validation must fail when counts decrease")
        #expect(mgr.isEnabled == false,
                "ECN must be disabled after validation failure")
    }

    @Test("ECN validation succeeds after 10 acknowledged ECT packets")
    func ecnValidationSuccess() {
        let mgr = ECNManager()
        mgr.enableECN()

        // Send feedback incrementally
        for i: UInt64 in 1...12 {
            let counts = ECNCountState(ect0: i, ect1: 0, ce: 0)
            _ = mgr.processACKFeedback(counts, level: .application)
        }

        #expect(mgr.validationState == .capable,
                "ECN must be validated after >= 10 acked ECT packets")
    }

    @Test("IncomingPacket carries ECN codepoint correctly")
    func incomingPacketECNField() {
        // Default must be .notECT
        let defaultPacket = IncomingPacket(
            buffer: .init(),
            remoteAddress: try! .init(ipAddress: "127.0.0.1", port: 443),
            receivedAt: .now
        )
        #expect(defaultPacket.ecnCodepoint == .notECT)

        // Explicit ECN
        let ect0Packet = IncomingPacket(
            buffer: .init(),
            remoteAddress: try! .init(ipAddress: "127.0.0.1", port: 443),
            receivedAt: .now,
            ecnCodepoint: .ect0
        )
        #expect(ect0Packet.ecnCodepoint == .ect0)

        let cePacket = IncomingPacket(
            buffer: .init(),
            remoteAddress: try! .init(ipAddress: "127.0.0.1", port: 443),
            receivedAt: .now,
            ecnCodepoint: .ce
        )
        #expect(cePacket.ecnCodepoint == .ce)
    }

    @Test("Outgoing codepoint reflects enable/disable state")
    func outgoingCodepointState() {
        let mgr = ECNManager()
        #expect(mgr.outgoingCodepoint() == .notECT)

        mgr.enableECN()
        #expect(mgr.outgoingCodepoint() == .ect0)

        mgr.disableECN()
        #expect(mgr.outgoingCodepoint() == .notECT)
    }
}

// ============================================================
// MARK: - QUICConfiguration Validation
// ============================================================

@Suite("QUICConfiguration.validate() Boundary Tests")
struct ConfigValidationTests {

    @Test("Default configuration passes validation")
    func defaultConfigValid() throws {
        let config = QUICConfiguration()
        try config.validate()
    }

    @Test("maxUDPPayloadSize below 1200 is rejected")
    func payloadSizeBelowMinimum() {
        var config = QUICConfiguration()
        config.maxUDPPayloadSize = 1199
        #expect(throws: QUICConfiguration.ValidationError.self) {
            try config.validate()
        }
    }

    @Test("maxUDPPayloadSize == 1200 is accepted (exact boundary)")
    func payloadSizeExactMinimum() throws {
        var config = QUICConfiguration()
        config.maxUDPPayloadSize = 1200
        try config.validate()
    }

    @Test("socketConfiguration.maxDatagramSize < maxUDPPayloadSize is rejected")
    func socketSmallerThanPayload() {
        var config = QUICConfiguration()
        config.maxUDPPayloadSize = 1400
        config.socketConfiguration = SocketConfiguration(
            receiveBufferSize: 65536,
            sendBufferSize: 65536,
            maxDatagramSize: 1399
        )
        #expect(throws: QUICConfiguration.ValidationError.self) {
            try config.validate()
        }
    }

    @Test("socketConfiguration.maxDatagramSize == maxUDPPayloadSize is accepted (exact boundary)")
    func socketEqualsPayload() throws {
        var config = QUICConfiguration()
        config.maxUDPPayloadSize = 1452
        config.socketConfiguration = SocketConfiguration(
            receiveBufferSize: 65536,
            sendBufferSize: 65536,
            maxDatagramSize: 1452
        )
        try config.validate()
    }

    @Test("connectionIDLength outside 0...20 is rejected")
    func connectionIDLengthOutOfRange() {
        var config = QUICConfiguration()
        config.connectionIDLength = 21
        #expect(throws: QUICConfiguration.ValidationError.self) {
            try config.validate()
        }

        config.connectionIDLength = -1
        #expect(throws: QUICConfiguration.ValidationError.self) {
            try config.validate()
        }
    }

    @Test("connectionIDLength boundary values 0 and 20 are accepted")
    func connectionIDLengthBoundaries() throws {
        var config = QUICConfiguration()
        config.connectionIDLength = 0
        try config.validate()

        config.connectionIDLength = 20
        try config.validate()
    }

    @Test("SocketConfiguration enableECN and enableDF default to true")
    func socketConfigDefaults() {
        let sc = SocketConfiguration()
        #expect(sc.enableECN == true)
        #expect(sc.enableDF == true)
        #expect(sc.receiveBufferSize == 65536)
        #expect(sc.sendBufferSize == 65536)
        #expect(sc.maxDatagramSize == 65507)
    }

    @Test("Large maxUDPPayloadSize with matching socket config validates")
    func largePayloadSize() throws {
        var config = QUICConfiguration()
        config.maxUDPPayloadSize = 9000  // jumbo frames
        config.socketConfiguration = SocketConfiguration(
            receiveBufferSize: 65536,
            sendBufferSize: 65536,
            maxDatagramSize: 65507
        )
        try config.validate()
    }
}

// ============================================================
// MARK: - ManagedConnection ECN + PMTUD API
// ============================================================

@Suite("ManagedConnection Network Config API")
struct ManagedConnectionNetworkTests {

    /// Helper: creates a minimal ManagedConnection for API testing.
    private func makeConnection() throws -> ManagedConnection {
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        var tp = TransportParameters()
        tp.initialMaxStreamsBidi = 100
        tp.initialMaxStreamsUni = 100
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        return ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: tp,
            tlsProvider: MockTLSProvider(),
            remoteAddress: address,
            maxDatagramSize: 1200
        )
    }

    @Test("ECN enable/disable lifecycle on ManagedConnection")
    func ecnLifecycle() throws {
        let conn = try makeConnection()
        #expect(conn.isECNEnabled == false)

        conn.enableECN()
        #expect(conn.isECNEnabled == true)

        conn.disableECN()
        #expect(conn.isECNEnabled == false)
    }

    @Test("PMTUD enable/disable lifecycle on ManagedConnection")
    func pmtudLifecycle() throws {
        let conn = try makeConnection()
        #expect(conn.pmtuState == .disabled)
        #expect(conn.currentPathMTU == 1200)

        conn.enablePMTUD()
        #expect(conn.pmtuState == .base)

        conn.disablePMTUD()
        #expect(conn.pmtuState == .disabled)
        #expect(conn.currentPathMTU == 1200)
    }

    @Test("PMTUD path change reset works through ManagedConnection")
    func pmtudPathChange() throws {
        let conn = try makeConnection()
        conn.enablePMTUD()
        #expect(conn.pmtuState == .base)

        conn.resetPMTUDForPathChange()
        #expect(conn.pmtuState == .base)
        #expect(conn.currentPathMTU == 1200)
    }

    @Test("pmtuDiagnostics returns non-empty string")
    func pmtudDiagnostics() throws {
        let conn = try makeConnection()
        let diag = conn.pmtuDiagnostics
        #expect(diag.contains("phase="))
        #expect(diag.contains("plpmtu="))
    }

    @Test("ecnValidationState starts as unknown")
    func ecnValidationStateInitial() throws {
        let conn = try makeConnection()
        #expect(conn.ecnValidationState == .unknown)
        #expect(conn.isECNValidated == false)
    }

    @Test("ecnValidationState transitions to testing on enable")
    func ecnValidationStateTesting() throws {
        let conn = try makeConnection()
        conn.enableECN()
        #expect(conn.ecnValidationState == .testing)
        #expect(conn.isECNValidated == false)
    }

    @Test("ecnValidationState transitions to failed on disable")
    func ecnValidationStateFailed() throws {
        let conn = try makeConnection()
        conn.enableECN()
        #expect(conn.ecnValidationState == .testing)
        conn.disableECN()
        #expect(conn.ecnValidationState == .failed)
        #expect(conn.isECNValidated == false)
    }

    @Test("pmtuHistoryCount starts at zero")
    func pmtuHistoryCountInitial() throws {
        let conn = try makeConnection()
        #expect(conn.pmtuHistoryCount == 0)
    }

    @Test("generatePMTUProbe returns nil when disabled")
    func generateProbeDisabled() throws {
        let conn = try makeConnection()
        #expect(conn.pmtuState == .disabled)
        let probe = conn.generatePMTUProbe()
        #expect(probe == nil)
    }

    @Test("generatePMTUProbe returns a probe when in base state")
    func generateProbeInBase() throws {
        let conn = try makeConnection()
        conn.enablePMTUD()
        #expect(conn.pmtuState == .base)

        let probe = conn.generatePMTUProbe()
        #expect(probe != nil)
        if let probe = probe {
            #expect(probe.packetSize > conn.currentPathMTU)
            #expect(probe.challengeData.count == 8)
        }
        // State should transition to searching after generating a probe
        #expect(conn.pmtuState == .searching)
    }
}