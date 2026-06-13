import Foundation
import HTTP3
import PummelchenCore
import QUIC
import QUICCrypto

public struct ClientWebTransportControlChannel: Sendable {
    private static let maxControlPayloadBytes = 16 * 1024

    public let preflight: WebTransportPreflightPayload
    public let clientID: String
    public let clientAPIToken: String

    public init(preflight: WebTransportPreflightPayload, clientID: String, clientAPIToken: String) {
        self.preflight = preflight
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
    }

    public func fetchEvents(afterEventID: String? = nil, limit: Int = 50) async throws -> ControlEventBatch {
        let response = try await send(WebTransportControlRequest(
            action: "fetch_events",
            clientID: clientID,
            clientAPIToken: clientAPIToken,
            afterEventID: afterEventID,
            limit: limit
        ))
        if let batch = response.batch {
            return batch
        }
        throw ContractValidationError.invalid(response.error ?? "WebTransport fetch_events returned no batch")
    }

    public func acknowledge(_ event: ControlEvent) async throws {
        let response = try await send(WebTransportControlRequest(
            action: "ack_event",
            clientID: clientID,
            clientAPIToken: clientAPIToken,
            eventID: event.eventID,
            receivedAt: Self.isoNow()
        ))
        if !response.ok {
            throw ContractValidationError.invalid(response.error ?? "WebTransport ack_event failed")
        }
    }

    public func register(_ payload: ClientRegistrationRequest) async throws -> ClientWriteAck {
        try await write(
            action: "register_client",
            request: WebTransportControlRequest(
                action: "register_client",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                registration: payload
            )
        )
    }

    public func reportStatus(_ payload: ClientStatusReport, action: String = "status_report") async throws -> ClientWriteAck {
        try await write(
            action: action,
            request: WebTransportControlRequest(
                action: action,
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                statusReport: payload
            )
        )
    }

    public func uploadInventory(_ payload: ClientInventoryUpload) async throws -> ClientWriteAck {
        try await write(
            action: "inventory_upload",
            request: WebTransportControlRequest(
                action: "inventory_upload",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                inventory: payload
            )
        )
    }

    public func uploadDiagnostics(_ payload: ClientDiagnosticsUpload) async throws -> ClientWriteAck {
        try await write(
            action: "diagnostics_upload",
            request: WebTransportControlRequest(
                action: "diagnostics_upload",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                diagnostics: payload
            )
        )
    }

    public func uploadDefaultsEvents(_ payload: ClientDefaultsEventUpload) async throws -> ClientWriteAck {
        try await write(
            action: "defaults_events_upload",
            request: WebTransportControlRequest(
                action: "defaults_events_upload",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                defaultsEvents: payload
            )
        )
    }

    private func write(action: String, request: WebTransportControlRequest) async throws -> ClientWriteAck {
        let response = try await send(request)
        if let ack = response.ack {
            return ack
        }
        throw ContractValidationError.invalid(response.error ?? "WebTransport \(action) returned no acknowledgement")
    }

    private func send(_ request: WebTransportControlRequest) async throws -> WebTransportControlResponse {
        guard let url = URL(string: preflight.sessionURL),
              let host = url.host(),
              let port = url.port else {
            throw ContractValidationError.invalid("invalid WebTransport session URL: \(preflight.sessionURL)")
        }
        let path = url.path().isEmpty ? "/" : url.path()
        let authority = "\(host):\(port)"

        var tls = TLSConfiguration.client(serverName: host, alpnProtocols: ["h3"])
        do {
            try tls.useSystemTrustStore()
            tls.verifyPeer = true
            tls.allowSelfSigned = false
        } catch {
            tls.verifyPeer = true
            tls.allowSelfSigned = false
        }
        let tlsConfiguration = tls

        var quic = QUICConfiguration.production {
            TLS13Handler(configuration: tlsConfiguration)
        }
        quic.alpn = ["h3"]
        quic.maxIdleTimeout = .seconds(45)
        quic.initialMaxStreamsBidi = 64
        quic.initialMaxStreamsUni = 64
        quic.initialMaxData = 8_000_000
        quic.initialMaxStreamDataBidiLocal = 1_000_000
        quic.initialMaxStreamDataBidiRemote = 1_000_000
        quic.initialMaxStreamDataUni = 1_000_000
        quic.enableDatagrams = true
        quic.maxDatagramFrameSize = 65_535

        let endpoint = QUICEndpoint(configuration: quic)
        let connection = try await endpoint.dial(
            address: QUIC.SocketAddress(ipAddress: host, port: UInt16(port)),
            timeout: .seconds(10)
        )
        defer {
            Task {
                await connection.close(error: nil)
                await endpoint.stop()
            }
        }

        let session = try await WebTransportClient.connect(
            authority: authority,
            path: path,
            over: connection,
            configuration: WebTransportConfiguration(
                quic: quic,
                maxSessions: 1,
                headers: [
                    ("authorization", "Bearer \(clientAPIToken)"),
                    ("x-pummelchen-client-id", clientID)
                ],
                connectionReadyTimeout: .seconds(10),
                connectTimeout: .seconds(10)
            )
        )
        defer {
            Task {
                try? await session.close()
            }
        }

        let stream = try await session.openBidirectionalStream()
        try await stream.write(JSONEncoder().encode(request))
        try await stream.closeWrite()
        let responseData = try await readAll(from: stream)
        let response = try JSONDecoder().decode(WebTransportControlResponse.self, from: responseData)
        if !response.ok {
            throw ContractValidationError.invalid(response.error ?? "WebTransport control request failed")
        }
        return response
    }

    private func readAll(from stream: WebTransportStream) async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await stream.read(maxBytes: 64 * 1024)
            if chunk.isEmpty {
                return data
            }
            data.append(chunk)
            if data.count > Self.maxControlPayloadBytes {
                throw ContractValidationError.invalid("WebTransport control response exceeded maximum size")
            }
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
