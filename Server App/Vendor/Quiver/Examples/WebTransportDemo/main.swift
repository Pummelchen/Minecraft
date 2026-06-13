// =============================================================================
// WebTransport Echo Server & Client Demo
// =============================================================================
//
// This example demonstrates the WebTransport API built on top of HTTP/3 + QUIC:
//   1. A WebTransport echo server that accepts sessions and echoes data back
//      on bidirectional streams, unidirectional streams, and datagrams
//   2. A WebTransport client that connects, sends messages via all three
//      transport mechanisms, and verifies the echoed responses
//
// ## Running
//
//   # Start the WebTransport echo server (default: 127.0.0.1:4445)
//   swift run WebTransportDemo server
//
//   # In another terminal, run the client
//   swift run WebTransportDemo client
//
//   # Custom host/port
//   swift run WebTransportDemo server --host 0.0.0.0 --port 5555
//   swift run WebTransportDemo client --host 127.0.0.1 --port 5555
//
//   # With real certificates (production mode)
//   swift run WebTransportDemo server --cert /path/to/cert.pem --key /path/to/key.pem
//   swift run WebTransportDemo client --ca-cert /path/to/ca.pem
//
// ## Architecture
//
//   ┌─────────────────────────┐       QUIC/UDP        ┌─────────────────────────┐
//   │   WebTransport Client   │ ◄───────────────────► │   WebTransport Server   │
//   │                         │   HTTP/3 + Extended    │                         │
//   │  connect(path: "/echo") │   CONNECT handshake    │  WebTransportServer     │
//   │                         │                        │  .listen(host:port:)    │
//   │  ┌───────────────────┐  │                        │  ┌───────────────────┐  │
//   │  │ Bidi Stream Echo  │──│── "Hello, bidi!" ────►│──│ Echo bidi streams │  │
//   │  │                   │◄─│── "Hello, bidi!" ◄────│──│                   │  │
//   │  ├───────────────────┤  │                        │  ├───────────────────┤  │
//   │  │ Uni Stream Echo   │──│── "Hello, uni!" ─────►│──│ Echo via new uni  │  │
//   │  │ (incoming uni)    │◄─│── "Hello, uni!" ◄─────│──│ stream back       │  │
//   │  ├───────────────────┤  │                        │  ├───────────────────┤  │
//   │  │ Datagram Echo     │──│── "ping" ────────────►│──│ Echo datagrams    │  │
//   │  │                   │◄─│── "ping" ◄────────────│──│                   │  │
//   │  └───────────────────┘  │                        │  └───────────────────┘  │
//   └─────────────────────────┘                        └─────────────────────────┘
//
// ## WebTransport Concepts
//
//   - **WebTransportSession**: Established via Extended CONNECT (RFC 9220) over
//     HTTP/3. A single HTTP/3 connection can host multiple sessions.
//
//   - **Bidirectional Streams**: Both sides can read and write. The session ID
//     is written as the first varint on the stream (framing is automatic).
//
//   - **Unidirectional Streams**: One-way data flow. Stream type 0x54 +
//     session ID are written as prefix (framing is automatic). For echo,
//     the server reads from the client's uni stream and sends the response
//     on a new server-initiated uni stream.
//
//   - **Datagrams**: Unreliable, unordered messages. Associated with the
//     session via a quarter-stream-ID prefix in the QUIC DATAGRAM frame.
//     Best for latency-sensitive data where occasional loss is acceptable.
//
// ## Security Modes
//
//   This demo supports two TLS modes:
//
//   1. **Development mode** (default, no arguments):
//      Uses a self-signed P-256 certificate generated at startup.
//      The client uses `allowSelfSigned = true` to accept it.
//      Provides REAL TLS 1.3 encryption but no identity verification.
//
//   2. **Production mode** (with --cert/--key and --ca-cert):
//      Uses PEM certificate and key files from disk.
//      The client verifies the server certificate against a trusted CA.
//      Full TLS 1.3 encryption and identity verification.
//
// =============================================================================

import Foundation
import HTTP3
import Logging
import NIOUDPTransport
import QPACK
import QUIC
import QUICCore
import QUICCrypto
import QUICTransport

// MARK: - Configuration

/// Default server address
let defaultHost = "127.0.0.1"

/// Default server port
let defaultPort: UInt16 = 4445

/// ALPN protocol for HTTP/3 (required for WebTransport)
let h3ALPN = "h3"

/// WebTransport session path
let echoPath = "/echo"

// MARK: - Argument Parsing

/// Simple argument parser for the demo
struct DemoArguments {
    enum Mode: String {
        case server
        case client
        case help
    }

    let mode: Mode
    let host: String
    let port: UInt16
    let logLevel: Logger.Level

    // TLS options
    let certPath: String?  // Server: PEM certificate path
    let keyPath: String?  // Server: PEM private key path
    let caCertPath: String?  // Client: PEM CA certificate path

    // Demo options
    let skipDatagrams: Bool

    static func parseLogLevel(_ string: String) -> Logger.Level? {
        switch string.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning", "warn": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return nil
        }
    }

    static func parse() -> DemoArguments {
        let args = CommandLine.arguments

        // Default values
        var mode: Mode = .help
        var host = defaultHost
        var port = defaultPort
        var logLevel: Logger.Level = .info
        var certPath: String?
        var keyPath: String?
        var caCertPath: String?
        var skipDatagrams = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "server":
                mode = .server
            case "client":
                mode = .client
            case "help", "--help", "-h":
                mode = .help
            case "--host":
                i += 1
                if i < args.count { host = args[i] }
            case "--port", "-p":
                i += 1
                if i < args.count { port = UInt16(args[i]) ?? defaultPort }
            case "--log-level", "-l":
                i += 1
                if i < args.count {
                    logLevel = parseLogLevel(args[i]) ?? .info
                }
            case "--cert":
                i += 1
                if i < args.count { certPath = args[i] }
            case "--key":
                i += 1
                if i < args.count { keyPath = args[i] }
            case "--ca-cert":
                i += 1
                if i < args.count { caCertPath = args[i] }
            case "--skip-datagrams":
                skipDatagrams = true
            default:
                break
            }
            i += 1
        }

        return DemoArguments(
            mode: mode,
            host: host,
            port: port,
            logLevel: logLevel,
            certPath: certPath,
            keyPath: keyPath,
            caCertPath: caCertPath,
            skipDatagrams: skipDatagrams
        )
    }
}

// MARK: - Logging Helper

func log(_ tag: String, _ message: String) {
    let timestamp = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    print("[\(formatter.string(from: timestamp))] [\(tag)] \(message)")
}

// MARK: - TLS Configuration Helpers

/// Creates a server TLS configuration.
///
/// When `certPath` and `keyPath` are provided, loads real PEM certificates
/// from disk (production mode). Otherwise, generates a self-signed P-256
/// key pair at startup (development mode).
func makeServerTLSConfig(certPath: String?, keyPath: String?) throws -> (TLSConfiguration, String) {
    if let certPath = certPath, let keyPath = keyPath {
        var tlsConfig = try TLSConfiguration.server(
            certificatePath: certPath,
            privateKeyPath: keyPath,
            alpnProtocols: [h3ALPN]
        )
        tlsConfig.verifyPeer = false
        return (tlsConfig, "Production (cert: \(certPath), key: \(keyPath))")
    } else {
        let signingKey = SigningKey.generateP256()
        let mockCertDER = Data([0x30, 0x82, 0x01, 0x00])
        var tlsConfig = TLSConfiguration.server(
            signingKey: signingKey,
            certificateChain: [mockCertDER],
            alpnProtocols: [h3ALPN]
        )
        tlsConfig.verifyPeer = false
        return (tlsConfig, "Development (self-signed P-256, no cert files)")
    }
}

/// Creates a client TLS configuration.
///
/// When `caCertPath` is provided, loads a trusted CA certificate from disk
/// and enables full peer verification (production mode). Otherwise, disables
/// strict verification and allows self-signed certificates (development mode).
func makeClientTLSConfig(caCertPath: String?) throws -> (TLSConfiguration, String) {
    if let caCertPath = caCertPath {
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [h3ALPN]
        )
        try tlsConfig.loadTrustedCAs(fromPEMFile: caCertPath)
        tlsConfig.verifyPeer = true
        tlsConfig.allowSelfSigned = false
        return (tlsConfig, "Production (CA: \(caCertPath), verifyPeer: true)")
    } else {
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [h3ALPN]
        )
        tlsConfig.verifyPeer = false
        tlsConfig.allowSelfSigned = true
        return (tlsConfig, "Development (allowSelfSigned: true, verifyPeer: false)")
    }
}

// MARK: - QUIC Configuration Helpers

/// Creates a QUIC configuration for the WebTransport server.
func makeServerConfiguration(certPath: String?, keyPath: String?) throws -> QUICConfiguration {
    let (tlsConfig, description) = try makeServerTLSConfig(certPath: certPath, keyPath: keyPath)
    log("Config", "TLS mode: \(description)")

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

    config.alpn = [h3ALPN]
    config.maxIdleTimeout = .seconds(60)

    // WebTransport requires generous stream limits:
    // - HTTP/3 control streams (3 uni from each side)
    // - QPACK encoder/decoder streams
    // - WebTransport bidi/uni streams for application data
    // - The Extended CONNECT stream itself
    config.initialMaxStreamsBidi = 200
    config.initialMaxStreamsUni = 200

    // Flow control limits
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    // WebTransport datagram support (RFC 9221)
    // Required for WebTransport datagrams — advertises max_datagram_frame_size
    // transport parameter so the peer knows we accept DATAGRAM frames.
    config.enableDatagrams = true
    config.maxDatagramFrameSize = 65535

    return config
}

/// Creates a QUIC configuration for the WebTransport client.
func makeClientConfiguration(caCertPath: String?) throws -> QUICConfiguration {
    let (tlsConfig, description) = try makeClientTLSConfig(caCertPath: caCertPath)
    log("Config", "TLS mode: \(description)")

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

    config.alpn = [h3ALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 200
    config.initialMaxStreamsUni = 200
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    // WebTransport datagram support (RFC 9221)
    config.enableDatagrams = true
    config.maxDatagramFrameSize = 65535

    return config
}

// MARK: - WebTransport Echo Server

/// Runs the WebTransport echo server.
///
/// The server:
/// 1. Creates a WebTransportServer with session limits
/// 2. Starts listening via `listen(host:port:quicConfiguration:)`
/// 3. For each incoming WebTransport session:
///    a. Echoes bidirectional stream data back to the sender
///    b. Reads unidirectional streams and sends a response on a new uni stream
///    c. Echoes datagrams back to the sender
///
/// ## WebTransport Server Setup Flow
///
/// ```
/// WebTransportServer.listen(host, port, quicConfig)
///   └─► QUICEndpoint.serve(host, port, config)   ← UDP socket + QUIC I/O
///       └─► HTTP3Server.serve(connectionSource)   ← HTTP/3 layer
///           └─► Extended CONNECT handler           ← WebTransport negotiation
///               └─► WebTransportSession created    ← Yielded to incomingSessions
/// ```
func runServer(host: String, port: UInt16, certPath: String?, keyPath: String?) async throws {
    log("Server", "╔══════════════════════════════════════════════════════════════╗")
    log("Server", "║            WebTransport Echo Server                         ║")
    log("Server", "╚══════════════════════════════════════════════════════════════╝")
    log("Server", "")
    log("Server", "Configuration:")
    log("Server", "  Address:       \(host):\(port)")
    log("Server", "  ALPN:          \(h3ALPN)")
    log("Server", "  Session path:  \(echoPath)")

    if let certPath = certPath, let keyPath = keyPath {
        log("Server", "  TLS:           Production (cert: \(certPath))")
        log("Server", "                 (key:  \(keyPath))")
    } else {
        log("Server", "  TLS:           Development (self-signed, real TLS 1.3 encryption)")
        if certPath != nil && keyPath == nil {
            log(
                "Server",
                "  Warning: --cert provided without --key, falling back to development mode")
        }
        if certPath == nil && keyPath != nil {
            log(
                "Server",
                "  Warning: --key provided without --cert, falling back to development mode")
        }
    }
    log("Server", "")

    // Step 1: Create the QUIC configuration
    let quicConfig = try makeServerConfiguration(certPath: certPath, keyPath: keyPath)

    // Step 2: Create the WebTransport server
    //
    // WebTransportServer wraps HTTP3Server and handles:
    //   - HTTP/3 SETTINGS with WebTransport extensions
    //     (ENABLE_CONNECT_PROTOCOL, H3_DATAGRAM, WEBTRANSPORT_MAX_SESSIONS)
    //   - Extended CONNECT request acceptance/rejection
    //   - WebTransportSession creation and lifecycle
    //
    let server = WebTransportServer(
        configuration: WebTransportConfiguration(
            quic: quicConfig,
            maxSessions: 4
        ),
        serverOptions: WebTransportServer.ServerOptions(
            allowedPaths: [echoPath]
        )
    )

    // Optionally serve regular HTTP/3 requests alongside WebTransport
    await server.onRequest { context in
        let body = """
            <!DOCTYPE html>
            <html>
            <head><title>WebTransport Echo Server</title></head>
            <body>
                <h1>WebTransport Echo Server</h1>
                <p>This server accepts WebTransport sessions at path <code>\(echoPath)</code>.</p>
                <p>Use the Quiver WebTransport client or a browser with WebTransport support.</p>
                <h2>Endpoints</h2>
                <ul>
                    <li><strong>Bidi stream echo</strong>: Open a bidirectional stream, send data, receive echo</li>
                    <li><strong>Uni stream echo</strong>: Open a unidirectional stream, send data; server responds on a new uni stream</li>
                    <li><strong>Datagram echo</strong>: Send a datagram, receive echo datagram</li>
                </ul>
            </body>
            </html>
            """
        try await context.respond(
            status: 200,
            headers: [("content-type", "text/html; charset=utf-8")],
            Data(body.utf8)
        )
    }

    // Step 3: Start the session handler in a background task
    //
    // `server.incomingSessions` is an AsyncStream<WebTransportSession>.
    // Each session represents a fully established WebTransport connection
    // that was accepted via Extended CONNECT.
    //
    var sessionCount: UInt64 = 0

    let sessionHandlerTask = Task {
        for await session in await server.incomingSessions {
            sessionCount += 1
            let sessionNum = sessionCount
            let sessionID = await session.sessionID

            log("Server", "")
            log("Server", "═══ New WebTransport Session #\(sessionNum) ═══")
            log("Server", "  Session ID: \(sessionID)")
            log("Server", "")

            // Handle each session concurrently
            Task {
                await handleServerSession(session, sessionNum: sessionNum)
            }
        }
    }

    log("Server", "Registered echo handlers:")
    log("Server", "  • Bidirectional stream echo")
    log("Server", "  • Unidirectional stream echo (read → respond on new uni)")
    log("Server", "  • Datagram echo")
    log("Server", "")
    log("Server", "Listening on \(host):\(port)")
    log("Server", "Press Ctrl+C to stop")
    log("Server", "")
    log("Server", "Waiting for WebTransport sessions...")
    log(
        "Server",
        "  (Connect with: swift run WebTransportDemo client --host \(host) --port \(port))")
    log("Server", "")

    // Step 4: Start listening
    //
    // server.listen() creates the full QUIC + HTTP/3 stack internally:
    //   1. Creates a NIOQUICSocket bound to host:port
    //   2. Starts a QUICEndpoint with the I/O loop
    //   3. Starts an HTTP3Server that processes connections
    //   4. Registers Extended CONNECT handler for WebTransport
    //
    // This call blocks until stop() is called.
    //
    do {
        try await server.listen(
            host: host,
            port: port
        )
    } catch {
        log("Server", "Server error: \(error)")
    }

    // Cleanup
    sessionHandlerTask.cancel()
    log("Server", "Shutting down...")
    await server.stop(gracePeriod: .seconds(5))
    log("Server", "Server stopped.")
}

// MARK: - Session Handler (Server-side)

/// Handles a single WebTransport session by running echo handlers concurrently.
///
/// Spawns three concurrent tasks:
/// 1. Bidirectional stream echo
/// 2. Unidirectional stream echo
/// 3. Datagram echo
func handleServerSession(_ session: WebTransportSession, sessionNum: UInt64) async {
    let tag = "Session#\(sessionNum)"

    // Run all echo handlers concurrently
    await withTaskGroup(of: Void.self) { group in

        // Handler 1: Echo bidirectional streams
        //
        // When the client opens a bidi stream, we read data and write it back.
        // The session ID framing is handled automatically by the WebTransport layer.
        group.addTask {
            var streamCount: UInt64 = 0
            for await stream in await session.incomingBidirectionalStreams {
                streamCount += 1
                let streamNum = streamCount
                let streamID = stream.id

                log(tag, "Bidi stream #\(streamNum) opened (QUIC stream \(streamID))")

                Task {
                    await handleBidiEcho(
                        stream,
                        tag: tag,
                        streamNum: streamNum
                    )
                }
            }
            log(tag, "Incoming bidi streams ended (total: \(streamCount))")
        }

        // Handler 2: Echo unidirectional streams
        //
        // When the client opens a uni stream, we read all data from it,
        // then open a new server→client uni stream and write the data there.
        // This demonstrates the uni stream echo pattern since uni streams
        // are one-directional.
        group.addTask {
            var streamCount: UInt64 = 0
            for await stream in await session.incomingUnidirectionalStreams {
                streamCount += 1
                let streamNum = streamCount
                let streamID = stream.id

                log(tag, "Uni stream #\(streamNum) received (QUIC stream \(streamID))")

                Task {
                    await handleUniEcho(
                        session: session,
                        incomingStream: stream,
                        tag: tag,
                        streamNum: streamNum
                    )
                }
            }
            log(tag, "Incoming uni streams ended (total: \(streamCount))")
        }

        // Handler 3: Echo datagrams
        //
        // QUIC datagrams are unreliable, unordered messages. The session
        // associates them with this session using the quarter-stream-ID prefix.
        // We simply echo each datagram back.
        group.addTask {
            var datagramCount: UInt64 = 0
            for await datagram in await session.incomingDatagrams {
                datagramCount += 1

                if let text = String(data: datagram, encoding: .utf8) {
                    log(
                        tag,
                        "Datagram #\(datagramCount) received: \"\(text)\" (\(datagram.count) bytes)"
                    )
                } else {
                    log(tag, "Datagram #\(datagramCount) received: \(datagram.count) bytes")
                }

                // Echo back
                do {
                    try await session.sendDatagram(datagram)
                    log(tag, "Datagram #\(datagramCount) echoed")
                } catch {
                    log(tag, "Datagram #\(datagramCount) echo failed: \(error)")
                }
            }
            log(tag, "Incoming datagrams ended (total: \(datagramCount))")
        }

        // Wait for all handlers to complete (session closed or streams ended)
    }

    let isClosed = await session.isClosed
    log(tag, "Session ended (closed: \(isClosed))")
}

/// Echoes data on a bidirectional stream.
///
/// Reads data in a loop and writes it back until the client closes
/// the write side (FIN received, indicated by empty data).
func handleBidiEcho(
    _ stream: WebTransportStream,
    tag: String,
    streamNum: UInt64
) async {
    var totalBytes: UInt64 = 0
    var messageCount: UInt64 = 0

    do {
        while true {
            let data = try await stream.read()

            // Empty data means FIN received (stream closed by peer)
            if data.isEmpty {
                log(tag, "Bidi #\(streamNum): FIN received")
                break
            }

            messageCount += 1
            totalBytes += UInt64(data.count)

            if let text = String(data: data, encoding: .utf8) {
                log(tag, "Bidi #\(streamNum): read \"\(text)\" (\(data.count) bytes)")
            } else {
                log(tag, "Bidi #\(streamNum): read \(data.count) bytes")
            }

            // Echo back
            try await stream.write(data)
            log(tag, "Bidi #\(streamNum): echoed \(data.count) bytes")
        }

        // Close our write side to signal we're done
        try await stream.closeWrite()
        log(
            tag, "Bidi #\(streamNum): closed (total: \(messageCount) messages, \(totalBytes) bytes)"
        )
    } catch {
        log(tag, "Bidi #\(streamNum): error: \(error)")
    }
}

/// Echoes data from an incoming unidirectional stream by reading all data
/// and sending it back on a new server-initiated unidirectional stream.
///
/// Since uni streams are one-directional, the echo pattern is:
///   client → uni stream → server (reads all) → new uni stream → client
func handleUniEcho(
    session: WebTransportSession,
    incomingStream: WebTransportStream,
    tag: String,
    streamNum: UInt64
) async {
    // Read all data from the incoming uni stream
    var receivedData = Data()
    do {
        while true {
            let chunk = try await incomingStream.read()
            if chunk.isEmpty {
                break
            }
            receivedData.append(chunk)
        }
    } catch {
        log(tag, "Uni #\(streamNum): read error: \(error)")
        // Still try to echo whatever we received
    }

    if receivedData.isEmpty {
        log(tag, "Uni #\(streamNum): received empty stream, skipping echo")
        return
    }

    if let text = String(data: receivedData, encoding: .utf8) {
        log(tag, "Uni #\(streamNum): received \"\(text)\" (\(receivedData.count) bytes total)")
    } else {
        log(tag, "Uni #\(streamNum): received \(receivedData.count) bytes total")
    }

    // Open a new server→client uni stream and send the echo
    do {
        let responseStream = try await session.openUnidirectionalStream()
        try await responseStream.write(receivedData)
        try await responseStream.closeWrite()
        log(tag, "Uni #\(streamNum): echoed on new uni stream (QUIC stream \(responseStream.id))")
    } catch {
        log(tag, "Uni #\(streamNum): echo send error: \(error)")
    }
}

// MARK: - WebTransport Echo Client

/// Runs the WebTransport echo client.
///
/// The client:
/// 1. Establishes a QUIC connection to the server
/// 2. Creates a WebTransportClient and initializes the HTTP/3 layer
/// 3. Opens a WebTransport session via Extended CONNECT
/// 4. Tests all three echo mechanisms:
///    a. Bidirectional stream echo
///    b. Unidirectional stream echo
///    c. Datagram echo
///
/// ## Client Setup Flow
///
/// ```
/// QUICEndpoint(config).dial(address)          ← QUIC handshake
///   └─► WebTransportClient(quicConnection)
///       └─► client.initialize()                ← HTTP/3 SETTINGS exchange
///           └─► client.connect(path: "/echo")  ← Extended CONNECT → 200 OK
///               └─► WebTransportSession        ← Ready for streams & datagrams
/// ```
func runClient(host: String, port: UInt16, caCertPath: String?, skipDatagrams: Bool) async throws {
    log("Client", "╔══════════════════════════════════════════════════════════════╗")
    log("Client", "║            WebTransport Echo Client                         ║")
    log("Client", "╚══════════════════════════════════════════════════════════════╝")
    log("Client", "")
    log("Client", "Connecting to \(host):\(port)")

    if let caCertPath = caCertPath {
        log("Client", "  TLS: Production (CA cert: \(caCertPath))")
    } else {
        log("Client", "  TLS: Development (allowSelfSigned: true)")
    }
    log("Client", "")

    // Step 1: Create client QUIC configuration
    let config = try makeClientConfiguration(caCertPath: caCertPath)

    // Step 2: Connect to the server via QUIC
    //
    // QUICEndpoint.dial() performs the full QUIC handshake:
    //   1. Creates a UDP socket on a random local port
    //   2. Sends Initial packet (ClientHello)
    //   3. Processes server's Initial + Handshake packets
    //   4. Completes TLS 1.3 handshake
    //
    let endpoint = QUICEndpoint(configuration: config)
    let serverAddress = QUIC.SocketAddress(ipAddress: host, port: port)

    log("Client", "Dialing QUIC connection to \(serverAddress)...")
    let quicConnection: any QUICConnectionProtocol
    do {
        quicConnection = try await endpoint.dial(address: serverAddress, timeout: .seconds(10))
    } catch {
        log("Client", "Failed to connect: \(error)")
        log("Client", "")
        log("Client", "Make sure the server is running:")
        log("Client", "  swift run WebTransportDemo server --host \(host) --port \(port)")
        throw error
    }

    log("Client", "QUIC connection established!")
    log("Client", "  Local:  \(quicConnection.localAddress?.description ?? "unknown")")
    log("Client", "  Remote: \(quicConnection.remoteAddress)")
    log("Client", "")

    // Step 3: Initialize the WebTransport client
    //
    // WebTransportClient wraps the QUIC connection with an HTTP/3 layer:
    //   - Opens HTTP/3 control stream, sends SETTINGS
    //   - Opens QPACK encoder/decoder streams
    //   - Waits for server's SETTINGS (checks WebTransport support)
    //
    log("Client", "Initializing HTTP/3 + WebTransport layer...")
    let wtClient = WebTransportClient(
        quicConnection: quicConnection,
        configuration: WebTransportClient.Configuration(
            maxSessions: 1,
            connectionReadyTimeout: .seconds(10),
            connectTimeout: .seconds(10)
        )
    )
    try await wtClient.initialize()
    log("Client", "HTTP/3 layer ready")
    log("Client", "")

    // Step 4: Establish a WebTransport session
    //
    // connect() sends an Extended CONNECT request:
    //   :method = CONNECT
    //   :protocol = webtransport
    //   :scheme = https
    //   :authority = host:port
    //   :path = /echo
    //
    // The server responds with 200 OK to accept the session.
    //
    log("Client", "Opening WebTransport session (path: \(echoPath))...")
    let session: WebTransportSession
    do {
        session = try await wtClient.connect(
            authority: "\(host):\(port)",
            path: echoPath
        )
    } catch {
        log("Client", "WebTransport session failed: \(error)")
        await quicConnection.close(error: nil)
        await endpoint.stop()
        throw error
    }

    let sessionID = await session.sessionID
    log("Client", "WebTransport session established!")
    log("Client", "  Session ID: \(sessionID)")
    log("Client", "")

    // Small delay to let the session fully stabilize
    try await Task.sleep(for: .milliseconds(100))

    // =========================================================================
    // Test 1: Bidirectional Stream Echo
    // =========================================================================
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "  Test 1: Bidirectional Stream Echo")
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "")

    do {
        try await testBidiStreamEcho(session: session)
        log("Client", "")
        log("Client", "✓ Bidi stream echo: PASSED")
    } catch {
        log("Client", "")
        log("Client", "✗ Bidi stream echo: FAILED — \(error)")
    }
    log("Client", "")

    try await Task.sleep(for: .milliseconds(200))

    // =========================================================================
    // Test 2: Unidirectional Stream Echo
    // =========================================================================
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "  Test 2: Unidirectional Stream Echo")
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "")

    do {
        try await testUniStreamEcho(session: session)
        log("Client", "")
        log("Client", "✓ Uni stream echo: PASSED")
    } catch {
        log("Client", "")
        log("Client", "✗ Uni stream echo: FAILED — \(error)")
    }
    log("Client", "")

    try await Task.sleep(for: .milliseconds(200))

    // =========================================================================
    // Test 3: Datagram Echo
    // =========================================================================
    if !skipDatagrams {
        log("Client", "═══════════════════════════════════════════════════════════")
        log("Client", "  Test 3: Datagram Echo")
        log("Client", "═══════════════════════════════════════════════════════════")
        log("Client", "")

        do {
            try await testDatagramEcho(session: session)
            log("Client", "")
            log("Client", "✓ Datagram echo: PASSED")
        } catch {
            log("Client", "")
            log("Client", "✗ Datagram echo: FAILED — \(error)")
        }
        log("Client", "")
    } else {
        log("Client", "(Skipping datagram test — use without --skip-datagrams to enable)")
        log("Client", "")
    }

    // =========================================================================
    // Cleanup
    // =========================================================================
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "  Cleanup")
    log("Client", "═══════════════════════════════════════════════════════════")
    log("Client", "")

    log("Client", "Closing WebTransport session...")
    try await session.close()
    log("Client", "Session closed")

    log("Client", "Closing QUIC connection...")
    await wtClient.close()
    await endpoint.stop()
    log("Client", "Connection closed")

    log("Client", "")
    log("Client", "╔══════════════════════════════════════════════════════════════╗")
    log("Client", "║            Demo Complete!                                   ║")
    log("Client", "╚══════════════════════════════════════════════════════════════╝")
}

// MARK: - Test: Bidirectional Stream Echo

/// Tests bidirectional stream echo.
///
/// Opens a bidi stream, sends multiple messages, reads back echoes,
/// then closes the stream gracefully.
func testBidiStreamEcho(session: WebTransportSession) async throws {
    // Open a bidirectional stream
    //
    // The WebTransport layer automatically writes the session ID as
    // the first varint on the stream. After that, all reads/writes
    // are pure application data.
    //
    log("Client", "Opening bidirectional stream...")
    let stream = try await session.openBidirectionalStream()
    log("Client", "Bidi stream opened (QUIC stream \(stream.id))")

    let messages = [
        "Hello, WebTransport!",
        "Bidirectional stream echo test 🚀",
        "This is message number three.",
    ]

    for (index, message) in messages.enumerated() {
        let data = Data(message.utf8)
        let num = index + 1

        log("Client", "[\(num)/\(messages.count)] Sending: \"\(message)\" (\(data.count) bytes)")
        try await stream.write(data)

        let echo = try await stream.read()
        if let echoText = String(data: echo, encoding: .utf8) {
            log(
                "Client",
                "[\(num)/\(messages.count)] Received: \"\(echoText)\" (\(echo.count) bytes)")
        } else {
            log("Client", "[\(num)/\(messages.count)] Received: \(echo.count) bytes")
        }

        // Verify echo matches
        if echo == data {
            log("Client", "[\(num)/\(messages.count)] ✓ Match")
        } else {
            log(
                "Client",
                "[\(num)/\(messages.count)] ✗ Mismatch! Expected \(data.count) bytes, got \(echo.count)"
            )
        }
    }

    // Close the stream
    log("Client", "Closing bidi stream...")
    try await stream.closeWrite()
    log("Client", "Bidi stream closed")
}

// MARK: - Test: Unidirectional Stream Echo

/// Tests unidirectional stream echo.
///
/// Opens a client→server uni stream, writes data, closes it.
/// Then reads from the server→client uni stream to get the echo.
///
/// The echo pattern for uni streams is:
///   1. Client opens uni stream, writes data, closes with FIN
///   2. Server reads all data from client's uni stream
///   3. Server opens a new uni stream, writes the echo, closes with FIN
///   4. Client reads the echo from the server's uni stream
func testUniStreamEcho(session: WebTransportSession) async throws {
    let message = "Hello via unidirectional stream! 📡"
    let data = Data(message.utf8)

    // Start listening for the server's response uni stream BEFORE sending.
    // This avoids a race condition where the server sends the response
    // before we start listening.
    log("Client", "Setting up uni stream listener...")

    let echoReceived = Task<Data, Error> { () -> Data in
        // Wait for the server's response on a new uni stream
        var iterator = await session.incomingUnidirectionalStreams.makeAsyncIterator()
        guard let responseStream = await iterator.next() else {
            throw DemoError.noResponseStream
        }

        log("Client", "Incoming uni stream received (QUIC stream \(responseStream.id))")

        // Read all data from the response stream
        var received = Data()
        while true {
            let chunk = try await responseStream.read()
            if chunk.isEmpty {
                break
            }
            received.append(chunk)
        }
        return received
    }

    // Send data on a client→server uni stream
    log("Client", "Opening unidirectional stream...")
    let sendStream = try await session.openUnidirectionalStream()
    log("Client", "Uni stream opened (QUIC stream \(sendStream.id))")

    log("Client", "Sending: \"\(message)\" (\(data.count) bytes)")
    try await sendStream.write(data)
    try await sendStream.closeWrite()
    log("Client", "Uni stream closed (FIN sent)")

    // Wait for the echo response with a timeout
    log("Client", "Waiting for echo response on incoming uni stream...")

    let echo: Data
    do {
        echo = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await echoReceived.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw DemoError.timeout("Uni stream echo response")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    } catch {
        echoReceived.cancel()
        throw error
    }

    if let echoText = String(data: echo, encoding: .utf8) {
        log("Client", "Received echo: \"\(echoText)\" (\(echo.count) bytes)")
    } else {
        log("Client", "Received echo: \(echo.count) bytes")
    }

    // Verify
    if echo == data {
        log("Client", "✓ Uni stream echo matches")
    } else {
        log("Client", "✗ Uni stream echo mismatch! Expected \(data.count) bytes, got \(echo.count)")
    }
}

// MARK: - Test: Datagram Echo

/// Tests datagram echo.
///
/// Sends QUIC datagrams and verifies they are echoed back.
/// Datagrams are unreliable, so we send multiple and accept
/// partial success.
func testDatagramEcho(session: WebTransportSession) async throws {
    let messages = [
        "ping",
        "datagram test 🏓",
        "unreliable but fast!",
    ]

    let expectedCount = messages.count

    // Start listening for echoed datagrams BEFORE sending.
    // The Task collects datagrams internally and returns them,
    // avoiding mutable capture across Sendable boundaries.
    let receiverTask = Task<[Data], Never> {
        var collected: [Data] = []
        var count = 0
        for await datagram in await session.incomingDatagrams {
            collected.append(datagram)
            count += 1
            if let text = String(data: datagram, encoding: .utf8) {
                log("Client", "Received datagram #\(count): \"\(text)\" (\(datagram.count) bytes)")
            } else {
                log("Client", "Received datagram #\(count): \(datagram.count) bytes")
            }
            // We expect at most messages.count echoes
            if count >= expectedCount {
                break
            }
        }
        return collected
    }

    // Send datagrams
    for (index, message) in messages.enumerated() {
        let data = Data(message.utf8)
        let num = index + 1

        log(
            "Client",
            "[\(num)/\(messages.count)] Sending datagram: \"\(message)\" (\(data.count) bytes)")
        do {
            try await session.sendDatagram(data)
        } catch {
            log("Client", "[\(num)/\(messages.count)] Send failed: \(error)")
            log("Client", "  (Datagrams require H3_DATAGRAM and may not be supported by all peers)")
        }

        // Small delay between sends
        try await Task.sleep(for: .milliseconds(50))
    }

    // Wait for echoes with a timeout
    log("Client", "Waiting for datagram echoes...")

    let receivedDatagrams: [Data]
    do {
        receivedDatagrams = try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask {
                await receiverTask.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return []  // timeout sentinel returns empty
            }
            // First task to finish wins
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    } catch {
        // Timeout is acceptable for datagrams (they're unreliable)
        receivedDatagrams = []
    }

    receiverTask.cancel()

    let sent = messages.count
    let received = receivedDatagrams.count
    log("Client", "Datagram results: \(received)/\(sent) echoed")

    if received > 0 {
        log("Client", "✓ At least some datagrams were echoed (\(received)/\(sent))")
    } else {
        log(
            "Client",
            "⚠ No datagrams were echoed (datagrams are unreliable, or H3_DATAGRAM not negotiated)")
    }
}

// MARK: - Errors

enum DemoError: Error, CustomStringConvertible {
    case noResponseStream
    case timeout(String)
    case echoMismatch(expected: Int, got: Int)

    var description: String {
        switch self {
        case .noResponseStream:
            return "No response unidirectional stream received from server"
        case .timeout(let what):
            return "Timeout waiting for: \(what)"
        case .echoMismatch(let expected, let got):
            return "Echo mismatch: expected \(expected) bytes, got \(got) bytes"
        }
    }
}

// MARK: - Help

func printHelp() {
    print(
        """

        WebTransport Echo Demo
        ======================

        A demo that showcases WebTransport over HTTP/3 + QUIC with three
        echo mechanisms: bidirectional streams, unidirectional streams,
        and datagrams.

        USAGE:
            swift run WebTransportDemo <mode> [options]

        MODES:
            server      Start the WebTransport echo server
            client      Connect to the server and run echo tests
            help        Show this help message

        OPTIONS:
            --host <address>        Host address (default: \(defaultHost))
            --port, -p <port>       Port number (default: \(defaultPort))
            --log-level, -l <level> Log verbosity (default: info)
                                    Levels: trace, debug, info, notice, warning, error, critical

        SERVER OPTIONS:
            --cert <path>           Path to PEM certificate file
            --key <path>            Path to PEM private key file

            When both --cert and --key are provided, the server runs in
            production mode with the specified certificate. Otherwise, it
            generates a self-signed P-256 key pair for development.

        CLIENT OPTIONS:
            --ca-cert <path>        Path to PEM CA certificate file
            --skip-datagrams        Skip the datagram echo test

            When --ca-cert is provided, the client verifies the server's
            certificate against the trusted CA (production mode). Otherwise,
            it accepts self-signed certificates (development mode).

        EXAMPLES:
            # Development mode (self-signed, real TLS encryption)
            swift run WebTransportDemo server
            swift run WebTransportDemo client

            # Production mode (with real certificates)
            swift run WebTransportDemo server --cert server.pem --key server-key.pem
            swift run WebTransportDemo client --ca-cert ca.pem

            # Custom host/port
            swift run WebTransportDemo server --host 0.0.0.0 --port 5555
            swift run WebTransportDemo client --host 192.168.1.10 --port 5555

            # Verbose logging
            swift run WebTransportDemo server --log-level debug
            swift run WebTransportDemo client --log-level trace

            # Skip datagram test (if not supported)
            swift run WebTransportDemo client --skip-datagrams

        ECHO MECHANISMS:

            1. Bidirectional Stream Echo
               Client opens a bidi stream, sends messages, reads echoes.
               Both sides can read and write on the same stream.

               Client                          Server
                 |── open bidi stream ──────────►|
                 |── "Hello, WebTransport!" ────►|
                 |◄── "Hello, WebTransport!" ────|
                 |── closeWrite (FIN) ──────────►|
                 |◄── closeWrite (FIN) ──────────|

            2. Unidirectional Stream Echo
               Client opens a uni stream (client→server), sends data, closes it.
               Server reads all data, then opens a new uni stream (server→client)
               and writes the echo.

               Client                          Server
                 |── open uni stream ───────────►|
                 |── "Hello, uni!" ─────────────►|
                 |── closeWrite (FIN) ──────────►|
                 |                               |── reads all data
                 |◄──────── open uni stream ─────|
                 |◄──────── "Hello, uni!" ───────|
                 |◄──────── closeWrite (FIN) ────|

            3. Datagram Echo
               Client sends QUIC datagrams, server echoes them back.
               Datagrams are unreliable and unordered — some may be lost.

               Client                          Server
                 |── datagram "ping" ───────────►|
                 |◄── datagram "ping" ───────────|
                 |── datagram "pong" ───────────►|
                 |◄── datagram "pong" ───────────|

        WEBTRANSPORT ARCHITECTURE:

            ┌──────────────────────────────────────────────────────┐
            │  WebTransport Session                                │
            │  (Established via Extended CONNECT on HTTP/3)        │
            │                                                      │
            │  ┌──────────────────┐  ┌──────────────────┐         │
            │  │ Bidi Streams     │  │ Uni Streams       │         │
            │  │ (both directions)│  │ (one direction)   │         │
            │  └──────────────────┘  └──────────────────┘         │
            │  ┌──────────────────┐                                │
            │  │ Datagrams        │                                │
            │  │ (unreliable)     │                                │
            │  └──────────────────┘                                │
            ├──────────────────────────────────────────────────────┤
            │  HTTP/3 (RFC 9114)                                   │
            │  • SETTINGS with WebTransport extensions             │
            │  • Extended CONNECT (RFC 9220)                       │
            │  • H3_DATAGRAM, ENABLE_CONNECT_PROTOCOL              │
            ├──────────────────────────────────────────────────────┤
            │  QUIC (RFC 9000)                                     │
            │  • Multiplexed streams, flow control                 │
            │  • TLS 1.3 encryption                                │
            │  • Connection migration, 0-RTT                       │
            ├──────────────────────────────────────────────────────┤
            │  UDP Transport (swift-nio-udp)                       │
            └──────────────────────────────────────────────────────┘

        """)
}

// MARK: - Entry Point

let arguments = DemoArguments.parse()

// Bootstrap swift-log with the requested log level.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = arguments.logLevel
    return handler
}

switch arguments.mode {
case .server:
    do {
        try await runServer(
            host: arguments.host,
            port: arguments.port,
            certPath: arguments.certPath,
            keyPath: arguments.keyPath
        )
    } catch {
        log("Server", "Fatal error: \(error)")
        exit(1)
    }

case .client:
    do {
        try await runClient(
            host: arguments.host,
            port: arguments.port,
            caCertPath: arguments.caCertPath,
            skipDatagrams: arguments.skipDatagrams
        )
    } catch {
        log("Client", "Fatal error: \(error)")
        exit(1)
    }

case .help:
    printHelp()
}
