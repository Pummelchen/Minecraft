// =============================================================================
// QUIC Network Configuration Demo — ECN / PMTUD / Platform Socket Options
// =============================================================================
//
// This demo exercises the network-configuration adaptation features:
//   1. Platform socket option generation (DF, ECN, GRO/GSO constants)
//   2. ECN (Explicit Congestion Notification) wiring and validation
//   3. DPLPMTUD (Datagram Packetization Layer PMTU Discovery, RFC 8899)
//   4. Interface MTU querying via ioctl/getifaddrs
//
// ## Running
//
//   # Show platform socket capabilities and interface MTU info
//   swift run QUICNetworkDemo info
//
//   # Start the server (ECN + DF enabled by default)
//   swift run QUICNetworkDemo server
//
//   # In another terminal, run the client
//   swift run QUICNetworkDemo client
//
//   # Disable ECN to observe fallback behaviour
//   swift run QUICNetworkDemo server --no-ecn
//   swift run QUICNetworkDemo client --no-ecn
//
//   # Custom host/port
//   swift run QUICNetworkDemo server --host 0.0.0.0 --port 5555
//   swift run QUICNetworkDemo client --host 127.0.0.1 --port 5555
//
// =============================================================================

import Foundation
import Logging
import QUIC
import QUICCore
import QUICCrypto
import QUICConnection
import QUICTransport
import NIOUDPTransport

// MARK: - Constants

let defaultHost = "127.0.0.1"
let defaultPort: UInt16 = 4434
let demoALPN = "quic-network-demo"

/// Number of ping-pong rounds used to drive ECN validation.
/// ECNManager requires 10 ACKed ECT packets before marking the path as capable.
let ecnPingRounds = 20

// MARK: - Logging

func log(_ tag: String, _ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] [\(tag)] \(message)")
}

// MARK: - Argument Parsing

struct DemoArguments {
    enum Mode: String {
        case server
        case client
        case info
        case help
    }

    let mode: Mode
    let host: String
    let port: UInt16
    let logLevel: Logger.Level
    let certPath: String?
    let keyPath: String?
    let caCertPath: String?
    let enableECN: Bool
    let enableDF: Bool

    static func parse() -> DemoArguments {
        let args = CommandLine.arguments.dropFirst()
        var mode: Mode = .help
        var host = defaultHost
        var port = defaultPort
        var logLevel: Logger.Level = .info
        var certPath: String?
        var keyPath: String?
        var caCertPath: String?
        var enableECN = true
        var enableDF = true

        var iter = args.makeIterator()
        if let first = iter.next() {
            mode = Mode(rawValue: first) ?? .help
        }

        while let arg = iter.next() {
            switch arg {
            case "--host":
                if let v = iter.next() { host = v }
            case "--port", "-p":
                if let v = iter.next(), let p = UInt16(v) { port = p }
            case "--log-level", "-l":
                if let v = iter.next() { logLevel = parseLogLevel(v) ?? .info }
            case "--cert":
                certPath = iter.next()
            case "--key":
                keyPath = iter.next()
            case "--ca-cert":
                caCertPath = iter.next()
            case "--no-ecn":
                enableECN = false
            case "--no-df":
                enableDF = false
            default:
                break
            }
        }

        return DemoArguments(
            mode: mode,
            host: host,
            port: port,
            logLevel: logLevel,
            certPath: certPath,
            keyPath: keyPath,
            caCertPath: caCertPath,
            enableECN: enableECN,
            enableDF: enableDF
        )
    }

    static func parseLogLevel(_ string: String) -> Logger.Level? {
        switch string.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return nil
        }
    }
}

// MARK: - Platform Info (mode: info)

func runInfo() {
    log("Info", "=== Platform Socket Constants ===")
    log("Info", "DF supported:  \(PlatformSocketConstants.isDFSupported)")
    log("Info", "ECN supported: \(PlatformSocketConstants.isECNSupported)")
    log("Info", "GRO supported: \(PlatformSocketConstants.isGROSupported)")
    log("Info", "GSO supported: \(PlatformSocketConstants.isGSOSupported)")
    log("Info", "MTU query supported: \(PlatformSocketConstants.isMTUQuerySupported)")
    log("Info", "")

    // IPv4 options
    log("Info", "=== IPv4 QUIC Socket Options ===")
    let ipv4Opts = PlatformSocketOptions.forQUIC(
        addressFamily: .ipv4,
        enableECN: true,
        enableDF: true
    )
    for opt in ipv4Opts.options {
        log("Info", "  \(opt)")
    }
    log("Info", "  ecnEnabled=\(ipv4Opts.ecnEnabled)  dfEnabled=\(ipv4Opts.dfEnabled)")
    log("Info", "")

    // IPv6 options
    log("Info", "=== IPv6 QUIC Socket Options ===")
    let ipv6Opts = PlatformSocketOptions.forQUIC(
        addressFamily: .ipv6,
        enableECN: true,
        enableDF: true
    )
    for opt in ipv6Opts.options {
        log("Info", "  \(opt)")
    }
    log("Info", "  ecnEnabled=\(ipv6Opts.ecnEnabled)  dfEnabled=\(ipv6Opts.dfEnabled)")
    log("Info", "")

    // ECN TOS helpers
    log("Info", "=== ECN / TOS Helpers ===")
    let tosECT0 = tosWithECN(dscp: 0, ecn: 0x02)
    let tosECT1 = tosWithECN(dscp: 0, ecn: 0x01)
    let tosCE   = tosWithECN(dscp: 0, ecn: 0x03)
    log("Info", "  tosWithECN(dscp=0, ecn=ECT0) -> 0x\(String(tosECT0, radix: 16))")
    log("Info", "  tosWithECN(dscp=0, ecn=ECT1) -> 0x\(String(tosECT1, radix: 16))")
    log("Info", "  tosWithECN(dscp=0, ecn=CE)   -> 0x\(String(tosCE, radix: 16))")
    log("Info", "  ecnFromTOS(0x02) -> \(ecnFromTOS(0x02))")
    log("Info", "  ecnFromTOS(0x03) -> \(ecnFromTOS(0x03))")
    log("Info", "  ecnFromTOS(0x00) -> \(ecnFromTOS(0x00))")
    log("Info", "")

    // Interface MTU queries
    log("Info", "=== Interface MTU Queries ===")
    #if os(Linux)
    let loopback = "lo"
    #else
    let loopback = "lo0"
    #endif
    if let mtu = queryInterfaceMTU(loopback) {
        log("Info", "  \(loopback) MTU: \(mtu)")
    } else {
        log("Info", "  \(loopback) MTU: query failed")
    }

    if let defaultMTU = queryDefaultInterfaceMTU() {
        log("Info", "  Default interface MTU: \(defaultMTU)")
    } else {
        log("Info", "  Default interface MTU: query failed or no non-loopback interface")
    }

    // PMTUD configuration defaults
    log("Info", "")
    log("Info", "=== PMTUD Default Configuration ===")
    let pmtuConfig = PMTUConfiguration()
    log("Info", "  basePLPMTU:       \(pmtuConfig.basePLPMTU)")
    log("Info", "  maxPLPMTU:        \(pmtuConfig.maxPLPMTU)")
    log("Info", "  searchGranularity: \(pmtuConfig.searchGranularity)")
    log("Info", "  maxProbes:        \(pmtuConfig.maxProbes)")
    log("Info", "  probeTimeout:     \(pmtuConfig.probeTimeout)")
    log("Info", "  raiseTimer:       \(pmtuConfig.raiseTimer)")
    log("Info", "")
    log("Info", "Done.")
}

// MARK: - TLS Configuration

func makeServerTLSConfig(certPath: String?, keyPath: String?) throws -> (TLSConfiguration, String) {
    if let certPath = certPath, let keyPath = keyPath {
        var tlsConfig = try TLSConfiguration.server(
            certificatePath: certPath,
            privateKeyPath: keyPath,
            alpnProtocols: [demoALPN]
        )
        tlsConfig.verifyPeer = false
        return (tlsConfig, "production (cert: \(certPath))")
    }

    let signingKey = SigningKey.generateP256()
    let mockCertDER = Data([0x30, 0x82, 0x01, 0x00])
    var tlsConfig = TLSConfiguration.server(
        signingKey: signingKey,
        certificateChain: [mockCertDER],
        alpnProtocols: [demoALPN]
    )
    tlsConfig.verifyPeer = false
    return (tlsConfig, "development (self-signed P-256)")
}

func makeClientTLSConfig(caCertPath: String?) throws -> (TLSConfiguration, String) {
    if let caCertPath = caCertPath {
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [demoALPN]
        )
        try tlsConfig.loadTrustedCAs(fromPEMFile: caCertPath)
        tlsConfig.verifyPeer = true
        tlsConfig.allowSelfSigned = false
        return (tlsConfig, "production (CA: \(caCertPath))")
    }

    var tlsConfig = TLSConfiguration.client(
        serverName: "localhost",
        alpnProtocols: [demoALPN]
    )
    tlsConfig.verifyPeer = false
    tlsConfig.allowSelfSigned = true
    return (tlsConfig, "development (allowSelfSigned)")
}

// MARK: - QUIC Configuration

func makeServerConfiguration(
    certPath: String?,
    keyPath: String?,
    enableECN: Bool,
    enableDF: Bool
) throws -> QUICConfiguration {
    let (tlsConfig, description) = try makeServerTLSConfig(certPath: certPath, keyPath: keyPath)
    log("Config", "TLS: \(description)")
    log("Config", "ECN: \(enableECN)  DF: \(enableDF)")

    let isProduction = (certPath != nil && keyPath != nil)
    var config: QUICConfiguration
    if isProduction {
        config = QUICConfiguration.production {
            TLS13Handler(configuration: tlsConfig)
        }
    } else {
        config = QUICConfiguration.development {
            TLS13Handler(configuration: tlsConfig)
        }
    }

    config.alpn = [demoALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 10
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    // Socket configuration — the core of this demo
    config.socketConfiguration = SocketConfiguration(
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
        maxDatagramSize: 65507,
        enableECN: enableECN,
        enableDF: enableDF
    )

    return config
}

func makeClientConfiguration(
    caCertPath: String?,
    enableECN: Bool,
    enableDF: Bool
) throws -> QUICConfiguration {
    let (tlsConfig, description) = try makeClientTLSConfig(caCertPath: caCertPath)
    log("Config", "TLS: \(description)")
    log("Config", "ECN: \(enableECN)  DF: \(enableDF)")

    let isProduction = (caCertPath != nil)
    var config: QUICConfiguration
    if isProduction {
        config = QUICConfiguration.production {
            TLS13Handler(configuration: tlsConfig)
        }
    } else {
        config = QUICConfiguration.development {
            TLS13Handler(configuration: tlsConfig)
        }
    }

    config.alpn = [demoALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 10
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    config.socketConfiguration = SocketConfiguration(
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
        maxDatagramSize: 65507,
        enableECN: enableECN,
        enableDF: enableDF
    )

    return config
}

// MARK: - Diagnostic Helpers

/// Prints ECN and PMTUD state for a connection (requires ManagedConnection).
func printConnectionDiagnostics(_ tag: String, _ connection: any QUICConnectionProtocol) {
    guard let mc = connection as? ManagedConnection else {
        log(tag, "  (diagnostics unavailable — not a ManagedConnection)")
        return
    }

    // ECN
    log(tag, "  ECN enabled:    \(mc.isECNEnabled)")
    let ecnState = mc.ecnValidationState
    log(tag, "  ECN validation: \(ecnState)")

    // PMTUD
    log(tag, "  PMTUD state:    \(mc.pmtuState)")
    log(tag, "  Current PLPMTU: \(mc.currentPathMTU)")
    log(tag, "  PMTUD detail:   \(mc.pmtuDiagnostics)")
}

// MARK: - Server

func runServer(
    host: String,
    port: UInt16,
    certPath: String?,
    keyPath: String?,
    enableECN: Bool,
    enableDF: Bool
) async throws {
    log("Server", "=== QUIC Network Demo Server ===")
    log("Server", "Bind: \(host):\(port)  ALPN: \(demoALPN)")

    let config = try makeServerConfiguration(
        certPath: certPath,
        keyPath: keyPath,
        enableECN: enableECN,
        enableDF: enableDF
    )

    // Validate configuration (prints error and exits on failure)
    do {
        try config.validate()
        log("Server", "Configuration validated OK")
    } catch {
        log("Server", "Configuration validation FAILED: \(error)")
        exit(1)
    }

    // Log the platform options that will be applied
    let addrFamily: PlatformSocketOptions.AddressFamily =
        host.contains(":") ? .ipv6 : .ipv4
    let platformOpts = PlatformSocketOptions.forQUIC(
        addressFamily: addrFamily,
        enableECN: enableECN,
        enableDF: enableDF
    )
    log("Server", "Platform socket options (\(platformOpts.options.count) total):")
    for opt in platformOpts.options {
        log("Server", "  \(opt)")
    }

    let (endpoint, runTask) = try await QUICEndpoint.serve(
        host: host,
        port: port,
        configuration: config
    )

    if let addr = await endpoint.localAddress {
        log("Server", "Listening on \(addr)")
    }
    log("Server", "Waiting for connections... (Ctrl+C to stop)")
    log("Server", "")

    let connectionStream = await endpoint.incomingConnections
    var connectionCount: UInt64 = 0

    for await connection in connectionStream {
        connectionCount += 1
        let connID = connectionCount
        log("Server", "--- Connection #\(connID) from \(connection.remoteAddress) ---")
        printConnectionDiagnostics("Server", connection)

        Task {
            await handleServerConnection(connection, id: connID)
        }
    }

    await endpoint.stop()
    runTask.cancel()
    log("Server", "Server stopped.")
}

func handleServerConnection(_ connection: any QUICConnectionProtocol, id: UInt64) async {
    let tag = "Srv[\(id)]"
    var streamCount: UInt64 = 0

    for await stream in connection.incomingStreams {
        streamCount += 1
        let sID = streamCount
        log(tag, "Stream #\(sID) opened (id=\(stream.id))")

        Task {
            await handleServerStream(stream, tag: tag, streamNum: sID, connection: connection)
        }
    }

    log(tag, "Connection closed. Streams handled: \(streamCount)")
    // Final diagnostics
    printConnectionDiagnostics(tag, connection)
}

func handleServerStream(
    _ stream: any QUICStreamProtocol,
    tag: String,
    streamNum: UInt64,
    connection: any QUICConnectionProtocol
) async {
    var messagesEchoed = 0

    do {
        while true {
            let data = try await stream.read()
            if data.isEmpty { break }

            messagesEchoed += 1
            // Echo back
            try await stream.write(data)

            if let text = String(data: data, encoding: .utf8) {
                log(tag, "  [stream \(streamNum)] echo #\(messagesEchoed): \"\(text)\"")
            } else {
                log(tag, "  [stream \(streamNum)] echo #\(messagesEchoed): \(data.count) bytes")
            }

            // Periodically log ECN/PMTUD state
            if messagesEchoed % 5 == 0 {
                log(tag, "  --- periodic diagnostics (after \(messagesEchoed) echoes) ---")
                printConnectionDiagnostics(tag, connection)
            }
        }
    } catch {
        // Stream closed or error
        if messagesEchoed == 0 {
            log(tag, "  [stream \(streamNum)] closed with error: \(error)")
        }
    }

    log(tag, "  [stream \(streamNum)] done. Total echoed: \(messagesEchoed)")
}

// MARK: - Client

func runClient(
    host: String,
    port: UInt16,
    caCertPath: String?,
    enableECN: Bool,
    enableDF: Bool
) async throws {
    log("Client", "=== QUIC Network Demo Client ===")
    log("Client", "Target: \(host):\(port)")

    let config = try makeClientConfiguration(
        caCertPath: caCertPath,
        enableECN: enableECN,
        enableDF: enableDF
    )

    do {
        try config.validate()
        log("Client", "Configuration validated OK")
    } catch {
        log("Client", "Configuration validation FAILED: \(error)")
        exit(1)
    }

    let endpoint = QUICEndpoint(configuration: config)
    let serverAddress = QUIC.SocketAddress(ipAddress: host, port: port)

    log("Client", "Dialing \(serverAddress)...")
    let connection: any QUICConnectionProtocol
    do {
        connection = try await endpoint.dial(address: serverAddress, timeout: .seconds(10))
    } catch {
        log("Client", "Connection failed: \(error)")
        log("Client", "Ensure the server is running:")
        log("Client", "  swift run QUICNetworkDemo server --host \(host) --port \(port)")
        throw error
    }

    log("Client", "Connected!")
    log("Client", "  Local:  \(connection.localAddress?.description ?? "unknown")")
    log("Client", "  Remote: \(connection.remoteAddress)")
    log("Client", "")

    // --- Phase 1: Initial diagnostics ---
    log("Client", "=== Phase 1: Post-Handshake Diagnostics ===")
    printConnectionDiagnostics("Client", connection)
    log("Client", "")

    // --- Phase 2: ECN validation ping-pong ---
    log("Client", "=== Phase 2: ECN Validation (\(ecnPingRounds) rounds) ===")
    log("Client", "Opening stream for ping-pong...")
    let stream = try await connection.openStream()
    log("Client", "Stream opened (id=\(stream.id))")

    for round in 1...ecnPingRounds {
        let payload = "ping-\(round)"
        try await stream.write(Data(payload.utf8))

        let response = try await stream.read()
        let text = String(data: response, encoding: .utf8) ?? "<binary:\(response.count)>"

        if round % 5 == 0 || round == 1 || round == ecnPingRounds {
            log("Client", "  round \(round)/\(ecnPingRounds): sent=\"\(payload)\" recv=\"\(text)\"")
            printConnectionDiagnostics("Client", connection)
        }

        // Small delay so ACKs can flow and ECN validation can progress
        try await Task.sleep(for: .milliseconds(50))
    }

    log("Client", "")
    log("Client", "=== Phase 3: Post-ECN-Validation Diagnostics ===")
    printConnectionDiagnostics("Client", connection)
    log("Client", "")

    // --- Phase 4: PMTUD probe round-trip ---
    log("Client", "=== Phase 4: PMTUD Probe Round-Trip ===")
    if let mc = connection as? ManagedConnection {
        log("Client", "  PMTUD state (before):  \(mc.pmtuState)")
        log("Client", "  Current PLPMTU:        \(mc.currentPathMTU)")
        log("Client", "  PMTUD diagnostics:     \(mc.pmtuDiagnostics)")

        if mc.pmtuState != .disabled {
            log("Client", "  Sending PMTUD probe via sendPMTUProbe()...")
            let probeBefore = mc.pmtuState
            do {
                if let probe = try mc.sendPMTUProbe() {
                    log("Client", "    Probe SENT: size=\(probe.packetSize) challenge=\(probe.challengeData.count) bytes")
                    log("Client", "    PMTUD state (after send): \(mc.pmtuState)")

                    // Drive the connection with ping-pong rounds so the
                    // server's PATH_RESPONSE can arrive and be processed.
                    // The outbound send loop transmits the probe packet;
                    // we need the inbound loop to run and deliver the
                    // PATH_RESPONSE back.  Sending stream data forces
                    // ACK exchange which keeps the IO loops active.
                    let maxWaitRounds = 20
                    var acked = false
                    for tick in 1...maxWaitRounds {
                        // Small echo keeps both IO loops running
                        let ping = "pmtu-tick-\(tick)"
                        try await stream.write(Data(ping.utf8))
                        _ = try await stream.read()

                        // Check if probeAcknowledged fired
                        if mc.currentPathMTU > probe.packetSize - 1 || mc.pmtuState != probeBefore {
                            log("Client", "    PATH_RESPONSE received after \(tick) tick(s)")
                            acked = true
                            break
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }

                    if acked {
                        log("Client", "    PMTUD probe ACKNOWLEDGED")
                    } else {
                        log("Client", "    PMTUD probe NOT acknowledged within \(maxWaitRounds) ticks")
                    }
                } else {
                    log("Client", "    No probe generated (state=\(mc.pmtuState))")
                }
            } catch {
                log("Client", "    sendPMTUProbe error: \(error)")
            }
        } else {
            log("Client", "  PMTUD is disabled, skipping probe")
        }

        log("Client", "  PMTUD state (after):   \(mc.pmtuState)")
        log("Client", "  Current PLPMTU:        \(mc.currentPathMTU)")
        log("Client", "  PMTUD diagnostics:     \(mc.pmtuDiagnostics)")
        log("Client", "  MTU history count:     \(mc.pmtuHistoryCount)")
    } else {
        log("Client", "  (PMTUD diagnostics unavailable — not ManagedConnection)")
    }
    log("Client", "")

    // --- Phase 5: Larger payload test ---
    log("Client", "=== Phase 5: Larger Payload Echo ===")
    let sizes = [100, 500, 1000]
    for size in sizes {
        let payload = Data(repeating: 0x42, count: size)
        try await stream.write(payload)
        let response = try await stream.read()
        let match = (response == payload)
        log("Client", "  \(size) bytes: sent -> recv \(response.count) bytes, match=\(match)")
    }
    log("Client", "")

    // Close stream
    try await stream.closeWrite()
    log("Client", "Stream closed.")

    // --- Phase 6: Final summary ---
    log("Client", "")
    log("Client", "=== Final Summary ===")
    printConnectionDiagnostics("Client", connection)

    if let mc = connection as? ManagedConnection {
        let ecnOK = mc.isECNValidated
        let ecnEnabled = mc.isECNEnabled
        log("Client", "")
        log("Client", "ECN result:  enabled=\(ecnEnabled) validated=\(ecnOK)")
        log("Client", "PMTUD result: state=\(mc.pmtuState) plpmtu=\(mc.currentPathMTU)")
    }
    log("Client", "")

    // Cleanup
    await connection.close(error: nil)
    await endpoint.stop()
    log("Client", "Done.")
}

// MARK: - Help

func printHelp() {
    print("""

    QUIC Network Configuration Demo
    ================================

    Tests ECN, PMTUD, and platform socket options over a live QUIC connection.

    USAGE:
        swift run QUICNetworkDemo <mode> [options]

    MODES:
        info        Show platform socket capabilities (no network I/O)
        server      Start the demo server
        client      Connect and run ECN/PMTUD test sequence
        help        Show this help

    OPTIONS:
        --host <addr>       Host address (default: \(defaultHost))
        --port, -p <port>   Port number (default: \(defaultPort))
        --log-level, -l <v> Log level: trace|debug|info|notice|warning|error|critical
        --no-ecn            Disable ECN on the socket
        --no-df             Disable Don't Fragment bit (disables PMTUD)

    SERVER OPTIONS:
        --cert <path>       PEM certificate file
        --key <path>        PEM private key file

    CLIENT OPTIONS:
        --ca-cert <path>    PEM CA certificate file

    EXAMPLES:
        # 1) Check platform capabilities
        swift run QUICNetworkDemo info

        # 2) Run server + client with ECN and DF enabled (default)
        swift run QUICNetworkDemo server
        swift run QUICNetworkDemo client

        # 3) Disable ECN to see the difference
        swift run QUICNetworkDemo server --no-ecn
        swift run QUICNetworkDemo client --no-ecn

        # 4) Verbose logging
        swift run QUICNetworkDemo server --log-level trace

    """)
}

// MARK: - Entry Point

let arguments = DemoArguments.parse()

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = arguments.logLevel
    return handler
}

switch arguments.mode {
case .info:
    runInfo()

case .server:
    do {
        try await runServer(
            host: arguments.host,
            port: arguments.port,
            certPath: arguments.certPath,
            keyPath: arguments.keyPath,
            enableECN: arguments.enableECN,
            enableDF: arguments.enableDF
        )
    } catch {
        log("Server", "Fatal: \(error)")
        exit(1)
    }

case .client:
    do {
        try await runClient(
            host: arguments.host,
            port: arguments.port,
            caCertPath: arguments.caCertPath,
            enableECN: arguments.enableECN,
            enableDF: arguments.enableDF
        )
    } catch {
        log("Client", "Fatal: \(error)")
        exit(1)
    }

case .help:
    printHelp()
}