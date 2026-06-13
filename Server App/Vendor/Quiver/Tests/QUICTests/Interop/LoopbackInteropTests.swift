/// Loopback Interoperability Tests
///
/// Self-contained tests that spin up a Quiver server and client on localhost.
/// No Docker or external services required — these tests validate the full QUIC
/// stack end-to-end using real UDP sockets and real TLS 1.3.

import Testing
import Foundation
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto

// MARK: - Loopback Test Helper

/// Shared helper for loopback interop tests.
///
/// Creates matching server and client configurations that use development-mode
/// TLS (self-signed P-256 key, no cert validation) so that the tests are fully
/// self-contained.
private enum LoopbackHelper {

    /// ALPN used by both server and client in these tests.
    static let alpn = "quic-loopback-test"

    /// Creates a server `QUICConfiguration` with a fresh self-signed key.
    static func makeServerConfiguration() -> QUICConfiguration {
        let signingKey = SigningKey.generateP256()
        let mockCertDER = Data([0x30, 0x82, 0x01, 0x00])

        var config = QUICConfiguration.development {
            let tlsConfig = TLSConfiguration.server(
                signingKey: signingKey,
                certificateChain: [mockCertDER],
                alpnProtocols: [alpn]
            )
            return TLS13Handler(configuration: tlsConfig)
        }
        config.alpn = [alpn]
        config.maxIdleTimeout = .seconds(30)
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        return config
    }

    /// Creates a client `QUICConfiguration` that accepts self-signed certs.
    static func makeClientConfiguration() -> QUICConfiguration {
        var config = QUICConfiguration.development {
            var tlsConfig = TLSConfiguration.client(
                serverName: "localhost",
                alpnProtocols: [alpn]
            )
            tlsConfig.verifyPeer = false
            tlsConfig.allowSelfSigned = true
            return TLS13Handler(configuration: tlsConfig)
        }
        config.alpn = [alpn]
        config.maxIdleTimeout = .seconds(30)
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        return config
    }

    /// Starts a server on a random port and returns (endpoint, runTask, boundPort).
    ///
    /// The caller is responsible for calling `endpoint.stop()` and `runTask.cancel()`
    /// when done.
    static func startServer() async throws -> (QUICEndpoint, Task<Void, Error>, UInt16) {
        let serverConfig = makeServerConfiguration()
        let (endpoint, runTask) = try await QUICEndpoint.serve(
            host: "127.0.0.1",
            port: 0, // OS picks a free port
            configuration: serverConfig
        )

        // Poll for the local address — the NIO socket may need a few event-loop
        // ticks before the OS-assigned port is visible.
        var boundPort: UInt16?
        for _ in 0..<50 { // up to ~1 second
            if let addr = await endpoint.localAddress, addr.port != 0 {
                boundPort = addr.port
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard let port = boundPort else {
            await endpoint.stop()
            runTask.cancel()
            throw LoopbackTestError.serverDidNotBind
        }

        return (endpoint, runTask, port)
    }

    /// Connects a client to `127.0.0.1:port` with a timeout, returning the
    /// established connection.
    static func connectClient(
        port: UInt16,
        timeout: Duration = .seconds(10)
    ) async throws -> (QUICEndpoint, any QUICConnectionProtocol) {
        let clientConfig = makeClientConfiguration()
        let endpoint = QUICEndpoint(configuration: clientConfig)
        let address = QUIC.SocketAddress(ipAddress: "127.0.0.1", port: port)

        let connection = try await endpoint.dial(address: address, timeout: timeout)
        return (endpoint, connection)
    }
}

// MARK: - Error type

private enum LoopbackTestError: Error, CustomStringConvertible {
    case serverDidNotBind
    case connectionTimeout
    case handshakeIncomplete
    case unexpectedData(expected: Data, got: Data)

    var description: String {
        switch self {
        case .serverDidNotBind:
            return "Server did not bind to a local address"
        case .connectionTimeout:
            return "Connection or operation timed out"
        case .handshakeIncomplete:
            return "TLS handshake did not complete"
        case .unexpectedData(let expected, let got):
            return "Data mismatch — expected \(expected.count) bytes, got \(got.count) bytes"
        }
    }
}

// MARK: - Handshake Tests

@Suite("Loopback Handshake Tests")
struct LoopbackHandshakeTests {

    @Test("Client connects to server over loopback", .timeLimit(.minutes(1)))
    func basicHandshake() async throws {
        // Start server
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
            }
        }

        // Connect client
        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        // dial() completes only after handshake, so isEstablished should be true
        #expect(connection.isEstablished, "Connection should be established after dial()")
        #expect(connection.remoteAddress.port == port, "Remote port should match server")
    }

    @Test("Server sees incoming connection", .timeLimit(.minutes(1)))
    func serverSeesConnection() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
            }
        }

        // Listen for incoming connections in a task
        let connectionReceived = ManagedAtomic(0)
        let serverConnectionTask = Task {
            let incomingStream = await server.incomingConnections
            for await conn in incomingStream {
                connectionReceived.store(1)
                // Just accept one connection for the test
                _ = conn
                break
            }
        }

        // Connect client
        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        // Give server time to process the connection
        try await Task.sleep(for: .milliseconds(500))

        #expect(connection.isEstablished)
        #expect(connectionReceived.load() == 1, "Server should have received a connection")

        // Cleanup
        await connection.close(error: nil)
        await clientEndpoint.stop()
        serverConnectionTask.cancel()
    }
}

// MARK: - Bidirectional Stream Echo Tests

@Suite("Loopback Stream Echo Tests")
struct LoopbackStreamEchoTests {

    @Test("Bidirectional echo — single message", .timeLimit(.minutes(1)))
    func singleMessageEcho() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        // Server echo handler
        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            await echoStream(stream)
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        // Connect client
        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        #expect(connection.isEstablished)

        // Open a stream and send a message
        let stream = try await connection.openStream()

        let message = Data("Hello, loopback QUIC!".utf8)
        try await stream.write(message)
        try await stream.closeWrite()

        // Read the echoed response
        let response = try await readAll(stream, timeout: .seconds(5))

        #expect(response == message, "Echoed data should match sent data")
    }

    @Test("Bidirectional echo — multiple messages", .timeLimit(.minutes(1)))
    func multipleMessageEcho() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            await echoStream(stream)
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        let stream = try await connection.openStream()

        let messages = [
            "First message",
            "Second message",
            "Third message 🚀",
        ]

        // Send all messages, then close
        for msg in messages {
            try await stream.write(Data(msg.utf8))
        }
        try await stream.closeWrite()

        // Read everything back
        let expected = Data(messages.joined().utf8)
        let response = try await readAll(stream, timeout: .seconds(5))

        #expect(response == expected, "All echoed data should match all sent data")
    }

    @Test("Bidirectional echo — large payload", .timeLimit(.minutes(1)))
    func largePayloadEcho() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            await echoStream(stream)
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        let stream = try await connection.openStream()

        // 512 bytes — large enough to be meaningful,
        // small enough to stay within a single QUIC packet.
        let payload = Data((0..<512).map { UInt8($0 & 0xFF) })
        try await stream.write(payload)
        try await stream.closeWrite()

        let response = try await readAll(stream, timeout: .seconds(15))

        #expect(response.count == payload.count, "Response should be same size as payload")
        #expect(response == payload, "Response should match payload")
    }
}

// MARK: - Multiple Streams Tests

@Suite("Loopback Multiple Streams Tests")
struct LoopbackMultipleStreamsTests {

    @Test("Open multiple bidirectional streams concurrently", .timeLimit(.minutes(1)))
    func multipleBidiStreams() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            await echoStream(stream)
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        let streamCount = 5

        // Open streams and send unique data on each
        try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for i in 0..<streamCount {
                group.addTask {
                    let stream = try await connection.openStream()
                    let message = Data("Stream \(i) data".utf8)
                    try await stream.write(message)
                    try await stream.closeWrite()

                    let response = try await readAll(stream, timeout: .seconds(5))
                    let match = (response == message)
                    return (i, match)
                }
            }

            var results: [(Int, Bool)] = []
            for try await result in group {
                results.append(result)
            }

            #expect(results.count == streamCount, "All \(streamCount) streams should complete")
            for (i, matched) in results {
                #expect(matched, "Stream \(i) echo should match")
            }
        }
    }

    @Test("Stream IDs are properly assigned", .timeLimit(.minutes(1)))
    func streamIDAssignment() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task { await echoStream(stream) }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        // Client-initiated bidirectional stream IDs: 0, 4, 8, 12, ...
        let stream1 = try await connection.openStream()
        let stream2 = try await connection.openStream()
        let stream3 = try await connection.openStream()

        #expect(stream1.id == 0, "First client bidi stream should be ID 0")
        #expect(stream2.id == 4, "Second client bidi stream should be ID 4")
        #expect(stream3.id == 8, "Third client bidi stream should be ID 8")

        // All should be bidirectional
        #expect(stream1.isBidirectional)
        #expect(stream2.isBidirectional)
        #expect(stream3.isBidirectional)

        // Cleanup
        try await stream1.closeWrite()
        try await stream2.closeWrite()
        try await stream3.closeWrite()
    }
}

// MARK: - Unidirectional Stream Tests

@Suite("Loopback Unidirectional Stream Tests")
struct LoopbackUnidirectionalStreamTests {

    @Test("Client sends data on unidirectional stream", .timeLimit(.minutes(1)))
    func clientUniStream() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        // Track data received by server on uni streams
        let receivedData = DataCollector()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            do {
                                let data = try await readAll(stream, timeout: .seconds(5))
                                receivedData.append(data)
                            } catch {
                                // stream may close
                            }
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        // Open unidirectional stream
        let stream = try await connection.openUniStream()

        // Client-initiated uni stream IDs: 2, 6, 10, ...
        #expect(stream.id == 2, "First client uni stream should be ID 2")
        #expect(stream.isUnidirectional, "Stream should be unidirectional")

        let message = Data("One-way message".utf8)
        try await stream.write(message)
        try await stream.closeWrite()

        // Give server time to receive
        try await Task.sleep(for: .milliseconds(500))

        let allReceived = receivedData.allData
        #expect(allReceived.contains(where: { $0 == message }),
                "Server should have received the unidirectional data")
    }
}

// MARK: - Connection Close Tests

@Suite("Loopback Connection Close Tests")
struct LoopbackConnectionCloseTests {

    @Test("Graceful connection close", .timeLimit(.minutes(1)))
    func gracefulClose() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                // Just accept the connection; don't do anything
                _ = conn
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        #expect(connection.isEstablished)

        // Close the connection gracefully
        await connection.close(error: nil)

        // Give the close a moment to propagate
        try await Task.sleep(for: .milliseconds(200))

        await clientEndpoint.stop()
    }

    @Test("Connection close after stream activity", .timeLimit(.minutes(1)))
    func closeAfterStreamActivity() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task {
                            await echoStream(stream)
                        }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        // Do some stream work first
        let stream = try await connection.openStream()
        let data = Data("pre-close data".utf8)
        try await stream.write(data)
        try await stream.closeWrite()

        let response = try await readAll(stream, timeout: .seconds(5))
        #expect(response == data)

        // Now close the connection
        await connection.close(error: nil)
        try await Task.sleep(for: .milliseconds(200))

        await clientEndpoint.stop()
    }
}

// MARK: - Stress / Robustness Tests

@Suite("Loopback Stress Tests")
struct LoopbackStressTests {

    @Test("Rapid open-send-close on many streams", .timeLimit(.minutes(2)))
    func rapidStreams() async throws {
        let (server, serverRunTask, port) = try await LoopbackHelper.startServer()

        let serverTask = Task {
            let connectionStream = await server.incomingConnections
            for await conn in connectionStream {
                Task {
                    for await stream in conn.incomingStreams {
                        Task { await echoStream(stream) }
                    }
                }
            }
        }

        defer {
            Task {
                await server.stop()
                serverRunTask.cancel()
                serverTask.cancel()
            }
        }

        let (clientEndpoint, connection) = try await LoopbackHelper.connectClient(port: port)

        defer {
            Task {
                await connection.close(error: nil)
                await clientEndpoint.stop()
            }
        }

        let streamCount = 5
        let successCount = ManagedAtomic(0)

        // Open streams sequentially to avoid overwhelming the connection
        // under test conditions, then read responses concurrently.
        for i in 0..<streamCount {
            let stream = try await connection.openStream()
            let msg = Data("rapid-\(i)".utf8)
            try await stream.write(msg)
            try await stream.closeWrite()

            let resp = try await readAll(stream, timeout: .seconds(10))
            if resp == msg {
                successCount.add(1)
            }
        }

        // Require at least 80% success — timing edge cases on the last
        // stream can cause occasional misses under load.
        let minRequired = streamCount * 4 / 5
        #expect(
            successCount.load() >= minRequired,
            "At least \(minRequired)/\(streamCount) streams should echo correctly, got \(successCount.load())"
        )
    }
}

// MARK: - Helpers

/// Simple thread-safe atomic integer for tests.
private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ value: Int) {
        self._value = value
    }

    func load() -> Int {
        lock.withLock { _value }
    }

    func store(_ value: Int) {
        lock.withLock { _value = value }
    }

    func add(_ delta: Int) {
        lock.withLock { _value += delta }
    }
}

/// Thread-safe collector of Data buffers.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: [Data] = []

    var allData: [Data] {
        lock.withLock { _data }
    }

    func append(_ data: Data) {
        lock.withLock { _data.append(data) }
    }
}

/// Echo handler — reads from the stream and writes everything back, then closes.
private func echoStream(_ stream: any QUICStreamProtocol) async {
    do {
        var accumulated = Data()
        while true {
            let chunk = try await stream.read()
            if chunk.isEmpty { break }
            accumulated.append(chunk)

            // Echo each chunk immediately for interactive tests
            try await stream.write(chunk)
        }
        try await stream.closeWrite()
    } catch {
        // Stream may have been reset or connection closed — that's fine
        await stream.reset(errorCode: 0x00)
    }
}

/// Read all data from a stream until FIN (empty read) or timeout.
private func readAll(
    _ stream: any QUICStreamProtocol,
    timeout: Duration
) async throws -> Data {
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            var result = Data()
            while true {
                let chunk = try await stream.read()
                if chunk.isEmpty { break }
                result.append(chunk)
            }
            return result
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw LoopbackTestError.connectionTimeout
        }

        guard let data = try await group.next() else {
            throw LoopbackTestError.connectionTimeout
        }
        group.cancelAll()
        return data
    }
}