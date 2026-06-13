# ``QUIC``

A pure Swift implementation of the QUIC protocol (RFC 9000).

## Overview

Quiver provides a modern, async/await-based QUIC implementation for Swift applications, fully compliant with RFC 9000, RFC 9001, and RFC 9002.

QUIC is a multiplexed transport protocol built on UDP that provides:
- Encrypted connections by default (TLS 1.3)
- Multiplexed streams over a single connection
- Low-latency connection establishment
- Connection migration support
- Improved congestion control

### Key Features

- **async/await everywhere** - Modern Swift concurrency
- **Value types first** - Struct-based data types
- **Protocol-oriented** - Clean abstractions
- **Sendable compliance** - Thread-safe by design

## Getting Started

### Client Connection

```swift
let config = QUICConfiguration.production {
    MyTLSProvider()
}
let endpoint = QUICEndpoint(configuration: config)
let connection = try await endpoint.connect(to: serverAddress)
let stream = try await connection.openStream()
try await stream.write(data)
let response = try await stream.read()
```

### Server Listener

```swift
let config = QUICConfiguration.production {
    MyTLSProvider()
}
let (endpoint, runTask) = try await QUICEndpoint.serve(
    host: "0.0.0.0",
    port: 4433,
    configuration: config
)
for await connection in await endpoint.incomingConnections {
    Task {
        for await stream in connection.incomingStreams {
            // Handle stream
        }
    }
}
await endpoint.stop()
runTask.cancel()
```

## Topics

### Essentials

- ``QUICEndpoint``
- ``QUICConfiguration``
- ``QUICSecurityMode``

### Connections

- ``QUICConnectionProtocol``
- ``SocketAddress``

### Streams

- ``QUICStreamProtocol``

### Errors

- ``QUICSecurityError``
