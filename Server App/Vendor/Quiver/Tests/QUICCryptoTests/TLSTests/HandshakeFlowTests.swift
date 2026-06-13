/// TLS 1.3 Handshake Flow Tests
///
/// Tests the complete TLS 1.3 handshake between client and server.

import Testing
import Foundation
@testable import QUICCore
@testable import QUICCrypto

@Suite("Handshake Flow Tests")
struct HandshakeFlowTests {

    // Shared test keys for server certificate
    private static let testSigningKey = SigningKey.generateP256()
    private static let testCertificateChain = [Data([0x30, 0x82, 0x01, 0x00])]

    // MARK: - TLS13Handler Tests

    @Test("TLS13Handler initializes in client mode")
    func clientModeInitialization() async throws {
        let handler = TLS13Handler()

        #expect(handler.isHandshakeComplete == false)
    }

    @Test("Client starts handshake")
    func clientStartHandshake() async throws {
        let handler = TLS13Handler()

        // Set transport parameters
        try handler.setLocalTransportParameters(Data([0x00, 0x04, 0x01, 0x02, 0x03, 0x04]))

        let outputs = try await handler.startHandshake(isClient: true)

        #expect(handler.isClient == true)
        #expect(handler.isHandshakeComplete == false)

        // Should have at least one output (ClientHello data)
        #expect(outputs.isEmpty == false)

        // First output should be handshake data at initial level
        if case .handshakeData(let data, let level) = outputs[0] {
            #expect(level == .initial)
            #expect(data.count > 0)
            // First byte should be ClientHello type (1)
            #expect(data[0] == 0x01)
        } else {
            Issue.record("Expected handshakeData output")
        }
    }

    @Test("Server starts handshake")
    func serverStartHandshake() async throws {
        let handler = TLS13Handler()

        let outputs = try await handler.startHandshake(isClient: false)

        #expect(handler.isClient == false)
        #expect(handler.isHandshakeComplete == false)
        // Server waits for ClientHello, so no initial outputs
        #expect(outputs.isEmpty == true)
    }

    // MARK: - Client State Machine Tests

    @Test("ClientStateMachine generates ClientHello")
    func clientStateMachineClientHello() throws {
        let config = TLSConfiguration.client(
            serverName: "example.com",
            alpnProtocols: ["h3"]
        )
        let transportParams = Data([0x00, 0x04, 0x01, 0x02, 0x03, 0x04])

        let clientMachine = ClientStateMachine()
        let (clientHelloData, _) = try clientMachine.startHandshake(
            configuration: config,
            transportParameters: transportParams
        )

        // Verify state transition
        #expect(clientMachine.handshakeState == .waitServerHello)

        // Verify ClientHello message format
        #expect(clientHelloData[0] == 0x01) // ClientHello type

        // Decode the ClientHello
        var reader = TLSReader(data: clientHelloData)
        _ = try reader.readUInt8()  // type
        let length = try reader.readUInt24()
        #expect(length > 0)
    }

    @Test("ClientStateMachine rejects double start")
    func clientStateMachineRejectsDoubleStart() throws {
        let clientMachine = ClientStateMachine()

        _ = try clientMachine.startHandshake(
            configuration: TLSConfiguration(),
            transportParameters: Data()
        )

        #expect(throws: TLSHandshakeError.self) {
            _ = try clientMachine.startHandshake(
                configuration: TLSConfiguration(),
                transportParameters: Data()
            )
        }
    }

    // MARK: - Full Handshake Tests

    // Note: Full client-server handshake test requires proper ClientHello parsing.
    // This is a placeholder for future integration test.
    @Test("Client generates valid ClientHello with extensions")
    func clientGeneratesValidClientHello() async throws {
        let config = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let client = TLS13Handler(configuration: config)
        try client.setLocalTransportParameters(Data([0x00, 0x01]))

        let outputs = try await client.startHandshake(isClient: true)
        #expect(outputs.count >= 1)

        guard case .handshakeData(let data, let level) = outputs[0] else {
            Issue.record("Expected ClientHello data")
            return
        }

        #expect(level == .initial)
        #expect(data.count > 100) // ClientHello should be substantial

        // Verify it's a valid handshake message
        let (type, length) = try HandshakeCodec.decodeHeader(from: data)
        #expect(type == .clientHello)
        #expect(length > 0)
        #expect(Int(length) == data.count - 4)
    }

    @Test("ClientStateMachine generates ClientHello with supportedVersions")
    func clientStateMachineGeneratesValidExtensions() throws {
        let config = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        let clientMachine = ClientStateMachine()

        let (clientHelloMessage, _) = try clientMachine.startHandshake(
            configuration: config,
            transportParameters: Data([0x00, 0x01])
        )

        // Parse the handshake message
        let (type, length) = try HandshakeCodec.decodeHeader(from: clientHelloMessage)
        #expect(type == .clientHello)

        // Extract content
        let content = clientHelloMessage.subdata(in: 4..<(4 + length))

        // Decode ClientHello
        let clientHello = try ClientHello.decode(from: content)

        // Check that extensions were properly encoded/decoded
        #expect(clientHello.extensions.count > 0, "Should have extensions")

        // Check supported_versions extension
        let supportedVersions = clientHello.supportedVersions
        #expect(supportedVersions != nil, "Should have supportedVersions extension")
        #expect(supportedVersions?.supportsTLS13 == true, "Should support TLS 1.3")

        // Check key_share extension
        let keyShare = clientHello.keyShare
        #expect(keyShare != nil, "Should have keyShare extension")
    }

    @Test("TLS13Handler client-to-server data flow")
    func tls13HandlerDataFlow() async throws {
        var clientConfig = TLSConfiguration.client(
            serverName: "localhost",
            alpnProtocols: ["h3"]
        )
        clientConfig.expectedPeerPublicKey = Self.testSigningKey.publicKeyBytes
        let clientHandler = TLS13Handler(configuration: clientConfig)

        var serverConfig = TLSConfiguration()
        serverConfig.alpnProtocols = ["h3"]
        serverConfig.signingKey = Self.testSigningKey
        serverConfig.certificateChain = Self.testCertificateChain
        let serverHandler = TLS13Handler(configuration: serverConfig)

        // Set transport parameters
        let params = Data([0x04, 0x04, 0x00, 0x01, 0x00, 0x00])
        try clientHandler.setLocalTransportParameters(params)
        try serverHandler.setLocalTransportParameters(params)

        // Client starts handshake
        let clientOutputs = try await clientHandler.startHandshake(isClient: true)

        // Get ClientHello data
        var clientHelloData: Data?
        for output in clientOutputs {
            if case .handshakeData(let data, let level) = output {
                #expect(level == .initial)
                clientHelloData = data
                break
            }
        }
        #expect(clientHelloData != nil, "Should have ClientHello data")

        // Server starts (must be done before processing)
        _ = try await serverHandler.startHandshake(isClient: false)

        // Verify the ClientHello message is valid before sending to server
        let (type, length) = try HandshakeCodec.decodeHeader(from: clientHelloData!)
        #expect(type == .clientHello)

        let content = clientHelloData!.subdata(in: 4..<(4 + length))
        let clientHello = try ClientHello.decode(from: content)
        #expect(clientHello.supportedVersions != nil, "ClientHello should have supportedVersions")
        #expect(clientHello.supportedVersions?.supportsTLS13 == true, "Should support TLS 1.3")

        // Server processes ClientHello
        let serverOutputs = try await serverHandler.processHandshakeData(
            clientHelloData!,
            at: .initial
        )

        // Should have outputs
        #expect(!serverOutputs.isEmpty, "Server should produce outputs")
    }

    // MARK: - Error Cases

    @Test("Unexpected message type throws error")
    func unexpectedMessageType() async throws {
        let client = TLS13Handler()
        _ = try await client.startHandshake(isClient: true)

        // Try to process a Finished message when expecting ServerHello
        let finishedMessage = HandshakeCodec.encode(
            type: .finished,
            content: Data(repeating: 0xAA, count: 32)
        )

        do {
            _ = try await client.processHandshakeData(finishedMessage, at: .initial)
            Issue.record("Expected error for unexpected message type")
        } catch {
            // Expected
        }
    }
}

// MARK: - TLSConfiguration Tests

@Suite("TLS Configuration Tests")
struct TLSConfigurationTests {

    @Test("Default configuration")
    func defaultConfiguration() throws {
        let config = TLSConfiguration()

        #expect(config.serverName == nil)
        #expect(config.alpnProtocols == ["h3"]) // Default is h3 for QUIC
    }

    @Test("Configuration with server name")
    func configurationWithServerName() throws {
        let config = TLSConfiguration.client(serverName: "example.com")

        #expect(config.serverName == "example.com")
    }

    @Test("Configuration with ALPN")
    func configurationWithALPN() throws {
        let config = TLSConfiguration.client(alpnProtocols: ["h3", "h3-29"])

        #expect(config.alpnProtocols == ["h3", "h3-29"])
    }
}
