// =============================================================================
// HTTP/3 Server & Client Demo
// =============================================================================
//
// This example demonstrates the HTTP/3 protocol API built on top of QUIC:
//   1. An HTTP/3 server with routing, middleware-style handling, and JSON APIs
//   2. An HTTP/3 client that makes requests to the server
//
// ## Running
//
//   # Start the HTTP/3 server (default: 127.0.0.1:4443)
//   swift run HTTP3Demo server
//
//   # In another terminal, run the client demo
//   swift run HTTP3Demo client
//
//   # Custom host/port
//   swift run HTTP3Demo server --host 0.0.0.0 --port 8443
//   swift run HTTP3Demo client --host 127.0.0.1 --port 8443
//
// ## Architecture
//
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │  HTTP/3 Layer (RFC 9114)                                           │
//   │  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐    │
//   │  │ HTTP3Server  │  │ HTTP3Router  │  │ HTTP3Connection        │    │
//   │  │ .onRequest() │──│ .get("/")    │  │ • Control stream       │    │
//   │  │ .serve()     │  │ .post("/api")│  │ • QPACK enc/dec streams│    │
//   │  │ .stop()      │  │ .handler     │  │ • Request streams      │    │
//   │  └──────┬───────┘  └──────────────┘  └────────────────────────┘    │
//   ├─────────┼──────────────────────────────────────────────────────────┤
//   │  QPACK Header Compression (RFC 9204)                               │
//   │  • Encodes/decodes HTTP headers efficiently                        │
//   │  • Literal-only mode (no dynamic table) for simplicity             │
//   ├─────────┼──────────────────────────────────────────────────────────┤
//   │  QUIC Transport (RFC 9000)                                         │
//   │  ┌──────┴───────┐  ┌──────────────┐  ┌────────────────────────┐   │
//   │  │ QUICEndpoint  │  │ Managed      │  │ NIOQUICSocket          │   │
//   │  │ (server mode) │──│ Connection   │──│ (UDP I/O via SwiftNIO) │   │
//   │  └──────────────┘  └──────────────┘  └────────────────────────┘   │
//   └─────────────────────────────────────────────────────────────────────┘
//
// ## HTTP/3 vs HTTP/1.1
//
//   HTTP/3 runs over QUIC instead of TCP, providing:
//   • No head-of-line blocking between streams
//   • Built-in encryption (TLS 1.3)
//   • Connection migration (survives IP changes)
//   • Faster connection establishment (0-RTT)
//   • QPACK header compression (evolved from HPACK)
//
// ## Key Types
//
//   - **HTTP3Server**: Accepts QUIC connections and dispatches HTTP/3 requests
//   - **HTTP3Router**: Path-based request routing (GET, POST, PUT, DELETE, etc.)
//   - **HTTP3Connection**: Manages HTTP/3 state on top of a QUIC connection
//   - **HTTP3Request**: Incoming request (method, path, headers, body)
//   - **HTTP3Response**: Outgoing response (status, headers, body)
//   - **HTTP3RequestContext**: Wraps request + respond callback for handlers
//   - **HTTP3Settings**: QPACK and HTTP/3 configuration parameters
//   - **HTTP3Client**: Connection-pooling HTTP/3 client
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
import HTTP3
import QPACK

// MARK: - Configuration

/// Default server address
let defaultHost = "127.0.0.1"

/// Default server port
let defaultPort: UInt16 = 4443

/// ALPN protocol for HTTP/3
let h3ALPN = "h3"

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

// MARK: - Logging

/// Prints a timestamped log message
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
            alpnProtocols: [h3ALPN]
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
///
/// - Parameter caCertPath: Optional path to PEM CA certificate file
/// - Returns: A tuple of (TLSConfiguration, description) for logging
func makeClientTLSConfig(caCertPath: String?) throws -> (TLSConfiguration, String) {
    if let caCertPath = caCertPath {
        // Production mode: verify server certificate against trusted CA
        var tlsConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: [h3ALPN]
        )
        try tlsConfig.loadTrustedCAs(fromPEMFile: caCertPath)
        tlsConfig.verifyPeer = true
        tlsConfig.allowSelfSigned = false
        return (tlsConfig, "Production (CA: \(caCertPath), verifyPeer: true)")
    } else {
        // Development mode: accept self-signed certificates
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

/// Creates a QUIC configuration for the HTTP/3 server.
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

    config.alpn = [h3ALPN]
    config.maxIdleTimeout = .seconds(60)

    // HTTP/3 requires multiple unidirectional streams for control and QPACK
    // (at minimum 3 from each side: control, QPACK encoder, QPACK decoder)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 100

    // Flow control limits
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    return config
}

/// Creates a QUIC configuration for the HTTP/3 client.
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

    config.alpn = [h3ALPN]
    config.maxIdleTimeout = .seconds(60)
    config.initialMaxStreamsBidi = 100
    config.initialMaxStreamsUni = 100
    config.initialMaxData = 10_000_000
    config.initialMaxStreamDataBidiLocal = 1_000_000
    config.initialMaxStreamDataBidiRemote = 1_000_000
    config.initialMaxStreamDataUni = 1_000_000

    return config
}

// MARK: - HTTP/3 Server

/// Runs the HTTP/3 demo server
///
/// ## Server Setup Flow
///
/// 1. **Create QUICConfiguration** — Transport parameters + TLS settings
/// 2. **Create NIOQUICSocket** — UDP socket for network I/O
/// 3. **Start QUICEndpoint** — Manages QUIC connections over the socket
/// 4. **Create HTTP3Server** — HTTP/3 layer on top of QUIC
/// 5. **Register routes** — Define request handlers via HTTP3Router
/// 6. **Serve** — Feed incoming QUIC connections to the HTTP/3 server
///
/// ## HTTP3Server API
///
/// ```swift
/// // Create server with settings
/// let server = HTTP3Server(settings: HTTP3Settings())
///
/// // Register a simple request handler
/// server.onRequest { context in
///     try await context.respond(status: 200, Data("OK".utf8))
/// }
///
/// // Or use a router for path-based routing
/// let router = HTTP3Router()
/// router.get("/") { ctx in ... }
/// router.post("/api/data") { ctx in ... }
/// server.onRequest(router.handler)
///
/// // Start serving (blocks until connection source ends or server stops)
/// try await server.serve(connectionSource: endpoint.incomingConnections)
///
/// // Graceful shutdown
/// await server.stop(gracePeriod: .seconds(5))
/// ```
///
/// ## HTTP3Settings
///
/// Controls QPACK header compression behavior:
///
/// ```swift
/// // Literal-only mode (simplest, no dynamic table)
/// let settings = HTTP3Settings()  // defaults
///
/// // With QPACK dynamic table for better compression
/// let settings = HTTP3Settings(
///     maxTableCapacity: 4096,       // 4 KB dynamic table
///     maxFieldSectionSize: 65536,   // 64 KB max header size
///     qpackBlockedStreams: 100      // Allow 100 blocked streams
/// )
///
/// // Predefined configurations
/// let s1 = HTTP3Settings.literalOnly          // No dynamic table
/// let s2 = HTTP3Settings.smallDynamicTable    // 4 KB table
/// let s3 = HTTP3Settings.largeDynamicTable    // 16 KB table
/// ```
func runServer(host: String, port: UInt16, certPath: String?, keyPath: String?) async throws {
    log("HTTP3", "╔══════════════════════════════════════════════════════════════╗")
    log("HTTP3", "║              HTTP/3 Demo Server                             ║")
    log("HTTP3", "╚══════════════════════════════════════════════════════════════╝")
    log("HTTP3", "")
    log("HTTP3", "Configuration:")
    log("HTTP3", "  Address:  \(host):\(port)")
    log("HTTP3", "  ALPN:     \(h3ALPN)")
    log("HTTP3", "  QPACK:    literal-only (no dynamic table)")

    if let certPath = certPath, let keyPath = keyPath {
        log("HTTP3", "  TLS:      Production (cert: \(certPath))")
        log("HTTP3", "            (key:  \(keyPath))")
    } else {
        log("HTTP3", "  TLS:      Development (self-signed, real TLS 1.3 encryption)")
        if certPath != nil && keyPath == nil {
            log("HTTP3", "  Warning: --cert provided without --key, falling back to development mode")
        }
        if certPath == nil && keyPath != nil {
            log("HTTP3", "  Warning: --key provided without --cert, falling back to development mode")
        }
    }
    log("HTTP3", "")

    // =========================================================================
    // Step 1: Create QUIC configuration with real TLS
    // =========================================================================
    //
    // The QUIC configuration determines transport parameters that are
    // exchanged during the handshake. Both client and server must agree
    // on compatible settings. TLS13Handler provides real TLS 1.3 encryption.
    //
    let quicConfig = try makeServerConfiguration(certPath: certPath, keyPath: keyPath)

    // =========================================================================
    // Step 2: Create the HTTP/3 server and set up routing
    // =========================================================================
    //
    // HTTP3Server manages the HTTP/3 protocol layer:
    //   - Accepts QUIC connections
    //   - Initializes HTTP/3 on each (control streams, SETTINGS exchange)
    //   - Dispatches incoming requests to the registered handler
    //   - Tracks connection and request metrics
    //
    // HTTP3Settings controls the QPACK header compression behavior:
    //   - literalOnly: Simple mode, no dynamic table synchronization needed
    //   - smallDynamicTable: Better compression for repeated headers
    //   - largeDynamicTable: Best compression for high-throughput
    //
    let h3Settings = HTTP3Settings.literalOnly
    let server = HTTP3Server(settings: h3Settings, maxConnections: 100)

    //
    // HTTP3Router provides Express.js-style path-based routing.
    //
    // Supported methods: .get(), .post(), .put(), .delete(), .patch(), .route()
    //
    // Each handler receives an HTTP3RequestContext containing:
    //   - context.request: The HTTP3Request (method, path, headers, body)
    //   - context.streamID: The QUIC stream ID this request arrived on
    //   - context.respond(): Send an HTTP3Response back to the client
    //
    let router = buildRouter()
    await server.onRequest(router.handler)

    log("HTTP3", "")
    log("HTTP3", "Registered routes:")
    log("HTTP3", "  GET  /              → Welcome page (HTML)")
    log("HTTP3", "  GET  /health        → Health check (JSON)")
    log("HTTP3", "  GET  /info          → Server info (JSON)")
    log("HTTP3", "  POST /echo          → Echo request body")
    log("HTTP3", "  POST /api/json      → JSON echo API")
    log("HTTP3", "  GET  /headers       → Reflect request headers")
    log("HTTP3", "  GET  /stream-info   → QUIC stream metadata")
    log("HTTP3", "  *    /api/method    → Shows which HTTP method was used")
    log("HTTP3", "  *    (not found)    → 404 with helpful message")
    log("HTTP3", "")
    log("HTTP3", "Server ready! Waiting for HTTP/3 connections...")
    log("HTTP3", "Press Ctrl+C to stop")
    log("HTTP3", "")

    // =========================================================================
    // Step 3: Listen for connections
    // =========================================================================
    //
    // server.listen() creates the full QUIC stack internally:
    //   1. Creates a NIOQUICSocket bound to host:port
    //   2. Starts a QUICEndpoint with the I/O loop
    //   3. Feeds incoming QUIC connections into the HTTP/3 layer
    //
    // For each new QUIC connection the server:
    //   1. Creates an HTTP3Connection (wraps QUICConnectionProtocol)
    //   2. Opens control stream → sends SETTINGS frame
    //   3. Opens QPACK encoder/decoder streams
    //   4. Waits for peer's control stream and SETTINGS
    //   5. Processes incoming request streams (bidi streams from client)
    //   6. For each request: decodes HEADERS, reads DATA, calls handler
    //   7. Handler calls context.respond() → encodes and sends response
    //
    // This call blocks until server.stop() is called.
    // stop() tears down the QUIC endpoint and I/O loop automatically.
    //
    do {
        try await server.listen(
            host: host,
            port: port,
            quicConfiguration: quicConfig
        )
    } catch {
        log("HTTP3", "Server error: \(error)")
    }

    // Cleanup
    log("HTTP3", "Shutting down...")
    await server.stop(gracePeriod: .seconds(5))
    log("HTTP3", "Server stopped.")
}

// MARK: - Router Setup

/// Builds the HTTP/3 router with demo routes
///
/// ## HTTP3Router API
///
/// ```swift
/// let router = HTTP3Router()
///
/// // Register routes by HTTP method
/// router.get("/path") { context in
///     try await context.respond(status: 200)
/// }
///
///     let body = try await context.body.data()
///     // ...
///     try await context.respond(status: 201)
/// }
///
/// // Route matching any method
/// router.route("/any-method") { context in
///     // context.request.method tells you which method was used
/// }
///
/// // Custom 404 handler
/// router.setNotFound { context in
///     try await context.respond(status: 404, Data("Oops!".utf8))
/// }
///
/// // Use the router with HTTP3Server
/// server.onRequest(router.handler)
/// ```
///
/// ## HTTP3Request
///
/// ```swift
/// let request = context.request
/// request.method      // HTTPMethod (.get, .post, .put, .delete, ...)
/// request.scheme      // "https" (always for HTTP/3)
/// request.authority   // "example.com:443"
/// request.path        // "/api/data"
/// request.headers     // [(String, String)] — header name-value pairs
/// request.body        // Data? — request body (nil for GET)
/// ```
///
/// ## HTTP3Response
///
/// ```swift
/// // Simple response
/// let response = HTTP3Response(status: 200)
///
/// // Response with headers and body
/// let response = HTTP3Response(
///     status: 200,
///     headers: [
///         ("content-type", "application/json"),
///         ("x-custom", "value")
///     ],
///     body: Data("{\"ok\": true}".utf8)
/// )
///
/// // Status helpers
/// response.isSuccess      // 200-299
/// response.isClientError  // 400-499
/// response.isServerError  // 500-599
/// response.statusText     // "OK", "Not Found", etc.
/// ```
func buildRouter() -> HTTP3Router {
    let router = HTTP3Router()
    let startTime = Date()

    // =========================================================================
    // GET / — Welcome page
    // =========================================================================
    router.get("/") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Quiver HTTP/3 Demo</title></head>
        <body>
            <h1>Welcome to Quiver HTTP/3 Demo Server</h1>
            <p>This server is running HTTP/3 (RFC 9114) over QUIC (RFC 9000).</p>
            <h2>Available Endpoints</h2>
            <ul>
                <li><code>GET /</code> — This page</li>
                <li><code>GET /health</code> — Health check (JSON)</li>
                <li><code>GET /info</code> — Server information (JSON)</li>
                <li><code>POST /echo</code> — Echo request body</li>
                <li><code>POST /api/json</code> — JSON echo API</li>
                <li><code>GET /headers</code> — Reflect your request headers</li>
                <li><code>GET /stream-info</code> — QUIC stream metadata</li>
                <li><code>ANY /api/method</code> — HTTP method echo</li>
            </ul>
            <h2>Protocol Stack</h2>
            <pre>
            HTTP/3 (RFC 9114)
              └── QPACK Header Compression (RFC 9204)
              └── QUIC Transport (RFC 9000)
                  └── TLS 1.3 (RFC 9001)
                  └── UDP
            </pre>
        </body>
        </html>
        """

        try await context.respond(
            status: 200,
            headers: [
                ("content-type", "text/html; charset=utf-8"),
                ("server", "quiver-http3-demo"),
                ("alt-svc", "h3=\":443\"; ma=86400"),
            ],
            Data(html.utf8)
        )
    }

    // =========================================================================
    // GET /health — Health check endpoint
    // =========================================================================
    //
    // Returns a simple JSON health status. Useful for monitoring and
    // load balancer health checks.
    //
    router.get("/health") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let json = """
        {
            "status": "healthy",
            "protocol": "h3",
            "timestamp": "\(ISO8601DateFormatter().string(from: Date()))"
        }
        """

        try await context.respond(
            status: 200,
            headers: [
                ("content-type", "application/json"),
                ("cache-control", "no-cache"),
            ],
            Data(json.utf8)
        )
    }

    // =========================================================================
    // GET /info — Server information
    // =========================================================================
    //
    // Returns detailed information about the server configuration.
    //
    router.get("/info") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let uptime = Date().timeIntervalSince(startTime)
        let json = """
        {
            "server": "Quiver HTTP/3 Demo",
            "version": "0.1.0",
            "protocols": {
                "quic": "RFC 9000 (QUIC v1)",
                "http3": "RFC 9114",
                "qpack": "RFC 9204"
            },
            "configuration": {
                "qpack_mode": "literal-only",
                "max_table_capacity": 0,
                "max_field_section_size": "unlimited",
                "qpack_blocked_streams": 0
            },
            "uptime_seconds": \(String(format: "%.1f", uptime)),
            "swift_version": "6.2",
            "platform": "\(platformDescription())"
        }
        """

        try await context.respond(
            status: 200,
            headers: [("content-type", "application/json")],
            Data(json.utf8)
        )
    }

    // =========================================================================
    // POST /echo — Echo request body
    // =========================================================================
    //
    // Echoes back the request body with the same content-type.
    // Demonstrates reading the request body from HTTP3Request.
    //
    // ## How Request Bodies Work in HTTP/3
    //
    // In HTTP/3, a request is sent as:
    //   1. HEADERS frame (contains pseudo-headers + regular headers)
    //   2. DATA frame(s) (contains the body, may be split across frames)
    //   3. Stream FIN (signals end of request)
    //
    // The HTTP3Connection fires the handler as soon as HEADERS are parsed.
    // The body is available via `context.body` — use .data(), .text(),
    // .json(), or .stream() to consume it.
    //
    router.post("/echo") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let body = try await context.body.data()
        let contentType = context.request.headers.first(where: { $0.0.lowercased() == "content-type" })?.1
            ?? "application/octet-stream"

        log("Handler", "  Echoing \(body.count) bytes (content-type: \(contentType))")

        try await context.respond(
            status: 200,
            headers: [
                ("content-type", contentType),
                ("x-echo", "true"),
                ("x-echo-size", "\(body.count)"),
            ],
            body
        )
    }

    // =========================================================================
    // POST /api/json — JSON API endpoint
    // =========================================================================
    //
    // Accepts a JSON body, parses it (or pretends to), and returns a
    // JSON response wrapping the original payload.
    //
    router.post("/api/json") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let body = try await context.body.data()

        // Validate content-type
        let contentType = context.request.headers.first(where: { $0.0.lowercased() == "content-type" })?.1 ?? ""

        if !contentType.contains("json") && !body.isEmpty {
            let errorJson = """
            {
                "error": "unsupported_content_type",
                "message": "Expected Content-Type: application/json, got: \(contentType)",
                "hint": "Send your request with -H 'Content-Type: application/json'"
            }
            """
            try await context.respond(
                status: 415,
                headers: [("content-type", "application/json")],
                Data(errorJson.utf8)
            )
            return
        }

        // Echo the JSON body wrapped in a response envelope
        let bodyString = String(data: body, encoding: .utf8) ?? "null"
        let responseJson = """
        {
            "received": true,
            "size": \(body.count),
            "stream_id": \(context.streamID),
            "payload": \(bodyString.isEmpty ? "null" : bodyString),
            "timestamp": "\(ISO8601DateFormatter().string(from: Date()))"
        }
        """

        try await context.respond(
            status: 200,
            headers: [
                ("content-type", "application/json"),
                ("x-stream-id", "\(context.streamID)"),
            ],
            Data(responseJson.utf8)
        )
    }

    // =========================================================================
    // GET /headers — Header reflection
    // =========================================================================
    //
    // Returns all request headers as JSON. Useful for debugging and
    // understanding how QPACK header compression works.
    //
    // ## QPACK Header Compression (RFC 9204)
    //
    // HTTP/3 uses QPACK for header compression, which is based on HPACK
    // (HTTP/2) but adapted for QUIC's out-of-order delivery:
    //
    // - Static table: 99 pre-defined header name-value pairs
    // - Dynamic table: Learned from previous headers (if enabled)
    // - Literal encoding: Headers sent as-is (literal-only mode)
    //
    // In literal-only mode (our default), every header is sent in full.
    // This is simpler but uses more bandwidth. Enable the dynamic table
    // via HTTP3Settings for better compression.
    //
    router.get("/headers") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        var headerEntries: [String] = []
        for (name, value) in context.request.headers {
            // Escape JSON strings
            let escapedName = name.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
            headerEntries.append("        \"\(escapedName)\": \"\(escapedValue)\"")
        }

        let json = """
        {
            "pseudo_headers": {
                ":method": "\(context.request.method)",
                ":scheme": "\(context.request.scheme)",
                ":authority": "\(context.request.authority)",
                ":path": "\(context.request.path)"
            },
            "headers": {
        \(headerEntries.joined(separator: ",\n"))
            },
            "header_count": \(context.request.headers.count)
        }
        """

        try await context.respond(
            status: 200,
            headers: [("content-type", "application/json")],
            Data(json.utf8)
        )
    }

    // =========================================================================
    // GET /stream-info — QUIC stream metadata
    // =========================================================================
    //
    // Returns information about the QUIC stream carrying this request.
    //
    // ## QUIC Stream IDs
    //
    // Stream IDs encode two pieces of information:
    //   - Initiator: Client-initiated (even) or Server-initiated (odd)
    //   - Direction: Bidirectional (bits 0b00/0b01) or Unidirectional (0b10/0b11)
    //
    // Stream ID format: least significant 2 bits determine type
    //   0x00: Client-initiated bidirectional
    //   0x01: Server-initiated bidirectional
    //   0x02: Client-initiated unidirectional
    //   0x03: Server-initiated unidirectional
    //
    // HTTP/3 request streams are client-initiated bidirectional: 0, 4, 8, 12, ...
    //
    router.get("/stream-info") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let streamID = context.streamID
        let streamType: String
        switch streamID & 0x03 {
        case 0x00: streamType = "client-initiated bidirectional"
        case 0x01: streamType = "server-initiated bidirectional"
        case 0x02: streamType = "client-initiated unidirectional"
        case 0x03: streamType = "server-initiated unidirectional"
        default: streamType = "unknown"
        }

        let json = """
        {
            "stream_id": \(streamID),
            "stream_type": "\(streamType)",
            "is_client_initiated": \(streamID % 2 == 0),
            "is_bidirectional": \(streamID & 0x02 == 0),
            "stream_sequence": \(streamID / 4),
            "explanation": "HTTP/3 request streams use client-initiated bidirectional streams (IDs: 0, 4, 8, ...)"
        }
        """

        try await context.respond(
            status: 200,
            headers: [("content-type", "application/json")],
            Data(json.utf8)
        )
    }

    // =========================================================================
    // ANY /api/method — HTTP method echo
    // =========================================================================
    //
    // Accepts any HTTP method and echoes which method was used.
    // Demonstrates the `router.route()` method that matches all HTTP methods.
    //
    router.route("/api/method") { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)]")

        let json = """
        {
            "method": "\(context.request.method)",
            "path": "\(context.request.path)",
            "description": "You sent a \(context.request.method) request",
            "supported_methods": ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
        }
        """

        try await context.respond(
            status: 200,
            headers: [("content-type", "application/json")],
            Data(json.utf8)
        )
    }

    // =========================================================================
    // Custom 404 handler
    // =========================================================================
    //
    // router.setNotFound() overrides the default 404 response for
    // any request that doesn't match a registered route.
    //
    router.setNotFound { context in
        log("Handler", "\(context.request.method) \(context.request.path) [stream:\(context.streamID)] → 404")

        let json = """
        {
            "error": "not_found",
            "message": "No route found for \(context.request.method) \(context.request.path)",
            "available_routes": [
                "GET /",
                "GET /health",
                "GET /info",
                "POST /echo",
                "POST /api/json",
                "GET /headers",
                "GET /stream-info",
                "ANY /api/method"
            ]
        }
        """

        try await context.respond(
            status: 404,
            headers: [("content-type", "application/json")],
            Data(json.utf8)
        )
    }

    return router
}

// MARK: - HTTP/3 Client Demo

/// Runs the HTTP/3 client demo
///
/// ## HTTP3Client API
///
/// ```swift
/// // Create client with a connection factory
/// let client = HTTP3Client(
///     connectionFactory: { host, port in
///         let endpoint = QUICEndpoint(configuration: config)
///         return try await endpoint.dial(
///             address: SocketAddress(ipAddress: host, port: port)
///         )
///     }
/// )
///
/// // Simple GET request
/// let response = try await client.get("https://example.com/api/data")
/// print(response.status)  // 200
/// print(String(data: response.body, encoding: .utf8)!)
///
/// // POST request with body
/// let response = try await client.post(
///     "https://example.com/api/submit",
///     body: Data("{\"key\": \"value\"}".utf8),
///     headers: [("content-type", "application/json")]
/// )
///
/// // Full request control
/// let request = HTTP3Request(
///     method: .put,
///     url: "https://example.com/api/resource/42",
///     headers: [("content-type", "application/json")],
///     body: Data("{\"updated\": true}".utf8)
/// )
/// let response = try await client.request(request)
///
/// // Clean up
/// await client.close()
/// ```
///
/// ## Manual Connection (lower-level API)
///
/// ```swift
/// // Create QUIC connection
/// let quicConn = try await endpoint.dial(address: serverAddress)
///
/// // Wrap in HTTP/3 connection
/// let h3Conn = HTTP3Connection(
///     quicConnection: quicConn,
///     role: .client,
///     settings: HTTP3Settings()
/// )
///
/// // Initialize HTTP/3 (opens control/QPACK streams, sends SETTINGS)
/// try await h3Conn.initialize()
///
/// // Wait for server's SETTINGS
/// try await h3Conn.waitForReady()
///
/// // Send a request
/// let response = try await h3Conn.sendRequest(
///     HTTP3Request(method: .get, scheme: "https", authority: "localhost:4443", path: "/")
/// )
/// ```
func runClient(host: String, port: UInt16, caCertPath: String?) async throws {
    log("HTTP3", "╔══════════════════════════════════════════════════════════════╗")
    log("HTTP3", "║              HTTP/3 Demo Client                             ║")
    log("HTTP3", "╚══════════════════════════════════════════════════════════════╝")
    log("HTTP3", "")
    log("HTTP3", "Connecting to \(host):\(port)...")

    if let caCertPath = caCertPath {
        log("HTTP3", "  TLS: Production (CA cert: \(caCertPath))")
    } else {
        log("HTTP3", "  TLS: Development (allowSelfSigned: true)")
    }
    log("HTTP3", "")

    // Create QUIC configuration with real TLS (must match server's ALPN)
    let config = try makeClientConfiguration(caCertPath: caCertPath)

    // Create QUIC endpoint and connect
    let endpoint = QUICEndpoint(configuration: config)
    let serverAddress = QUIC.SocketAddress(ipAddress: host, port: port)

    let quicConnection: any QUICConnectionProtocol
    do {
        quicConnection = try await endpoint.dial(address: serverAddress, timeout: .seconds(10))
    } catch {
        log("Client", "Failed to connect: \(error)")
        log("Client", "")
        log("Client", "Make sure the HTTP/3 server is running:")
        log("Client", "  swift run HTTP3Demo server --host \(host) --port \(port)")
        throw error
    }

    log("Client", "QUIC connection established!")
    log("Client", "  Remote: \(quicConnection.remoteAddress)")
    log("Client", "")

    // Wrap in HTTP/3 connection
    //
    // HTTP3Connection manages the HTTP/3 state on top of a QUIC connection:
    //   - Opens control stream and sends SETTINGS
    //   - Opens QPACK encoder/decoder streams
    //   - Provides sendRequest() for making HTTP requests
    //   - Manages stream lifecycle
    //
    let h3Connection = HTTP3Connection(
        quicConnection: quicConnection,
        role: .client,
        settings: HTTP3Settings.literalOnly
    )

    // Initialize HTTP/3 (opens control/QPACK streams, sends SETTINGS)
    log("Client", "Initializing HTTP/3 connection...")
    try await h3Connection.initialize()
    log("Client", "HTTP/3 initialized (control stream + QPACK streams opened)")
    log("Client", "")

    // Wait for the server's SETTINGS
    log("Client", "Waiting for server SETTINGS...")
    try await h3Connection.waitForReady(timeout: .seconds(5))
    log("Client", "HTTP/3 connection ready!")
    log("Client", "")

    // =========================================================================
    // Demo: Make several HTTP/3 requests
    // =========================================================================

    // --- Request 1: GET / ---
    log("Client", "━━━ Request 1: GET / ━━━")
    let req1 = HTTP3Request(
        method: .get,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/"
    )
    let resp1 = try await h3Connection.sendRequest(req1)
    try await printResponse(resp1, label: "1")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 2: GET /health ---
    log("Client", "━━━ Request 2: GET /health ━━━")
    let req2 = HTTP3Request(
        method: .get,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/health"
    )
    let resp2 = try await h3Connection.sendRequest(req2)
    try await printResponse(resp2, label: "2")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 3: POST /echo ---
    log("Client", "━━━ Request 3: POST /echo ━━━")
    let echoBody = "Hello from HTTP/3 client! 🚀"
    let req3 = HTTP3Request(
        method: .post,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/echo",
        headers: [("content-type", "text/plain")],
        body: Data(echoBody.utf8)
    )
    let resp3 = try await h3Connection.sendRequest(req3)
    try await printResponse(resp3, label: "3")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 4: POST /api/json ---
    log("Client", "━━━ Request 4: POST /api/json ━━━")
    let jsonBody = """
    {"name": "quiver", "version": "0.1.0", "features": ["http3", "qpack", "0-rtt"]}
    """
    let req4 = HTTP3Request(
        method: .post,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/api/json",
        headers: [("content-type", "application/json")],
        body: Data(jsonBody.utf8)
    )
    let resp4 = try await h3Connection.sendRequest(req4)
    try await printResponse(resp4, label: "4")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 5: GET /headers ---
    log("Client", "━━━ Request 5: GET /headers ━━━")
    let req5 = HTTP3Request(
        method: .get,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/headers",
        headers: [
            ("user-agent", "quiver-http3-demo/0.1"),
            ("accept", "application/json"),
            ("x-custom-header", "hello-from-client"),
        ]
    )
    let resp5 = try await h3Connection.sendRequest(req5)
    try await printResponse(resp5, label: "5")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 6: GET /stream-info ---
    log("Client", "━━━ Request 6: GET /stream-info ━━━")
    let req6 = HTTP3Request(
        method: .get,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/stream-info"
    )
    let resp6 = try await h3Connection.sendRequest(req6)
    try await printResponse(resp6, label: "6")

    try await Task.sleep(for: .milliseconds(200))

    // --- Request 7: GET /nonexistent (404 test) ---
    log("Client", "━━━ Request 7: GET /nonexistent (expecting 404) ━━━")
    let req7 = HTTP3Request(
        method: .get,
        scheme: "https",
        authority: "\(host):\(port)",
        path: "/nonexistent"
    )
    let resp7 = try await h3Connection.sendRequest(req7)
    try await printResponse(resp7, label: "7")

    // =========================================================================
    // Cleanup
    // =========================================================================
    log("Client", "")
    log("Client", "All requests completed successfully!")
    log("Client", "Closing HTTP/3 connection...")
    await h3Connection.close()
    await quicConnection.close(error: nil)
    await endpoint.stop()
    log("Client", "Done!")
}

/// Pretty-prints an HTTP/3 response
func printResponse(_ response: consuming HTTP3Response, label: String) async throws {
    log("Client", "  Status: \(response.status) \(response.statusText)")

    // Print a few interesting headers
    for (name, value) in response.headers {
        log("Client", "  Header: \(name): \(value)")
    }

    // Print body (truncated if too long)
    let bodyData = try await response.body().data()
    if !bodyData.isEmpty {
        let bodyStr = String(data: bodyData, encoding: .utf8) ?? "<binary \(bodyData.count) bytes>"
        let truncated = bodyStr.count > 300 ? String(bodyStr.prefix(300)) + "... (\(bodyStr.count) chars total)" : bodyStr
        log("Client", "  Body: \(truncated)")
    }
    log("Client", "")
}

// MARK: - Utility

/// Returns a platform description string
func platformDescription() -> String {
    #if os(Linux)
    return "Linux"
    #elseif os(macOS)
    return "macOS"
    #elseif os(Windows)
    return "Windows"
    #else
    return "Unknown"
    #endif
}

// MARK: - Help Text

func printHelp() {
    print("""
    ╔══════════════════════════════════════════════════════════════╗
    ║              HTTP/3 Demo Server & Client                    ║
    ╚══════════════════════════════════════════════════════════════╝

    USAGE:
        swift run HTTP3Demo <mode> [options]

    MODES:
        server      Start the HTTP/3 server
        client      Connect and make demo HTTP/3 requests
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
        swift run HTTP3Demo server
        swift run HTTP3Demo client

        # Production mode (with real certificates)
        swift run HTTP3Demo server --cert server.pem --key server-key.pem
        swift run HTTP3Demo client --ca-cert ca.pem

        # Custom host/port
        swift run HTTP3Demo server --host 0.0.0.0 --port 8443
        swift run HTTP3Demo client --host 192.168.1.10 --port 8443

        # Enable verbose logging
        swift run HTTP3Demo server --log-level trace

    HTTP/3 PROTOCOL OVERVIEW:

        HTTP/3 (RFC 9114) is the latest version of HTTP, built on QUIC
        instead of TCP. It provides:

        • No head-of-line blocking — Each stream is independent
        • Built-in encryption — TLS 1.3 is mandatory
        • Connection migration — Survives IP address changes
        • 0-RTT — Send data in the first flight
        • QPACK compression — Efficient header encoding

        Protocol Stack:
        ┌────────────────────────────────────────┐
        │  HTTP/3 (RFC 9114)                     │
        │  • Request/Response multiplexing       │
        │  • Server Push                         │
        │  • QPACK header compression            │
        ├────────────────────────────────────────┤
        │  QUIC Transport (RFC 9000)             │
        │  • Reliable, ordered stream delivery   │
        │  • Connection-level flow control       │
        │  • Stream-level flow control           │
        │  • Loss detection & retransmission     │
        ├────────────────────────────────────────┤
        │  TLS 1.3 (RFC 9001)                    │
        │  • Key exchange & authentication       │
        │  • Packet & header protection          │
        ├────────────────────────────────────────┤
        │  UDP                                   │
        │  • Unreliable datagram transport       │
        └────────────────────────────────────────┘

    API QUICK REFERENCE:

        === Server Setup ===

        // 1. Configuration
        var config = QUICConfiguration()
        config.securityMode = .production { MyTLSProvider() }
        config.alpn = ["h3"]

        // 2. Socket & Endpoint
        let socket = NIOQUICSocket(configuration: .unicast(port: 443))
        let (endpoint, runTask) = try await QUICEndpoint.serve(
            socket: socket, configuration: config
        )

        // 3. HTTP/3 Server
        let server = HTTP3Server(settings: HTTP3Settings())
        let router = HTTP3Router()
        router.get("/") { ctx in
            try await ctx.respond(HTTP3Response(status: 200))
        }
        server.onRequest(router.handler)

        // 4. Serve
        try await server.serve(
            connectionSource: endpoint.incomingConnections
        )

        === Client Setup ===

        // 1. Connect
        let endpoint = QUICEndpoint(configuration: config)
        let conn = try await endpoint.dial(address: serverAddress)

        // 2. HTTP/3 Layer
        let h3 = HTTP3Connection(
            quicConnection: conn, role: .client
        )
        try await h3.initialize()
        try await h3.waitForReady()

        // 3. Send Request
        let resp = try await h3.sendRequest(
            HTTP3Request(method: .get, url: "https://example.com/")
        )

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
        log("HTTP3", "Fatal error: \(error)")
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
        log("HTTP3", "Fatal error: \(error)")
        exit(1)
    }

case .help:
    printHelp()
}
