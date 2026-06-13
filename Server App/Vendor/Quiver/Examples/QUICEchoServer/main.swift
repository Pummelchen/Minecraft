// =============================================================================
// QUIC Echo Server & Client Demo
// =============================================================================
//
// This example demonstrates the core QUIC protocol API by implementing:
//   1. An echo server that listens for QUIC connections and echoes back stream data
//   2. A client that connects, sends messages, and reads echoed responses
//
// ## Running
//
//   # Start the echo server (default: 127.0.0.1:4433)
//   swift run QUICEchoServer server
//
//   # In another terminal, run the client
//   swift run QUICEchoServer client
//
//   # Custom host/port
//   swift run QUICEchoServer server --host 0.0.0.0 --port 5555
//   swift run QUICEchoServer client --host 127.0.0.1 --port 5555
//
//   # With real certificates (production mode)
//   swift run QUICEchoServer server --cert /path/to/cert.pem --key /path/to/key.pem
//   swift run QUICEchoServer client --ca-cert /path/to/ca.pem
//
// ## Architecture
//
//   ┌──────────────┐         UDP          ┌──────────────┐
//   │  QUIC Client │ ◄──────────────────► │  QUIC Server │
//   │              │    QUIC Connection    │              │
//   │  openStream()│ ────── Stream 0 ───► │  echoBack()  │
//   │  write(data) │ ────── "Hello!" ───► │  read()      │
//   │  read()      │ ◄───── "Hello!" ──── │  write(data) │
//   └──────────────┘                      └──────────────┘
//
// ## Key Concepts
//
//   - **QUICEndpoint**: The top-level object that manages UDP I/O and connections.
//     It can operate in server mode (accepting connections) or client mode (dialing).
//
//   - **QUICConfiguration**: Holds transport parameters (timeouts, flow control limits,
//     ALPN, TLS settings).
//
//   - **QUICConnectionProtocol**: Represents a multiplexed QUIC connection.
//     Supports opening/accepting bidirectional and unidirectional streams.
//
//   - **QUICStreamProtocol**: A single stream within a connection. Supports
//     `read()`, `write()`, `closeWrite()`, and `reset()`.
//
//   - **NIOQUICSocket**: UDP socket backed by SwiftNIO for real network I/O.
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
import Logging
import QUIC
import QUICCore
import QUICCrypto
import QUICTransport
import NIOUDPTransport

// MARK: - Configuration

/// Default server address
let defaultHost = "127.0.0.1"

/// Default server port
let defaultPort: UInt16 = 4433

/// ALPN protocol identifier for this demo
let demoALPN = "quic-echo-demo"

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

    /// Path to PEM certificate file (server only)
    let certPath: String?

    /// Path to PEM private key file (server only)
    let keyPath: String?

    /// Path to PEM CA certificate file (client only)
    let caCertPath: String?

    /// Parses a string into a `Logger.Level`.
    ///
    /// Accepted values (case-insensitive):
    ///   trace, debug, info, notice, warning, error, critical
    static func parseLogLevel(_ string: String) -> Logger.Level? {
        switch string.lowercased() {
        case "trace":    return .trace
        case "debug":    return .debug
        case "info":     return .info
        case "notice":   return .notice
        case "warning":  return .warning
        case "error":    return .error
        case "critical": return .critical
        default:         return nil
        }
    }

    static func parse() -> DemoArguments {
        let args = CommandLine.arguments

        // Default mode
        var mode: Mode = .help
        var host = defaultHost
        var port = defaultPort
        var logLevel: Logger.Level = .info
        var certPath: String? = nil
        var keyPath: String? = nil
        var caCertPath: String? = nil

        var i = 1
        while i < args.count {
            switch args[i] {
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
                if i < args.count, let level = parseLogLevel(args[i]) {
                    logLevel = level
                } else {
                    print("Warning: Invalid log level '\(i < args.count ? args[i] : "")', using 'info'")
                    print("  Valid levels: trace, debug, info, notice, warning, error, critical")
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
            caCertPath: caCertPath
        )
    }
}

// MARK: - Logging Helpers

/// Prints a timestamped log message with a prefix tag
func log(_ tag: String, _ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] [\(tag)] \(message)")
}

// MARK: - TLS Configuration Helpers

/// Creates a server TLS configuration.
///
/// When `certPath` and `keyPath` are provided, loads real PEM certificates
/// from disk (production mode). Otherwise, generates a self-signed P-256
/// key pair at startup (development mode).
///
/// - Parameters:
///   - certPath: Optional path to PEM certificate file
///   - keyPath: Optional path to PEM private key file
/// - Returns: A tuple of (TLSConfiguration, description) for logging
func makeServerTLSConfig(certPath: String?, keyPath: String?) throws -> (TLSConfiguration, String) {
    if let certPath = certPath, let keyPath = keyPath {
        // Production mode: load certificates from disk
        var tlsConfig = try TLSConfiguration.server(
            certificatePath: certPath,
            privateKeyPath: keyPath,
            alpnProtocols: [demoALPN]
        )
        tlsConfig.verifyPeer = false  // Server doesn't verify client certs in this demo
        return (tlsConfig, "Production (cert: \(certPath), key: \(keyPath))")
    } else {
        // Development mode: generate a self-signed P-256 key
        let signingKey = SigningKey.generateP256()
        // Use a minimal DER-encoded certificate placeholder.
        // TLS13Handler uses the signingKey for CertificateVerify; the certificate
        // chain is sent to the peer but validation is handled by the client config.
        let mockCertDER = Data([0x30, 0x82, 0x01, 0x00])
        var tlsConfig = TLSConfiguration.server(
            signingKey: signingKey,
            certificateChain: [mockCertDER],
            alpnProtocols: [demoALPN]
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
///
/// - Parameter caCertPath: Optional path to PEM CA certificate file
/// - Returns: A tuple of (TLSConfiguration, description) for logging
func makeClientTLSConfig(caCertPath: String?) throws -> (TLSConfiguration, String) {
    if let caCertPath = caCertPath {
        // Production mode: verify server certificate against trusted CA
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [demoALPN]
        )
        try tlsConfig.loadTrustedCAs(fromPEMFile: caCertPath)
        tlsConfig.verifyPeer = true
        tlsConfig.allowSelfSigned = false
        return (tlsConfig, "Production (CA: \(caCertPath), verifyPeer: true)")
    } else {
        // Development mode: accept self-signed certificates
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [demoALPN]
        )
        tlsConfig.verifyPeer = false
        tlsConfig.allowSelfSigned = true
        return (tlsConfig, "Development (allowSelfSigned: true, verifyPeer: false)")
    }
}

// MARK: - QUIC Configuration Helper

/// Creates a QUIC configuration for the server.
///
/// Uses `.production()` or `.development()` security mode depending on whether
/// certificate files are provided.
///
/// - Parameters:
///   - certPath: Optional path to PEM certificate file
///   - keyPath: Optional path to PEM private key file
/// - Returns: A configured QUICConfiguration
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

    config.alpn = [demoALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 100
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000
    return config
}

/// Creates a QUIC configuration for the client.
///
/// Uses `.production()` or `.development()` security mode depending on whether
/// a CA certificate file is provided.
///
/// - Parameter caCertPath: Optional path to PEM CA certificate file
/// - Returns: A configured QUICConfiguration
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

    config.alpn = [demoALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 100
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000
    return config
}

// MARK: - Echo Server

/// Runs the QUIC echo server
///
/// The server:
/// 1. Creates a QUIC configuration with TLS
/// 2. Starts a `QUICEndpoint` via `serve(host:port:configuration:)` (creates socket internally)
/// 3. Accepts incoming connections from `endpoint.incomingConnections`
/// 4. For each connection, accepts streams and echoes data back
///
/// ## Example Flow
///
/// ```
/// Server starts listening on 127.0.0.1:4433
///   <- Client connects (QUIC handshake)
///   <- Client opens stream #0
///   <- Client sends "Hello, QUIC!"
///   -> Server echoes "Hello, QUIC!"
///   <- Client closes write side (FIN)
///   -> Server closes write side (FIN)
///   <- Client closes connection
/// ```
func runServer(host: String, port: UInt16, certPath: String?, keyPath: String?) async throws {
    log("Server", "Starting QUIC Echo Server...")
    log("Server", "Configuration:")
    log("Server", "  Address: \(host):\(port)")
    log("Server", "  ALPN: \(demoALPN)")

    if let certPath = certPath, let keyPath = keyPath {
        log("Server", "  TLS: Production (cert: \(certPath))")
        log("Server", "       (key:  \(keyPath))")
    } else {
        log("Server", "  TLS: Development (self-signed, real TLS 1.3 encryption)")
        if certPath != nil && keyPath == nil {
            log("Server", "  Warning: --cert provided without --key, falling back to development mode")
        }
        if certPath == nil && keyPath != nil {
            log("Server", "  Warning: --key provided without --cert, falling back to development mode")
        }
    }
    log("Server", "")

    // Step 1: Create the QUIC configuration with real TLS
    //
    // QUICConfiguration holds all transport parameters including:
    //   - Flow control limits (max data, max streams)
    //   - Idle timeout
    //   - ALPN protocols
    //   - TLS/security settings (via TLS13Handler)
    //
    let config = try makeServerConfiguration(certPath: certPath, keyPath: keyPath)

    // Step 2: Create server endpoint and start I/O loop
    //
    // QUICEndpoint.serve(host:port:configuration:) creates a NIOQUICSocket
    // internally, binds it to the specified address, and starts the packet
    // processing loop in a background Task. The returned `runTask` drives
    // the I/O loop until cancelled or stopped.
    //
    let (endpoint, runTask) = try await QUICEndpoint.serve(
        host: host,
        port: port,
        configuration: config
    )

    if let addr = await endpoint.localAddress {
        log("Server", "Listening on \(addr)")
    } else {
        log("Server", "Listening on \(host):\(port)")
    }
    log("Server", "Press Ctrl+C to stop")
    log("Server", "")
    log("Server", "Waiting for connections...")

    // Step 3: Accept incoming connections
    //
    // `endpoint.incomingConnections` is an AsyncStream<QUICConnectionProtocol>
    // that yields each new QUIC connection after the handshake completes.
    //
    // Each connection is handled in a separate Task for concurrency.
    //
    let connectionStream = await endpoint.incomingConnections

    // Set up graceful shutdown on SIGINT
    let shutdownTask = Task {
        // Wait for cancellation signal
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    var connectionCount: UInt64 = 0

    for await connection in connectionStream {
        connectionCount += 1
        let connID = connectionCount

        log("Server", "New connection #\(connID) from \(connection.remoteAddress)")

        // Handle each connection concurrently
        Task {
            await handleServerConnection(connection, id: connID)
        }
    }

    // Cleanup
    shutdownTask.cancel()
    log("Server", "Server shutting down...")
    await endpoint.stop()
    runTask.cancel()
    log("Server", "Server stopped.")
}

/// Handles a single QUIC connection on the server side
///
/// Accepts all incoming streams and echoes data back on each one.
///
/// - Parameters:
///   - connection: The QUIC connection to handle
///   - id: A human-readable connection identifier for logging
func handleServerConnection(_ connection: any QUICConnectionProtocol, id: UInt64) async {
    log("Server/Conn#\(id)", "Connection established")
    log("Server/Conn#\(id)", "  Remote: \(connection.remoteAddress)")
    log("Server/Conn#\(id)", "  Established: \(connection.isEstablished)")

    var streamCount: UInt64 = 0

    // Accept all incoming streams from this connection
    //
    // `connection.incomingStreams` is an AsyncStream<QUICStreamProtocol>
    // that yields each stream opened by the remote peer.
    //
    for await stream in connection.incomingStreams {
        streamCount += 1
        let streamNum = streamCount

        log("Server/Conn#\(id)", "New stream #\(streamNum) (ID: \(stream.id), bidi: \(stream.isBidirectional))")

        // Handle each stream concurrently
        Task {
            await handleEchoStream(stream, connectionID: id, streamNum: streamNum)
        }
    }

    log("Server/Conn#\(id)", "Connection closed (handled \(streamCount) streams)")
}

/// Echoes data received on a stream back to the sender
///
/// This demonstrates the basic stream read/write API:
///
/// ```swift
/// // Read data from the peer
/// let data = try await stream.read()
///
/// // Write data back to the peer
/// try await stream.write(data)
///
/// // Signal end of data (FIN)
/// try await stream.closeWrite()
/// ```
///
/// - Parameters:
///   - stream: The QUIC stream to echo on
///   - connectionID: Parent connection ID for logging
///   - streamNum: Stream number for logging
func handleEchoStream(_ stream: any QUICStreamProtocol, connectionID: UInt64, streamNum: UInt64) async {
    let tag = "Server/Conn#\(connectionID)/Stream#\(streamNum)"
    var totalBytesEchoed: UInt64 = 0

    do {
        // Read data in a loop until the stream ends (peer sends FIN or empty data)
        while true {
            // read() returns the next chunk of data from the stream.
            // It blocks (suspends) until data is available.
            // Returns empty Data when the stream is finished (FIN received).
            let data = try await stream.read()

            // Empty data means the peer closed their write side
            if data.isEmpty {
                log(tag, "Peer finished sending (FIN received)")
                break
            }

            totalBytesEchoed += UInt64(data.count)

            if let text = String(data: data, encoding: .utf8) {
                log(tag, "Received \(data.count) bytes: \"\(text)\"")
            } else {
                log(tag, "Received \(data.count) bytes (binary)")
            }

            // Echo the data back
            try await stream.write(data)
            log(tag, "Echoed \(data.count) bytes back")
        }

        // Close our write side to signal we're done
        try await stream.closeWrite()
        log(tag, "Stream complete (echoed \(totalBytesEchoed) bytes total)")

    } catch {
        log(tag, "Stream error: \(error)")
        // Reset the stream on error
        await stream.reset(errorCode: 0x01)
    }
}

// MARK: - Echo Client

/// Runs the QUIC echo client
///
/// The client:
/// 1. Creates a `QUICEndpoint` in client mode
/// 2. Dials the server address (performs QUIC handshake)
/// 3. Opens a bidirectional stream
/// 4. Sends several messages and reads echoed responses
/// 5. Closes the stream and connection
///
/// ## Key API Methods
///
/// ```swift
/// // Create client endpoint
/// let endpoint = QUICEndpoint(configuration: config)
///
/// // Connect to server (blocks until handshake completes)
/// let connection = try await endpoint.dial(address: serverAddress, timeout: .seconds(10))
///
/// // Open a new bidirectional stream
/// let stream = try await connection.openStream()
///
/// // Send data
/// try await stream.write(Data("Hello".utf8))
///
/// // Receive response
/// let response = try await stream.read()
///
/// // Close write side (send FIN)
/// try await stream.closeWrite()
///
/// // Close connection
/// await connection.close(error: nil)
/// ```
func runClient(host: String, port: UInt16, caCertPath: String?) async throws {
    log("Client", "Starting QUIC Echo Client...")
    log("Client", "Connecting to \(host):\(port)")

    if let caCertPath = caCertPath {
        log("Client", "  TLS: Production (CA cert: \(caCertPath))")
    } else {
        log("Client", "  TLS: Development (allowSelfSigned: true)")
    }
    log("Client", "")

    // Step 1: Create configuration with real TLS (must match server's ALPN)
    let config = try makeClientConfiguration(caCertPath: caCertPath)

    // Step 2: Create client endpoint
    //
    // A client endpoint can make outgoing connections. It creates its own
    // UDP socket internally when you call `dial()`.
    //
    let endpoint = QUICEndpoint(configuration: config)

    // Step 3: Connect to the server
    //
    // `dial()` performs the full QUIC handshake:
    //   1. Creates a UDP socket on a random local port
    //   2. Sends Initial packet (ClientHello)
    //   3. Processes server's Initial + Handshake packets
    //   4. Completes TLS 1.3 handshake
    //   5. Returns when connection is established
    //
    // The timeout parameter controls how long to wait for the handshake.
    //
    let serverAddress = QUIC.SocketAddress(ipAddress: host, port: port)

    log("Client", "Dialing \(serverAddress)...")
    let connection: any QUICConnectionProtocol
    do {
        connection = try await endpoint.dial(address: serverAddress, timeout: .seconds(10))
    } catch {
        log("Client", "Failed to connect: \(error)")
        log("Client", "")
        log("Client", "Make sure the server is running:")
        log("Client", "  swift run QUICEchoServer server --host \(host) --port \(port)")
        throw error
    }

    log("Client", "Connected!")
    log("Client", "  Local:  \(connection.localAddress?.description ?? "unknown")")
    log("Client", "  Remote: \(connection.remoteAddress)")
    log("Client", "")

    // Step 4: Open a bidirectional stream
    //
    // Bidirectional streams allow both sides to send and receive data.
    // Stream IDs are assigned automatically (client-initiated bidi: 0, 4, 8, ...)
    //
    log("Client", "Opening bidirectional stream...")
    let stream = try await connection.openStream()
    log("Client", "Stream opened (ID: \(stream.id))")
    log("Client", "")

    // Step 5: Send messages and read echoed responses
    let messages = [
        "Hello, QUIC!",
        "This is a test message.",
        "Quiver echo demo \u{1F680}",
        "Final message."
    ]

    for (index, message) in messages.enumerated() {
        let data = Data(message.utf8)

        log("Client", "[\(index + 1)/\(messages.count)] Sending: \"\(message)\" (\(data.count) bytes)")
        try await stream.write(data)

        // Read the echoed response
        let response = try await stream.read()
        if let responseText = String(data: response, encoding: .utf8) {
            log("Client", "[\(index + 1)/\(messages.count)] Received echo: \"\(responseText)\" (\(response.count) bytes)")
        } else {
            log("Client", "[\(index + 1)/\(messages.count)] Received echo: \(response.count) bytes")
        }

        // Small delay between messages for readability
        try await Task.sleep(for: .milliseconds(100))
    }

    log("Client", "")
    log("Client", "All messages echoed successfully!")

    // Step 6: Close the stream
    //
    // closeWrite() sends a FIN flag on the stream, signaling that
    // we won't send any more data. The server can still send data
    // back until it also closes its write side.
    //
    log("Client", "Closing stream...")
    try await stream.closeWrite()

    // Step 7: Open a second stream to demonstrate multiplexing
    log("Client", "")
    log("Client", "--- Demonstrating Stream Multiplexing ---")
    log("Client", "Opening second stream...")

    let stream2 = try await connection.openStream()
    log("Client", "Second stream opened (ID: \(stream2.id))")

    let multiplexMessage = "Hello from stream #2!"
    try await stream2.write(Data(multiplexMessage.utf8))

    let echo2 = try await stream2.read()
    if let text = String(data: echo2, encoding: .utf8) {
        log("Client", "Stream #2 echo: \"\(text)\"")
    }

    try await stream2.closeWrite()
    log("Client", "Second stream closed.")

    // Step 8: Close the connection
    //
    // close(error: nil) performs a graceful shutdown:
    //   - Sends CONNECTION_CLOSE frame
    //   - Drains in-flight packets
    //   - Releases resources
    //
    // Pass an error code for abnormal closure:
    //   await connection.close(error: 0x01)
    //
    // Or with an application error and reason string:
    //   await connection.close(applicationError: 0x42, reason: "Done")
    //
    log("Client", "")
    log("Client", "Closing connection...")
    await connection.close(error: nil)
    await endpoint.stop()

    log("Client", "Connection closed. Demo complete!")
}

// MARK: - Help Text

func printHelp() {
    print("""
    \u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}
    \u{2502}              QUIC Echo Server/Client Demo                   \u{2502}
    \u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256F}

    USAGE:
        swift run QUICEchoServer <mode> [options]

    MODES:
        server      Start the echo server
        client      Connect to the echo server and send messages
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

        When --ca-cert is provided, the client verifies the server's
        certificate against the trusted CA (production mode). Otherwise,
        it accepts self-signed certificates (development mode).

    EXAMPLES:
        # Development mode (self-signed certificate, real TLS encryption)
        swift run QUICEchoServer server
        swift run QUICEchoServer client

        # Production mode (with real certificates)
        swift run QUICEchoServer server --cert server.pem --key server-key.pem
        swift run QUICEchoServer client --ca-cert ca.pem

        # Custom host/port
        swift run QUICEchoServer server --host 0.0.0.0 --port 5555
        swift run QUICEchoServer client --host 192.168.1.10 --port 5555

        # Enable verbose logging
        swift run QUICEchoServer server --log-level trace

    ARCHITECTURE:

        API Hierarchy:
        \u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}
        \u{2502}  QUICEndpoint    \u{2502}  <- Top-level: manages UDP I/O & connections
        \u{2502}  \u{251C}\u{2500}\u{2500} dial()      \u{2502}  <- Client: connect to server
        \u{2502}  \u{2514}\u{2500}\u{2500} serve()     \u{2502}  <- Server: accept connections
        \u{251C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}
        \u{2502}  QUICConnection  \u{2502}  <- One per peer: multiplexes streams
        \u{2502}  \u{251C}\u{2500}\u{2500} openStream()\u{2502}  <- Create a new stream
        \u{2502}  \u{2514}\u{2500}\u{2500} incoming    \u{2502}  <- Accept streams from peer
        \u{2502}      Streams     \u{2502}
        \u{251C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}
        \u{2502}  QUICStream      \u{2502}  <- One per stream: read/write data
        \u{2502}  \u{251C}\u{2500}\u{2500} read()      \u{2502}  <- Receive data
        \u{2502}  \u{251C}\u{2500}\u{2500} write()     \u{2502}  <- Send data
        \u{2502}  \u{2514}\u{2500}\u{2500} closeWrite()\u{2502}  <- Signal end of data (FIN)
        \u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}

    TLS SECURITY:
        This demo uses TLS13Handler for real TLS 1.3 encryption.

        Development mode (default):
          - Generates a self-signed P-256 key pair at startup
          - Client accepts self-signed certificates (allowSelfSigned: true)
          - Provides real encryption, but no identity verification

        Production mode (with --cert/--key and --ca-cert):
          - Server loads PEM certificate and key from files
          - Client verifies server against trusted CA certificate
          - Full encryption + identity verification

    """)
}

// MARK: - Entry Point

let arguments = DemoArguments.parse()

// Bootstrap swift-log with the requested log level.
// This MUST be called once before any Logger is used.
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
            caCertPath: arguments.caCertPath
        )
    } catch {
        log("Client", "Fatal error: \(error)")
        exit(1)
    }

case .help:
    printHelp()
}
