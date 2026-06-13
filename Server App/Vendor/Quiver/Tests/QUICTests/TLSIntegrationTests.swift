/// TLS 1.3 Integration Tests
///
/// Tests the complete TLS 1.3 handshake between client and server
/// using the real TLS13Handler implementation (not MockTLSProvider).

import Testing
import Foundation
import Crypto
import Synchronization
@testable import QUIC
@testable import QUICCore
@testable import QUICCrypto
@testable import QUICConnection

// MARK: - TLS Integration Tests

@Suite("TLS Integration Tests")
struct TLSIntegrationTests {

    /// Shared server signing key for tests (generated once per test suite)
    private static let serverSigningKey = SigningKey.generateP256()
    /// Mock certificate chain for server (minimal valid DER structure)
    private static let serverCertificateChain = [Data([0x30, 0x82, 0x01, 0x00])]

    /// Creates a client ManagedConnection with TLS13Handler
    private func createClientConnection(
        dcid: ConnectionID,
        scid: ConnectionID,
        serverName: String = "localhost"
    ) -> ManagedConnection {
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)

        // Use real TLS13Handler with public key verification
        var tlsConfig = TLSConfiguration.client(
            serverName: serverName,
            alpnProtocols: ["h3"]
        )
        // Use public key verification for test certificates
        tlsConfig.expectedPeerPublicKey = Self.serverSigningKey.publicKeyBytes
        let tlsProvider = TLS13Handler(configuration: tlsConfig)

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

    /// Creates a server ManagedConnection with TLS13Handler
    private func createServerConnection(
        dcid: ConnectionID,
        scid: ConnectionID,
        originalDCID: ConnectionID
    ) -> ManagedConnection {
        let config = QUICConfiguration()
        let params = TransportParameters(from: config, sourceConnectionID: scid)

        // Use real TLS13Handler with certificate
        var tlsConfig = TLSConfiguration()
        tlsConfig.alpnProtocols = ["h3"]
        tlsConfig.signingKey = Self.serverSigningKey
        tlsConfig.certificateChain = Self.serverCertificateChain
        let tlsProvider = TLS13Handler(configuration: tlsConfig)

        let address = SocketAddress(ipAddress: "127.0.0.1", port: 54321)

        return ManagedConnection(
            role: .server,
            version: .v1,
            sourceConnectionID: scid,
            destinationConnectionID: dcid,
            originalConnectionID: originalDCID,
            transportParameters: params,
            tlsProvider: tlsProvider,
            remoteAddress: address
        )
    }

    // MARK: - Basic Handshake Tests

    @Test("Client generates Initial packet with TLS13Handler")
    func clientGeneratesInitialPacket() async throws {
        let clientSCID = ConnectionID.random(length: 8)!
        let serverDCID = ConnectionID.random(length: 8)!

        let client = createClientConnection(dcid: serverDCID, scid: clientSCID)

        #expect(client.handshakeState == .idle)

        // Start should generate Initial packet with ClientHello
        let packets = try await client.start()

        #expect(client.handshakeState == .connecting)
        #expect(!packets.isEmpty, "Expected at least one Initial packet")

        // Initial packet should be at least 1200 bytes
        if let firstPacket = packets.first {
            #expect(firstPacket.count >= 1200, "Initial packet must be >= 1200 bytes")

            // Verify it's a Long Header Initial packet
            #expect(firstPacket[0] & 0x80 != 0, "Should be long header")
        }
    }

    @Test("Full client-server handshake with TLS13Handler", .timeLimit(.minutes(1)))
    func fullClientServerHandshake() async throws {
        // Connection IDs
        let clientSCID = ConnectionID.random(length: 8)!
        let serverSCID = ConnectionID.random(length: 8)!
        // Client's initial DCID (becomes original DCID for Initial key derivation)
        let originalDCID = ConnectionID.random(length: 8)!

        // Create connections
        // Client uses originalDCID as its destination (server's ID)
        let client = createClientConnection(dcid: originalDCID, scid: clientSCID)

        // Server responds with its own SCID, uses client's SCID as destination
        let server = createServerConnection(
            dcid: clientSCID,
            scid: serverSCID,
            originalDCID: originalDCID
        )

        // Step 1: Client starts handshake
        let clientInitial = try await client.start()
        #expect(!clientInitial.isEmpty, "Client should send Initial packet")
        #expect(client.handshakeState == .connecting)

        // Server must also call start() to derive Initial keys before processing
        _ = try await server.start()

        // Step 2: Server processes Initial (contains ClientHello)
        var serverResponse: [Data] = []
        for packet in clientInitial {
            let response = try await server.processDatagram(packet)
            serverResponse.append(contentsOf: response)
        }

        #expect(!serverResponse.isEmpty, "Server should respond with packets")

        // Step 3: Client processes server response
        // (ServerHello + EncryptedExtensions + Finished)
        var clientResponse: [Data] = []
        for packet in serverResponse {
            let response = try await client.processDatagram(packet)
            clientResponse.append(contentsOf: response)
        }

        // Client should now be established (after processing server Finished)
        #expect(client.handshakeState == .established, "Client should be established")
        #expect(client.isEstablished, "Client isEstablished should be true")

        // Step 4: Server processes client Finished
        for packet in clientResponse {
            // Check packet type - after handshake is established, keys may be discarded
            let isLongHeader = (packet[0] & 0x80) != 0
            do {
                _ = try await server.processDatagram(packet)
            } catch {
                // Once handshake is established, ignore Handshake/Initial packets
                // as keys may be discarded per QUIC spec
                if server.handshakeState == .established && isLongHeader {
                    continue
                }
                throw error
            }
        }

        #expect(server.handshakeState == .established, "Server should be established")
        #expect(server.isEstablished, "Server isEstablished should be true")

        // Cleanup
        client.shutdown()
        server.shutdown()
    }

    @Test("Handshake produces correct encryption levels", .timeLimit(.minutes(1)))
    func handshakeEncryptionLevels() async throws {
        let clientSCID = ConnectionID.random(length: 8)!
        let serverSCID = ConnectionID.random(length: 8)!
        let originalDCID = ConnectionID.random(length: 8)!

        let client = createClientConnection(dcid: originalDCID, scid: clientSCID)
        let server = createServerConnection(
            dcid: clientSCID,
            scid: serverSCID,
            originalDCID: originalDCID
        )

        // Client Initial
        let clientInitial = try await client.start()

        // Verify Initial packet format
        if let packet = clientInitial.first {
            let processor = PacketProcessor(dcidLength: 8)
            let headerInfo = try processor.extractHeaderInfo(from: packet)
            #expect(headerInfo.packetType == .initial, "First packet should be Initial")
        }

        // Server must start to derive Initial keys
        _ = try await server.start()

        // Server processes and responds
        var serverResponse: [Data] = []
        for packet in clientInitial {
            let response = try await server.processDatagram(packet)
            serverResponse.append(contentsOf: response)
        }

        // Server response should contain Handshake-level packets
        let processor = PacketProcessor(dcidLength: 8)
        for packet in serverResponse {
            let headerInfo = try processor.extractHeaderInfo(from: packet)
            // Server can send Initial (with ServerHello) or Handshake packets
            #expect(
                headerInfo.packetType == .initial || headerInfo.packetType == .handshake,
                "Server should send Initial or Handshake packets"
            )
        }

        // Complete handshake
        for packet in serverResponse {
            _ = try await client.processDatagram(packet)
        }

        #expect(client.isEstablished)

        client.shutdown()
        server.shutdown()
    }

    @Test("ALPN negotiation works", .timeLimit(.minutes(1)))
    func alpnNegotiation() async throws {
        let clientSCID = ConnectionID.random(length: 8)!
        let serverSCID = ConnectionID.random(length: 8)!
        let originalDCID = ConnectionID.random(length: 8)!

        // Create client with h3 ALPN
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3", "h3-29"]
        )
        clientConfig.expectedPeerPublicKey = Self.serverSigningKey.publicKeyBytes
        let clientTLS = TLS13Handler(configuration: clientConfig)
        let clientParams = TransportParameters(
            from: QUICConfiguration(),
            sourceConnectionID: clientSCID
        )
        let client = ManagedConnection(
            role: .client,
            version: .v1,
            sourceConnectionID: clientSCID,
            destinationConnectionID: originalDCID,
            transportParameters: clientParams,
            tlsProvider: clientTLS,
            remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 4433)
        )

        // Create server with h3 ALPN
        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = Self.serverSigningKey
        serverConfig.certificateChain = Self.serverCertificateChain
        let serverTLS = TLS13Handler(configuration: serverConfig)
        let serverParams = TransportParameters(
            from: QUICConfiguration(),
            sourceConnectionID: serverSCID
        )
        let server = ManagedConnection(
            role: .server,
            version: .v1,
            sourceConnectionID: serverSCID,
            destinationConnectionID: clientSCID,
            originalConnectionID: originalDCID,
            transportParameters: serverParams,
            tlsProvider: serverTLS,
            remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 54321)
        )

        // Complete handshake
        let clientInitial = try await client.start()
        _ = try await server.start()  // Server needs to derive Initial keys
        var serverResponse: [Data] = []
        for packet in clientInitial {
            serverResponse.append(contentsOf: try await server.processDatagram(packet))
        }
        var clientResponse: [Data] = []
        for packet in serverResponse {
            clientResponse.append(contentsOf: try await client.processDatagram(packet))
        }
        for packet in clientResponse {
            // Check packet type - after handshake is established, keys may be discarded
            let isLongHeader = (packet[0] & 0x80) != 0
            do {
                _ = try await server.processDatagram(packet)
            } catch {
                // Once handshake is established, ignore Handshake/Initial packets
                // as keys may be discarded per QUIC spec
                if server.handshakeState == .established && isLongHeader {
                    continue
                }
                throw error
            }
        }

        // Both sides should have negotiated h3
        #expect(clientTLS.negotiatedALPN == "h3", "Client ALPN should be h3")
        #expect(serverTLS.negotiatedALPN == "h3", "Server ALPN should be h3")

        client.shutdown()
        server.shutdown()
    }

    // MARK: - Stream Tests After Handshake

    @Test("Can open stream after handshake", .timeLimit(.minutes(1)))
    func openStreamAfterHandshake() async throws {
        let clientSCID = ConnectionID.random(length: 8)!
        let serverSCID = ConnectionID.random(length: 8)!
        let originalDCID = ConnectionID.random(length: 8)!

        let client = createClientConnection(dcid: originalDCID, scid: clientSCID)
        let server = createServerConnection(
            dcid: clientSCID,
            scid: serverSCID,
            originalDCID: originalDCID
        )

        // Complete handshake
        let clientInitial = try await client.start()
        _ = try await server.start()  // Server needs to derive Initial keys
        var serverResponse: [Data] = []
        for packet in clientInitial {
            serverResponse.append(contentsOf: try await server.processDatagram(packet))
        }
        var clientResponse: [Data] = []
        for packet in serverResponse {
            clientResponse.append(contentsOf: try await client.processDatagram(packet))
        }
        for packet in clientResponse {
            // Check packet type - after handshake is established, keys may be discarded
            let isLongHeader = (packet[0] & 0x80) != 0
            do {
                _ = try await server.processDatagram(packet)
            } catch {
                // Once handshake is established, ignore Handshake/Initial packets
                // as keys may be discarded per QUIC spec
                if server.handshakeState == .established && isLongHeader {
                    continue
                }
                throw error
            }
        }

        #expect(client.isEstablished)
        #expect(server.isEstablished)

        // Open a stream
        let stream = try await client.openStream()
        #expect(stream.isBidirectional)

        // Write data
        let testData = Data("Hello, QUIC with TLS 1.3!".utf8)
        try await stream.write(testData)

        client.shutdown()
        server.shutdown()
    }

    // MARK: - Error Handling Tests

    @Test("Client handles server not responding", .timeLimit(.minutes(1)))
    func clientHandlesNoResponse() async throws {
        let clientSCID = ConnectionID.random(length: 8)!
        let serverDCID = ConnectionID.random(length: 8)!

        let client = createClientConnection(dcid: serverDCID, scid: clientSCID)

        // Start handshake
        let packets = try await client.start()
        #expect(!packets.isEmpty)
        #expect(client.handshakeState == .connecting)

        // Without server response, client stays in connecting state
        #expect(!client.isEstablished)

        client.shutdown()
    }

    @Test("Key update after handshake", .timeLimit(.minutes(1)))
    func keyUpdateAfterHandshake() async throws {
        // Create TLS handlers directly
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        clientConfig.expectedPeerPublicKey = Self.serverSigningKey.publicKeyBytes
        let clientTLS = TLS13Handler(configuration: clientConfig)

        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = Self.serverSigningKey
        serverConfig.certificateChain = Self.serverCertificateChain
        let serverTLS = TLS13Handler(configuration: serverConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientTLS.setLocalTransportParameters(params)
        try serverTLS.setLocalTransportParameters(params)

        // Complete handshake
        let clientOutputs = try await clientTLS.startHandshake(isClient: true)
        _ = try await serverTLS.startHandshake(isClient: false)

        // Get ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, _) = output {
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil)

        // Server processes ClientHello
        let serverOutputs = try await serverTLS.processHandshakeData(clientHelloData!, at: .initial)

        // Get server messages
        var serverMessages: [(Data, EncryptionLevel)] = []
        for output in serverOutputs {
            if case .handshakeData(let data, let level) = output {
                serverMessages.append((data, level))
            }
        }

        // Client processes server messages
        for (data, level) in serverMessages {
            _ = try await clientTLS.processHandshakeData(data, at: level)
        }

        #expect(clientTLS.isHandshakeComplete)

        // Verify initial key phase
        #expect(clientTLS.keyPhase == 0)

        // Request key update
        let keyUpdateOutputs = try await clientTLS.requestKeyUpdate()
        #expect(!keyUpdateOutputs.isEmpty)

        // Verify key phase changed
        #expect(clientTLS.keyPhase == 1)

        // Verify we got new keys
        var gotNewKeys = false
        for output in keyUpdateOutputs {
            if case .keysAvailable(let info) = output {
                #expect(info.level == .application)
                gotNewKeys = true
            }
        }
        #expect(gotNewKeys, "Should get new application keys after key update")

        // Request another key update
        let keyUpdateOutputs2 = try await clientTLS.requestKeyUpdate()
        #expect(!keyUpdateOutputs2.isEmpty)

        // Verify key phase toggled back
        #expect(clientTLS.keyPhase == 0)
    }
}

// MARK: - TLS Handler Unit Tests

@Suite("TLS13Handler Direct Tests")
struct TLS13HandlerDirectTests {

    /// Shared server signing key for direct TLS tests
    private static let directTestSigningKey = SigningKey.generateP256()
    /// Mock certificate chain for direct TLS tests
    private static let directTestCertificateChain = [Data([0x30, 0x82, 0x01, 0x00])]

    @Test("Client and server complete handshake directly")
    func directHandshakeCompletion() async throws {
        // This test verifies the TLS layer directly without QUIC packet framing.
        // It tests the message flow: ClientHello -> ServerHello + EE + Finished -> client Finished

        // Create handlers with matching configs
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        clientConfig.expectedPeerPublicKey = Self.directTestSigningKey.publicKeyBytes
        let clientHandler = TLS13Handler(configuration: clientConfig)

        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = Self.directTestSigningKey
        serverConfig.certificateChain = Self.directTestCertificateChain
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)
        try serverHandler.setLocalTransportParameters(params)

        // Client starts handshake
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)

        // Verify client produced ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, let level) = output {
                #expect(level == .initial)
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil, "Should have ClientHello data")
        #expect(clientHandler.isClient == true)

        // Server starts
        _ = try await serverHandler.startHandshake(isClient: false)
        #expect(serverHandler.isClient == false)

        // Server processes ClientHello
        let serverOutputs = try await serverHandler.processHandshakeData(
            clientHelloData!,
            at: .initial
        )

        // Verify server outputs
        var serverMessages: [(Data, EncryptionLevel)] = []
        var gotHandshakeKeys = false
        var gotAppKeys = false

        for output in serverOutputs {
            switch output {
            case .handshakeData(let data, let level):
                serverMessages.append((data, level))
            case .keysAvailable(let info):
                if info.level == .handshake { gotHandshakeKeys = true }
                if info.level == .application { gotAppKeys = true }
            default:
                break
            }
        }

        #expect(gotHandshakeKeys, "Server should provide handshake keys")
        #expect(gotAppKeys, "Server should provide application keys")
        #expect(!serverMessages.isEmpty, "Server should send messages")

        // Client processes all server messages
        var clientGotAppKeys = false
        var clientComplete = false
        var clientFinishedData: Data?

        for (data, level) in serverMessages {
            let outputs = try await clientHandler.processHandshakeData(data, at: level)
            for output in outputs {
                switch output {
                case .keysAvailable(let info):
                    if info.level == .application { clientGotAppKeys = true }
                case .handshakeComplete:
                    clientComplete = true
                case .handshakeData(let data, _):
                    clientFinishedData = data
                default:
                    break
                }
            }
        }

        #expect(clientGotAppKeys, "Client should get application keys")
        #expect(clientComplete, "Client handshake should complete")
        #expect(clientHandler.isHandshakeComplete)

        // Server processes client Finished
        if let finData = clientFinishedData {
            let serverOutputs2 = try await serverHandler.processHandshakeData(finData, at: .handshake)
            var serverComplete = false
            for output in serverOutputs2 {
                if case .handshakeComplete = output { serverComplete = true }
            }
            #expect(serverComplete, "Server handshake should complete")
        }

        #expect(serverHandler.isHandshakeComplete)
    }

    @Test("TLS13Handler exports correct ALPN")
    func tlsHandlerExportsALPN() async throws {
        let config = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let handler = TLS13Handler(configuration: config)

        // Before handshake
        #expect(handler.negotiatedALPN == nil)

        // Start handshake
        _ = try await handler.startHandshake(isClient: true)

        // Still nil until server responds
        #expect(handler.negotiatedALPN == nil)
    }

    @Test("TLS13Handler isHandshakeComplete tracks state")
    func tlsHandlerTracksHandshakeState() async throws {
        let handler = TLS13Handler()

        #expect(handler.isHandshakeComplete == false)

        _ = try await handler.startHandshake(isClient: true)

        #expect(handler.isHandshakeComplete == false)
    }

    @Test("Transport parameters roundtrip")
    func transportParametersRoundtrip() async throws {
        let handler = TLS13Handler()

        let params = Data([0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00])
        try handler.setLocalTransportParameters(params)

        let retrieved = handler.getLocalTransportParameters()
        #expect(retrieved == params)
    }

    @Test("Server sends Certificate and CertificateVerify with signing key")
    func serverSendsCertificateAndCertificateVerify() async throws {
        // Create server with signing key and certificate chain
        let signingKey = SigningKey.generateP256()
        let certificateChain = [Data([0x30, 0x82, 0x01, 0x00])]  // Mock DER cert

        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = signingKey
        serverConfig.certificateChain = certificateChain
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Create client with expected peer public key for verification
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        clientConfig.expectedPeerPublicKey = signingKey.publicKeyBytes
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)
        try serverHandler.setLocalTransportParameters(params)

        // Client starts handshake
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)
        _ = try await serverHandler.startHandshake(isClient: false)

        // Get ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, _) = output {
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil)

        // Server processes ClientHello
        let serverOutputs = try await serverHandler.processHandshakeData(clientHelloData!, at: .initial)

        // Verify server outputs include Certificate and CertificateVerify
        var serverMessages: [(Data, EncryptionLevel)] = []
        for output in serverOutputs {
            if case .handshakeData(let data, let level) = output {
                serverMessages.append((data, level))
            }
        }

        // Server should send more messages (SH, EE, Cert, CertVerify, Finished)
        // At minimum: ServerHello + EncryptedExtensions + Certificate + CertificateVerify + Finished
        // But ServerHello is at .initial, others at .handshake
        #expect(serverMessages.count >= 2, "Server should send multiple message types")

        // Client processes all server messages (should verify signature)
        var clientComplete = false
        for (data, level) in serverMessages {
            let outputs = try await clientHandler.processHandshakeData(data, at: level)
            for output in outputs {
                if case .handshakeComplete = output {
                    clientComplete = true
                }
            }
        }

        #expect(clientComplete, "Client should complete handshake after verifying signature")
        #expect(clientHandler.isHandshakeComplete)
    }

    @Test("Rejects EncryptedExtensions at Initial level")
    func rejectsEEAtWrongLevel() async throws {
        // Create handlers
        let clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)

        // Client starts handshake
        _ = try await clientHandler.startHandshake(isClient: true)

        // Create a fake EncryptedExtensions message
        let fakeEE = Data([
            0x08,  // HandshakeType: encryptedExtensions
            0x00, 0x00, 0x02,  // length: 2
            0x00, 0x00  // empty extensions
        ])

        // Attempt to process at .initial level (should fail)
        do {
            _ = try await clientHandler.processHandshakeData(fakeEE, at: .initial)
            Issue.record("Expected error for EncryptedExtensions at initial level")
        } catch {
            // Expected: should reject EncryptedExtensions at initial level
            let errorDesc = String(describing: error)
            #expect(errorDesc.contains("encryptedExtensions") || errorDesc.contains("level"))
        }
    }

    @Test("Client rejects invalid signature")
    func clientRejectsInvalidSignature() async throws {
        // Create server with signing key and certificate chain
        let serverSigningKey = SigningKey.generateP256()
        let certificateChain = [Data([0x30, 0x82, 0x01, 0x00])]  // Mock DER cert

        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = serverSigningKey
        serverConfig.certificateChain = certificateChain
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Create client with a DIFFERENT expected public key (should fail verification)
        let differentKey = SigningKey.generateP256()
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        clientConfig.expectedPeerPublicKey = differentKey.publicKeyBytes
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)
        try serverHandler.setLocalTransportParameters(params)

        // Client starts handshake
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)
        _ = try await serverHandler.startHandshake(isClient: false)

        // Get ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, _) = output {
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil)

        // Server processes ClientHello
        let serverOutputs = try await serverHandler.processHandshakeData(clientHelloData!, at: .initial)

        // Get server messages
        var serverMessages: [(Data, EncryptionLevel)] = []
        for output in serverOutputs {
            if case .handshakeData(let data, let level) = output {
                serverMessages.append((data, level))
            }
        }

        // Client should fail when verifying the signature
        do {
            for (data, level) in serverMessages {
                _ = try await clientHandler.processHandshakeData(data, at: level)
            }
            // If we get here, the verification didn't fail - which is unexpected
            Issue.record("Expected signature verification to fail with mismatched key")
        } catch {
            // Expected: signature verification should fail
            #expect(String(describing: error).contains("signatureVerificationFailed") ||
                    String(describing: error).contains("verification"))
        }
    }

    @Test("Client handles HelloRetryRequest with different group")
    func clientHandlesHelloRetryRequest() async throws {
        // This test simulates a server sending HelloRetryRequest
        // asking the client to use a different key share group

        // Create client
        let clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)

        // Client starts handshake - sends ClientHello with X25519
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)

        // Extract ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, _) = output {
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil)

        // Decode ClientHello to get session ID
        var reader = TLSReader(data: clientHelloData!)
        // Skip handshake header (4 bytes)
        _ = try reader.readBytes(4)
        // Skip legacy_version (2 bytes)
        _ = try reader.readBytes(2)
        // Skip random (32 bytes)
        _ = try reader.readBytes(32)
        // Read legacy_session_id
        let sessionID = try reader.readVector8()

        // Create HelloRetryRequest asking for P-256 instead of X25519
        let hrrExtensions: [TLSExtension] = [
            .supportedVersionsServer(TLSConstants.version13),
            .keyShare(.helloRetryRequest(KeyShareHelloRetryRequest(selectedGroup: .secp256r1)))
        ]
        let hrr = ServerHello.helloRetryRequest(
            legacySessionIDEcho: sessionID,
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: hrrExtensions
        )
        let hrrData = hrr.encode()

        // Client processes HRR
        let hrrOutputs = try await clientHandler.processHandshakeData(
            HandshakeCodec.encode(type: .serverHello, content: hrrData),
            at: .initial
        )

        // Verify client sends ClientHello2 with P-256 key share
        var clientHello2Data: Data?
        for output in hrrOutputs {
            if case .handshakeData(let data, let level) = output {
                #expect(level == .initial, "ClientHello2 should be at initial level")
                clientHello2Data = data
            }
        }
        #expect(clientHello2Data != nil, "Client should send ClientHello2 after HRR")

        // Verify ClientHello2 contains P-256 key share
        // Parse the handshake message - skip the 4-byte header
        let ch2Content = clientHello2Data!.dropFirst(4)
        let clientHello2 = try ClientHello.decode(from: Data(ch2Content))

        // Find key_share extension
        var foundP256KeyShare = false
        for ext in clientHello2.extensions {
            if case .keyShare(let keyShareExt) = ext {
                if case .clientHello(let clientKeyShare) = keyShareExt {
                    for entry in clientKeyShare.clientShares {
                        if entry.group == NamedGroup.secp256r1 {
                            foundP256KeyShare = true
                            #expect(entry.keyExchange.count > 0, "P-256 key share should have data")
                        }
                    }
                }
            }
        }
        #expect(foundP256KeyShare, "ClientHello2 should contain P-256 key share")

        // Verify client is in correct state (waiting for ServerHello after HRR)
        #expect(!clientHandler.isHandshakeComplete, "Handshake should not be complete yet")
    }

    @Test("Server sends HelloRetryRequest when client offers unsupported group")
    func serverSendsHelloRetryRequest() async throws {
        // Create server that only supports X25519 (default)
        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.supportedGroups = [.x25519]  // Only X25519
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Create client that will send only P-256 in key_share
        // We'll manually construct a ClientHello with P-256 only
        let clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)
        try serverHandler.setLocalTransportParameters(params)

        // Generate a P-256 key pair for the client
        let p256KeyExchange = try KeyExchange.generate(for: .secp256r1)

        // Create a ClientHello with only P-256 key share
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sessionID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let extensions: [TLSExtension] = [
            .supportedVersionsClient([TLSConstants.version13]),
            .keyShare(.clientHello(KeyShareClientHello(clientShares: [
                p256KeyExchange.keyShareEntry()  // Only P-256, no X25519
            ]))),
            .supportedGroups(SupportedGroupsExtension(namedGroups: [.secp256r1, .x25519])),
            .signatureAlgorithms(SignatureAlgorithmsExtension.default),
            .alpn(ALPNExtension(protocols: ["h3"])),
            .quicTransportParameters(params)
        ]

        let clientHello = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: extensions
        )
        let clientHelloData = clientHello.encode()

        // Server starts
        _ = try await serverHandler.startHandshake(isClient: false)

        // Server processes ClientHello - should send HRR
        let serverOutputs = try await serverHandler.processHandshakeData(
            HandshakeCodec.encode(type: .clientHello, content: clientHelloData),
            at: .initial
        )

        // Verify server sends HelloRetryRequest
        var hrrData: Data?
        for output in serverOutputs {
            if case .handshakeData(let data, let level) = output {
                #expect(level == .initial, "HRR should be at initial level")
                hrrData = data
            }
        }
        #expect(hrrData != nil, "Server should send HelloRetryRequest")

        // Verify no keys are generated yet (HRR doesn't derive keys)
        var gotKeys = false
        for output in serverOutputs {
            if case .keysAvailable = output {
                gotKeys = true
            }
        }
        #expect(!gotKeys, "No keys should be derived after HRR")

        // Parse the HRR to verify it requests X25519
        // Skip handshake header (4 bytes)
        let hrrContent = Data(hrrData!.dropFirst(4))
        let serverHello = try ServerHello.decode(from: hrrContent)

        #expect(serverHello.isHelloRetryRequest, "Should be a HelloRetryRequest")
        #expect(serverHello.helloRetryRequestSelectedGroup == .x25519,
                "HRR should request X25519")

        // Now client would send ClientHello2 with X25519
        // For this test, we verify the server is in the correct state
        #expect(!serverHandler.isHandshakeComplete, "Handshake should not be complete yet")
    }

    @Test("Server completes handshake after HelloRetryRequest")
    func serverCompletesHandshakeAfterHRR() async throws {
        // Create server that only supports X25519
        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.supportedGroups = [.x25519]
        serverConfig.signingKey = Self.directTestSigningKey
        serverConfig.certificateChain = Self.directTestCertificateChain
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try serverHandler.setLocalTransportParameters(params)

        // Generate a P-256 key pair for the first ClientHello
        let p256KeyExchange = try KeyExchange.generate(for: .secp256r1)

        // Create first ClientHello with only P-256 key share
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sessionID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let extensions1: [TLSExtension] = [
            .supportedVersionsClient([TLSConstants.version13]),
            .keyShare(.clientHello(KeyShareClientHello(clientShares: [
                p256KeyExchange.keyShareEntry()  // Only P-256
            ]))),
            .supportedGroups(SupportedGroupsExtension(namedGroups: [.secp256r1, .x25519])),
            .signatureAlgorithms(SignatureAlgorithmsExtension.default),
            .alpn(ALPNExtension(protocols: ["h3"])),
            .quicTransportParameters(params)
        ]

        let clientHello1 = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: extensions1
        )
        let ch1Data = clientHello1.encode()

        // Server starts
        _ = try await serverHandler.startHandshake(isClient: false)

        // Server processes ClientHello1 - should send HRR
        let hrrOutputs = try await serverHandler.processHandshakeData(
            HandshakeCodec.encode(type: .clientHello, content: ch1Data),
            at: .initial
        )

        // Verify HRR was sent
        var hrrSent = false
        for output in hrrOutputs {
            if case .handshakeData(let data, _) = output {
                let content = Data(data.dropFirst(4))
                if let sh = try? ServerHello.decode(from: content), sh.isHelloRetryRequest {
                    hrrSent = true
                }
            }
        }
        #expect(hrrSent, "Server should send HRR")

        // Now create ClientHello2 with X25519 as requested
        let x25519KeyExchange = try KeyExchange.generate(for: .x25519)

        let extensions2: [TLSExtension] = [
            .supportedVersionsClient([TLSConstants.version13]),
            .keyShare(.clientHello(KeyShareClientHello(clientShares: [
                x25519KeyExchange.keyShareEntry()  // X25519 as requested
            ]))),
            .supportedGroups(SupportedGroupsExtension(namedGroups: [.secp256r1, .x25519])),
            .signatureAlgorithms(SignatureAlgorithmsExtension.default),
            .alpn(ALPNExtension(protocols: ["h3"])),
            .quicTransportParameters(params)
        ]

        let clientHello2 = ClientHello(
            random: random,  // Same random per RFC 8446
            legacySessionID: sessionID,  // Same session ID
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: extensions2
        )
        let ch2Data = clientHello2.encode()

        // Server processes ClientHello2 - should complete with ServerHello
        let serverOutputs = try await serverHandler.processHandshakeData(
            HandshakeCodec.encode(type: .clientHello, content: ch2Data),
            at: .initial
        )

        // Verify server sends proper response (ServerHello + EE + Finished)
        var gotHandshakeKeys = false
        var gotAppKeys = false
        var messageCount = 0

        for output in serverOutputs {
            switch output {
            case .handshakeData:
                messageCount += 1
            case .keysAvailable(let info):
                if info.level == .handshake { gotHandshakeKeys = true }
                if info.level == .application { gotAppKeys = true }
            default:
                break
            }
        }

        #expect(gotHandshakeKeys, "Server should derive handshake keys after ClientHello2")
        #expect(gotAppKeys, "Server should derive application keys after ClientHello2")
        #expect(messageCount >= 2, "Server should send multiple messages")
    }

    @Test("Server rejects second HelloRetryRequest attempt")
    func serverRejectsMultipleHRR() async throws {
        // Create server that only supports X25519
        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.supportedGroups = [.x25519]
        let serverHandler = TLS13Handler(configuration: serverConfig)

        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try serverHandler.setLocalTransportParameters(params)

        let p256KeyExchange = try KeyExchange.generate(for: .secp256r1)

        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sessionID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let extensions: [TLSExtension] = [
            .supportedVersionsClient([TLSConstants.version13]),
            .keyShare(.clientHello(KeyShareClientHello(clientShares: [
                p256KeyExchange.keyShareEntry()
            ]))),
            .supportedGroups(SupportedGroupsExtension(namedGroups: [.secp256r1, .x25519])),
            .signatureAlgorithms(SignatureAlgorithmsExtension.default),
            .alpn(ALPNExtension(protocols: ["h3"])),
            .quicTransportParameters(params)
        ]

        let clientHello = ClientHello(
            random: random,
            legacySessionID: sessionID,
            cipherSuites: [.tls_aes_128_gcm_sha256],
            extensions: extensions
        )
        let chData = clientHello.encode()

        _ = try await serverHandler.startHandshake(isClient: false)

        // First ClientHello - server sends HRR
        _ = try await serverHandler.processHandshakeData(
            HandshakeCodec.encode(type: .clientHello, content: chData),
            at: .initial
        )

        // Second ClientHello that still only has P-256 (client didn't follow HRR)
        // This should fail because server already sent HRR and client didn't provide X25519
        do {
            _ = try await serverHandler.processHandshakeData(
                HandshakeCodec.encode(type: .clientHello, content: chData),
                at: .initial
            )
            Issue.record("Expected error for invalid ClientHello2")
        } catch {
            // Expected: should fail because ClientHello2 doesn't have the requested group
            let errorDesc = String(describing: error)
            #expect(errorDesc.contains("noKeyShareMatch") || errorDesc.contains("key"))
        }
    }

    @Test("Client rejects second HelloRetryRequest")
    func clientRejectsSecondHRR() async throws {
        // Create client
        let clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let clientHandler = TLS13Handler(configuration: clientConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)

        // Client starts handshake
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)

        // Extract session ID from ClientHello
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, _) = output {
                clientHelloData = data
                break
            }
        }

        var reader = TLSReader(data: clientHelloData!)
        _ = try reader.readBytes(4)  // Skip handshake header
        _ = try reader.readBytes(2)  // Skip legacy_version
        _ = try reader.readBytes(32) // Skip random
        let sessionID = try reader.readVector8()

        // Create first HRR
        let hrr = ServerHello.helloRetryRequest(
            legacySessionIDEcho: sessionID,
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: [
                .supportedVersionsServer(TLSConstants.version13),
                .keyShare(.helloRetryRequest(KeyShareHelloRetryRequest(selectedGroup: .secp256r1)))
            ]
        )
        let hrrData = hrr.encode()

        // Client processes first HRR (should succeed)
        _ = try await clientHandler.processHandshakeData(
            HandshakeCodec.encode(type: .serverHello, content: hrrData),
            at: .initial
        )

        // Create second HRR (should fail)
        let hrr2 = ServerHello.helloRetryRequest(
            legacySessionIDEcho: sessionID,
            cipherSuite: .tls_aes_128_gcm_sha256,
            extensions: [
                .supportedVersionsServer(TLSConstants.version13),
                .keyShare(.helloRetryRequest(KeyShareHelloRetryRequest(selectedGroup: .x25519)))
            ]
        )
        let hrr2Data = hrr2.encode()

        // Client should reject second HRR
        do {
            _ = try await clientHandler.processHandshakeData(
                HandshakeCodec.encode(type: .serverHello, content: hrr2Data),
                at: .initial
            )
            Issue.record("Expected error for second HelloRetryRequest")
        } catch {
            // Expected: should reject second HRR
            let errorDesc = String(describing: error)
            #expect(errorDesc.contains("second") || errorDesc.contains("HelloRetryRequest"))
        }
    }
}
