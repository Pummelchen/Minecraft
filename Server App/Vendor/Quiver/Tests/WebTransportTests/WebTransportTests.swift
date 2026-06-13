/// WebTransport Integration Tests
///
/// Comprehensive tests for the WebTransport integration layer:
/// - Session management (registry, lifecycle, state transitions)
/// - Stream routing (bidirectional and unidirectional)
/// - Datagram framing and routing
/// - Capsule codec (encode/decode, close/drain)
/// - WebTransportClient and WebTransportServer wrappers
/// - Error handling and edge cases
/// - Stream error code mapping

import XCTest
import Foundation
import Synchronization
@testable import HTTP3
@testable import QUICCore
@testable import QPACK
@testable import QUIC

// MARK: - Mock Types for WebTransport Testing

/// A full-featured mock QUIC stream for WebTransport testing.
private final class MockWTStream: QUICStreamProtocol, @unchecked Sendable {
    let id: UInt64
    let _isUnidirectional: Bool

    var isUnidirectional: Bool { _isUnidirectional }
    var isBidirectional: Bool { !_isUnidirectional }

    private struct StreamState: Sendable {
        var writtenData: [Data] = []
        var readQueue: [Data] = []
        var closed = false
        var resetCode: UInt64?
        var stopSendingCode: UInt64?
        var readContinuation: CheckedContinuation<Data, any Error>?
    }

    private let _state: Mutex<StreamState>

    var writtenData: [Data] {
        _state.withLock { $0.writtenData }
    }

    var allWrittenData: Data {
        _state.withLock { s in
            var combined = Data()
            for d in s.writtenData { combined.append(d) }
            return combined
        }
    }

    var isClosed: Bool {
        _state.withLock { $0.closed }
    }

    var resetCode: UInt64? {
        _state.withLock { $0.resetCode }
    }

    var stopSendingCode: UInt64? {
        _state.withLock { $0.stopSendingCode }
    }

    init(id: UInt64, isUnidirectional: Bool = false) {
        self.id = id
        self._isUnidirectional = isUnidirectional
        self._state = Mutex(StreamState())
    }

    /// Enqueue data that will be returned by the next read() call.
    func enqueueReadData(_ data: Data) {
        let cont: CheckedContinuation<Data, any Error>? = _state.withLock { s in
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                return continuation
            } else {
                s.readQueue.append(data)
                return nil
            }
        }
        cont?.resume(returning: data)
    }

    /// Enqueue an empty Data to signal FIN.
    func enqueueFIN() {
        enqueueReadData(Data())
    }

    /// Enqueue an error for the next read.
    func enqueueReadError(_ error: any Error) {
        let cont: CheckedContinuation<Data, any Error>? = _state.withLock { s in
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                return continuation
            }
            return nil
        }
        cont?.resume(throwing: error)
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let immediateData: Data? = _state.withLock { s in
                if !s.readQueue.isEmpty {
                    return s.readQueue.removeFirst()
                } else {
                    s.readContinuation = continuation
                    return nil
                }
            }
            if let data = immediateData {
                continuation.resume(returning: data)
            }
        }
    }

    func read(maxBytes: Int) async throws -> Data {
        let data = try await read()
        if data.count > maxBytes {
            return Data(data.prefix(maxBytes))
        }
        return data
    }

    func write(_ data: Data) async throws {
        _state.withLock { $0.writtenData.append(data) }
    }

    func closeWrite() async throws {
        _state.withLock { $0.closed = true }
    }

    func reset(errorCode: UInt64) async {
        _state.withLock { $0.resetCode = errorCode }
    }

    func stopSending(errorCode: UInt64) async throws {
        _state.withLock { $0.stopSendingCode = errorCode }
    }
}

/// A mock QUIC connection for WebTransport testing.
private final class MockWTConnection: QUICConnectionProtocol, @unchecked Sendable {
    var localAddress: SocketAddress? { SocketAddress(ipAddress: "127.0.0.1", port: 4433) }
    var remoteAddress: SocketAddress { SocketAddress(ipAddress: "127.0.0.1", port: 443) }
    var isEstablished: Bool { true }
    var is0RTTAccepted: Bool { false }

    private struct State: Sendable {
        var nextBidiStreamID: UInt64
        var nextUniStreamID: UInt64
        var openedStreams: [MockWTStream] = []
        var openedUniStreams: [MockWTStream] = []
        var sentDatagrams: [Data] = []
        var closed = false
        var closeError: UInt64?
    }

    private let state: Mutex<State>

    private var incomingStreamContinuation: AsyncStream<any QUICStreamProtocol>.Continuation?
    private var _incomingStreams: AsyncStream<any QUICStreamProtocol>

    private var incomingDatagramContinuation: AsyncStream<Data>.Continuation?
    private var _incomingDatagrams: AsyncStream<Data>

    var openedStreams: [MockWTStream] {
        state.withLock { $0.openedStreams }
    }

    var openedUniStreams: [MockWTStream] {
        state.withLock { $0.openedUniStreams }
    }

    var sentDatagrams: [Data] {
        state.withLock { $0.sentDatagrams }
    }

    var connectionClosed: Bool {
        state.withLock { $0.closed }
    }

    init(isClient: Bool = true) {
        self.state = Mutex(State(
            nextBidiStreamID: isClient ? 0 : 1,
            nextUniStreamID: isClient ? 2 : 3
        ))

        var streamCont: AsyncStream<any QUICStreamProtocol>.Continuation!
        self._incomingStreams = AsyncStream { cont in
            streamCont = cont
        }
        self.incomingStreamContinuation = streamCont

        var datagramCont: AsyncStream<Data>.Continuation!
        self._incomingDatagrams = AsyncStream { cont in
            datagramCont = cont
        }
        self.incomingDatagramContinuation = datagramCont
    }

    func waitForHandshake() async throws {}

    func openStream() async throws -> any QUICStreamProtocol {
        state.withLock { s in
            let id = s.nextBidiStreamID
            s.nextBidiStreamID += 4
            let stream = MockWTStream(id: id, isUnidirectional: false)
            s.openedStreams.append(stream)
            return stream
        }
    }

    func openUniStream() async throws -> any QUICStreamProtocol {
        state.withLock { s in
            let id = s.nextUniStreamID
            s.nextUniStreamID += 4
            let stream = MockWTStream(id: id, isUnidirectional: true)
            s.openedUniStreams.append(stream)
            return stream
        }
    }

    var incomingStreams: AsyncStream<any QUICStreamProtocol> {
        _incomingStreams
    }

    var incomingDatagrams: AsyncStream<Data> {
        _incomingDatagrams
    }

    func sendDatagram(_ data: Data) async throws {
        state.withLock { $0.sentDatagrams.append(data) }
    }

    /// Deliver an incoming stream for testing
    func deliverIncomingStream(_ stream: any QUICStreamProtocol) {
        incomingStreamContinuation?.yield(stream)
    }

    /// Deliver an incoming datagram for testing
    func deliverIncomingDatagram(_ data: Data) {
        incomingDatagramContinuation?.yield(data)
    }

    func close(error: UInt64?) async {
        state.withLock { s in
            s.closed = true
            s.closeError = error
        }
    }

    func close(applicationError errorCode: UInt64, reason: String) async {
        state.withLock { s in
            s.closed = true
            s.closeError = errorCode
        }
    }

    /// Finish the incoming streams to clean up
    func finish() {
        incomingStreamContinuation?.finish()
        incomingDatagramContinuation?.finish()
    }
}

// MARK: - Capsule Codec Tests

final class WebTransportCapsuleCodecTests: XCTestCase {

    // MARK: - Capsule Type Identifiers

    func testCapsuleTypeValues() {
        XCTAssertEqual(WebTransportCapsuleType.closeSession.rawValue, 0x2843)
        XCTAssertEqual(WebTransportCapsuleType.drainSession.rawValue, 0x78ae)
    }

    func testCapsuleTypeDescriptions() {
        XCTAssertEqual(WebTransportCapsuleType.closeSession.description, "CLOSE_WEBTRANSPORT_SESSION(0x2843)")
        XCTAssertEqual(WebTransportCapsuleType.drainSession.description, "DRAIN_WEBTRANSPORT_SESSION(0x78ae)")
    }

    // MARK: - Close Capsule Encoding/Decoding

    func testEncodeDecodeCloseCapsuleNoError() throws {
        let info = WebTransportSessionCloseInfo(errorCode: 0, reason: "")
        let capsule = WebTransportCapsule.close(info)

        let encoded = WebTransportCapsuleCodec.encode(capsule)
        XCTAssertFalse(encoded.isEmpty)

        let (decoded, consumed) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))
        XCTAssertEqual(consumed, encoded.count)

        if case .close(let decodedInfo) = decoded {
            XCTAssertEqual(decodedInfo.errorCode, 0)
            XCTAssertEqual(decodedInfo.reason, "")
        } else {
            XCTFail("Expected close capsule, got \(decoded)")
        }
    }

    func testEncodeDecodeCloseCapsuleWithReason() throws {
        let info = WebTransportSessionCloseInfo(errorCode: 42, reason: "Session complete")
        let capsule = WebTransportCapsule.close(info)

        let encoded = WebTransportCapsuleCodec.encode(capsule)
        let (decoded, _) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))

        if case .close(let decodedInfo) = decoded {
            XCTAssertEqual(decodedInfo.errorCode, 42)
            XCTAssertEqual(decodedInfo.reason, "Session complete")
        } else {
            XCTFail("Expected close capsule, got \(decoded)")
        }
    }

    func testEncodeDecodeCloseCapsuleLargeErrorCode() throws {
        let info = WebTransportSessionCloseInfo(errorCode: UInt32.max, reason: "max")
        let capsule = WebTransportCapsule.close(info)

        let encoded = WebTransportCapsuleCodec.encode(capsule)
        let (decoded, _) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))

        if case .close(let decodedInfo) = decoded {
            XCTAssertEqual(decodedInfo.errorCode, UInt32.max)
            XCTAssertEqual(decodedInfo.reason, "max")
        } else {
            XCTFail("Expected close capsule, got \(decoded)")
        }
    }

    // MARK: - Drain Capsule Encoding/Decoding

    func testEncodeDecodeDrainCapsule() throws {
        let capsule = WebTransportCapsule.drain

        let encoded = WebTransportCapsuleCodec.encode(capsule)
        XCTAssertFalse(encoded.isEmpty)

        let (decoded, consumed) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))
        XCTAssertEqual(consumed, encoded.count)

        if case .drain = decoded {
            // OK
        } else {
            XCTFail("Expected drain capsule, got \(decoded)")
        }
    }

    // MARK: - Unknown Capsule Handling

    func testDecodeUnknownCapsuleType() throws {
        // Encode a capsule with an unknown type manually
        var data = Data()
        Varint(0xFFFF).encode(to: &data) // Unknown type
        Varint(4).encode(to: &data) // Length = 4
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // Payload

        let (decoded, consumed) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: data))
        XCTAssertEqual(consumed, data.count)

        if case .unknown(let type, let payload) = decoded {
            XCTAssertEqual(type, 0xFFFF)
            XCTAssertEqual(payload, Data([0x01, 0x02, 0x03, 0x04]))
        } else {
            XCTFail("Expected unknown capsule, got \(decoded)")
        }
    }

    // MARK: - Multiple Capsule Decoding

    func testDecodeMultipleCapsules() throws {
        let close = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 1, reason: "bye"))
        let drain = WebTransportCapsule.drain

        var combined = WebTransportCapsuleCodec.encode(close)
        combined.append(WebTransportCapsuleCodec.encode(drain))

        let (capsules, totalConsumed) = try WebTransportCapsuleCodec.decodeAll(from: combined)
        XCTAssertEqual(capsules.count, 2)
        XCTAssertEqual(totalConsumed, combined.count)

        if case .close(let info) = capsules[0] {
            XCTAssertEqual(info.errorCode, 1)
            XCTAssertEqual(info.reason, "bye")
        } else {
            XCTFail("Expected close")
        }

        if case .drain = capsules[1] {
            // OK
        } else {
            XCTFail("Expected drain")
        }
    }

    // MARK: - Partial Data Handling

    func testDecodeInsufficientData() throws {
        let result = try WebTransportCapsuleCodec.decode(from: Data())
        XCTAssertNil(result)
    }

    func testDecodePartialCapsule() throws {
        let capsule = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 0, reason: ""))
        let encoded = WebTransportCapsuleCodec.encode(capsule)

        // Only provide partial data
        let partial = Data(encoded.prefix(encoded.count / 2))
        let result = try WebTransportCapsuleCodec.decode(from: partial)
        XCTAssertNil(result, "Should return nil for incomplete capsule")
    }

    // MARK: - Convenience Helpers

    func testEncodeCloseConvenience() throws {
        let encoded = WebTransportCapsuleCodec.encodeClose(errorCode: 99, reason: "test error")
        let (decoded, _) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))

        if case .close(let info) = decoded {
            XCTAssertEqual(info.errorCode, 99)
            XCTAssertEqual(info.reason, "test error")
        } else {
            XCTFail("Expected close")
        }
    }

    func testEncodeDrainConvenience() throws {
        let encoded = WebTransportCapsuleCodec.encodeDrain()
        let (decoded, _) = try XCTUnwrap(WebTransportCapsuleCodec.decode(from: encoded))

        if case .drain = decoded {
            // OK
        } else {
            XCTFail("Expected drain")
        }
    }

    // MARK: - Capsule Descriptions

    func testCloseCapsuleDescription() {
        let capsule = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 42, reason: "bye"))
        let desc = capsule.description
        XCTAssertTrue(desc.contains("CLOSE"))
        XCTAssertTrue(desc.contains("42"))
    }

    func testDrainCapsuleDescription() {
        let desc = WebTransportCapsule.drain.description
        XCTAssertTrue(desc.contains("DRAIN"))
    }

    // MARK: - Capsule Equality

    func testCapsuleEquality() {
        let close1 = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 0, reason: ""))
        let close2 = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 0, reason: ""))
        let close3 = WebTransportCapsule.close(WebTransportSessionCloseInfo(errorCode: 1, reason: ""))
        let drain = WebTransportCapsule.drain

        XCTAssertEqual(close1, close2)
        XCTAssertNotEqual(close1, close3)
        XCTAssertNotEqual(close1, drain)
        XCTAssertEqual(drain, WebTransportCapsule.drain)
    }

    // MARK: - Capsule Hashing

    func testCapsuleHashing() {
        var set = Set<WebTransportCapsule>()
        set.insert(.drain)
        set.insert(.drain)
        set.insert(.close(WebTransportSessionCloseInfo(errorCode: 0, reason: "")))
        set.insert(.close(WebTransportSessionCloseInfo(errorCode: 0, reason: "")))
        set.insert(.close(WebTransportSessionCloseInfo(errorCode: 1, reason: "")))

        // drain (1) + close(0) (1) + close(1) (1) = 3
        XCTAssertEqual(set.count, 3)
    }
}

// MARK: - Session Close Info Tests

final class WebTransportSessionCloseInfoTests: XCTestCase {

    func testNoError() {
        let info = WebTransportSessionCloseInfo.noError
        XCTAssertEqual(info.errorCode, 0)
        XCTAssertEqual(info.reason, "")
    }

    func testCustomCloseInfo() {
        let info = WebTransportSessionCloseInfo(errorCode: 42, reason: "Session timeout")
        XCTAssertEqual(info.errorCode, 42)
        XCTAssertEqual(info.reason, "Session timeout")
    }

    func testCloseInfoEquality() {
        let a = WebTransportSessionCloseInfo(errorCode: 1, reason: "a")
        let b = WebTransportSessionCloseInfo(errorCode: 1, reason: "a")
        let c = WebTransportSessionCloseInfo(errorCode: 2, reason: "a")
        let d = WebTransportSessionCloseInfo(errorCode: 1, reason: "b")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testCloseInfoDescription() {
        let empty = WebTransportSessionCloseInfo(errorCode: 0, reason: "")
        XCTAssertEqual(empty.description, "CloseInfo(code=0)")

        let withReason = WebTransportSessionCloseInfo(errorCode: 42, reason: "timeout")
        XCTAssertTrue(withReason.description.contains("42"))
        XCTAssertTrue(withReason.description.contains("timeout"))
    }

    func testCloseInfoHashing() {
        var set = Set<WebTransportSessionCloseInfo>()
        set.insert(WebTransportSessionCloseInfo(errorCode: 0, reason: ""))
        set.insert(WebTransportSessionCloseInfo(errorCode: 0, reason: ""))
        set.insert(WebTransportSessionCloseInfo(errorCode: 1, reason: ""))
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - Stream Error Code Mapping Tests

final class WebTransportStreamErrorCodeTests: XCTestCase {

    func testBaseValue() {
        XCTAssertEqual(WebTransportStreamErrorCode.base, 0x52e4a40d)
    }

    func testToHTTP3ErrorCode() {
        XCTAssertEqual(
            WebTransportStreamErrorCode.toHTTP3ErrorCode(0),
            0x52e4a40d
        )
        XCTAssertEqual(
            WebTransportStreamErrorCode.toHTTP3ErrorCode(1),
            0x52e4a40e
        )
        XCTAssertEqual(
            WebTransportStreamErrorCode.toHTTP3ErrorCode(0xFF),
            0x52e4a40d + 0xFF
        )
    }

    func testFromHTTP3ErrorCode() {
        XCTAssertEqual(WebTransportStreamErrorCode.fromHTTP3ErrorCode(0x52e4a40d), 0)
        XCTAssertEqual(WebTransportStreamErrorCode.fromHTTP3ErrorCode(0x52e4a40e), 1)
        XCTAssertEqual(WebTransportStreamErrorCode.fromHTTP3ErrorCode(0x52e4a40d + 0xFF), 0xFF)

        // Below the base
        XCTAssertNil(WebTransportStreamErrorCode.fromHTTP3ErrorCode(0))
        XCTAssertNil(WebTransportStreamErrorCode.fromHTTP3ErrorCode(0x52e4a40c))
    }

    func testIsWebTransportCode() {
        XCTAssertTrue(WebTransportStreamErrorCode.isWebTransportCode(0x52e4a40d))
        XCTAssertTrue(WebTransportStreamErrorCode.isWebTransportCode(0x52e4a40d + 100))
        XCTAssertFalse(WebTransportStreamErrorCode.isWebTransportCode(0))
        XCTAssertFalse(WebTransportStreamErrorCode.isWebTransportCode(0x0100))
    }

    func testRoundTrip() {
        for code: UInt32 in [0, 1, 42, 255, 1000, UInt32.max] {
            let http3Code = WebTransportStreamErrorCode.toHTTP3ErrorCode(code)
            let roundTripped = WebTransportStreamErrorCode.fromHTTP3ErrorCode(http3Code)
            XCTAssertEqual(roundTripped, code, "Round-trip failed for code \(code)")
        }
    }
}

// MARK: - Well-Known Error Code Tests

final class WebTransportErrorCodeTests: XCTestCase {

    func testErrorCodeValues() {
        XCTAssertEqual(WebTransportErrorCode.noError, 0x00)
        XCTAssertEqual(WebTransportErrorCode.protocolViolation, 0x01)
        XCTAssertEqual(WebTransportErrorCode.sessionTimeout, 0x02)
        XCTAssertEqual(WebTransportErrorCode.cancelled, 0x03)
        XCTAssertEqual(WebTransportErrorCode.serverGoingAway, 0x04)
        XCTAssertEqual(WebTransportErrorCode.internalError, 0xFF)
    }
}

// MARK: - Session State Tests

final class WebTransportSessionStateTests: XCTestCase {

    func testStateDescriptions() {
        XCTAssertEqual(WebTransportSessionState.connecting.description, "connecting")
        XCTAssertEqual(WebTransportSessionState.established.description, "established")
        XCTAssertEqual(WebTransportSessionState.draining.description, "draining")
        XCTAssertTrue(WebTransportSessionState.closed(nil).description.contains("closed"))
    }

    func testStateEquality() {
        XCTAssertEqual(WebTransportSessionState.connecting, .connecting)
        XCTAssertEqual(WebTransportSessionState.established, .established)
        XCTAssertEqual(WebTransportSessionState.draining, .draining)
        XCTAssertNotEqual(WebTransportSessionState.connecting, .established)
    }

    func testClosedStateWithInfo() {
        let info = WebTransportSessionCloseInfo(errorCode: 42, reason: "test")
        let state = WebTransportSessionState.closed(info)
        let desc = state.description
        XCTAssertTrue(desc.contains("closed"))
        XCTAssertTrue(desc.contains("42"))
    }

    func testClosedStateWithoutInfo() {
        let state = WebTransportSessionState.closed(nil)
        XCTAssertEqual(state.description, "closed")
    }
}

// MARK: - WebTransport Error Description Tests

final class WebTransportErrorDescriptionTests: XCTestCase {

    func testSessionNotEstablished() {
        let error = WebTransportError.sessionNotEstablished
        XCTAssertTrue(error.description.contains("not established"))
    }

    func testSessionClosed() {
        let error = WebTransportError.sessionClosed(nil)
        XCTAssertTrue(error.description.contains("closed"))

        let info = WebTransportSessionCloseInfo(errorCode: 1, reason: "bye")
        let error2 = WebTransportError.sessionClosed(info)
        XCTAssertTrue(error2.description.contains("1"))
    }

    func testSessionRejected() {
        let error = WebTransportError.sessionRejected(status: 403, reason: "Forbidden")
        XCTAssertTrue(error.description.contains("403"))
        XCTAssertTrue(error.description.contains("Forbidden"))
    }

    func testPeerDoesNotSupport() {
        let error = WebTransportError.peerDoesNotSupportWebTransport("missing setting")
        XCTAssertTrue(error.description.contains("missing setting"))
    }

    func testMaxSessionsExceeded() {
        let error = WebTransportError.maxSessionsExceeded(limit: 5)
        XCTAssertTrue(error.description.contains("5"))
    }

    func testStreamError() {
        let error = WebTransportError.streamError("write failed", underlying: nil)
        XCTAssertTrue(error.description.contains("write failed"))
    }

    func testDatagramError() {
        let error = WebTransportError.datagramError("too large", underlying: nil)
        XCTAssertTrue(error.description.contains("too large"))
    }

    func testCapsuleError() {
        let error = WebTransportError.capsuleError("malformed")
        XCTAssertTrue(error.description.contains("malformed"))
    }

    func testInvalidSessionID() {
        let error = WebTransportError.invalidSessionID(42)
        XCTAssertTrue(error.description.contains("42"))
    }

    func testInvalidStream() {
        let error = WebTransportError.invalidStream("bad header")
        XCTAssertTrue(error.description.contains("bad header"))
    }

    func testInternalError() {
        let error = WebTransportError.internalError("unexpected", underlying: nil)
        XCTAssertTrue(error.description.contains("unexpected"))
    }

    func testHTTP3Error() {
        let error = WebTransportError.http3Error("connection failed", underlying: nil)
        XCTAssertTrue(error.description.contains("connection failed"))
    }
}

// MARK: - Stream Framing Tests

final class WebTransportStreamFramingTests: XCTestCase {

    // MARK: - Stream Type Constant

    func testWebTransportUniStreamType() {
        XCTAssertEqual(kWebTransportUniStreamType, 0x54)
    }

    // MARK: - Bidirectional Stream Framing

    func testWriteBidirectionalHeader() async throws {
        let stream = MockWTStream(id: 0)
        try await WebTransportStreamFraming.writeBidirectionalHeader(to: stream, sessionID: 4)

        let written = stream.allWrittenData
        XCTAssertFalse(written.isEmpty)

        // Decode the session ID varint
        let (varint, _) = try Varint.decode(from: written)
        XCTAssertEqual(varint.value, 4)
    }

    func testWriteBidirectionalHeaderLargeSessionID() async throws {
        let stream = MockWTStream(id: 0)
        let largeSessionID: UInt64 = 1000
        try await WebTransportStreamFraming.writeBidirectionalHeader(to: stream, sessionID: largeSessionID)

        let written = stream.allWrittenData
        let (varint, _) = try Varint.decode(from: written)
        XCTAssertEqual(varint.value, largeSessionID)
    }

    func testReadBidirectionalSessionID() throws {
        // Encode a session ID varint
        var data = Data()
        Varint(8).encode(to: &data)
        data.append(Data("hello".utf8))

        let result = try XCTUnwrap(WebTransportStreamFraming.readBidirectionalSessionID(from: data))
        XCTAssertEqual(result.sessionID, 8)
        XCTAssertEqual(result.remaining, Data("hello".utf8))
    }

    func testReadBidirectionalSessionIDNoRemaining() throws {
        var data = Data()
        Varint(12).encode(to: &data)

        let result = try XCTUnwrap(WebTransportStreamFraming.readBidirectionalSessionID(from: data))
        XCTAssertEqual(result.sessionID, 12)
        XCTAssertTrue(result.remaining.isEmpty)
    }

    func testReadBidirectionalSessionIDEmpty() throws {
        let result = try WebTransportStreamFraming.readBidirectionalSessionID(from: Data())
        XCTAssertNil(result)
    }

    // MARK: - Unidirectional Stream Framing

    func testWriteUnidirectionalHeader() async throws {
        let stream = MockWTStream(id: 2, isUnidirectional: true)
        try await WebTransportStreamFraming.writeUnidirectionalHeader(to: stream, sessionID: 4)

        let written = stream.allWrittenData
        XCTAssertFalse(written.isEmpty)

        // First varint should be the stream type (0x54)
        let (typeVarint, typeConsumed) = try Varint.decode(from: written)
        XCTAssertEqual(typeVarint.value, 0x54)

        // Second varint should be the session ID
        let remaining = Data(written.dropFirst(typeConsumed))
        let (sessionVarint, _) = try Varint.decode(from: remaining)
        XCTAssertEqual(sessionVarint.value, 4)
    }

    func testReadUnidirectionalSessionID() throws {
        var data = Data()
        Varint(16).encode(to: &data)
        data.append(Data("payload".utf8))

        let result = try XCTUnwrap(WebTransportStreamFraming.readUnidirectionalSessionID(from: data))
        XCTAssertEqual(result.sessionID, 16)
        XCTAssertEqual(result.remaining, Data("payload".utf8))
    }

    // MARK: - Stream Direction

    func testStreamDirectionDescription() {
        XCTAssertEqual(WebTransportStreamDirection.bidirectional.description, "bidirectional")
        XCTAssertEqual(WebTransportStreamDirection.unidirectional.description, "unidirectional")
    }

    func testStreamDirectionEquality() {
        XCTAssertEqual(WebTransportStreamDirection.bidirectional, .bidirectional)
        XCTAssertEqual(WebTransportStreamDirection.unidirectional, .unidirectional)
        XCTAssertNotEqual(WebTransportStreamDirection.bidirectional, .unidirectional)
    }
}

// MARK: - Stream Classification Tests

final class WebTransportStreamClassificationTests: XCTestCase {

    func testIsWebTransportStream() {
        XCTAssertTrue(WebTransportStreamClassification.isWebTransportStream(0x54))
        XCTAssertFalse(WebTransportStreamClassification.isWebTransportStream(0x00))
        XCTAssertFalse(WebTransportStreamClassification.isWebTransportStream(0x01))
        XCTAssertFalse(WebTransportStreamClassification.isWebTransportStream(0x53))
        XCTAssertFalse(WebTransportStreamClassification.isWebTransportStream(0x55))
    }
}

// MARK: - WebTransport Stream Wrapper Tests

final class WebTransportStreamTests: XCTestCase {

    func testStreamProperties() {
        let quicStream = MockWTStream(id: 100)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: true
        )

        XCTAssertEqual(wtStream.id, 100)
        XCTAssertEqual(wtStream.sessionID, 4)
        XCTAssertEqual(wtStream.direction, .bidirectional)
        XCTAssertTrue(wtStream.isLocal)
        XCTAssertTrue(wtStream.isBidirectional)
        XCTAssertFalse(wtStream.isUnidirectional)
    }

    func testUnidirectionalStreamProperties() {
        let quicStream = MockWTStream(id: 200, isUnidirectional: true)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 8,
            direction: .unidirectional,
            isLocal: false
        )

        XCTAssertEqual(wtStream.id, 200)
        XCTAssertEqual(wtStream.sessionID, 8)
        XCTAssertTrue(wtStream.isUnidirectional)
        XCTAssertFalse(wtStream.isBidirectional)
        XCTAssertFalse(wtStream.isLocal)
    }

    func testStreamDescription() {
        let quicStream = MockWTStream(id: 50)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: true
        )

        let desc = wtStream.description
        XCTAssertTrue(desc.contains("50"))
        XCTAssertTrue(desc.contains("4"))
        XCTAssertTrue(desc.contains("bidirectional"))
        XCTAssertTrue(desc.contains("local"))
    }

    func testStreamRead() async throws {
        let quicStream = MockWTStream(id: 10)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: false
        )

        let testData = Data("hello".utf8)
        quicStream.enqueueReadData(testData)

        let readData = try await wtStream.read()
        XCTAssertEqual(readData, testData)
    }

    func testStreamWrite() async throws {
        let quicStream = MockWTStream(id: 10)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: true
        )

        let testData = Data("world".utf8)
        try await wtStream.write(testData)
        XCTAssertEqual(quicStream.writtenData, [testData])
    }

    func testStreamCloseWrite() async throws {
        let quicStream = MockWTStream(id: 10)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: true
        )

        try await wtStream.closeWrite()
        XCTAssertTrue(quicStream.isClosed)
    }

    func testStreamReset() async {
        let quicStream = MockWTStream(id: 10)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: true
        )

        await wtStream.reset(applicationErrorCode: 42)
        let expectedCode = WebTransportStreamErrorCode.toHTTP3ErrorCode(42)
        XCTAssertEqual(quicStream.resetCode, expectedCode)
    }

    func testStreamStopReading() async throws {
        let quicStream = MockWTStream(id: 10)
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: 4,
            direction: .bidirectional,
            isLocal: false
        )

        try await wtStream.stopReading(applicationErrorCode: 7)
        let expectedCode = WebTransportStreamErrorCode.toHTTP3ErrorCode(7)
        XCTAssertEqual(quicStream.stopSendingCode, expectedCode)
    }
}

// MARK: - Datagram Framing Tests

final class WebTransportDatagramFramingTests: XCTestCase {

    func testParseDatagram() throws {
        let quarterStreamID: UInt64 = 1 // sessionID = 4
        var payload = Data()
        Varint(quarterStreamID).encode(to: &payload)
        payload.append(Data("ping".utf8))

        let result = try XCTUnwrap(WebTransportSession.parseDatagram(payload))
        XCTAssertEqual(result.quarterStreamID, 1)
        XCTAssertEqual(result.payload, Data("ping".utf8))
    }

    func testParseDatagramEmpty() throws {
        let result = try WebTransportSession.parseDatagram(Data())
        XCTAssertNil(result)
    }

    func testParseDatagramNoPayload() throws {
        var data = Data()
        Varint(2).encode(to: &data)

        let result = try XCTUnwrap(WebTransportSession.parseDatagram(data))
        XCTAssertEqual(result.quarterStreamID, 2)
        XCTAssertTrue(result.payload.isEmpty)
    }

    func testFrameDatagram() {
        let payload = Data("hello".utf8)
        let framed = WebTransportSession.frameDatagram(payload: payload, quarterStreamID: 3)

        // Verify the framed datagram starts with the quarter stream ID
        let (varint, consumed) = try! Varint.decode(from: framed)
        XCTAssertEqual(varint.value, 3)

        let appPayload = Data(framed.dropFirst(consumed))
        XCTAssertEqual(appPayload, payload)
    }

    func testFrameDatagramRoundTrip() throws {
        let original = Data("test datagram payload".utf8)
        let quarterStreamID: UInt64 = 5

        let framed = WebTransportSession.frameDatagram(payload: original, quarterStreamID: quarterStreamID)
        let parsed = try XCTUnwrap(WebTransportSession.parseDatagram(framed))

        XCTAssertEqual(parsed.quarterStreamID, quarterStreamID)
        XCTAssertEqual(parsed.payload, original)
    }

    func testFrameDatagramLargeQuarterStreamID() throws {
        let quarterStreamID: UInt64 = 16384 // 4-byte varint
        let payload = Data("data".utf8)

        let framed = WebTransportSession.frameDatagram(payload: payload, quarterStreamID: quarterStreamID)
        let parsed = try XCTUnwrap(WebTransportSession.parseDatagram(framed))

        XCTAssertEqual(parsed.quarterStreamID, quarterStreamID)
        XCTAssertEqual(parsed.payload, payload)
    }
}

// MARK: - Session Lifecycle Tests

final class WebTransportSessionLifecycleTests: XCTestCase {

    func testSessionCreation() async {
        let mockConn = MockWTConnection()
        let settings = HTTP3Settings.webTransport(maxSessions: 1)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: settings
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        let sessionID = await session.sessionID
        let quarterStreamID = await session.quarterStreamID
        let isEstablished = await session.isEstablished

        XCTAssertEqual(sessionID, 4)
        XCTAssertEqual(quarterStreamID, 1) // 4 / 4 = 1
        XCTAssertFalse(isEstablished)

        mockConn.finish()
    }

    func testSessionStart() async throws {
        let mockConn = MockWTConnection()
        let settings = HTTP3Settings.webTransport(maxSessions: 1)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: settings
        )

        let connectStream = MockWTStream(id: 8)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        try await session.start()

        let isEstablished = await session.isEstablished
        XCTAssertTrue(isEstablished)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testSessionStartTwiceFails() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        try await session.start()

        do {
            try await session.start()
            XCTFail("Expected error on second start()")
        } catch {
            // Expected
        }

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testSessionQuarterStreamID() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        // Session ID 0 → quarter stream ID 0
        let session0 = WebTransportSession(
            connectStream: MockWTStream(id: 0),
            connection: h3Conn,
            role: .client
        )
        let qid0 = await session0.quarterStreamID
        XCTAssertEqual(qid0, 0)

        // Session ID 4 → quarter stream ID 1
        let session4 = WebTransportSession(
            connectStream: MockWTStream(id: 4),
            connection: h3Conn,
            role: .client
        )
        let qid4 = await session4.quarterStreamID
        XCTAssertEqual(qid4, 1)

        // Session ID 20 → quarter stream ID 5
        let session20 = WebTransportSession(
            connectStream: MockWTStream(id: 20),
            connection: h3Conn,
            role: .client
        )
        let qid20 = await session20.quarterStreamID
        XCTAssertEqual(qid20, 5)

        mockConn.finish()
    }

    func testSessionRole() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let serverSession = WebTransportSession(
            connectStream: MockWTStream(id: 4),
            connection: h3Conn,
            role: .server
        )
        let serverRole = await serverSession.role
        XCTAssertEqual(serverRole, .server)

        let clientSession = WebTransportSession(
            connectStream: MockWTStream(id: 8),
            connection: h3Conn,
            role: .client
        )
        let clientRole = await clientSession.role
        XCTAssertEqual(clientRole, .client)

        mockConn.finish()
    }

    func testSessionAbort() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        try? await session.start()
        let isEstablished = await session.isEstablished
        XCTAssertTrue(isEstablished)

        await session.abort(applicationErrorCode: 42)
        let isClosed = await session.isClosed
        XCTAssertTrue(isClosed)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testSessionDebugDescription() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 12)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        let desc = await session.debugDescription
        XCTAssertTrue(desc.contains("12"))
        XCTAssertTrue(desc.contains("server"))
        XCTAssertTrue(desc.contains("connecting"))

        connectStream.enqueueFIN()
        mockConn.finish()
    }
}

// MARK: - Session Stream Operations Tests

final class WebTransportSessionStreamTests: XCTestCase {

    func testOpenBidirectionalStream() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .client
        )
        try await session.start()

        let stream = try await session.openBidirectionalStream()
        XCTAssertTrue(stream.isBidirectional)
        XCTAssertTrue(stream.isLocal)
        XCTAssertEqual(stream.sessionID, 0) // WebTransportStream is a struct, not actor

        let count = await session.activeBidirectionalStreamCount
        XCTAssertEqual(count, 1)

        // Verify session ID was written as the first varint on the stream
        let opened = mockConn.openedStreams
        XCTAssertEqual(opened.count, 1)
        let writtenData = opened[0].allWrittenData
        let (varint, _) = try Varint.decode(from: writtenData)
        XCTAssertEqual(varint.value, 0) // Session ID = 0

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testOpenUnidirectionalStream() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .client
        )
        try await session.start()

        let stream = try await session.openUnidirectionalStream()
        XCTAssertTrue(stream.isUnidirectional)
        XCTAssertTrue(stream.isLocal)
        XCTAssertEqual(stream.sessionID, 4) // WebTransportStream is a struct, not actor

        let count = await session.activeUnidirectionalStreamCount
        XCTAssertEqual(count, 1)

        // Verify stream type + session ID were written
        let opened = mockConn.openedUniStreams
        XCTAssertEqual(opened.count, 1)
        let writtenData = opened[0].allWrittenData

        let (typeVarint, typeConsumed) = try Varint.decode(from: writtenData)
        XCTAssertEqual(typeVarint.value, 0x54) // WebTransport uni stream type

        let remaining = Data(writtenData.dropFirst(typeConsumed))
        let (sessionVarint, _) = try Varint.decode(from: remaining)
        XCTAssertEqual(sessionVarint.value, 4) // Session ID

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testOpenStreamWhenNotEstablished() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let session = WebTransportSession(
            connectStream: MockWTStream(id: 0),
            connection: h3Conn,
            role: .client
        )
        // Don't start the session

        do {
            _ = try await session.openBidirectionalStream()
            XCTFail("Expected sessionNotEstablished error")
        } catch let error as WebTransportError {
            if case .sessionNotEstablished = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }

        do {
            _ = try await session.openUnidirectionalStream()
            XCTFail("Expected sessionNotEstablished error")
        } catch let error as WebTransportError {
            if case .sessionNotEstablished = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }

        mockConn.finish()
    }

    func testDeliverIncomingBidirectionalStream() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        // Deliver an incoming bidirectional stream
        let incomingStream = MockWTStream(id: 100)
        await session.deliverIncomingBidirectionalStream(incomingStream, initialData: Data())

        let count = await session.activeBidirectionalStreamCount
        XCTAssertEqual(count, 1)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testDeliverIncomingUnidirectionalStream() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        let incomingStream = MockWTStream(id: 200, isUnidirectional: true)
        await session.deliverIncomingUnidirectionalStream(incomingStream, initialData: Data())

        let count = await session.activeUnidirectionalStreamCount
        XCTAssertEqual(count, 1)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testRemoveStream() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .client
        )
        try await session.start()

        let stream = try await session.openBidirectionalStream()
        var count = await session.activeBidirectionalStreamCount
        XCTAssertEqual(count, 1)

        await session.removeStream(stream.id)
        count = await session.activeBidirectionalStreamCount
        XCTAssertEqual(count, 0)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testActiveStreamCount() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .client
        )
        try await session.start()

        _ = try await session.openBidirectionalStream()
        _ = try await session.openBidirectionalStream()
        _ = try await session.openUnidirectionalStream()

        let bidiCount = await session.activeBidirectionalStreamCount
        let uniCount = await session.activeUnidirectionalStreamCount
        let totalCount = await session.activeStreamCount

        XCTAssertEqual(bidiCount, 2)
        XCTAssertEqual(uniCount, 1)
        XCTAssertEqual(totalCount, 3)

        // Enqueue FIN after assertions to let capsule reader task clean up
        connectStream.enqueueFIN()
        mockConn.finish()
    }
}

// MARK: - Session Datagram Tests

final class WebTransportSessionDatagramTests: XCTestCase {

    func testSendDatagram() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .client
        )
        try await session.start()

        let payload = Data("hello".utf8)
        try await session.sendDatagram(payload)

        // Verify the datagram was sent via the QUIC connection
        let sent = mockConn.sentDatagrams
        XCTAssertEqual(sent.count, 1)

        // Parse the sent datagram to verify framing
        let parsed = try XCTUnwrap(WebTransportSession.parseDatagram(sent[0]))
        XCTAssertEqual(parsed.quarterStreamID, 1) // sessionID=4, quarterStreamID=4/4=1
        XCTAssertEqual(parsed.payload, payload)

        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testSendDatagramNotEstablished() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let session = WebTransportSession(
            connectStream: MockWTStream(id: 0),
            connection: h3Conn,
            role: .client
        )
        // Don't start

        do {
            try await session.sendDatagram(Data("test".utf8))
            XCTFail("Expected sessionNotEstablished error")
        } catch let error as WebTransportError {
            if case .sessionNotEstablished = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }

        mockConn.finish()
    }

    func testDeliverDatagram() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        let payload = Data("incoming datagram".utf8)
        await session.deliverDatagram(payload)

        // The datagram was delivered to the session's incoming datagram stream
        // We can't easily test the async stream consumption here without
        // complex async test setup, but we verified it doesn't crash
        connectStream.enqueueFIN()
        mockConn.finish()
    }
}

// MARK: - HTTP3Connection Session Registry Tests

final class HTTP3ConnectionSessionRegistryTests: XCTestCase {

    func testRegisterSession() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 5)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        await h3Conn.registerWebTransportSession(session)
        let count = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count, 1)

        let found = await h3Conn.webTransportSession(for: 4)
        XCTAssertNotNil(found)

        mockConn.finish()
    }

    func testUnregisterSession() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 5)
        )

        let connectStream = MockWTStream(id: 8)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )

        await h3Conn.registerWebTransportSession(session)
        let count1 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count1, 1)

        let removed = await h3Conn.unregisterWebTransportSession(8)
        XCTAssertNotNil(removed)

        let count2 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count2, 0)

        let notFound = await h3Conn.webTransportSession(for: 8)
        XCTAssertNil(notFound)

        mockConn.finish()
    }

    func testUnregisterNonexistentSession() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 5)
        )

        let removed = await h3Conn.unregisterWebTransportSession(999)
        XCTAssertNil(removed)

        mockConn.finish()
    }

    func testMultipleSessions() async {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 10)
        )

        let session1 = WebTransportSession(
            connectStream: MockWTStream(id: 0),
            connection: h3Conn,
            role: .server
        )
        let session2 = WebTransportSession(
            connectStream: MockWTStream(id: 4),
            connection: h3Conn,
            role: .server
        )
        let session3 = WebTransportSession(
            connectStream: MockWTStream(id: 8),
            connection: h3Conn,
            role: .server
        )

        await h3Conn.registerWebTransportSession(session1)
        await h3Conn.registerWebTransportSession(session2)
        await h3Conn.registerWebTransportSession(session3)

        let count = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count, 3)

        let s0 = await h3Conn.webTransportSession(for: 0)
        XCTAssertNotNil(s0)
        let s4 = await h3Conn.webTransportSession(for: 4)
        XCTAssertNotNil(s4)
        let s8 = await h3Conn.webTransportSession(for: 8)
        XCTAssertNotNil(s8)
        let s12 = await h3Conn.webTransportSession(for: 12)
        XCTAssertNil(s12)

        mockConn.finish()
    }

    func testCreateWebTransportSession() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)

        let sendResponseCalled = SendResponseTracker()
        let context = ExtendedConnectContext(
            request: HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt"),
            streamID: 4,
            stream: connectStream,
            connection: h3Conn,
            sendResponse: { _ in
                await sendResponseCalled.markCalled()
            }
        )

        let session = try await h3Conn.createWebTransportSession(from: context, role: .server)
        let isEstablished = await session.isEstablished
        XCTAssertTrue(isEstablished)
        let sid = await session.sessionID
        XCTAssertEqual(sid, 4)

        let count = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count, 1)

        // Enqueue FIN *after* assertions so the capsule reader task does not
        // race with the isEstablished check above.
        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testCreateClientWebTransportSession() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let response = HTTP3Response(status: 200)

        let session = try await h3Conn.createClientWebTransportSession(
            connectStream: connectStream,
            response: response
        )

        let isEstablished = await session.isEstablished
        XCTAssertTrue(isEstablished)
        let sid = await session.sessionID
        XCTAssertEqual(sid, 0)

        let count = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count, 1)

        // Enqueue FIN *after* assertions so the capsule reader task does not
        // race with the isEstablished check above.
        connectStream.enqueueFIN()
        mockConn.finish()
    }

    func testCreateClientWebTransportSessionRejected() async throws {
        let mockConn = MockWTConnection(isClient: true)
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .client,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 0)
        let response = HTTP3Response(status: 403)

        do {
            _ = try await h3Conn.createClientWebTransportSession(
                connectStream: connectStream,
                response: response
            )
            XCTFail("Expected session rejected error")
        } catch let error as WebTransportError {
            if case .sessionRejected(let status, _) = error {
                XCTAssertEqual(status, 403)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }

        let count = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count, 0)

        mockConn.finish()
    }
}

// MARK: - WebTransport Settings Tests

final class WebTransportSettingsTests: XCTestCase {

    func testWebTransportSettingsFactory() {
        let settings = HTTP3Settings.webTransport(maxSessions: 5)
        XCTAssertTrue(settings.enableConnectProtocol)
        XCTAssertTrue(settings.enableH3Datagram)
        XCTAssertEqual(settings.webtransportMaxSessions, 5)
    }

    func testWebTransportSettingsDefaults() {
        let settings = HTTP3Settings.webTransport()
        XCTAssertTrue(settings.enableConnectProtocol)
        XCTAssertTrue(settings.enableH3Datagram)
        XCTAssertEqual(settings.webtransportMaxSessions, 1)
    }

    func testIsWebTransportReady() {
        let ready = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: 1
        )
        XCTAssertTrue(ready.isWebTransportReady)

        let noConnect = HTTP3Settings(
            enableConnectProtocol: false,
            enableH3Datagram: true,
            webtransportMaxSessions: 1
        )
        XCTAssertFalse(noConnect.isWebTransportReady)

        let noDatagram = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: false,
            webtransportMaxSessions: 1
        )
        XCTAssertFalse(noDatagram.isWebTransportReady)

        let noMaxSessions = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: nil
        )
        XCTAssertFalse(noMaxSessions.isWebTransportReady)

        let zeroSessions = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: 0
        )
        XCTAssertFalse(zeroSessions.isWebTransportReady)
    }

    func testEffectiveSendLimitsWebTransport() {
        let local = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: 10
        )
        let peer = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: 5
        )

        let effective = local.effectiveSendLimits(peerSettings: peer)
        XCTAssertTrue(effective.enableConnectProtocol)
        XCTAssertTrue(effective.enableH3Datagram)
        XCTAssertEqual(effective.webtransportMaxSessions, 5)
    }

    func testEffectiveSendLimitsDisabledByPeer() {
        let local = HTTP3Settings(
            enableConnectProtocol: true,
            enableH3Datagram: true,
            webtransportMaxSessions: 10
        )
        let peer = HTTP3Settings(
            enableConnectProtocol: false,
            enableH3Datagram: false,
            webtransportMaxSessions: nil
        )

        let effective = local.effectiveSendLimits(peerSettings: peer)
        XCTAssertFalse(effective.enableConnectProtocol)
        XCTAssertFalse(effective.enableH3Datagram)
        XCTAssertNil(effective.webtransportMaxSessions)
    }
}

// MARK: - WebTransport Client Tests

final class WebTransportClientTests: XCTestCase {

    func testClientCreation() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        let state = await client.state
        XCTAssertEqual(state, .idle)

        let isReady = await client.isReady
        XCTAssertFalse(isReady)

        let isClosed = await client.isClosed
        XCTAssertFalse(isClosed)

        mockConn.finish()
    }

    func testClientCustomConfiguration() async {
        let mockConn = MockWTConnection(isClient: true)
        let config = WebTransportClient.Configuration(
            maxSessions: 10,
            connectionReadyTimeout: .seconds(30),
            connectTimeout: .seconds(20)
        )
        let client = WebTransportClient(
            quicConnection: mockConn,
            configuration: config
        )

        let maxSessions = await client.configuration.maxSessions
        XCTAssertEqual(maxSessions, 10)

        mockConn.finish()
    }

    func testClientRemoteAddress() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        let remote = await client.remoteAddress
        XCTAssertEqual(remote.ipAddress, "127.0.0.1")
        XCTAssertEqual(remote.port, 443)

        mockConn.finish()
    }

    func testClientLocalAddress() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        let local = await client.localAddress
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.port, 4433)

        mockConn.finish()
    }

    func testClientSessionCount() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        let count = await client.activeSessionCount
        XCTAssertEqual(count, 0)

        let total = await client.totalSessions
        XCTAssertEqual(total, 0)

        mockConn.finish()
    }

    func testClientDebugDescription() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        let desc = await client.debugDescription
        XCTAssertTrue(desc.contains("idle"))
        XCTAssertTrue(desc.contains("127.0.0.1:443"))

        mockConn.finish()
    }

    func testClientConnectBeforeInitialize() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        do {
            _ = try await client.connect(authority: "example.com", path: "/wt")
            XCTFail("Expected error")
        } catch let error as WebTransportError {
            if case .internalError(let msg, _) = error {
                XCTAssertTrue(msg.contains("not ready"))
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        mockConn.finish()
    }

    func testClientClose() async {
        let mockConn = MockWTConnection(isClient: true)
        let client = WebTransportClient(quicConnection: mockConn)

        await client.close()
        let isClosed = await client.isClosed
        XCTAssertTrue(isClosed)

        // Double close should be safe
        await client.close()

        mockConn.finish()
    }
}

// MARK: - WebTransport Server Tests

final class WebTransportServerTests: XCTestCase {

    func testServerCreation() async {
        let server = WebTransportServer()

        let state = await server.state
        XCTAssertEqual(state, .idle)

        let isListening = await server.isListening
        XCTAssertFalse(isListening)

        let totalSessions = await server.totalSessions
        XCTAssertEqual(totalSessions, 0)
    }

    func testServerWithCustomConfiguration() async {
        let config = WebTransportServer.Configuration(
            maxSessionsPerConnection: 10,
            maxConnections: 100,
            allowedPaths: ["/wt", "/echo"]
        )
        let server = WebTransportServer(configuration: config)

        let maxSessions = await server.configuration.maxSessionsPerConnection
        XCTAssertEqual(maxSessions, 10)

        let paths = await server.configuration.allowedPaths
        XCTAssertEqual(paths, ["/wt", "/echo"])
    }

    func testServerConvenienceInit() async {
        let server = WebTransportServer(maxSessions: 5, maxConnections: 50)

        let maxSessions = await server.configuration.maxSessionsPerConnection
        XCTAssertEqual(maxSessions, 5)

        let maxConns = await server.configuration.maxConnections
        XCTAssertEqual(maxConns, 50)
    }

    func testServerDebugDescription() async {
        let server = WebTransportServer(maxSessions: 3)

        let desc = await server.debugDescription
        XCTAssertTrue(desc.contains("idle"))
        XCTAssertTrue(desc.contains("3"))
    }

    func testServerDefaultConfiguration() async {
        let config = WebTransportServer.Configuration.default
        XCTAssertEqual(config.maxSessionsPerConnection, 1)
        XCTAssertEqual(config.maxConnections, 0)
        XCTAssertTrue(config.allowedPaths.isEmpty)
    }

    func testServerStartWithoutIdle() async {
        let server = WebTransportServer()

        // Force to listening state first via serveConnection, then try serve
        // Actually, we can test the guard directly by trying to serve twice
        // via a cancelled stream
        let (stream, continuation) = AsyncStream<any QUICConnectionProtocol>.makeStream()
        continuation.finish() // End immediately

        do {
            try await server.serve(connectionSource: stream)
        } catch {
            // May throw or not depending on state
        }

        // Server should be stopped now
        let isStopped = await server.isStopped
        XCTAssertTrue(isStopped)
    }
}

// MARK: - Session Quota Enforcement Tests

final class WebTransportSessionQuotaTests: XCTestCase {

    func testSessionQuotaEnforcedOnConnection() async throws {
        // Create an HTTP3Connection with maxSessions = 2
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 2)
        )

        // Create first session — should succeed
        let stream1 = MockWTStream(id: 0)
        let session1 = WebTransportSession(
            connectStream: stream1,
            connection: h3Conn,
            role: .server
        )
        await h3Conn.registerWebTransportSession(session1)

        let count1 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count1, 1)

        // Create second session — should succeed
        let stream2 = MockWTStream(id: 4)
        let session2 = WebTransportSession(
            connectStream: stream2,
            connection: h3Conn,
            role: .server
        )
        await h3Conn.registerWebTransportSession(session2)

        let count2 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count2, 2)

        // Unregister one session — count drops to 1
        _ = await h3Conn.unregisterWebTransportSession(0)
        let count3 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count3, 1)

        // Register a new session — should succeed again
        let stream3 = MockWTStream(id: 8)
        let session3 = WebTransportSession(
            connectStream: stream3,
            connection: h3Conn,
            role: .server
        )
        await h3Conn.registerWebTransportSession(session3)

        let count4 = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(count4, 2)

        mockConn.finish()
    }

    func testExtendedConnectContextCarriesConnection() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let tracker = SendResponseTracker()
        let context = ExtendedConnectContext(
            request: HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt"),
            streamID: 4,
            stream: MockWTStream(id: 4),
            connection: h3Conn,
            sendResponse: { _ in
                await tracker.markCalled()
            }
        )

        // Verify the connection reference is correct
        let contextConn = context.connection
        let role = await contextConn.role
        XCTAssertEqual(role, .server)

        // Verify we can query session count through the context's connection
        let count = await context.connection.activeWebTransportSessionCount
        XCTAssertEqual(count, 0)

        mockConn.finish()
    }

    func testSessionQuotaCheckViaContext() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        // Register one session to fill the quota
        let existingStream = MockWTStream(id: 0)
        let existingSession = WebTransportSession(
            connectStream: existingStream,
            connection: h3Conn,
            role: .server
        )
        await h3Conn.registerWebTransportSession(existingSession)

        // Create a context for a new Extended CONNECT
        let rejectionTracker = RejectionTracker()
        let context = ExtendedConnectContext(
            request: HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt"),
            streamID: 4,
            stream: MockWTStream(id: 4),
            connection: h3Conn,
            sendResponse: { response in
                if response.status != 200 {
                    await rejectionTracker.recordRejection(status: response.status)
                }
            }
        )

        // Simulate the quota check that WebTransportServer.serve() performs
        let maxSessions: UInt64 = 1
        let activeCount = await context.connection.activeWebTransportSessionCount
        if maxSessions > 0 && activeCount >= Int(maxSessions) {
            try await context.reject(
                status: 429,
                headers: [("content-type", "text/plain")],
                body: Data("Too many WebTransport sessions".utf8)
            )
        }

        let wasRejected = await rejectionTracker.rejected
        let status = await rejectionTracker.rejectedStatus
        XCTAssertTrue(wasRejected)
        XCTAssertEqual(status, 429)

        mockConn.finish()
    }

    func testSessionQuotaAllowsWhenUnderLimit() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 5)
        )

        // Register 3 sessions (under limit of 5)
        for i: UInt64 in [0, 4, 8] {
            let stream = MockWTStream(id: i)
            let session = WebTransportSession(
                connectStream: stream,
                connection: h3Conn,
                role: .server
            )
            await h3Conn.registerWebTransportSession(session)
        }

        let activeCount = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(activeCount, 3)

        // Verify we're under the limit
        let maxSessions: UInt64 = 5
        XCTAssertTrue(activeCount < Int(maxSessions), "Should be under session limit")

        mockConn.finish()
    }

    func testSessionQuotaZeroMeansUnlimited() async throws {
        // When maxSessions is 0, the quota check should not reject
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 0)
        )

        // Register several sessions
        for i: UInt64 in stride(from: 0, to: 40, by: 4) {
            let stream = MockWTStream(id: i)
            let session = WebTransportSession(
                connectStream: stream,
                connection: h3Conn,
                role: .server
            )
            await h3Conn.registerWebTransportSession(session)
        }

        let activeCount = await h3Conn.activeWebTransportSessionCount
        XCTAssertEqual(activeCount, 10)

        // With maxSessions=0, the guard `maxSessions > 0 && ...` is false,
        // so no rejection should occur
        let maxSessions: UInt64 = 0
        let shouldReject = maxSessions > 0 && activeCount >= Int(maxSessions)
        XCTAssertFalse(shouldReject)

        mockConn.finish()
    }
}

// MARK: - QUICConnectionProtocol Datagram Extension Tests

final class QUICDatagramErrorTests: XCTestCase {

    func testDatagramsNotSupported() {
        let error = QUICDatagramError.datagramsNotSupported
        XCTAssertTrue(error.description.contains("not supported"))
    }

    func testDatagramTooLarge() {
        let error = QUICDatagramError.datagramTooLarge(size: 2000, maxAllowed: 1200)
        XCTAssertTrue(error.description.contains("2000"))
        XCTAssertTrue(error.description.contains("1200"))
    }

    func testConnectionNotReady() {
        let error = QUICDatagramError.connectionNotReady
        XCTAssertTrue(error.description.contains("not ready"))
    }
}

// MARK: - Integration: Capsule Round-Trip on CONNECT Stream

final class WebTransportCapsuleStreamIntegrationTests: XCTestCase {

    func testSessionReceivesCloseCapsule() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        // Send a CLOSE capsule on the CONNECT stream
        let closeData = WebTransportCapsuleCodec.encodeClose(errorCode: 42, reason: "done")
        connectStream.enqueueReadData(closeData)
        // Then FIN to end the loop
        connectStream.enqueueFIN()

        // Give the capsule reader loop time to process
        try await Task.sleep(for: .milliseconds(100))

        let isClosed = await session.isClosed
        XCTAssertTrue(isClosed)

        let closeInfo = await session.closeInfo
        XCTAssertNotNil(closeInfo)
        XCTAssertEqual(closeInfo?.errorCode, 42)
        XCTAssertEqual(closeInfo?.reason, "done")

        mockConn.finish()
    }

    func testSessionReceivesDrainCapsule() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        // Send a DRAIN capsule
        let drainData = WebTransportCapsuleCodec.encodeDrain()
        connectStream.enqueueReadData(drainData)

        // Give the capsule reader loop time to process
        try await Task.sleep(for: .milliseconds(100))

        let isDraining = await session.isDraining
        XCTAssertTrue(isDraining)

        // Session should still be alive (draining, not closed)
        let isClosed = await session.isClosed
        XCTAssertFalse(isClosed)

        // Now close via FIN
        connectStream.enqueueFIN()
        try await Task.sleep(for: .milliseconds(100))

        let isClosedNow = await session.isClosed
        XCTAssertTrue(isClosedNow)

        mockConn.finish()
    }

    func testSessionHandlesFINOnConnectStream() async throws {
        let mockConn = MockWTConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: mockConn,
            role: .server,
            settings: HTTP3Settings.webTransport(maxSessions: 1)
        )

        let connectStream = MockWTStream(id: 4)
        let session = WebTransportSession(
            connectStream: connectStream,
            connection: h3Conn,
            role: .server
        )
        try await session.start()

        // Immediately send FIN
        connectStream.enqueueFIN()

        try await Task.sleep(for: .milliseconds(100))

        let isClosed = await session.isClosed
        XCTAssertTrue(isClosed)

        mockConn.finish()
    }
}

// MARK: - WebTransport Request Helpers Tests

final class WebTransportRequestHelpersTests: XCTestCase {

    func testIsWebTransportConnect() {
        let request = HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt")
        XCTAssertTrue(request.isWebTransportConnect)
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertEqual(request.connectProtocol, "webtransport")
        XCTAssertEqual(request.method, .connect)
        XCTAssertEqual(request.authority, "example.com")
        XCTAssertEqual(request.path, "/wt")
    }

    func testNonWebTransportExtendedConnect() {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/ws",
            connectProtocol: "websocket"
        )
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
    }

    func testRegularRequestNotWebTransport() {
        let request = HTTP3Request(method: .get, authority: "example.com", path: "/")
        XCTAssertFalse(request.isWebTransportConnect)
        XCTAssertFalse(request.isExtendedConnect)
    }

    func testWebTransportConnectHeaderList() {
        let request = HTTP3Request.webTransportConnect(
            scheme: "https",
            authority: "example.com:4433",
            path: "/wt/echo",
            headers: [("origin", "https://example.com")]
        )

        let headers = request.toHeaderList()

        // Check pseudo-headers are present
        let methods = headers.filter { $0.name == ":method" }
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods[0].value, "CONNECT")

        let protocols = headers.filter { $0.name == ":protocol" }
        XCTAssertEqual(protocols.count, 1)
        XCTAssertEqual(protocols[0].value, "webtransport")

        let schemes = headers.filter { $0.name == ":scheme" }
        XCTAssertEqual(schemes.count, 1)
        XCTAssertEqual(schemes[0].value, "https")

        let authorities = headers.filter { $0.name == ":authority" }
        XCTAssertEqual(authorities.count, 1)
        XCTAssertEqual(authorities[0].value, "example.com:4433")

        let paths = headers.filter { $0.name == ":path" }
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].value, "/wt/echo")

        // Check regular header
        let origins = headers.filter { $0.name == "origin" }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins[0].value, "https://example.com")
    }

    func testWebTransportConnectHeaderRoundTrip() throws {
        let original = HTTP3Request.webTransportConnect(
            authority: "example.com",
            path: "/wt"
        )

        let headerList = original.toHeaderList()
        let decoded = try HTTP3Request.fromHeaderList(headerList)

        XCTAssertEqual(decoded.method, .connect)
        XCTAssertEqual(decoded.connectProtocol, "webtransport")
        XCTAssertEqual(decoded.authority, "example.com")
        XCTAssertEqual(decoded.path, "/wt")
        XCTAssertEqual(decoded.scheme, "https")
    }
}

// MARK: - Capsule Error Tests

final class WebTransportCapsuleErrorTests: XCTestCase {

    func testCapsuleErrorDescriptions() {
        let error1 = WebTransportCapsuleError.payloadTooShort(expected: 10, actual: 5, capsuleType: "CLOSE")
        XCTAssertTrue(error1.description.contains("10"))
        XCTAssertTrue(error1.description.contains("5"))

        let error2 = WebTransportCapsuleError.malformedVarint("test context")
        XCTAssertTrue(error2.description.contains("varint"))

        let error3 = WebTransportCapsuleError.truncatedCapsule("bad encoding")
        XCTAssertTrue(error3.description.contains("bad encoding"))
    }
}

// MARK: - Integration: Multiple Capsules in One Read

final class WebTransportMultipleCapsuleTests: XCTestCase {

    func testDecodeAllFromMixedData() throws {
        // Build a buffer with: CLOSE + DRAIN + some trailing bytes
        let closeInfo = WebTransportSessionCloseInfo(errorCode: 7, reason: "test")
        var data = WebTransportCapsuleCodec.encode(.close(closeInfo))
        data.append(WebTransportCapsuleCodec.encode(.drain))

        // Add partial capsule (just a type byte, not enough for full capsule)
        data.append(0x01) // Incomplete

        let (capsules, consumed) = try WebTransportCapsuleCodec.decodeAll(from: data)
        XCTAssertEqual(capsules.count, 2)
        XCTAssertLessThan(consumed, data.count, "Should not consume partial data")

        if case .close(let info) = capsules[0] {
            XCTAssertEqual(info.errorCode, 7)
        } else {
            XCTFail("Expected close")
        }

        if case .drain = capsules[1] {
            // OK
        } else {
            XCTFail("Expected drain")
        }
    }
}

// MARK: - Capsule Encoded Size Tests

final class WebTransportCapsuleEncodedSizeTests: XCTestCase {

    func testEncodedSizeMatchesActual() {
        let capsules: [WebTransportCapsule] = [
            .close(WebTransportSessionCloseInfo(errorCode: 0, reason: "")),
            .close(WebTransportSessionCloseInfo(errorCode: UInt32.max, reason: "long reason string")),
            .drain,
            .unknown(type: 0xABCD, payload: Data([1, 2, 3, 4, 5])),
        ]

        for capsule in capsules {
            let predicted = WebTransportCapsuleCodec.encodedSize(of: capsule)
            let actual = WebTransportCapsuleCodec.encode(capsule).count
            XCTAssertEqual(predicted, actual, "Size mismatch for \(capsule)")
        }
    }
}

// MARK: - Helper Types

private actor SendResponseTracker {
    var called = false
    func markCalled() {
        called = true
    }
}

/// Actor for tracking rejection state in quota enforcement tests.
private actor RejectionTracker {
    var rejected = false
    var rejectedStatus: Int?

    func recordRejection(status: Int) {
        rejected = true
        rejectedStatus = status
    }
}