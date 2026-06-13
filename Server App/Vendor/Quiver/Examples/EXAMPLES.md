# Quiver Examples

This directory contains runnable demo binaries that showcase the **QUIC** and **HTTP/3** APIs provided by the `quiver` library.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [QUICEchoServer — QUIC Protocol Demo](#quicechoserver--quic-protocol-demo)
  - [Running the Echo Server](#running-the-echo-server)
  - [Running the Echo Client](#running-the-echo-client)
  - [QUIC API Reference](#quic-api-reference)
- [HTTP3Demo — HTTP/3 Server & Client Demo](#http3demo--http3-server--client-demo)
  - [Running the HTTP/3 Server](#running-the-http3-server)
  - [Running the HTTP/3 Client](#running-the-http3-client)
  - [HTTP/3 API Reference](#http3-api-reference)
- [WebTransportDemo — WebTransport Echo Demo](#webtransportdemo--webtransport-echo-demo)
  - [Running the WebTransport Server](#running-the-webtransport-server)
  - [Running the WebTransport Client](#running-the-webtransport-client)
  - [Echo Mechanisms](#echo-mechanisms)
  - [WebTransport API Reference](#webtransport-api-reference)
- [QUICNetworkDemo — ECN / PMTUD / Platform Socket Demo](#quicnetworkdemo--ecn--pmtud--platform-socket-demo)
  - [Platform Info Mode](#platform-info-mode)
  - [Running the Server](#running-the-network-demo-server)
  - [Running the Client](#running-the-network-demo-client)
  - [Network Config API Reference](#network-config-api-reference)
- [Architecture Overview](#architecture-overview)
- [Security & TLS Configuration](#security--tls-configuration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Swift 6.2+** (swift-tools-version: 6.2)
- **Linux** or **macOS** (both supported)
- The examples use `TLS13Handler` with real TLS 1.3 encryption
- No certificates required for development (self-signed P-256 key generated at startup)
- For production mode, provide PEM certificate/key files via command-line arguments

Build the examples:

```sh
# Build everything
swift build

# Build only the QUIC echo server
swift build --target QUICEchoServer

# Build only the HTTP/3 demo
swift build --target HTTP3Demo

# Build only the WebTransport demo
swift build --target WebTransportDemo
```

---

## Quick Start

### Development Mode (no certificates needed)

**Terminal 1** — Start the QUIC echo server:

```sh
swift run QUICEchoServer server
```

**Terminal 2** — Run the echo client:

```sh
swift run QUICEchoServer client
```

**Terminal 1** — Start the HTTP/3 server:

```sh
swift run HTTP3Demo server
```

**Terminal 2** — Run the HTTP/3 client demo:

```sh
swift run HTTP3Demo client
```

**Terminal 1** — Start the WebTransport echo server:

```sh
swift run WebTransportDemo server
```

**Terminal 2** — Run the WebTransport echo client:

```sh
swift run WebTransportDemo client
```

### Production Mode (with PEM certificates)

```sh
# QUIC echo server/client with real certificates
swift run QUICEchoServer server --cert server.pem --key server-key.pem
swift run QUICEchoServer client --ca-cert ca.pem

# HTTP/3 server/client with real certificates
swift run HTTP3Demo server --cert server.pem --key server-key.pem
swift run HTTP3Demo client --ca-cert ca.pem

# WebTransport server/client with real certificates
swift run WebTransportDemo server --cert server.pem --key server-key.pem
swift run WebTransportDemo client --ca-cert ca.pem
```

---

## QUICEchoServer — QUIC Protocol Demo

Demonstrates the **core QUIC transport API**: endpoints, connections, and streams.

The server echoes back any data received on bidirectional streams. The client opens streams, sends messages, and reads the echoed responses.

### Running the Echo Server

```sh
# Development mode (self-signed, real TLS encryption)
swift run QUICEchoServer server

# Production mode (with PEM certificate and key)
swift run QUICEchoServer server --cert server.pem --key server-key.pem

# Custom address
swift run QUICEchoServer server --host 0.0.0.0 --port 5555
```

Output:

```
[2025-01-01T00:00:00Z] [Server] Starting QUIC Echo Server...
[2025-01-01T00:00:00Z] [Server] Listening on 127.0.0.1:4433
[2025-01-01T00:00:00Z] [Server] Waiting for connections...
```

### Running the Echo Client

```sh
# Development mode (accepts self-signed certificates)
swift run QUICEchoServer client

# Production mode (verifies server against trusted CA)
swift run QUICEchoServer client --ca-cert ca.pem

# Custom address
swift run QUICEchoServer client --host 192.168.1.10 --port 5555
```

Output:

```
[2025-01-01T00:00:01Z] [Client] Connected!
[2025-01-01T00:00:01Z] [Client] Stream opened (ID: 0)
[2025-01-01T00:00:01Z] [Client] [1/4] Sending: "Hello, QUIC!" (12 bytes)
[2025-01-01T00:00:01Z] [Client] [1/4] Received echo: "Hello, QUIC!" (12 bytes)
...
[2025-01-01T00:00:01Z] [Client] All messages echoed successfully!
```

### QUIC API Reference

#### QUICConfiguration

Configuration holds all QUIC transport parameters. These are exchanged during the TLS handshake.

```swift
import QUIC
import QUICCrypto

// Production mode: load PEM certificate and key from disk
let tlsConfig = try TLSConfiguration.server(
    certificatePath: "/path/to/cert.pem",
    privateKeyPath: "/path/to/key.pem",
    alpnProtocols: ["h3"]
)
let config = QUICConfiguration.production {
    TLS13Handler(configuration: tlsConfig)
}

// Development mode: self-signed certificate (real TLS encryption)
let signingKey = SigningKey.generateP256()
var devTLSConfig = TLSConfiguration.server(
    signingKey: signingKey,
    certificateChain: [Data([0x30, 0x82, 0x01, 0x00])],
    alpnProtocols: ["h3"]
)
devTLSConfig.verifyPeer = false
let devConfig = QUICConfiguration.development {
    TLS13Handler(configuration: devTLSConfig)
}

// Client with CA verification (production)
var clientTLS = TLSConfiguration.client(serverName: "localhost", alpnProtocols: ["h3"])
try clientTLS.loadTrustedCAs(fromPEMFile: "/path/to/ca.pem")
let clientConfig = QUICConfiguration.production {
    TLS13Handler(configuration: clientTLS)
}

// Client accepting self-signed (development)
var devClientTLS = TLSConfiguration.client(serverName: "localhost", alpnProtocols: ["h3"])
devClientTLS.verifyPeer = false
devClientTLS.allowSelfSigned = true
let devClientConfig = QUICConfiguration.development {
    TLS13Handler(configuration: devClientTLS)
}
```

Key configuration properties:

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `alpn` | `[String]` | `["h3"]` | Application Layer Protocol Negotiation |
| `maxIdleTimeout` | `Duration` | `.seconds(30)` | Close idle connections after this duration |
| `initialMaxData` | `UInt64` | `10_000_000` | Connection-level flow control limit (bytes) |
| `initialMaxStreamDataBidiLocal` | `UInt64` | `1_000_000` | Per-stream flow control (locally-initiated) |
| `initialMaxStreamDataBidiRemote` | `UInt64` | `1_000_000` | Per-stream flow control (remotely-initiated) |
| `initialMaxStreamsBidi` | `UInt64` | `100` | Max concurrent bidirectional streams |
| `initialMaxStreamsUni` | `UInt64` | `100` | Max concurrent unidirectional streams |
| `version` | `QUICVersion` | `.v1` | QUIC protocol version |
| `maxUDPPayloadSize` | `Int` | `1200` | Maximum UDP datagram payload size |

#### QUICEndpoint

The top-level object that manages UDP I/O and QUIC connections.

**Server mode (convenience):**

```swift
// 1. Start endpoint — creates NIOQUICSocket internally
let (endpoint, runTask) = try await QUICEndpoint.serve(
    host: "0.0.0.0",
    port: 4433,
    configuration: config
)

// 2. Accept incoming connections
for await connection in await endpoint.incomingConnections {
    Task {
        // Handle each connection concurrently
        await handleConnection(connection)
    }
}

// 3. Stop when done
await endpoint.stop()
runTask.cancel()
```

**Server mode (custom socket):**

```swift
import QUICTransport
import NIOUDPTransport

// For advanced use cases where you need control over the UDP socket
let socket = NIOQUICSocket(configuration: UDPConfiguration(
    bindAddress: .specific(host: "0.0.0.0", port: 4433),
    reuseAddress: true
))
let (endpoint, runTask) = try await QUICEndpoint.serve(
    socket: socket,
    configuration: config
)
```

**Client mode:**

```swift
// 1. Create client endpoint
let endpoint = QUICEndpoint(configuration: config)

// 2. Dial the server (performs full QUIC handshake)
let connection = try await endpoint.dial(
    address: QUIC.SocketAddress(ipAddress: "127.0.0.1", port: 4433),
    timeout: .seconds(10)
)

// connection.isEstablished == true at this point
```

#### QUICConnectionProtocol

Represents a single QUIC connection (multiplexes many streams).

```swift
// Open a new bidirectional stream
let stream = try await connection.openStream()

// Open a unidirectional stream (send-only)
let uniStream = try await connection.openUniStream()

// Accept incoming streams from the remote peer
for await stream in connection.incomingStreams {
    Task { await handleStream(stream) }
}

// Close gracefully
await connection.close(error: nil)

// Close with an error code
await connection.close(error: 0x01)

// Close with application error and reason
await connection.close(applicationError: 0x42, reason: "shutting down")
```

#### QUICStreamProtocol

A single QUIC stream for sending/receiving data.

```swift
// Write data
try await stream.write(Data("Hello".utf8))

// Read data (suspends until data arrives)
let data = try await stream.read()

// Read with a byte limit
let chunk = try await stream.read(maxBytes: 4096)

// Close write side (sends FIN — signals end of data)
try await stream.closeWrite()

// Reset the stream with an error code
await stream.reset(errorCode: 0x01)

// Signal to the peer that you won't read any more
try await stream.stopSending(errorCode: 0x00)

// Inspect stream properties
stream.id               // UInt64 — the stream ID
stream.isBidirectional  // true for bidi streams
stream.isUnidirectional // true for uni streams
```

**Stream ID encoding:**

| Bits 0-1 | Type |
|----------|------|
| `0x00` | Client-initiated bidirectional |
| `0x01` | Server-initiated bidirectional |
| `0x02` | Client-initiated unidirectional |
| `0x03` | Server-initiated unidirectional |

Client bidi stream IDs: 0, 4, 8, 12, ...
Server bidi stream IDs: 1, 5, 9, 13, ...

#### NIOQUICSocket

UDP socket backed by SwiftNIO for real network I/O.

```swift
import QUICTransport
import NIOUDPTransport

// Unicast (simple)
let socket = NIOQUICSocket(configuration: .unicast(port: 4433))

// Full configuration
let socket = NIOQUICSocket(configuration: UDPConfiguration(
    bindAddress: .specific(host: "0.0.0.0", port: 4433),
    reuseAddress: true,
    reusePort: false,
    receiveBufferSize: 65536,
    sendBufferSize: 65536,
    maxDatagramSize: 65507,
    streamBufferSize: 100
))

// Start and stop
try await socket.start()
await socket.stop()

// I/O
try await socket.send(data, to: address)
for await packet in socket.incomingPackets {
    // packet.data, packet.remoteAddress, packet.receivedAt
}
```

---

## HTTP3Demo — HTTP/3 Server & Client Demo

Demonstrates the **HTTP/3 protocol layer** (RFC 9114) built on top of QUIC, including routing, request handling, QPACK header compression, and the full request/response lifecycle.

### Running the HTTP/3 Server

```sh
# Development mode (self-signed, real TLS encryption)
swift run HTTP3Demo server

# Production mode (with PEM certificate and key)
swift run HTTP3Demo server --cert server.pem --key server-key.pem

# Custom address
swift run HTTP3Demo server --host 0.0.0.0 --port 8443
```

Available routes:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Welcome page (HTML) |
| `GET` | `/health` | Health check (JSON) |
| `GET` | `/info` | Server information (JSON) |
| `POST` | `/echo` | Echo request body |
| `POST` | `/api/json` | JSON echo API |
| `GET` | `/headers` | Reflect request headers (JSON) |
| `GET` | `/stream-info` | QUIC stream metadata (JSON) |
| `ANY` | `/api/method` | HTTP method echo (JSON) |

### Running the HTTP/3 Client

```sh
# Development mode (accepts self-signed certificates)
swift run HTTP3Demo client

# Production mode (verifies server against trusted CA)
swift run HTTP3Demo client --ca-cert ca.pem

# Custom address
swift run HTTP3Demo client --host 192.168.1.10 --port 8443
```

The client makes 7 demo requests showcasing different HTTP methods, headers, JSON payloads, and error handling (404).

### HTTP/3 API Reference

#### HTTP3Server

Accepts QUIC connections and dispatches HTTP/3 requests to handlers.

**Convenience (recommended):**

```swift
import HTTP3

// 1. Create server with settings
let server = HTTP3Server(
    settings: HTTP3Settings.literalOnly,
    maxConnections: 100  // 0 = unlimited
)

// 2. Register a request handler
await server.onRequest { context in
    try await context.respond(HTTP3Response(
        status: 200,
        headers: [("content-type", "text/plain")],
        body: Data("Hello, HTTP/3!".utf8)
    ))
}

// 3. Listen — creates QUIC endpoint internally, blocks until stop()
try await server.listen(
    host: "0.0.0.0",
    port: 443,
    quicConfiguration: quicConfig
)

// 4. Graceful shutdown (call from another task)
await server.stop(gracePeriod: .seconds(5))
```

**Lower-level (custom QUIC endpoint):**

```swift
// When you need control over the QUIC endpoint (e.g. custom socket)
let (endpoint, runTask) = try await QUICEndpoint.serve(
    host: "0.0.0.0", port: 443, configuration: quicConfig
)
try await server.serve(connectionSource: endpoint.incomingConnections)
```

**WebTransport opt-in:**

```swift
let server = HTTP3Server(maxConnections: 100)
await server.onRequest { context in /* handle HTTP requests */ }

// Enable WebTransport — merges required settings, registers handler
let sessions = await server.enableWebTransport(
    WebTransportOptions(maxSessionsPerConnection: 4)
)

Task {
    for await session in sessions {
        Task { await handleSession(session) }
    }
}

try await server.listen(host: "0.0.0.0", port: 443, quicConfiguration: quicConfig)
```

**Server properties:**

```swift
await server.activeConnectionCount  // Int
await server.totalConnections       // UInt64 — total accepted
await server.totalRequests          // UInt64 — total handled
await server.isListening            // Bool
await server.isStopped              // Bool
```

#### HTTP3Router

Express.js-style path-based routing.

```swift
let router = HTTP3Router()

// Route by HTTP method
router.get("/") { context in
    try await context.respond(HTTP3Response(status: 200, body: Data("Home".utf8)))
}

router.post("/api/data") { context in
    let body = try await context.body.data()  // or .text(), .json(MyType.self)
    // Process body...
    try await context.respond(status: 201)
}

router.put("/api/resource") { context in /* ... */ }
router.delete("/api/resource") { context in /* ... */ }
router.patch("/api/resource") { context in /* ... */ }

// Route matching any HTTP method
router.route("/api/anything") { context in
    // context.request.method tells you which method was used
}

// Custom 404 handler
router.setNotFound { context in
    try await context.respond(HTTP3Response(
        status: 404,
        body: Data("Not Found".utf8)
    ))
}

// Attach to server
await server.onRequest(router.handler)
```

#### HTTP3Request

Represents an incoming HTTP/3 request.

```swift
// Creating a request (client-side)
let request = HTTP3Request(
    method: .get,          // HTTPMethod enum
    scheme: "https",       // Always "https" for HTTP/3
    authority: "example.com:443",
    path: "/api/data",
    headers: [
        ("accept", "application/json"),
        ("user-agent", "quiver/0.1"),
    ],
    body: nil              // Data? — request body
)

// Convenience: create from URL string
let request = HTTP3Request(
    method: .post,
    url: "https://example.com/api/data",
    headers: [("content-type", "application/json")],
    body: Data("{\"key\": \"value\"}".utf8)
)

// Accessing request properties (server-side)
context.request.method      // .get, .post, .put, .delete, .patch, .head, .options, .connect, .trace
context.request.scheme      // "https"
context.request.authority   // "example.com:443"
context.request.path        // "/api/data"
context.request.headers     // [(String, String)]
context.request.trailers    // [(String, String)]?  (RFC 9114 §4.1)

// Request body (server-side) — consumed via context, not request:
let data = try await context.body.data()            // full body as Data
let text = try await context.body.text()            // full body as String
let obj  = try await context.body.json(MyType.self) // JSON decode
for await chunk in context.body.stream() {          // raw streaming
    process(chunk)
}
```

#### HTTP3Response

Represents an HTTP/3 response. `HTTP3Response` is `~Copyable` — the body is consumed exactly once via `.body()`.

```swift
// Creating a response (server-side)
let response = HTTP3Response(status: 200)
let response = HTTP3Response(
    status: 200,
    headers: [
        ("content-type", "application/json"),
        ("cache-control", "no-cache"),
    ],
    body: Data("{\"ok\": true}".utf8),
    trailers: [("x-checksum", "abc123")]  // optional trailing headers
)

// Status helpers
response.isInformational  // 100-199
response.isSuccess        // 200-299
response.isRedirect       // 300-399
response.isClientError    // 400-499
response.isServerError    // 500-599
response.statusText       // "OK", "Not Found", etc.

// Consuming the body (~Copyable — pick exactly one):
let data = try await response.body().data()              // full Data
let text = try await response.body().text()              // String (UTF-8)
let obj  = try await response.body().json(MyType.self)   // JSON decode
for await chunk in response.body().stream() { ... }      // raw AsyncStream<Data>
```

#### HTTP3RequestContext

Wraps a request, a stream-backed body, and respond methods. Passed to request handlers.

```swift
await server.onRequest { context in
    // Read request metadata
    let method = context.request.method
    let path = context.request.path
    let streamID = context.streamID

    // Consume request body (stream-backed, pick one):
    let body = try await context.body.data()            // full Data
    // let text = try await context.body.text()          // String
    // let obj  = try await context.body.json(T.self)    // JSON
    // for await chunk in context.body.stream() { … }    // raw chunks

    // Buffered response (HEADERS + DATA + FIN)
    try await context.respond(
        status: 200,
        headers: [("content-type", "text/plain")],
        Data("OK".utf8)
    )
}
```

**Streaming response (flat memory):**

```swift
await server.onRequest { context in
    try await context.respond(
        status: 200,
        headers: [("content-type", "application/octet-stream")]
    ) { writer in
        for chunk in largeDataChunks {
            try await writer.write(chunk)   // each call sends a DATA frame
        }
    }
}
```

**Trailers:**

```swift
try await context.respond(
    status: 200,
    headers: [("content-type", "application/grpc")],
    responseData,
    trailers: [("grpc-status", "0"), ("grpc-message", "OK")]
)
```

#### HTTP3Settings

Controls QPACK header compression and HTTP/3 connection behavior.

```swift
// Literal-only mode (simplest — no dynamic table)
let settings = HTTP3Settings()  // or .literalOnly

// With QPACK dynamic table (better compression)
let settings = HTTP3Settings(
    maxTableCapacity: 4096,       // Dynamic table size in bytes
    maxFieldSectionSize: 65536,   // Max header block size
    qpackBlockedStreams: 100      // Max blocked streams
)

// Predefined configurations
HTTP3Settings.literalOnly          // No dynamic table (default)
HTTP3Settings.smallDynamicTable    // 4 KB table, 64 KB headers, 100 blocked
HTTP3Settings.largeDynamicTable    // 16 KB table, 256 KB headers, 200 blocked

// Inspect settings
settings.usesDynamicTable          // Bool
settings.isLiteralOnly             // Bool
settings.hasFieldSectionSizeLimit  // Bool
```

#### HTTP3Connection (Lower-Level API)

For when you need direct control over the HTTP/3 connection.

```swift
// Wrap a QUIC connection in HTTP/3
let h3conn = HTTP3Connection(
    quicConnection: quicConnection,
    role: .client,       // or .server
    settings: HTTP3Settings.literalOnly
)

// Initialize (opens control + QPACK streams, sends SETTINGS)
try await h3conn.initialize()

// Wait for peer's SETTINGS frame
try await h3conn.waitForReady(timeout: .seconds(5))

// Send a request (client-side)
let response = try await h3conn.sendRequest(
    HTTP3Request(method: .get, scheme: "https", authority: "localhost:4443", path: "/")
)

// Accept incoming requests (server-side)
for await context in await h3conn.incomingRequests {
    // Handle request...
}

// Graceful shutdown
try await h3conn.goaway(lastStreamID: 0)

// Close
await h3conn.close(error: .noError)

// Properties
await h3conn.isReady       // Bool — SETTINGS exchanged
await h3conn.isGoingAway   // Bool — GOAWAY sent/received
await h3conn.isClosed      // Bool
```

#### HTTP3Client (Connection-Pooling Client)

High-level client with automatic connection management.

```swift
// Create client with a connection factory
let client = HTTP3Client(
    configuration: .default,
    connectionFactory: { host, port in
        let endpoint = QUICEndpoint(configuration: config)
        return try await endpoint.dial(
            address: QUIC.SocketAddress(ipAddress: host, port: port),
            timeout: .seconds(10)
        )
    }
)

// Convenience methods
let resp = try await client.get("https://example.com/api/data")
let resp = try await client.post("https://example.com/api/submit",
                                  body: Data("{\"key\":\"value\"}".utf8),
                                  headers: [("content-type", "application/json")])
let resp = try await client.put("https://example.com/api/resource",
                                 body: updateData)
let resp = try await client.delete("https://example.com/api/resource/42")

// Streaming upload (flat memory regardless of body size)
let resp = try await client.post(
    "https://example.com/upload",
    headers: [("content-type", "application/octet-stream")]
) { writer in
    for chunk in fileChunks {
        try await writer.write(chunk)   // each call sends a DATA frame
    }
}

// Full request control
let request = HTTP3Request(method: .patch, url: "https://example.com/api/item/1",
                           headers: [("content-type", "application/json")],
                           body: patchData)
let resp = try await client.request(request)

// Response body is ~Copyable — read status/headers first, then consume body:
let status = resp.status
let data = try await resp.body().data()     // or .text(), .json(T.self), .stream()

// Connection pool management
client.connectionCount        // Number of active connections
client.connectedAuthorities   // ["example.com:443", ...]

// Manual connection injection (for testing)
await client.setConnection(h3conn, for: "example.com:443")

// Clean up
await client.close()
```

**Client Configuration:**

```swift
let client = HTTP3Client.build(connectionFactory: myFactory) { config in
    config.settings = HTTP3Settings.smallDynamicTable
    config.maxConcurrentRequests = 100
    config.idleTimeout = .seconds(30)
    config.autoRetry = true
    config.maxConnections = 16
}
```

#### HTTP3ErrorCode

Standard HTTP/3 error codes (RFC 9114 Section 8.1).

```swift
HTTP3ErrorCode.noError                // 0x0100 — Graceful shutdown
HTTP3ErrorCode.generalProtocolError   // 0x0101 — Protocol violation
HTTP3ErrorCode.internalError          // 0x0102 — Internal error
HTTP3ErrorCode.streamCreationError    // 0x0103 — Stream not allowed
HTTP3ErrorCode.closedCriticalStream   // 0x0104 — Critical stream closed
HTTP3ErrorCode.frameUnexpected        // 0x0105 — Unexpected frame
HTTP3ErrorCode.frameError             // 0x0106 — Malformed frame
HTTP3ErrorCode.excessiveLoad          // 0x0107 — Excessive load
HTTP3ErrorCode.idError                // 0x0108 — Stream/push ID error
HTTP3ErrorCode.settingsError          // 0x0109 — SETTINGS error
HTTP3ErrorCode.missingSettings        // 0x010a — Missing SETTINGS
HTTP3ErrorCode.requestRejected        // 0x010b — Request rejected (retryable)
HTTP3ErrorCode.requestCancelled       // 0x010c — Request cancelled
HTTP3ErrorCode.requestIncomplete      // 0x010d — Incomplete request
HTTP3ErrorCode.messageError           // 0x010e — Malformed message
HTTP3ErrorCode.connectError           // 0x010f — CONNECT failure
HTTP3ErrorCode.versionFallback        // 0x0110 — Retry over HTTP/1.1
```

---

## WebTransportDemo — WebTransport Echo Demo

Demonstrates the **WebTransport** API built on top of HTTP/3 + QUIC, showcasing three transport mechanisms: bidirectional streams, unidirectional streams, and datagrams.

WebTransport sessions are established via **Extended CONNECT** (RFC 9220) over HTTP/3. The server accepts sessions at a configurable path and echoes data back through all three mechanisms.

### Running the WebTransport Server

```sh
# Default: listen on 127.0.0.1:4445
swift run WebTransportDemo server

# Custom host/port
swift run WebTransportDemo server --host 0.0.0.0 --port 5555

# With verbose logging
swift run WebTransportDemo server --log-level debug

# Production mode (with certificates)
swift run WebTransportDemo server --cert server.pem --key server-key.pem
```

### Running the WebTransport Client

```sh
# Connect to default server (127.0.0.1:4445)
swift run WebTransportDemo client

# Custom host/port
swift run WebTransportDemo client --host 192.168.1.10 --port 5555

# Skip datagram test (if not supported by peer)
swift run WebTransportDemo client --skip-datagrams

# Production mode (with CA certificate)
swift run WebTransportDemo client --ca-cert ca.pem
```

### Echo Mechanisms

The demo tests three WebTransport transport mechanisms:

#### 1. Bidirectional Stream Echo

Both sides can read and write on the same stream. The client sends messages and reads back echoes.

```
Client                          Server
  |── open bidi stream ──────────►|
  |── "Hello, WebTransport!" ────►|
  |◄── "Hello, WebTransport!" ────|  (echo)
  |── closeWrite (FIN) ──────────►|
  |◄── closeWrite (FIN) ──────────|
```

#### 2. Unidirectional Stream Echo

Uni streams are one-directional. The client sends data on a client→server uni stream, and the server responds on a new server→client uni stream.

```
Client                          Server
  |── open uni stream ───────────►|
  |── "Hello, uni!" ─────────────►|
  |── closeWrite (FIN) ──────────►|
  |                               |── reads all data
  |◄──────── open uni stream ─────|
  |◄──────── "Hello, uni!" ───────|  (echo)
  |◄──────── closeWrite (FIN) ────|
```

#### 3. Datagram Echo

QUIC datagrams are unreliable, unordered messages associated with the session via a quarter-stream-ID prefix. The server echoes each datagram back. Some may be lost (datagrams are best-effort).

```
Client                          Server
  |── datagram "ping" ───────────►|
  |◄── datagram "ping" ───────────|  (echo)
  |── datagram "pong" ───────────►|
  |◄── datagram "pong" ───────────|  (echo)
```

### WebTransport API Reference

#### WebTransportConfiguration

Unified configuration shared by both client and server. Composes `QUICConfiguration` directly — no property duplication.

```swift
import HTTP3
import QUIC

// Minimal — just provide the QUIC config
let config = WebTransportConfiguration(quic: myQuicConfig)

// Full customization
var config = WebTransportConfiguration(
    quic: myQuicConfig,
    maxSessions: 4,                          // SETTINGS_WEBTRANSPORT_MAX_SESSIONS
    headers: [("authorization", "Bearer …")], // Client-side only; ignored on server
    http3Settings: HTTP3Settings(),           // QPACK / HTTP/3 overrides
    connectionReadyTimeout: .seconds(10),     // SETTINGS exchange timeout
    connectTimeout: .seconds(10)              // Extended CONNECT timeout
)

// Modify QUIC settings directly
config.quic.maxIdleTimeout = .seconds(60)
config.quic.initialMaxStreamsBidi = 200
```

#### WebTransportServer

The server-side convenience wrapper that handles session establishment automatically:

```swift
import HTTP3
import QUIC

// Create server with unified configuration + server-only options
let config = WebTransportConfiguration(
    quic: quicConfig,
    maxSessions: 4
)
let server = WebTransportServer(
    configuration: config,
    serverOptions: .init(
        maxConnections: 0,          // unlimited
        allowedPaths: ["/echo"]     // restrict accepted paths
    )
)

// Optionally handle regular HTTP/3 requests alongside WebTransport
await server.onRequest { context in
    try await context.respond(HTTP3Response(status: 200, body: Data("OK".utf8)))
}

// Process incoming sessions
Task {
    for await session in await server.incomingSessions {
        Task { await handleSession(session) }
    }
}

// Start serving (blocks until stop() is called)
// QUIC config comes from configuration.quic — no separate parameter
try await server.listen(host: "0.0.0.0", port: 4445)
```

**Static factory (one-call):**

```swift
let server = try await WebTransportServer.listen(
    host: "0.0.0.0",
    port: 4445,
    configuration: config,
    serverOptions: .init(allowedPaths: ["/echo"])
)
// Returns immediately — serve() runs in the background
for await session in server.incomingSessions {
    Task { await handleSession(session) }
}
```

#### WebTransportClient

The client-side wrapper that establishes sessions via Extended CONNECT:

**One-call convenience (Tier 1):**

```swift
import HTTP3
import QUIC

let config = WebTransportConfiguration(quic: myQuicConfig)
let session = try await WebTransportClient.connect(
    url: "https://example.com:4445/echo",
    configuration: config
)
// session is ready — QUIC endpoint, HTTP/3, and Extended CONNECT all handled internally
```

**Bring your own QUIC connection (Tier 2):**

```swift
let quicConn = try await endpoint.dial(address: serverAddress)
let session = try await WebTransportClient.connect(
    authority: "example.com:4445",
    path: "/echo",
    over: quicConn
    // configuration is optional — QUIC part is ignored since you provide the connection
)
```

**Full manual control (Tier 3):**

```swift
let client = WebTransportClient(quicConnection: quicConn)
try await client.initialize()
let session = try await client.connect(
    authority: "example.com:4445",
    path: "/echo"
)
```

#### WebTransportSession

The core session object — supports streams and datagrams:

```swift
// Bidirectional streams
let bidiStream = try await session.openBidirectionalStream()
try await bidiStream.write(Data("Hello".utf8))
let echo = try await bidiStream.read()
try await bidiStream.closeWrite()

// Unidirectional streams (send-only from our side)
let uniStream = try await session.openUnidirectionalStream()
try await uniStream.write(Data("Fire and forget".utf8))
try await uniStream.closeWrite()

// Incoming streams from the peer
for await stream in await session.incomingBidirectionalStreams {
    Task { /* handle stream */ }
}
for await stream in await session.incomingUnidirectionalStreams {
    Task { /* handle stream */ }
}

// Datagrams (unreliable, unordered)
try await session.sendDatagram(Data("ping".utf8))
for await datagram in await session.incomingDatagrams {
    print("Got: \(datagram.count) bytes")
}

// Graceful close
try await session.close()
```

#### WebTransportStream

Wraps a QUIC stream with session-scoped I/O:

```swift
let stream: WebTransportStream

// Properties
stream.id              // Underlying QUIC stream ID
stream.sessionID       // Parent session ID
stream.direction       // .bidirectional or .unidirectional
stream.isLocal         // Whether we initiated this stream
stream.priority        // RFC 9218 scheduling priority

// I/O
let data = try await stream.read()
try await stream.write(Data("response".utf8))
try await stream.closeWrite()           // Send FIN
await stream.reset(applicationErrorCode: 0)  // Send RESET_STREAM
```

---

## QUICNetworkDemo — ECN / PMTUD / Platform Socket Demo

This demo exercises the network-configuration adaptation features added to
quiver: platform socket option generation, ECN (Explicit Congestion
Notification) wiring and validation, DPLPMTUD (RFC 8899) state inspection,
and interface MTU querying.

It runs in three modes: `info` (no network I/O), `server`, and `client`.

### Platform Info Mode

Prints platform socket constants, generated socket option descriptors,
ECN/TOS helpers, interface MTU queries, and default PMTUD configuration
without opening any network connections.

```bash
swift run QUICNetworkDemo info
```

Output includes:

- `PlatformSocketConstants` — DF/ECN/GRO/GSO/MTU-query support flags
- IPv4 and IPv6 `PlatformSocketOptions.forQUIC(...)` descriptor lists
- `ecnFromTOS()` / `tosWithECN()` helper results
- Loopback and default-interface MTU via `queryInterfaceMTU()` / `queryDefaultInterfaceMTU()`
- `PMTUConfiguration` defaults (basePLPMTU, maxPLPMTU, granularity, probes, timers)

### Running the Network Demo Server

```bash
# Default: ECN + DF enabled, bind 127.0.0.1:4434
swift run QUICNetworkDemo server

# Disable ECN
swift run QUICNetworkDemo server --no-ecn

# Disable DF (disables PMTUD)
swift run QUICNetworkDemo server --no-df

# Custom bind address
swift run QUICNetworkDemo server --host 0.0.0.0 --port 5555

# Verbose logging
swift run QUICNetworkDemo server --log-level trace
```

The server:

1. Validates `QUICConfiguration` (socket ceiling >= QUIC payload >= 1200).
2. Logs the `PlatformSocketOptions` that will be applied to the UDP socket.
3. Accepts connections and echoes stream data back.
4. Prints ECN/PMTUD diagnostics after every 5 echoed messages and on
   connection close.

### Running the Network Demo Client

```bash
# Default: connects to 127.0.0.1:4434
swift run QUICNetworkDemo client

# Disable ECN on client side
swift run QUICNetworkDemo client --no-ecn
```

The client runs a six-phase test sequence:

| Phase | Description |
|-------|-------------|
| 1 | Post-handshake diagnostics — ECN enabled/validation state, PMTUD state/PLPMTU |
| 2 | ECN validation — 20 ping-pong rounds with 50 ms delays; logs ECN validation progression (`testing` -> `capable`) |
| 3 | Post-ECN-validation diagnostics |
| 4 | PMTUD state inspection — current state, PLPMTU, history count, probe generation attempt |
| 5 | Larger payload echo — 100 / 500 / 1000 byte payloads to verify data integrity |
| 6 | Final summary — ECN validated flag, PMTUD state, confirmed PLPMTU |

### Network Config API Reference

#### SocketConfiguration

```swift
// Sources/QUIC/QUICConfiguration.swift
public struct SocketConfiguration: Sendable {
    var receiveBufferSize: Int?    // SO_RCVBUF (default: 65536)
    var sendBufferSize: Int?       // SO_SNDBUF (default: 65536)
    var maxDatagramSize: Int       // OS/NIO ceiling (default: 65507)
    var enableECN: Bool            // IP_RECVTOS / IPV6_RECVTCLASS (default: true)
    var enableDF: Bool             // IP_DONTFRAG / IP_MTU_DISCOVER (default: true)
}
```

#### PlatformSocketConstants

```swift
// Sources/QUICTransport/PlatformSocket.swift
enum PlatformSocketConstants {
    static let isDFSupported: Bool
    static let isECNSupported: Bool
    static let isGROSupported: Bool
    static let isGSOSupported: Bool
    static let isMTUQuerySupported: Bool
}
```

#### PlatformSocketOptions

```swift
// Sources/QUICTransport/PlatformSocket.swift
struct PlatformSocketOptions: Sendable {
    let options: [SocketOptionDescriptor]
    let dfEnabled: Bool
    let ecnEnabled: Bool

    static func forQUIC(
        addressFamily: AddressFamily,
        enableECN: Bool = true,
        enableDF: Bool = true,
        ecnValue: UInt8 = 0x02
    ) -> PlatformSocketOptions
}

func queryInterfaceMTU(_ interfaceName: String) -> Int?
func queryDefaultInterfaceMTU() -> Int?
func ecnFromTOS(_ tosByte: UInt8) -> UInt8
func tosWithECN(dscp: UInt8 = 0, ecn: UInt8) -> UInt8
```

#### ECN on ManagedConnection

```swift
// Sources/QUIC/ManagedConnection.swift
extension ManagedConnection {
    func enableECN()
    func disableECN()
    var isECNEnabled: Bool
    var ecnValidationState: ECNValidationState   // .unknown | .testing | .capable | .failed
    var isECNValidated: Bool
}
```

#### DPLPMTUD on ManagedConnection

```swift
// Sources/QUIC/ManagedConnection.swift
extension ManagedConnection {
    func enablePMTUD()
    func disablePMTUD()
    var pmtuState: PMTUState       // .disabled | .base | .searching | .searchComplete | .error
    var currentPathMTU: Int
    var pmtuDiagnostics: String
    var pmtuHistoryCount: Int
    func generatePMTUProbe() -> PMTUDiscoveryManager.ProbeRequest?
    func resetPMTUDForPathChange()
}
```

#### QUICConfiguration.validate()

```swift
// Sources/QUIC/QUICConfiguration.swift
extension QUICConfiguration {
    func validate() throws
    // Checks:
    //   maxUDPPayloadSize >= 1200
    //   socketConfiguration.maxDatagramSize >= maxUDPPayloadSize
    //   connectionIDLength in 0...20
}
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  Application Layer                                                  │
│  ┌──────────────┐  ┌───────────────┐  ┌─────────────────────────┐  │
│  │ HTTP3Server   │  │ HTTP3Client   │  │ HTTP3Router             │  │
│  │ • onRequest() │  │ • get/post()  │  │ • get("/path") { ... }  │  │
│  │ • serve()     │  │ • request()   │  │ • post("/path") { ... } │  │
│  │ • stop()      │  │ • close()     │  │ • handler               │  │
│  └───────┬───────┘  └───────┬───────┘  └─────────────────────────┘  │
│          │                  │                                        │
│  ┌───────┴──────────────────┴───────┐                               │
│  │ HTTP3Connection                  │   ← HTTP/3 session state      │
│  │ • Control stream (SETTINGS)      │                               │
│  │ • QPACK encoder/decoder streams  │                               │
│  │ • Request stream multiplexing    │                               │
│  └──────────────┬───────────────────┘                               │
├─────────────────┼───────────────────────────────────────────────────┤
│  QPACK (RFC 9204)                                                   │
│  │ QPACKEncoder: Encodes HTTP headers → compact binary              │
│  │ QPACKDecoder: Decodes compact binary → HTTP headers              │
│  │ Static table (99 entries) + optional dynamic table               │
├─────────────────┼───────────────────────────────────────────────────┤
│  QUIC Transport (RFC 9000)                                          │
│  ┌──────────────┴───────────────────┐                               │
│  │ QUICEndpoint                     │   ← UDP I/O + connection mgmt │
│  │ ├── ConnectionRouter             │   ← Routes packets by DCID    │
│  │ ├── TimerManager                 │   ← Loss detection timers     │
│  │ └── VersionNegotiator            │   ← QUIC version negotiation  │
│  └──────────────┬───────────────────┘                               │
│  ┌──────────────┴───────────────────┐                               │
│  │ ManagedConnection                │   ← One per QUIC connection   │
│  │ ├── QUICConnectionHandler        │   ← Frame processing          │
│  │ ├── PacketProcessor              │   ← Packet encoding/decoding  │
│  │ ├── TLS13Provider                │   ← TLS 1.3 handshake         │
│  │ ├── AntiAmplificationLimiter     │   ← DDoS protection           │
│  │ └── StreamManager                │   ← Stream multiplexing       │
│  └──────────────┬───────────────────┘                               │
│  ┌──────────────┴───────────────────┐                               │
│  │ NIOQUICSocket                    │   ← SwiftNIO UDP transport    │
│  │ └── NIOUDPTransport              │                               │
│  └──────────────────────────────────┘                               │
└─────────────────────────────────────────────────────────────────────┘
```

### HTTP/3 Connection Initialization Flow

```
Client                                          Server
  │                                               │
  │── QUIC Initial (ClientHello) ────────────────►│
  │◄── QUIC Initial (ServerHello) ───────────────│
  │◄── QUIC Handshake (EncryptedExtensions) ─────│
  │── QUIC Handshake (Finished) ─────────────────►│
  │                                               │
  │  ═══ QUIC Connection Established ═══          │
  │                                               │
  │── Uni Stream: Control (type=0x00) ───────────►│
  │── SETTINGS frame ────────────────────────────►│
  │── Uni Stream: QPACK Encoder (type=0x02) ─────►│
  │── Uni Stream: QPACK Decoder (type=0x03) ─────►│
  │                                               │
  │◄── Uni Stream: Control (type=0x00) ──────────│
  │◄── SETTINGS frame ──────────────────────────│
  │◄── Uni Stream: QPACK Encoder (type=0x02) ────│
  │◄── Uni Stream: QPACK Decoder (type=0x03) ────│
  │                                               │
  │  ═══ HTTP/3 Connection Ready ═══              │
  │                                               │
  │── Bidi Stream 0: HEADERS (GET /) ────────────►│
  │◄── Bidi Stream 0: HEADERS (200 OK) ─────────│
  │◄── Bidi Stream 0: DATA (response body) ──────│
  │◄── Bidi Stream 0: FIN ───────────────────────│
  │                                               │
  │── Bidi Stream 4: HEADERS (POST /api) ────────►│
  │── Bidi Stream 4: DATA (request body) ────────►│
  │── Bidi Stream 4: FIN ────────────────────────►│
  │◄── Bidi Stream 4: HEADERS (201 Created) ─────│
  │◄── Bidi Stream 4: FIN ───────────────────────│
```

### QUIC Stream Types in HTTP/3

| Stream | Type Byte | Purpose |
|--------|-----------|---------|
| Control | `0x00` | SETTINGS, GOAWAY, MAX_PUSH_ID |
| Push | `0x01` | Server push (not implemented) |
| QPACK Encoder | `0x02` | Dynamic table updates |
| QPACK Decoder | `0x03` | Dynamic table acknowledgments |
| Request (bidi) | — | Client-initiated bidi streams for requests |

---

## Security & TLS Configuration

Both demos use `TLS13Handler` — the built-in TLS 1.3 implementation — for **real encryption**. Two modes are supported depending on command-line arguments.

### Development Mode (Default)

When no certificate arguments are provided, the demos run in development mode:

- **Server**: Generates a self-signed P-256 key pair at startup
- **Client**: Accepts self-signed certificates (`allowSelfSigned: true`, `verifyPeer: false`)
- **Encryption**: Real TLS 1.3 (AES-128-GCM / ChaCha20-Poly1305)
- **Identity verification**: None (any server certificate is accepted)

```swift
import QUICCrypto

// Server: generate ephemeral self-signed credentials
let signingKey = SigningKey.generateP256()
var serverTLS = TLSConfiguration.server(
    signingKey: signingKey,
    certificateChain: [Data([0x30, 0x82, 0x01, 0x00])],
    alpnProtocols: ["h3"]
)
serverTLS.verifyPeer = false

let serverConfig = QUICConfiguration.development {
    TLS13Handler(configuration: serverTLS)
}

// Client: accept self-signed certificates
var clientTLS = TLSConfiguration.client(serverName: "localhost", alpnProtocols: ["h3"])
clientTLS.verifyPeer = false
clientTLS.allowSelfSigned = true

let clientConfig = QUICConfiguration.development {
    TLS13Handler(configuration: clientTLS)
}
```

### Production Mode (With Certificates)

When certificate files are provided via `--cert`/`--key` (server) and `--ca-cert` (client):

- **Server**: Loads PEM certificate and private key from disk
- **Client**: Verifies the server's certificate against the trusted CA
- **Encryption**: Real TLS 1.3
- **Identity verification**: Full X.509 chain validation

```sh
# Server
swift run HTTP3Demo server --cert /etc/ssl/certs/fullchain.pem --key /etc/ssl/private/privkey.pem

# Client
swift run HTTP3Demo client --ca-cert /etc/ssl/certs/ca-bundle.pem
```

```swift
import QUICCrypto

// Server: load certificate and key from PEM files
let serverTLS = try TLSConfiguration.server(
    certificatePath: "/path/to/fullchain.pem",
    privateKeyPath: "/path/to/privkey.pem",
    alpnProtocols: ["h3"]
)
let serverConfig = QUICConfiguration.production {
    TLS13Handler(configuration: serverTLS)
}

// Client: verify server against trusted CA
var clientTLS = TLSConfiguration.client(serverName: "example.com", alpnProtocols: ["h3"])
try clientTLS.loadTrustedCAs(fromPEMFile: "/path/to/ca.pem")
let clientConfig = QUICConfiguration.production {
    TLS13Handler(configuration: clientTLS)
}
```

### Testing Mode (Unit Tests Only)

For unit tests that don't need real encryption, `MockTLSProvider` is available in DEBUG builds:

```swift
#if DEBUG
let config = QUICConfiguration.testing()  // ⚠️ No encryption — never use in production
#endif
```

### Custom TLS Provider

You can implement your own TLS 1.3 provider by conforming to the `TLS13Provider` protocol:

```swift
import QUICCrypto

public final class MyTLSProvider: TLS13Provider, Sendable {
    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] { ... }
    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] { ... }
    public func getLocalTransportParameters() -> Data { ... }
    public func setLocalTransportParameters(_ params: Data) throws { ... }
    public func getPeerTransportParameters() -> Data? { ... }
    public var isHandshakeComplete: Bool { ... }
    public var isClient: Bool { ... }
    public var negotiatedALPN: String? { ... }
    // ... plus session resumption and 0-RTT methods
}
```

---

## Troubleshooting

### "Connection refused" / Client can't connect

Make sure the server is running first:

```sh
# Terminal 1
swift run QUICEchoServer server

# Terminal 2 (after server shows "Listening on ...")
swift run QUICEchoServer client
```

### "TLS provider not configured"

You're running in release mode, which doesn't have `MockTLSProvider`. Build in debug mode:

```sh
# Debug mode (default for `swift run`)
swift run QUICEchoServer server

# Explicitly debug
swift build -c debug && .build/debug/QUICEchoServer server
```

### Build errors about NIOCore.SocketAddress

If you see type conflicts between `SocketAddress` types, use the fully qualified name:

```swift
// Use QUIC's SocketAddress (takes UInt16 port)
let addr = QUIC.SocketAddress(ipAddress: "127.0.0.1", port: 4433)

// NIOCore's SocketAddress (takes Int port)
let nioAddr = try NIOCore.SocketAddress(ipAddress: "127.0.0.1", port: 4433)
```

### Port already in use

The default ports are 4433 (QUIC echo) and 4443 (HTTP/3). If they're in use:

```sh
swift run QUICEchoServer server --port 5555
swift run HTTP3Demo server --port 8443
```

### Performance tips

- Use `HTTP3Settings.smallDynamicTable` or `.largeDynamicTable` for better header compression on connections with many requests
- Increase `initialMaxStreamsBidi` if you need more concurrent requests
- Increase `initialMaxData` and `initialMaxStreamDataBidiLocal` for large file transfers
- Set `maxIdleTimeout` appropriately to avoid keeping unused connections open

---

## Files

```
Examples/
├── EXAMPLES.md                  ← This documentation
├── QUICEchoServer/
│   └── main.swift               ← QUIC echo server + client demo
├── HTTP3Demo/
│   └── main.swift               ← HTTP/3 server + client demo
├── WebTransportDemo/
│   └── main.swift               ← WebTransport echo server + client demo
└── QUICNetworkDemo/
    └── main.swift               ← ECN / PMTUD / platform socket demo
```

---

## Related Documentation

- [RFC 9000 — QUIC Transport](https://www.rfc-editor.org/rfc/rfc9000.html)
- [RFC 9001 — QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001.html)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002.html)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html)
- [RFC 9204 — QPACK](https://www.rfc-editor.org/rfc/rfc9204.html)
- [RFC 9218 — Extensible Priorities for HTTP](https://www.rfc-editor.org/rfc/rfc9218.html)
- [RFC 9220 — Bootstrapping WebSockets with HTTP/3](https://www.rfc-editor.org/rfc/rfc9220.html) (Extended CONNECT)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297.html)
- [draft-ietf-webtrans-http3 — WebTransport over HTTP/3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
- [RFC 3168 — Explicit Congestion Notification](https://www.rfc-editor.org/rfc/rfc3168.html)
- [RFC 8899 — DPLPMTUD](https://www.rfc-editor.org/rfc/rfc8899.html)