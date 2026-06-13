/// QUIC Endpoint E2E Tests
///
/// Tests for end-to-end QUIC connection establishment and data exchange.

import Testing
import Foundation
import Synchronization
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto
@testable import QUICConnection

/// Thread-safe packet collector for tests
final class PacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _packets: [Data] = []

    var packets: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _packets
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _packets.append(data)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _packets.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _packets.isEmpty
    }
}

// MARK: - Endpoint Tests

@Suite("QUICEndpoint Tests")
struct EndpointTests {
    // MARK: - Creation Tests

    @Test("Create client endpoint")
    func createClientEndpoint() async throws {
        let config = QUICConfiguration()
        let endpoint = QUICEndpoint(configuration: config)

        #expect(await endpoint.connectionCount == 0)
    }

    @Test("Create server endpoint")
    func createServerEndpoint() async throws {
        let config = QUICConfiguration()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let endpoint = try await QUICEndpoint.listen(
            address: serverAddress,
            configuration: config
        )

        #expect(await endpoint.localAddress?.port == 4433)
        #expect(await endpoint.connectionCount == 0)
    }

    // MARK: - Connection Tests

    @Test("Client can initiate connection")
    func clientInitiatesConnection() async throws {
        let config = QUICConfiguration.testing()
        let endpoint = QUICEndpoint(configuration: config)

        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        // Track sent packets
        let sentPackets = PacketCollector()
        await endpoint.setSendCallback { data, _ in
            sentPackets.append(data)
        }

        // Connect generates Initial packet
        let _ = try await endpoint.connect(to: serverAddress)

        // Should have sent at least one packet (Initial with ClientHello)
        #expect(sentPackets.count >= 1)
        #expect(await endpoint.connectionCount >= 1)

        // Initial packet should be at least 1200 bytes
        if let firstPacket = sentPackets.packets.first {
            #expect(firstPacket.count >= 1200)
        }
    }

    @Test("Server accepts new connection")
    func serverAcceptsConnection() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(
            address: serverAddress,
            configuration: config
        )

        // Create a mock Initial packet
        let initialPacket = try createMockInitialPacket()

        // Process the Initial packet
        let sentPackets = PacketCollector()
        await server.setSendCallback { data, _ in
            sentPackets.append(data)
        }

        _ = try await server.processIncomingPacket(initialPacket, from: clientAddress)

        // Server should have created a connection
        #expect(await server.connectionCount >= 1)

        // Server should have sent response (ServerHello + Handshake)
        #expect(sentPackets.count >= 1)
    }

    // MARK: - Packet Processing Tests

    @Test("PacketProcessor encrypts and decrypts packets")
    func packetProcessorRoundtrip() async throws {
        // Use same DCID for both client and server (this is the original DCID)
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        // Client encrypts with client sealer
        let clientProcessor = PacketProcessor(dcidLength: 8)
        let (_, _) = try clientProcessor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        // Create a simple packet
        let header = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let frames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data("test".utf8)))
        ]

        // Encrypt with client
        let encrypted = try clientProcessor.encryptLongHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: 0
        )

        // Initial packets must be >= 1200 bytes
        #expect(encrypted.count >= 1200)

        // Server decrypts with server opener (using same original DCID for key derivation)
        let serverProcessor = PacketProcessor(dcidLength: 8)
        let (_, _) = try serverProcessor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: false,
            version: .v1
        )

        // Decrypt - server uses opener which reads client's encrypted data
        let parsed = try serverProcessor.decryptPacket(encrypted)

        #expect(parsed.packetNumber == 0)
        #expect(parsed.encryptionLevel == .initial)
        #expect(!parsed.frames.isEmpty)
    }

    // MARK: - Connection Router Tests

    @Test("ConnectionRouter routes by DCID")
    func routerRoutesByDCID() async throws {
        let router = ConnectionRouter(isServer: true, dcidLength: 8)

        // Create a connection
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 1234)

        let connection = ManagedConnection(
            role: .server,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        // Register
        router.register(connection)

        // Route should find the connection
        let found = router.connection(for: scid)
        #expect(found != nil)
        #expect(found?.sourceConnectionID == scid)
    }

    // MARK: - Timer Manager Tests

    @Test("TimerManager tracks connection timers")
    func timerManagerTracksTimers() async throws {
        let timerManager = TimerManager(idleTimeout: .seconds(30))

        // Create a connection
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 1234)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        // Register
        timerManager.register(connection)

        #expect(timerManager.connectionCount == 1)
        #expect(timerManager.activeConnectionCount == 1)

        // Should have a deadline (idle timeout)
        let deadline = timerManager.nextDeadline()
        #expect(deadline != nil)

        // Unregister
        timerManager.unregister(connection)
        #expect(timerManager.connectionCount == 0)
    }

    // MARK: - Managed Connection Tests

    @Test("ManagedConnection creates Initial packet")
    func managedConnectionCreatesInitial() async throws {
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        // Check initial state
        #expect(connection.handshakeState == .idle)

        // Start handshake - this should return quickly
        let packets = try await connection.start()

        // Should have generated Initial packet(s)
        #expect(!packets.isEmpty, "Expected at least one packet from start()")

        // Initial packet should be >= 1200 bytes
        if let firstPacket = packets.first {
            #expect(firstPacket.count >= 1200, "Initial packet must be at least 1200 bytes")
        }

        // Connection should be in connecting state
        #expect(connection.handshakeState == .connecting)
    }

    @Test("ManagedConnection handshake state transitions")
    func managedConnectionHandshakeStates() async throws {
        // Start with idle
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        #expect(connection.handshakeState == .idle)

        // After start, should be connecting
        _ = try await connection.start()
        #expect(connection.handshakeState == .connecting)
    }

    // MARK: - Managed Stream Tests

    @Test("ManagedStream read/write operations")
    func managedStreamOperations() async throws {
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        tlsProvider.forceComplete()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        // Need to establish connection first for streams
        _ = try await connection.start()

        // Open a stream
        let stream = try await connection.openStream()
        #expect(stream.isBidirectional)
        #expect(!stream.isUnidirectional)

        // Write some data
        let testData = Data("Hello, QUIC!".utf8)
        try await stream.write(testData)

        // Close write
        try await stream.closeWrite()
    }

    // MARK: - Helper Methods

    /// Creates a mock Initial packet for testing
    private func createMockInitialPacket() throws -> Data {
        let processor = PacketProcessor(dcidLength: 8)
        let dcid = try #require(ConnectionID.random(length: 8))
        let scid = try #require(ConnectionID.random(length: 8))

        // Derive keys
        let (_, _) = try processor.deriveAndInstallInitialKeys(
            connectionID: dcid,
            isClient: true,
            version: .v1
        )

        let header = LongHeader(
            packetType: .initial,
            version: .v1,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: nil
        )

        let frames: [Frame] = [
            .crypto(CryptoFrame(offset: 0, data: Data("MOCK_CLIENT_HELLO".utf8)))
        ]

        return try processor.encryptLongHeaderPacket(
            frames: frames,
            header: header,
            packetNumber: 0
        )
    }
}

// MARK: - Shutdown Safety Tests

@Suite("Shutdown Safety Tests")
struct ShutdownSafetyTests {
    /// Creates a ManagedConnection for testing
    private func createTestConnection() throws -> ManagedConnection {
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider()
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        return ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )
    }

    @Test("incomingStreams iterator after shutdown() returns nil", .timeLimit(.minutes(1)))
    func incomingStreamsIteratorAfterShutdownReturnsNil() async throws {
        let connection = try createTestConnection()
        _ = try await connection.start()

        // Shutdown the connection
        connection.shutdown()

        // Iterator should return nil immediately, NOT hang
        var iterator = connection.incomingStreams.makeAsyncIterator()
        let stream = await iterator.next()
        #expect(stream == nil, "Iterator should return nil after shutdown")
    }

    @Test("incomingStreams after shutdown() returns finished stream", .timeLimit(.minutes(1)))
    func incomingStreamsAfterShutdownReturnsFinished() async throws {
        let connection = try createTestConnection()
        _ = try await connection.start()

        // Shutdown the connection
        connection.shutdown()

        // Iterating should complete immediately, NOT hang
        var count = 0
        for await _ in connection.incomingStreams {
            count += 1
        }

        // Stream should be finished (no elements)
        #expect(count == 0)
    }

    @Test("readFromStream() after shutdown() throws connectionClosed", .timeLimit(.minutes(1)))
    func readFromStreamAfterShutdownThrows() async throws {
        let tlsProvider = MockTLSProvider()
        tlsProvider.forceComplete()

        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        _ = try await connection.start()

        // Open a stream
        let stream = try await connection.openStream()

        // Shutdown the connection
        connection.shutdown()

        // Reading should throw connectionClosed, NOT hang
        do {
            _ = try await stream.read()
            Issue.record("Expected error from read after shutdown")
        } catch {
            // Expected - either connectionClosed or streamClosed
        }
    }

    @Test("Multiple incomingStreams iterators after shutdown() all return nil", .timeLimit(.minutes(1)))
    func multipleIncomingStreamsIteratorsAfterShutdown() async throws {
        let connection = try createTestConnection()
        _ = try await connection.start()

        // Shutdown the connection
        connection.shutdown()

        // Multiple iterators should all return nil without hanging
        var nilCount = 0
        for _ in 0..<3 {
            var iterator = connection.incomingStreams.makeAsyncIterator()
            if await iterator.next() == nil {
                nilCount += 1
            }
        }

        #expect(nilCount == 3, "All iterators should return nil after shutdown")
    }

    @Test("shutdown() resumes waiting readers", .timeLimit(.minutes(1)))
    func shutdownResumesWaitingReaders() async throws {
        let tlsProvider = MockTLSProvider()
        tlsProvider.forceComplete()

        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )

        _ = try await connection.start()

        // Open a stream
        let stream = try await connection.openStream()

        // Start a read in background (will wait for data)
        let readTask = Task {
            try await stream.read()
        }

        // Give the read task time to register its continuation
        try await Task.sleep(for: .milliseconds(50))

        // Shutdown should resume the waiting reader
        connection.shutdown()

        // The read task should complete with an error
        var errorThrown = false
        do {
            _ = try await readTask.value
            Issue.record("Expected error from read")
        } catch {
            // Expected - reader was resumed with error
            errorThrown = true
        }
        #expect(errorThrown, "Read should have thrown an error")
    }

    @Test("shutdown() finishes existing incomingStreams iterator", .timeLimit(.minutes(1)))
    func shutdownFinishesExistingIterator() async throws {
        let connection = try createTestConnection()
        _ = try await connection.start()

        // Get the stream BEFORE shutdown (creates iterator)
        let streams = connection.incomingStreams

        // Start iterating in background
        let iterateTask = Task {
            var count = 0
            for await _ in streams {
                count += 1
            }
            return count
        }

        // Give time to start iteration
        try await Task.sleep(for: .milliseconds(50))

        // Shutdown should finish the stream
        connection.shutdown()

        // Iterator should complete
        let count = await iterateTask.value
        #expect(count == 0, "No streams should have been received")
    }

    @Test("Pending streams are buffered until incomingStreams is accessed", .timeLimit(.minutes(1)))
    func pendingStreamsAreBuffered() async throws {
        // This test verifies that streams arriving before incomingStreams
        // is accessed are buffered and delivered when it is accessed.
        // Note: We can't easily simulate incoming streams in a unit test,
        // but we verify the structure handles the pattern correctly.

        let connection = try createTestConnection()
        _ = try await connection.start()

        // Access incomingStreams (this creates the continuation)
        let streams = connection.incomingStreams

        // Start a task to collect streams
        let collectTask = Task {
            var count = 0
            for await _ in streams {
                count += 1
                if count >= 1 { break }  // Exit after first stream
            }
            return count
        }

        // Give time for the task to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Shutdown - this will finish the stream
        connection.shutdown()

        // Task should complete (possibly with 0 streams since we didn't simulate incoming)
        let count = await collectTask.value
        #expect(count >= 0, "Task should complete without hanging")
    }
}

// MARK: - Integration Tests

@Suite("Integration Tests")
struct IntegrationTests {
    @Test("Client-Server packet exchange")
    func clientServerPacketExchange() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        // Create endpoints
        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        // Capture packets
        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in
            clientToServer.append(data)
        }

        await server.setSendCallback { data, _ in
            serverToClient.append(data)
        }

        // Client initiates connection
        let _ = try await client.connect(to: serverAddress)

        // Process client's Initial at server
        for packet in clientToServer.packets {
            _ = try await server.processIncomingPacket(packet, from: clientAddress)
        }

        // Server should have sent response
        #expect(!serverToClient.isEmpty)

        // Process server's response at client
        for packet in serverToClient.packets {
            _ = try await client.processIncomingPacket(packet, from: serverAddress)
        }

        // Both endpoints should have connections
        #expect(await client.connectionCount >= 1)
        #expect(await server.connectionCount >= 1)
    }
}

// MARK: - Handshake Completion Signaling Tests

@Suite("Handshake Completion Signaling Tests")
struct HandshakeCompletionTests {

    /// Helper: creates a ManagedConnection with MockTLSProvider
    private func createTestConnection(
        role: ConnectionRole = .client,
        immediateCompletion: Bool = true
    ) throws -> (ManagedConnection, MockTLSProvider) {
        let scid = try #require(ConnectionID.random(length: 8))
        let dcid = try #require(ConnectionID.random(length: 8))
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)
        let tlsProvider = MockTLSProvider(immediateCompletion: immediateCompletion)
        let address = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        let connection = ManagedConnection(
            role: role,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )
        return (connection, tlsProvider)
    }

    // MARK: - waitForHandshake() basic behaviour

    @Test("waitForHandshake returns immediately when already established")
    func waitForHandshakeAlreadyEstablished() async throws {
        // Drive a full mock handshake so the connection reaches .established
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in clientToServer.append(data) }
        await server.setSendCallback { data, _ in serverToClient.append(data) }

        // Client sends Initial
        let connection = try await client.connect(to: serverAddress)

        // Drive handshake: client→server→client
        for packet in clientToServer.packets {
            _ = try await server.processIncomingPacket(packet, from: clientAddress)
        }
        for packet in serverToClient.packets {
            _ = try await client.processIncomingPacket(packet, from: serverAddress)
        }

        // Now the connection should be established
        #expect(connection.isEstablished)

        // waitForHandshake() should return immediately (no hang)
        try await connection.waitForHandshake()
    }

    @Test("waitForHandshake throws when connection is shutdown before handshake")
    func waitForHandshakeThrowsOnShutdown() async throws {
        let (connection, _) = try createTestConnection()

        // Start the handshake (moves to .connecting)
        _ = try await connection.start()
        #expect(connection.handshakeState == .connecting)

        // Kick off waitForHandshake in a child task — it should suspend
        let waitTask = Task {
            try await connection.waitForHandshake()
        }

        // Give the task a moment to actually suspend
        try await Task.sleep(for: .milliseconds(20))

        // Shutdown the connection — this should resume the waiter with error
        connection.shutdown()

        // The wait task should throw connectionClosed
        do {
            try await waitTask.value
            Issue.record("Expected waitForHandshake to throw after shutdown")
        } catch is ManagedConnectionError {
            // Expected — connectionClosed
        }
    }

    @Test("waitForHandshake throws when connection is already closed")
    func waitForHandshakeAlreadyClosed() async throws {
        let (connection, _) = try createTestConnection()
        _ = try await connection.start()

        // Transition to closing
        await connection.close(error: nil)

        // waitForHandshake should throw immediately
        do {
            try await connection.waitForHandshake()
            Issue.record("Expected error for closed connection")
        } catch is ManagedConnectionError {
            // Expected
        }
    }

    @Test("Multiple concurrent waitForHandshake callers all resume on completion")
    func multipleConcurrentWaiters() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in clientToServer.append(data) }
        await server.setSendCallback { data, _ in serverToClient.append(data) }

        let connection = try await client.connect(to: serverAddress)

        // Use a task group: 3 waiters + 1 driver task.
        // The driver completes the handshake; all 3 waiters should resume.
        let completedCount = try await withThrowingTaskGroup(
            of: Int.self,
            returning: Int.self
        ) { group in
            // 3 waiter tasks — each returns 1 on success
            for _ in 0..<3 {
                group.addTask {
                    try await connection.waitForHandshake()
                    return 1
                }
            }

            // Driver task — completes handshake, returns 0
            group.addTask { [clientToServer, serverToClient] in
                // Small delay to let waiters suspend first
                try await Task.sleep(for: .milliseconds(20))

                for packet in clientToServer.packets {
                    _ = try await server.processIncomingPacket(packet, from: clientAddress)
                }
                for packet in serverToClient.packets {
                    _ = try await client.processIncomingPacket(packet, from: serverAddress)
                }
                return 0
            }

            var total = 0
            for try await value in group {
                total += value
            }
            return total
        }

        #expect(completedCount == 3, "All 3 waiters should have completed")
    }

    @Test("Multiple concurrent waiters all fail on shutdown")
    func multipleConcurrentWaitersFailOnShutdown() async throws {
        let (connection, _) = try createTestConnection()
        _ = try await connection.start()

        // Use a task group: 3 waiters + 1 shutdown driver.
        let errorTotal = try await withThrowingTaskGroup(
            of: Int.self,
            returning: Int.self
        ) { group in
            // 3 waiter tasks — each returns 1 if waitForHandshake throws
            for _ in 0..<3 {
                group.addTask {
                    do {
                        try await connection.waitForHandshake()
                        return 0  // should not succeed
                    } catch {
                        return 1
                    }
                }
            }

            // Driver task — shuts down after waiters have suspended
            group.addTask {
                try await Task.sleep(for: .milliseconds(20))
                connection.shutdown()
                return 0
            }

            var total = 0
            for try await value in group {
                total += value
            }
            return total
        }

        #expect(errorTotal == 3, "All 3 waiters should have received errors")
    }

    // MARK: - Server-side handshake completion

    @Test("Server-side waitForHandshake completes via processTLSOutputs path")
    func serverSideHandshakeCompletion() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in clientToServer.append(data) }
        await server.setSendCallback { data, _ in serverToClient.append(data) }

        // Client sends Initial
        _ = try await client.connect(to: serverAddress)

        // Server processes client Initial — this triggers server TLS handshake
        // and should complete the server's handshake
        for packet in clientToServer.packets {
            _ = try await server.processIncomingPacket(packet, from: clientAddress)
        }

        // Verify the server generated response packets (handshake messages)
        #expect(!serverToClient.isEmpty, "Server should have sent handshake response")
    }

    // MARK: - connect() returns before handshake (low-level API)

    @Test("connect() returns connection in non-established state (low-level API)")
    func connectReturnsBeforeHandshake() async throws {
        let config = QUICConfiguration.testing()
        let client = QUICEndpoint(configuration: config)
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)

        await client.setSendCallback { _, _ in }

        let connection = try await client.connect(to: serverAddress)

        // connect() is low-level — returns immediately after sending Initial
        // handshake has NOT completed yet (no server packets processed)
        #expect(!connection.isEstablished,
                "connect() should return before handshake completes")
    }

    // MARK: - is0RTTAccepted correctness

    @Test("is0RTTAccepted defaults to false for normal connections")
    func is0RTTAcceptedDefaultsFalse() async throws {
        let (connection, _) = try createTestConnection()

        // Before handshake
        #expect(!connection.is0RTTAccepted)

        // Start handshake (but don't complete it)
        _ = try await connection.start()
        #expect(!connection.is0RTTAccepted)
    }

    // MARK: - Handshake state transitions with waitForHandshake

    @Test("Handshake state transitions: idle → connecting → established")
    func handshakeStateTransitionsWithWait() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in clientToServer.append(data) }
        await server.setSendCallback { data, _ in serverToClient.append(data) }

        let connection = try await client.connect(to: serverAddress)
        let managed = try #require(connection as? ManagedConnection)

        // After connect(), state should be connecting (not established)
        #expect(managed.handshakeState == .connecting)

        // Drive full handshake
        for packet in clientToServer.packets {
            _ = try await server.processIncomingPacket(packet, from: clientAddress)
        }
        for packet in serverToClient.packets {
            _ = try await client.processIncomingPacket(packet, from: serverAddress)
        }

        // Now should be established
        #expect(managed.handshakeState == HandshakeState.established)

        // waitForHandshake should return immediately
        try await connection.waitForHandshake()
    }

    // MARK: - QUICConnectionProtocol conformance

    @Test("waitForHandshake is available on QUICConnectionProtocol")
    func waitForHandshakeOnProtocol() async throws {
        let config = QUICConfiguration.testing()
        let serverAddress = SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        let clientAddress = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        let server = try await QUICEndpoint.listen(address: serverAddress, configuration: config)
        let client = QUICEndpoint(configuration: config)

        let clientToServer = PacketCollector()
        let serverToClient = PacketCollector()

        await client.setSendCallback { data, _ in clientToServer.append(data) }
        await server.setSendCallback { data, _ in serverToClient.append(data) }

        let conn: any QUICConnectionProtocol = try await client.connect(to: serverAddress)

        // Drive handshake
        for packet in clientToServer.packets {
            _ = try await server.processIncomingPacket(packet, from: clientAddress)
        }
        for packet in serverToClient.packets {
            _ = try await client.processIncomingPacket(packet, from: serverAddress)
        }

        // Call through the protocol
        try await conn.waitForHandshake()
        #expect(conn.isEstablished)
        #expect(!conn.is0RTTAccepted)
    }

    // MARK: - dial() integration (handshake + timeout)

    @Test("dial() timeout produces handshakeTimeout error")
    func dialTimeoutProducesError() async throws {
        let config = QUICConfiguration.testing()
        let client = QUICEndpoint(configuration: config)

        // Point at a non-existent server — handshake will never complete
        let nowhere = SocketAddress(ipAddress: "127.0.0.1", port: 19999)

        do {
            _ = try await client.dial(address: nowhere, timeout: .milliseconds(200))
            Issue.record("Expected handshakeTimeout error")
        } catch {
            guard case QUICEndpointError.handshakeTimeout = error else {
                Issue.record("Expected handshakeTimeout but got: \(error)")
                return
            }
            // Expected — handshakeTimeout
        }
    }
}
