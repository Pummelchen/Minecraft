/// HTTP/3 Tests
///
/// Tests for HTTP/3 frame codec, settings, types, error codes,
/// and stream type handling (RFC 9114).

import Foundation
import XCTest

@testable import HTTP3
@testable import QPACK
@testable import QUIC
@testable import QUICCore

// MARK: - HTTP/3 Frame Type Tests

final class HTTP3FrameTypeTests: XCTestCase {

    // MARK: - Frame Type Identifiers

    func testFrameTypeRawValues() {
        XCTAssertEqual(HTTP3FrameType.data.rawValue, 0x00)
        XCTAssertEqual(HTTP3FrameType.headers.rawValue, 0x01)
        XCTAssertEqual(HTTP3FrameType.cancelPush.rawValue, 0x03)
        XCTAssertEqual(HTTP3FrameType.settings.rawValue, 0x04)
        XCTAssertEqual(HTTP3FrameType.pushPromise.rawValue, 0x05)
        XCTAssertEqual(HTTP3FrameType.goaway.rawValue, 0x07)
        XCTAssertEqual(HTTP3FrameType.maxPushID.rawValue, 0x0d)
    }

    func testFrameTypeDescriptions() {
        XCTAssertEqual(HTTP3FrameType.data.description, "DATA")
        XCTAssertEqual(HTTP3FrameType.headers.description, "HEADERS")
        XCTAssertEqual(HTTP3FrameType.settings.description, "SETTINGS")
        XCTAssertEqual(HTTP3FrameType.goaway.description, "GOAWAY")
    }

    // MARK: - Frame Properties

    func testFrameTypeProperty() {
        let dataFrame = HTTP3Frame.data(Data([1, 2, 3]))
        XCTAssertEqual(dataFrame.frameType, 0x00)

        let headersFrame = HTTP3Frame.headers(Data([4, 5, 6]))
        XCTAssertEqual(headersFrame.frameType, 0x01)

        let settingsFrame = HTTP3Frame.settings(HTTP3Settings())
        XCTAssertEqual(settingsFrame.frameType, 0x04)

        let goawayFrame = HTTP3Frame.goaway(streamID: 42)
        XCTAssertEqual(goawayFrame.frameType, 0x07)

        let unknownFrame = HTTP3Frame.unknown(type: 0xff, payload: Data())
        XCTAssertEqual(unknownFrame.frameType, 0xff)
    }

    func testControlStreamAllowedFrames() {
        XCTAssertTrue(HTTP3Frame.settings(HTTP3Settings()).isAllowedOnControlStream)
        XCTAssertTrue(HTTP3Frame.goaway(streamID: 0).isAllowedOnControlStream)
        XCTAssertTrue(HTTP3Frame.maxPushID(pushID: 0).isAllowedOnControlStream)
        XCTAssertTrue(HTTP3Frame.cancelPush(pushID: 0).isAllowedOnControlStream)
        XCTAssertTrue(HTTP3Frame.unknown(type: 0xff, payload: Data()).isAllowedOnControlStream)

        XCTAssertFalse(HTTP3Frame.data(Data()).isAllowedOnControlStream)
        XCTAssertFalse(HTTP3Frame.headers(Data()).isAllowedOnControlStream)
        XCTAssertFalse(
            HTTP3Frame.pushPromise(pushID: 0, headerBlock: Data()).isAllowedOnControlStream)
    }

    func testRequestStreamAllowedFrames() {
        XCTAssertTrue(HTTP3Frame.data(Data()).isAllowedOnRequestStream)
        XCTAssertTrue(HTTP3Frame.headers(Data()).isAllowedOnRequestStream)
        XCTAssertTrue(
            HTTP3Frame.pushPromise(pushID: 0, headerBlock: Data()).isAllowedOnRequestStream)
        XCTAssertTrue(HTTP3Frame.unknown(type: 0xff, payload: Data()).isAllowedOnRequestStream)

        XCTAssertFalse(HTTP3Frame.settings(HTTP3Settings()).isAllowedOnRequestStream)
        XCTAssertFalse(HTTP3Frame.goaway(streamID: 0).isAllowedOnRequestStream)
        XCTAssertFalse(HTTP3Frame.maxPushID(pushID: 0).isAllowedOnRequestStream)
        XCTAssertFalse(HTTP3Frame.cancelPush(pushID: 0).isAllowedOnRequestStream)
    }

    // MARK: - Frame Equality

    func testFrameEquality() {
        let data1 = HTTP3Frame.data(Data([1, 2, 3]))
        let data2 = HTTP3Frame.data(Data([1, 2, 3]))
        let data3 = HTTP3Frame.data(Data([4, 5, 6]))
        XCTAssertEqual(data1, data2)
        XCTAssertNotEqual(data1, data3)

        let settings1 = HTTP3Frame.settings(HTTP3Settings())
        let settings2 = HTTP3Frame.settings(HTTP3Settings())
        XCTAssertEqual(settings1, settings2)

        let goaway1 = HTTP3Frame.goaway(streamID: 10)
        let goaway2 = HTTP3Frame.goaway(streamID: 10)
        let goaway3 = HTTP3Frame.goaway(streamID: 20)
        XCTAssertEqual(goaway1, goaway2)
        XCTAssertNotEqual(goaway1, goaway3)

        // Different types are never equal
        XCTAssertNotEqual(HTTP3Frame.data(Data()), HTTP3Frame.headers(Data()))
    }

    // MARK: - Reserved Frame Types

    func testReservedFrameTypes() {
        XCTAssertTrue(HTTP3ReservedFrameType.isReserved(0x02))  // PRIORITY
        XCTAssertTrue(HTTP3ReservedFrameType.isReserved(0x06))  // PING
        XCTAssertTrue(HTTP3ReservedFrameType.isReserved(0x08))  // WINDOW_UPDATE
        XCTAssertTrue(HTTP3ReservedFrameType.isReserved(0x09))  // CONTINUATION

        XCTAssertFalse(HTTP3ReservedFrameType.isReserved(0x00))  // DATA
        XCTAssertFalse(HTTP3ReservedFrameType.isReserved(0x01))  // HEADERS
        XCTAssertFalse(HTTP3ReservedFrameType.isReserved(0x04))  // SETTINGS
        XCTAssertFalse(HTTP3ReservedFrameType.isReserved(0x07))  // GOAWAY
    }

    // MARK: - GREASE Frame Types

    func testGreaseFrameTypes() {
        // 0x1f * N + 0x21 for N = 0, 1, 2, ...
        XCTAssertTrue(HTTP3GreaseFrameType.isGrease(0x21))  // N=0
        XCTAssertTrue(HTTP3GreaseFrameType.isGrease(0x40))  // N=1: 0x1f + 0x21 = 0x40
        XCTAssertTrue(HTTP3GreaseFrameType.isGrease(0x5f))  // N=2: 0x3e + 0x21 = 0x5f

        XCTAssertFalse(HTTP3GreaseFrameType.isGrease(0x00))
        XCTAssertFalse(HTTP3GreaseFrameType.isGrease(0x01))
        XCTAssertFalse(HTTP3GreaseFrameType.isGrease(0x04))
        XCTAssertFalse(HTTP3GreaseFrameType.isGrease(0x20))
        XCTAssertFalse(HTTP3GreaseFrameType.isGrease(0x22))
    }
}

// MARK: - HTTP/3 Frame Codec Tests

final class HTTP3FrameCodecTests: XCTestCase {

    // MARK: - DATA Frame

    func testEncodeDecodeDataFrame() throws {
        let payload = Data("Hello, HTTP/3!".utf8)
        let frame = HTTP3Frame.data(payload)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded, frame)

        if case .data(let decodedPayload) = decoded {
            XCTAssertEqual(decodedPayload, payload)
        } else {
            XCTFail("Expected DATA frame, got \(decoded)")
        }
    }

    func testEncodeDecodeEmptyDataFrame() throws {
        let frame = HTTP3Frame.data(Data())

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded, frame)

        if case .data(let payload) = decoded {
            XCTAssertTrue(payload.isEmpty)
        } else {
            XCTFail("Expected empty DATA frame")
        }
    }

    // MARK: - HEADERS Frame

    func testEncodeDecodeHeadersFrame() throws {
        let headerBlock = Data([0x00, 0x00, UInt8(0xc0) | UInt8(17)])  // Minimal QPACK encoded
        let frame = HTTP3Frame.headers(headerBlock)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded, frame)
    }

    // MARK: - SETTINGS Frame

    func testEncodeDecodeDefaultSettings() throws {
        let settings = HTTP3Settings()
        let frame = HTTP3Frame.settings(settings)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .settings(let decodedSettings) = decoded {
            XCTAssertEqual(decodedSettings.maxTableCapacity, 0)
            XCTAssertEqual(decodedSettings.maxFieldSectionSize, UInt64.max)
            XCTAssertEqual(decodedSettings.qpackBlockedStreams, 0)
        } else {
            XCTFail("Expected SETTINGS frame, got \(decoded)")
        }
    }

    func testEncodeDecodeCustomSettings() throws {
        var settings = HTTP3Settings()
        settings.maxTableCapacity = 4096
        settings.maxFieldSectionSize = 16384
        settings.qpackBlockedStreams = 100
        let frame = HTTP3Frame.settings(settings)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .settings(let decodedSettings) = decoded {
            XCTAssertEqual(decodedSettings.maxTableCapacity, 4096)
            XCTAssertEqual(decodedSettings.maxFieldSectionSize, 16384)
            XCTAssertEqual(decodedSettings.qpackBlockedStreams, 100)
        } else {
            XCTFail("Expected SETTINGS frame")
        }
    }

    func testDefaultSettingsProduceEmptyPayload() throws {
        // Default settings have all default values, so the payload should be empty
        let settings = HTTP3Settings()
        let frame = HTTP3Frame.settings(settings)

        let encoded = HTTP3FrameCodec.encode(frame)
        // Frame should be: type varint (0x04 = 1 byte) + length varint (0x00 = 1 byte) = 2 bytes
        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded[0], 0x04)  // SETTINGS type
        XCTAssertEqual(encoded[1], 0x00)  // Empty payload
    }

    // MARK: - GOAWAY Frame

    func testEncodeDecodeGoawayFrame() throws {
        let frame = HTTP3Frame.goaway(streamID: 256)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .goaway(let streamID) = decoded {
            XCTAssertEqual(streamID, 256)
        } else {
            XCTFail("Expected GOAWAY frame, got \(decoded)")
        }
    }

    func testEncodeDecodeGoawayZero() throws {
        let frame = HTTP3Frame.goaway(streamID: 0)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, _) = try HTTP3FrameCodec.decode(from: encoded)

        if case .goaway(let streamID) = decoded {
            XCTAssertEqual(streamID, 0)
        } else {
            XCTFail("Expected GOAWAY frame")
        }
    }

    // MARK: - CANCEL_PUSH Frame

    func testEncodeDecodeCancelPushFrame() throws {
        let frame = HTTP3Frame.cancelPush(pushID: 7)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .cancelPush(let pushID) = decoded {
            XCTAssertEqual(pushID, 7)
        } else {
            XCTFail("Expected CANCEL_PUSH frame")
        }
    }

    // MARK: - MAX_PUSH_ID Frame

    func testEncodeDecodeMaxPushIDFrame() throws {
        let frame = HTTP3Frame.maxPushID(pushID: 42)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .maxPushID(let pushID) = decoded {
            XCTAssertEqual(pushID, 42)
        } else {
            XCTFail("Expected MAX_PUSH_ID frame")
        }
    }

    // MARK: - PUSH_PROMISE Frame

    func testEncodeDecodePushPromiseFrame() throws {
        let headerBlock = Data([0x00, 0x00, 0xd1])
        let frame = HTTP3Frame.pushPromise(pushID: 3, headerBlock: headerBlock)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .pushPromise(let pushID, let decodedBlock) = decoded {
            XCTAssertEqual(pushID, 3)
            XCTAssertEqual(decodedBlock, headerBlock)
        } else {
            XCTFail("Expected PUSH_PROMISE frame")
        }
    }

    // MARK: - Unknown Frame Type (Forward Compatibility)

    func testEncodeDecodeUnknownFrameType() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = HTTP3Frame.unknown(type: 0xff, payload: payload)

        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)

        XCTAssertEqual(consumed, encoded.count)
        if case .unknown(let type, let decodedPayload) = decoded {
            XCTAssertEqual(type, 0xff)
            XCTAssertEqual(decodedPayload, payload)
        } else {
            XCTFail("Expected unknown frame, got \(decoded)")
        }
    }

    // MARK: - Multiple Frames

    func testDecodeMultipleFrames() throws {
        let frame1 = HTTP3Frame.data(Data("Hello".utf8))
        let frame2 = HTTP3Frame.data(Data(" World".utf8))
        let frame3 = HTTP3Frame.goaway(streamID: 4)

        var buffer = Data()
        HTTP3FrameCodec.encode(frame1, into: &buffer)
        HTTP3FrameCodec.encode(frame2, into: &buffer)
        HTTP3FrameCodec.encode(frame3, into: &buffer)

        let (frames, totalConsumed) = try HTTP3FrameCodec.decodeAll(from: buffer)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(totalConsumed, buffer.count)
        XCTAssertEqual(frames[0], frame1)
        XCTAssertEqual(frames[1], frame2)
        XCTAssertEqual(frames[2], frame3)
    }

    func testEncodeMultipleFrames() throws {
        let frames = [
            HTTP3Frame.data(Data("A".utf8)),
            HTTP3Frame.data(Data("B".utf8)),
        ]
        let encoded = HTTP3FrameCodec.encode(frames)

        let (decoded, _) = try HTTP3FrameCodec.decodeAll(from: encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0], frames[0])
        XCTAssertEqual(decoded[1], frames[1])
    }

    // MARK: - Error Cases

    func testDecodeInsufficientData() {
        let data = Data([0x00])  // Type varint only, no length
        XCTAssertThrowsError(try HTTP3FrameCodec.decode(from: data)) { error in
            XCTAssertTrue(error is HTTP3FrameCodecError)
        }
    }

    func testDecodeInsufficientPayloadData() {
        // Type=DATA(0x00), Length=10, but only 3 bytes of payload
        let data = Data([0x00, 0x0a, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try HTTP3FrameCodec.decode(from: data)) { error in
            if let codecError = error as? HTTP3FrameCodecError {
                if case .insufficientData = codecError {
                    // Expected
                } else {
                    XCTFail("Expected insufficientData, got \(codecError)")
                }
            }
        }
    }

    func testDecodeEmptyData() {
        let data = Data()
        XCTAssertThrowsError(try HTTP3FrameCodec.decode(from: data))
    }

    func testDecodeAllWithPartialFrameAtEnd() throws {
        let frame1 = HTTP3Frame.data(Data("Complete".utf8))
        var buffer = HTTP3FrameCodec.encode(frame1)
        buffer.append(Data([0x00, 0x0a]))  // Partial frame: type + length but no payload

        let (frames, consumed) = try HTTP3FrameCodec.decodeAll(from: buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], frame1)
        XCTAssertLessThan(consumed, buffer.count)
    }

    // MARK: - Settings Validation

    func testDuplicateSettingIdentifierRejected() {
        // Manually construct a SETTINGS payload with duplicate identifier
        // Identifier=0x01, Value=100, Identifier=0x01, Value=200
        var payload = Data()
        Varint(0x01).encode(to: &payload)
        Varint(100).encode(to: &payload)
        Varint(0x01).encode(to: &payload)
        Varint(200).encode(to: &payload)

        // Wrap in frame: type=0x04, length, payload
        var frame = Data()
        Varint(0x04).encode(to: &frame)
        Varint(UInt64(payload.count)).encode(to: &frame)
        frame.append(payload)

        XCTAssertThrowsError(try HTTP3FrameCodec.decode(from: frame)) { error in
            if let codecError = error as? HTTP3FrameCodecError {
                if case .duplicateSettingIdentifier(let id) = codecError {
                    XCTAssertEqual(id, 0x01)
                } else {
                    XCTFail("Expected duplicateSettingIdentifier, got \(codecError)")
                }
            }
        }
    }

    func testHTTP2SettingRejected() {
        // Manually construct a SETTINGS payload with an HTTP/2-only setting
        // 0x02 = SETTINGS_ENABLE_PUSH (HTTP/2 only)
        var payload = Data()
        Varint(0x02).encode(to: &payload)
        Varint(1).encode(to: &payload)

        var frame = Data()
        Varint(0x04).encode(to: &frame)
        Varint(UInt64(payload.count)).encode(to: &frame)
        frame.append(payload)

        XCTAssertThrowsError(try HTTP3FrameCodec.decode(from: frame)) { error in
            if let codecError = error as? HTTP3FrameCodecError {
                if case .http2SettingReceived(let id) = codecError {
                    XCTAssertEqual(id, 0x02)
                } else {
                    XCTFail("Expected http2SettingReceived, got \(codecError)")
                }
            }
        }
    }

    func testUnknownSettingsIgnored() throws {
        // Unknown settings should be preserved but not cause errors
        var payload = Data()
        Varint(0x01).encode(to: &payload)  // maxTableCapacity
        Varint(4096).encode(to: &payload)
        Varint(0x99).encode(to: &payload)  // Unknown setting
        Varint(42).encode(to: &payload)

        var frame = Data()
        Varint(0x04).encode(to: &frame)
        Varint(UInt64(payload.count)).encode(to: &frame)
        frame.append(payload)

        let (decoded, _) = try HTTP3FrameCodec.decode(from: frame)
        if case .settings(let settings) = decoded {
            XCTAssertEqual(settings.maxTableCapacity, 4096)
            XCTAssertEqual(settings.additionalSettings.count, 1)
            XCTAssertEqual(settings.additionalSettings[0].0, 0x99)
            XCTAssertEqual(settings.additionalSettings[0].1, 42)
        } else {
            XCTFail("Expected SETTINGS frame")
        }
    }

    // MARK: - Size Calculation

    func testEncodedSizeMatchesActualSize() {
        let frames: [HTTP3Frame] = [
            .data(Data("Hello".utf8)),
            .data(Data()),
            .headers(Data([0x00, 0x00, 0xc0])),
            .settings(HTTP3Settings()),
            .goaway(streamID: 100),
            .cancelPush(pushID: 5),
            .maxPushID(pushID: 999),
            .unknown(type: 0xab, payload: Data([1, 2, 3])),
        ]

        for frame in frames {
            let encoded = HTTP3FrameCodec.encode(frame)
            let calculatedSize = HTTP3FrameCodec.encodedSize(of: frame)
            XCTAssertEqual(
                encoded.count, calculatedSize,
                "Size mismatch for \(frame): encoded=\(encoded.count), calculated=\(calculatedSize)"
            )
        }
    }

    // MARK: - Peek Frame Size

    func testPeekFrameSize() {
        let frame = HTTP3Frame.data(Data("Hello".utf8))
        let encoded = HTTP3FrameCodec.encode(frame)

        let peekedSize = HTTP3FrameCodec.peekFrameSize(from: encoded)
        XCTAssertEqual(peekedSize, encoded.count)
    }

    func testPeekFrameSizeWithInsufficientData() {
        XCTAssertNil(HTTP3FrameCodec.peekFrameSize(from: Data()))
        XCTAssertNil(HTTP3FrameCodec.peekFrameSize(from: Data([0x00])))  // Only type, no length
    }

    // MARK: - Round-Trip for All Frame Types

    func testRoundTripAllFrameTypes() throws {
        let frames: [HTTP3Frame] = [
            .data(Data("test payload".utf8)),
            .headers(Data([0x00, 0x00, 0xd1, 0xd7, 0x51, 0x01, 0x2f])),
            .cancelPush(pushID: 0),
            .cancelPush(pushID: 12345),
            .settings(HTTP3Settings()),
            .settings(
                HTTP3Settings(
                    maxTableCapacity: 8192, maxFieldSectionSize: 32768, qpackBlockedStreams: 50)),
            .pushPromise(pushID: 1, headerBlock: Data([0x00, 0x00])),
            .goaway(streamID: 0),
            .goaway(streamID: 100),
            .maxPushID(pushID: 0),
            .maxPushID(pushID: 1000),
            .unknown(type: 0x1234, payload: Data([0xca, 0xfe])),
        ]

        for original in frames {
            let encoded = HTTP3FrameCodec.encode(original)
            let (decoded, consumed) = try HTTP3FrameCodec.decode(from: encoded)
            XCTAssertEqual(consumed, encoded.count, "Consumed bytes mismatch for \(original)")
            XCTAssertEqual(decoded, original, "Round-trip failed for \(original)")
        }
    }
}

// MARK: - HTTP/3 Settings Tests

final class HTTP3SettingsTests: XCTestCase {

    func testDefaultSettings() {
        let settings = HTTP3Settings()
        XCTAssertEqual(settings.maxTableCapacity, 0)
        XCTAssertEqual(settings.maxFieldSectionSize, UInt64.max)
        XCTAssertEqual(settings.qpackBlockedStreams, 0)
        XCTAssertTrue(settings.additionalSettings.isEmpty)
    }

    func testCustomSettings() {
        let settings = HTTP3Settings(
            maxTableCapacity: 4096,
            maxFieldSectionSize: 65536,
            qpackBlockedStreams: 100
        )
        XCTAssertEqual(settings.maxTableCapacity, 4096)
        XCTAssertEqual(settings.maxFieldSectionSize, 65536)
        XCTAssertEqual(settings.qpackBlockedStreams, 100)
    }

    func testIsLiteralOnly() {
        let literalOnly = HTTP3Settings()
        XCTAssertTrue(literalOnly.isLiteralOnly)
        XCTAssertFalse(literalOnly.usesDynamicTable)

        let withDynamic = HTTP3Settings(maxTableCapacity: 4096)
        XCTAssertFalse(withDynamic.isLiteralOnly)
        XCTAssertTrue(withDynamic.usesDynamicTable)

        let withBlocked = HTTP3Settings(maxTableCapacity: 0, qpackBlockedStreams: 10)
        XCTAssertFalse(withBlocked.isLiteralOnly)
    }

    func testHasFieldSectionSizeLimit() {
        let unlimited = HTTP3Settings()
        XCTAssertFalse(unlimited.hasFieldSectionSizeLimit)

        let limited = HTTP3Settings(maxFieldSectionSize: 8192)
        XCTAssertTrue(limited.hasFieldSectionSizeLimit)
    }

    func testSettingsEquality() {
        let a = HTTP3Settings(
            maxTableCapacity: 100, maxFieldSectionSize: 200, qpackBlockedStreams: 10)
        let b = HTTP3Settings(
            maxTableCapacity: 100, maxFieldSectionSize: 200, qpackBlockedStreams: 10)
        XCTAssertEqual(a, b)

        let c = HTTP3Settings(
            maxTableCapacity: 100, maxFieldSectionSize: 300, qpackBlockedStreams: 10)
        XCTAssertNotEqual(a, c)
    }

    func testEffectiveSendLimits() {
        let local = HTTP3Settings(
            maxTableCapacity: 8192, maxFieldSectionSize: 65536, qpackBlockedStreams: 200)
        let peer = HTTP3Settings(
            maxTableCapacity: 4096, maxFieldSectionSize: 32768, qpackBlockedStreams: 100)

        let effective = local.effectiveSendLimits(peerSettings: peer)
        XCTAssertEqual(effective.maxTableCapacity, 4096)  // min(8192, 4096)
        XCTAssertEqual(effective.maxFieldSectionSize, 32768)  // peer's limit
        XCTAssertEqual(effective.qpackBlockedStreams, 100)  // min(200, 100)
    }

    func testPredefinedConfigurations() {
        let literalOnly = HTTP3Settings.literalOnly
        XCTAssertTrue(literalOnly.isLiteralOnly)
        XCTAssertEqual(literalOnly.maxTableCapacity, 0)

        let small = HTTP3Settings.smallDynamicTable
        XCTAssertEqual(small.maxTableCapacity, 4096)
        XCTAssertEqual(small.maxFieldSectionSize, 65536)
        XCTAssertEqual(small.qpackBlockedStreams, 100)

        let large = HTTP3Settings.largeDynamicTable
        XCTAssertEqual(large.maxTableCapacity, 16384)
        XCTAssertEqual(large.maxFieldSectionSize, 262144)
        XCTAssertEqual(large.qpackBlockedStreams, 200)
    }

    func testSettingsDescription() {
        let defaults = HTTP3Settings()
        XCTAssertEqual(defaults.description, "HTTP3Settings(defaults)")

        let custom = HTTP3Settings(maxTableCapacity: 100)
        XCTAssertTrue(custom.description.contains("maxTableCapacity=100"))
    }
}

// MARK: - HTTP/3 Error Code Tests

final class HTTP3ErrorCodeTests: XCTestCase {

    func testErrorCodeRawValues() {
        XCTAssertEqual(HTTP3ErrorCode.noError.rawValue, 0x0100)
        XCTAssertEqual(HTTP3ErrorCode.generalProtocolError.rawValue, 0x0101)
        XCTAssertEqual(HTTP3ErrorCode.internalError.rawValue, 0x0102)
        XCTAssertEqual(HTTP3ErrorCode.streamCreationError.rawValue, 0x0103)
        XCTAssertEqual(HTTP3ErrorCode.closedCriticalStream.rawValue, 0x0104)
        XCTAssertEqual(HTTP3ErrorCode.frameUnexpected.rawValue, 0x0105)
        XCTAssertEqual(HTTP3ErrorCode.frameError.rawValue, 0x0106)
        XCTAssertEqual(HTTP3ErrorCode.excessiveLoad.rawValue, 0x0107)
        XCTAssertEqual(HTTP3ErrorCode.idError.rawValue, 0x0108)
        XCTAssertEqual(HTTP3ErrorCode.settingsError.rawValue, 0x0109)
        XCTAssertEqual(HTTP3ErrorCode.missingSettings.rawValue, 0x010a)
        XCTAssertEqual(HTTP3ErrorCode.requestRejected.rawValue, 0x010b)
        XCTAssertEqual(HTTP3ErrorCode.requestCancelled.rawValue, 0x010c)
        XCTAssertEqual(HTTP3ErrorCode.requestIncomplete.rawValue, 0x010d)
        XCTAssertEqual(HTTP3ErrorCode.messageError.rawValue, 0x010e)
        XCTAssertEqual(HTTP3ErrorCode.connectError.rawValue, 0x010f)
        XCTAssertEqual(HTTP3ErrorCode.versionFallback.rawValue, 0x0110)
    }

    func testErrorCodeDescriptions() {
        XCTAssertEqual(HTTP3ErrorCode.noError.description, "H3_NO_ERROR")
        XCTAssertEqual(HTTP3ErrorCode.frameError.description, "H3_FRAME_ERROR")
        XCTAssertEqual(HTTP3ErrorCode.settingsError.description, "H3_SETTINGS_ERROR")
    }

    func testErrorCodeReasons() {
        XCTAssertFalse(HTTP3ErrorCode.noError.reason.isEmpty)
        XCTAssertFalse(HTTP3ErrorCode.frameUnexpected.reason.isEmpty)
        XCTAssertFalse(HTTP3ErrorCode.versionFallback.reason.isEmpty)
    }

    func testQPACKErrorCodes() {
        XCTAssertEqual(QPACKErrorCode.decompressionFailed.rawValue, 0x0200)
        XCTAssertEqual(QPACKErrorCode.encoderStreamError.rawValue, 0x0201)
        XCTAssertEqual(QPACKErrorCode.decoderStreamError.rawValue, 0x0202)
    }

    func testHTTP3Error() {
        let error = HTTP3Error(code: .frameUnexpected, reason: "DATA on control stream")
        XCTAssertEqual(error.code, .frameUnexpected)
        XCTAssertEqual(error.reason, "DATA on control stream")
        XCTAssertTrue(error.isConnectionError)
        XCTAssertFalse(error.isRetryable)
    }

    func testHTTP3ErrorConvenienceConstructors() {
        let noError = HTTP3Error.noError
        XCTAssertEqual(noError.code, .noError)

        let proto = HTTP3Error.protocolError("test")
        XCTAssertEqual(proto.code, .generalProtocolError)
        XCTAssertTrue(proto.isConnectionError)

        let missing = HTTP3Error.missingSettings
        XCTAssertEqual(missing.code, .missingSettings)
        XCTAssertTrue(missing.isConnectionError)

        let cancelled = HTTP3Error.requestCancelled
        XCTAssertEqual(cancelled.code, .requestCancelled)
        XCTAssertFalse(cancelled.isConnectionError)
        XCTAssertFalse(cancelled.isRetryable)
    }

    func testHTTP3ErrorRetryable() {
        let rejected = HTTP3Error(code: .requestRejected, reason: "Try again")
        XCTAssertTrue(rejected.isRetryable)

        let cancelled = HTTP3Error(code: .requestCancelled)
        XCTAssertFalse(cancelled.isRetryable)
    }

    func testGreaseErrorCodes() {
        // 0x1f * N + 0x21
        XCTAssertTrue(HTTP3ErrorCode.isGrease(0x21))
        XCTAssertTrue(HTTP3ErrorCode.isGrease(0x40))

        XCTAssertFalse(HTTP3ErrorCode.isGrease(0x0100))
        XCTAssertFalse(HTTP3ErrorCode.isGrease(0x00))
    }
}

// MARK: - HTTP/3 Stream Type Tests

final class HTTP3StreamTypeTests: XCTestCase {

    func testStreamTypeRawValues() {
        XCTAssertEqual(HTTP3StreamType.control.rawValue, 0x00)
        XCTAssertEqual(HTTP3StreamType.push.rawValue, 0x01)
        XCTAssertEqual(HTTP3StreamType.qpackEncoder.rawValue, 0x02)
        XCTAssertEqual(HTTP3StreamType.qpackDecoder.rawValue, 0x03)
    }

    func testCriticalStreams() {
        XCTAssertTrue(HTTP3StreamType.control.isCritical)
        XCTAssertTrue(HTTP3StreamType.qpackEncoder.isCritical)
        XCTAssertTrue(HTTP3StreamType.qpackDecoder.isCritical)
        XCTAssertFalse(HTTP3StreamType.push.isCritical)
    }

    func testServerOnlyStreams() {
        XCTAssertTrue(HTTP3StreamType.push.isServerOnly)
        XCTAssertFalse(HTTP3StreamType.control.isServerOnly)
        XCTAssertFalse(HTTP3StreamType.qpackEncoder.isServerOnly)
        XCTAssertFalse(HTTP3StreamType.qpackDecoder.isServerOnly)
    }

    func testSingletonStreams() {
        XCTAssertTrue(HTTP3StreamType.control.isSingleton)
        XCTAssertTrue(HTTP3StreamType.qpackEncoder.isSingleton)
        XCTAssertTrue(HTTP3StreamType.qpackDecoder.isSingleton)
        XCTAssertFalse(HTTP3StreamType.push.isSingleton)
    }

    func testStreamTypeEncode() {
        let encoded = HTTP3StreamType.control.encode()
        XCTAssertEqual(encoded, Data([0x00]))

        let encoderEncoded = HTTP3StreamType.qpackEncoder.encode()
        XCTAssertEqual(encoderEncoded, Data([0x02]))
    }

    func testStreamTypeDecode() throws {
        let data = Data([0x00])
        let result = try HTTP3StreamType.decode(from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, 0x00)
        XCTAssertEqual(result?.1, 1)
    }

    func testStreamClassification() {
        let control = HTTP3StreamClassification.classify(0x00)
        if case .known(let type) = control {
            XCTAssertEqual(type, .control)
        } else {
            XCTFail("Expected known control stream type")
        }

        let grease = HTTP3StreamClassification.classify(0x21)
        if case .grease(let value) = grease {
            XCTAssertEqual(value, 0x21)
        } else {
            XCTFail("Expected grease stream type")
        }

        let unknown = HTTP3StreamClassification.classify(0x99)
        if case .unknown(let value) = unknown {
            XCTAssertEqual(value, 0x99)
        } else {
            XCTFail("Expected unknown stream type")
        }
    }

    func testGreaseStreamTypes() {
        XCTAssertTrue(HTTP3GreaseStreamType.isGrease(0x21))
        XCTAssertTrue(HTTP3GreaseStreamType.isGrease(0x40))

        XCTAssertFalse(HTTP3GreaseStreamType.isGrease(0x00))
        XCTAssertFalse(HTTP3GreaseStreamType.isGrease(0x01))

        XCTAssertEqual(HTTP3GreaseStreamType.greaseValue(for: 0), 0x21)
        XCTAssertEqual(HTTP3GreaseStreamType.greaseValue(for: 1), 0x40)
    }
}

// MARK: - HTTP/3 Types Tests

final class HTTP3TypesTests: XCTestCase {

    // MARK: - HTTPMethod

    func testHTTPMethodRawValues() {
        XCTAssertEqual(HTTPMethod.get.rawValue, "GET")
        XCTAssertEqual(HTTPMethod.post.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.put.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.delete.rawValue, "DELETE")
        XCTAssertEqual(HTTPMethod.head.rawValue, "HEAD")
        XCTAssertEqual(HTTPMethod.options.rawValue, "OPTIONS")
        XCTAssertEqual(HTTPMethod.patch.rawValue, "PATCH")
        XCTAssertEqual(HTTPMethod.connect.rawValue, "CONNECT")
        XCTAssertEqual(HTTPMethod.trace.rawValue, "TRACE")
    }

    // MARK: - HTTP3Request

    func testRequestFromComponents() {
        let request = HTTP3Request(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/api/data",
            headers: [("accept", "application/json")]
        )

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "example.com")
        XCTAssertEqual(request.path, "/api/data")
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.headers[0].0, "accept")
        XCTAssertNil(request.body)
    }

    func testRequestFromURL() {
        let request = HTTP3Request(method: .get, url: "https://example.com/index.html")

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "example.com")
        XCTAssertEqual(request.path, "/index.html")
    }

    func testRequestFromURLWithPort() {
        let request = HTTP3Request(method: .post, url: "https://localhost:4433/api")

        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "localhost:4433")
        XCTAssertEqual(request.path, "/api")
    }

    func testRequestFromURLNoPath() {
        let request = HTTP3Request(method: .get, url: "https://example.com")

        XCTAssertEqual(request.authority, "example.com")
        XCTAssertEqual(request.path, "/")
    }

    func testRequestToHeaderList() {
        let request = HTTP3Request(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/",
            headers: [("accept", "*/*"), ("user-agent", "quiver")]
        )

        let headers = request.toHeaderList()
        XCTAssertEqual(headers.count, 6)  // 4 pseudo-headers + 2 regular

        // Pseudo-headers must come first
        XCTAssertEqual(headers[0].name, ":method")
        XCTAssertEqual(headers[0].value, "GET")
        XCTAssertEqual(headers[1].name, ":scheme")
        XCTAssertEqual(headers[1].value, "https")
        XCTAssertEqual(headers[2].name, ":authority")
        XCTAssertEqual(headers[2].value, "example.com")
        XCTAssertEqual(headers[3].name, ":path")
        XCTAssertEqual(headers[3].value, "/")

        // Regular headers
        XCTAssertEqual(headers[4].name, "accept")
        XCTAssertEqual(headers[4].value, "*/*")
        XCTAssertEqual(headers[5].name, "user-agent")
        XCTAssertEqual(headers[5].value, "quiver")
    }

    func testRequestFromHeaderList() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "POST"),
            (":scheme", "https"),
            (":authority", "api.example.com"),
            (":path", "/submit"),
            ("content-type", "application/json"),
        ]

        let request = try HTTP3Request.fromHeaderList(headers)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "api.example.com")
        XCTAssertEqual(request.path, "/submit")
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.headers[0].0, "content-type")
    }

    func testRequestFromHeaderListMissingMethod() {
        let headers: [(name: String, value: String)] = [
            (":scheme", "https"),
            (":path", "/"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .missingPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":method")
                } else {
                    XCTFail("Expected missingPseudoHeader, got \(typeError)")
                }
            }
        }
    }

    func testRequestFromHeaderListDuplicatePseudoHeader() {
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":method", "POST"),
            (":scheme", "https"),
            (":path", "/"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .duplicatePseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":method")
                }
            }
        }
    }

    func testRequestFromHeaderListUnknownPseudoHeader() {
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/"),
            (":unknown", "value"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .unknownPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":unknown")
                }
            }
        }
    }

    func testRequestDescription() {
        let request = HTTP3Request(method: .get, url: "https://example.com/path")
        XCTAssertEqual(request.description, "GET https://example.com/path")
    }

    // MARK: - HTTP3Response

    func testResponseCreation() {
        let response = HTTP3Response(
            status: 200,
            headers: [("content-type", "text/plain")],
            body: Data("OK".utf8)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers.count, 1)
        XCTAssertEqual(response.bufferedBodyData, Data("OK".utf8))
    }

    func testResponseStatusText() {
        XCTAssertEqual(HTTP3Response(status: 200).statusText, "OK")
        XCTAssertEqual(HTTP3Response(status: 201).statusText, "Created")
        XCTAssertEqual(HTTP3Response(status: 204).statusText, "No Content")
        XCTAssertEqual(HTTP3Response(status: 301).statusText, "Moved Permanently")
        XCTAssertEqual(HTTP3Response(status: 304).statusText, "Not Modified")
        XCTAssertEqual(HTTP3Response(status: 400).statusText, "Bad Request")
        XCTAssertEqual(HTTP3Response(status: 401).statusText, "Unauthorized")
        XCTAssertEqual(HTTP3Response(status: 403).statusText, "Forbidden")
        XCTAssertEqual(HTTP3Response(status: 404).statusText, "Not Found")
        XCTAssertEqual(HTTP3Response(status: 500).statusText, "Internal Server Error")
        XCTAssertEqual(HTTP3Response(status: 502).statusText, "Bad Gateway")
        XCTAssertEqual(HTTP3Response(status: 503).statusText, "Service Unavailable")
        XCTAssertEqual(HTTP3Response(status: 999).statusText, "Unknown")
    }

    func testResponseStatusCategories() {
        XCTAssertTrue(HTTP3Response(status: 100).isInformational)
        XCTAssertFalse(HTTP3Response(status: 100).isSuccess)

        XCTAssertTrue(HTTP3Response(status: 200).isSuccess)
        XCTAssertFalse(HTTP3Response(status: 200).isRedirect)

        XCTAssertTrue(HTTP3Response(status: 301).isRedirect)
        XCTAssertFalse(HTTP3Response(status: 301).isClientError)

        XCTAssertTrue(HTTP3Response(status: 404).isClientError)
        XCTAssertFalse(HTTP3Response(status: 404).isServerError)

        XCTAssertTrue(HTTP3Response(status: 500).isServerError)
        XCTAssertFalse(HTTP3Response(status: 500).isSuccess)
    }

    func testResponseToHeaderList() {
        let response = HTTP3Response(
            status: 200,
            headers: [("content-type", "text/html"), ("server", "quiver")]
        )

        let headers = response.toHeaderList()
        XCTAssertEqual(headers.count, 3)  // 1 pseudo-header + 2 regular
        XCTAssertEqual(headers[0].name, ":status")
        XCTAssertEqual(headers[0].value, "200")
        XCTAssertEqual(headers[1].name, "content-type")
        XCTAssertEqual(headers[2].name, "server")
    }

    func testResponseFromHeaderList() throws {
        let headers: [(name: String, value: String)] = [
            (":status", "404"),
            ("content-type", "text/html"),
        ]

        let response = try HTTP3Response.fromHeaderList(headers)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.headers.count, 1)
        XCTAssertTrue(response.bufferedBodyData.isEmpty)
    }

    func testResponseFromHeaderListMissingStatus() {
        let headers: [(name: String, value: String)] = [
            ("content-type", "text/html")
        ]

        do {
            let _ = try HTTP3Response.fromHeaderList(headers)
            XCTFail("Expected HTTP3TypeError to be thrown")
        } catch let error as HTTP3TypeError {
            if case .missingPseudoHeader(let name) = error {
                XCTAssertEqual(name, ":status")
            } else {
                XCTFail("Expected missingPseudoHeader, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testResponseFromHeaderListInvalidStatus() {
        let headers: [(name: String, value: String)] = [
            (":status", "abc")
        ]

        do {
            let _ = try HTTP3Response.fromHeaderList(headers)
            XCTFail("Expected HTTP3TypeError to be thrown")
        } catch let error as HTTP3TypeError {
            if case .invalidPseudoHeaderValue(let name, _) = error {
                XCTAssertEqual(name, ":status")
            } else {
                XCTFail("Expected invalidPseudoHeaderValue, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testResponseDescription() {
        let response = HTTP3Response(status: 200, body: Data("Hello".utf8))
        XCTAssertEqual(response.description, "200 OK (5 bytes)")

        let streamResponse = HTTP3Response(
            status: 404, bodyStream: AsyncStream<Data> { $0.finish() })
        XCTAssertEqual(streamResponse.description, "404 Not Found (stream)")
    }

    // MARK: - Request/Response Header Round-Trip

    func testRequestHeaderRoundTrip() throws {
        let original = HTTP3Request(
            method: .post,
            scheme: "https",
            authority: "example.com:8443",
            path: "/api/v2/resource",
            headers: [
                ("content-type", "application/json"),
                ("accept", "application/json"),
                ("authorization", "Bearer token123"),
            ]
        )

        let headerList = original.toHeaderList()
        let restored = try HTTP3Request.fromHeaderList(headerList)

        XCTAssertEqual(restored.method, original.method)
        XCTAssertEqual(restored.scheme, original.scheme)
        XCTAssertEqual(restored.authority, original.authority)
        XCTAssertEqual(restored.path, original.path)
        XCTAssertEqual(restored.headers.count, original.headers.count)
    }

    func testResponseHeaderRoundTrip() throws {
        let original = HTTP3Response(
            status: 200,
            headers: [
                ("content-type", "application/json"),
                ("content-length", "42"),
                ("cache-control", "no-cache"),
            ]
        )

        let headerList = original.toHeaderList()
        let restored = try HTTP3Response.fromHeaderList(headerList)

        XCTAssertEqual(restored.status, original.status)
        XCTAssertEqual(restored.headers.count, original.headers.count)
    }

    // MARK: - QPACK Integration with Types

    func testRequestQPACKRoundTrip() throws {
        let request = HTTP3Request(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/",
            headers: [("accept", "*/*")]
        )

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let headerList = request.toHeaderList()
        let encoded = encoder.encode(headerList)
        let decodedHeaders = try decoder.decode(encoded)

        let restored = try HTTP3Request.fromHeaderList(decodedHeaders)
        XCTAssertEqual(restored.method, .get)
        XCTAssertEqual(restored.scheme, "https")
        XCTAssertEqual(restored.authority, "example.com")
        XCTAssertEqual(restored.path, "/")
        XCTAssertEqual(restored.headers.count, 1)
        XCTAssertEqual(restored.headers[0].0, "accept")
        XCTAssertEqual(restored.headers[0].1, "*/*")
    }

    func testResponseQPACKRoundTrip() throws {
        let response = HTTP3Response(
            status: 200,
            headers: [
                ("content-type", "text/plain"),
                ("content-length", "5"),
            ],
            body: Data("Hello".utf8)
        )

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let headerList = response.toHeaderList()
        let encoded = encoder.encode(headerList)
        let decodedHeaders = try decoder.decode(encoded)

        let restored = try HTTP3Response.fromHeaderList(decodedHeaders)
        XCTAssertEqual(restored.status, 200)
        XCTAssertEqual(restored.headers.count, 2)
    }

    // MARK: - Full Frame Round-Trip (QPACK + Frame Codec)

    func testFullRequestFrameRoundTrip() throws {
        let request = HTTP3Request(
            method: .post,
            scheme: "https",
            authority: "api.example.com",
            path: "/submit",
            headers: [("content-type", "application/json")],
            body: Data("{\"key\":\"value\"}".utf8)
        )

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        // Encode: Request → header list → QPACK → HEADERS frame → wire bytes
        let headerList = request.toHeaderList()
        let encodedHeaders = encoder.encode(headerList)
        let headersFrame = HTTP3Frame.headers(encodedHeaders)
        let headersWire = HTTP3FrameCodec.encode(headersFrame)

        // Also encode body as DATA frame
        let dataFrame = HTTP3Frame.data(request.body!)
        let dataWire = HTTP3FrameCodec.encode(dataFrame)

        // Combine
        var wire = headersWire
        wire.append(dataWire)

        // Decode: wire bytes → frames → QPACK decode → request
        let (frames, consumed) = try HTTP3FrameCodec.decodeAll(from: wire)
        XCTAssertEqual(consumed, wire.count)
        XCTAssertEqual(frames.count, 2)

        guard case .headers(let headerBlock) = frames[0] else {
            XCTFail("Expected HEADERS frame")
            return
        }

        guard case .data(let bodyData) = frames[1] else {
            XCTFail("Expected DATA frame")
            return
        }

        let decodedHeaders = try decoder.decode(headerBlock)
        let restored = try HTTP3Request.fromHeaderList(decodedHeaders)
        XCTAssertEqual(restored.method, .post)
        XCTAssertEqual(restored.scheme, "https")
        XCTAssertEqual(restored.authority, "api.example.com")
        XCTAssertEqual(restored.path, "/submit")

        XCTAssertEqual(bodyData, request.body)
    }
}

// MARK: - HTTP/3 Client Tests

final class HTTP3ClientTests: XCTestCase {

    func testClientDefaultConfiguration() {
        let config = HTTP3Client.Configuration.default
        XCTAssertTrue(config.settings.isLiteralOnly)
        XCTAssertEqual(config.maxConcurrentRequests, 100)
        XCTAssertEqual(config.maxConnections, 16)
        XCTAssertTrue(config.autoRetry)
    }

    func testClientCustomConfiguration() {
        let config = HTTP3Client.Configuration(
            settings: HTTP3Settings(maxTableCapacity: 4096),
            maxConcurrentRequests: 50,
            idleTimeout: .seconds(60),
            autoRetry: false,
            maxConnections: 8
        )
        XCTAssertEqual(config.settings.maxTableCapacity, 4096)
        XCTAssertEqual(config.maxConcurrentRequests, 50)
        XCTAssertFalse(config.autoRetry)
        XCTAssertEqual(config.maxConnections, 8)
    }

    func testClientBuildPattern() async {
        let client = HTTP3Client.build { config in
            config.maxConnections = 4
            config.settings = HTTP3Settings(maxTableCapacity: 2048)
        }
        let config = await client.configuration
        XCTAssertEqual(config.maxConnections, 4)
        XCTAssertEqual(config.settings.maxTableCapacity, 2048)
    }

    func testClientRejectsRequestsWhenClosed() async throws {
        let client = HTTP3Client()
        await client.close()

        let request = HTTP3Request(method: .get, url: "https://example.com/")
        do {
            _ = try await client.request(request)
            XCTFail("Expected error when client is closed")
        } catch {
            // Expected
        }
    }
}

// MARK: - HTTP/3 Server Tests

final class HTTP3ServerTests: XCTestCase {

    func testServerDefaultState() async {
        let server = HTTP3Server()
        let state = await server.state
        XCTAssertEqual(state, .idle)
        let isListening = await server.isListening
        XCTAssertFalse(isListening)
        let isStopped = await server.isStopped
        XCTAssertFalse(isStopped)
    }

    func testServerRejectsServeWithoutHandler() async {
        let server = HTTP3Server()

        do {
            let stream = AsyncStream<any QUICConnectionProtocol> { continuation in
                continuation.finish()
            }
            try await server.serve(connectionSource: stream)
            XCTFail("Expected error when no handler registered")
        } catch {
            // Expected
        }
    }

    func testServerWithCustomSettings() async {
        let settings = HTTP3Settings(maxTableCapacity: 8192)
        let server = HTTP3Server(settings: settings, maxConnections: 10)

        let serverSettings = await server.settings
        XCTAssertEqual(serverSettings.maxTableCapacity, 8192)
    }
}

// MARK: - HTTP/3 Trailer Tests

final class HTTP3TrailerTests: XCTestCase {

    // MARK: - Request Trailer Properties

    func testRequestTrailersDefaultNil() {
        let request = HTTP3Request(authority: "example.com")
        XCTAssertNil(request.trailers)
    }

    func testRequestWithTrailers() {
        let request = HTTP3Request(
            method: .post,
            authority: "example.com",
            path: "/upload",
            headers: [("content-type", "application/octet-stream")],
            body: Data("hello".utf8),
            trailers: [("checksum", "abc123"), ("x-request-id", "42")]
        )
        XCTAssertNotNil(request.trailers)
        XCTAssertEqual(request.trailers?.count, 2)
        XCTAssertEqual(request.trailers?[0].0, "checksum")
        XCTAssertEqual(request.trailers?[0].1, "abc123")
        XCTAssertEqual(request.trailers?[1].0, "x-request-id")
        XCTAssertEqual(request.trailers?[1].1, "42")
    }

    func testRequestTrailersInEquality() {
        let a = HTTP3Request(
            authority: "example.com",
            trailers: [("grpc-status", "0")]
        )
        let b = HTTP3Request(
            authority: "example.com",
            trailers: [("grpc-status", "0")]
        )
        let c = HTTP3Request(
            authority: "example.com",
            trailers: [("grpc-status", "1")]
        )
        let d = HTTP3Request(authority: "example.com")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testRequestTrailersInHashable() {
        let a = HTTP3Request(
            authority: "example.com",
            trailers: [("grpc-status", "0")]
        )
        let b = HTTP3Request(
            authority: "example.com",
            trailers: [("grpc-status", "0")]
        )
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - Response Trailer Properties

    func testResponseTrailersDefaultNil() {
        let response = HTTP3Response(status: 200)
        XCTAssertNil(response.trailers)
    }

    func testResponseWithTrailers() {
        let response = HTTP3Response(
            status: 200,
            headers: [("content-type", "text/plain")],
            body: Data("ok".utf8),
            trailers: [("grpc-status", "0"), ("grpc-message", "OK")]
        )
        XCTAssertNotNil(response.trailers)
        XCTAssertEqual(response.trailers?.count, 2)
        XCTAssertEqual(response.trailers?[0].0, "grpc-status")
        XCTAssertEqual(response.trailers?[1].0, "grpc-message")
    }

    func testResponseTrailersStatusAndHeadersComparable() {
        let a = HTTP3Response(status: 200, trailers: [("x-checksum", "sha256")])
        let b = HTTP3Response(status: 200, trailers: [("x-checksum", "sha256")])
        let c = HTTP3Response(status: 200, trailers: [("x-checksum", "md5")])
        let d = HTTP3Response(status: 200)

        // HTTP3Response is no longer Equatable/Hashable (body is HTTP3Body reference type).
        // Verify status and trailers are independently accessible and correct.
        XCTAssertEqual(a.status, b.status)
        XCTAssertEqual(a.trailers?.count, b.trailers?.count)
        XCTAssertEqual(a.trailers?[0].0, b.trailers?[0].0)
        XCTAssertEqual(a.trailers?[0].1, b.trailers?[0].1)

        XCTAssertNotEqual(a.trailers?[0].1, c.trailers?[0].1)
        XCTAssertNil(d.trailers)
    }

    // MARK: - Trailer Validation

    func testValidateTrailersAcceptsRegularHeaders() throws {
        let fields: [(String, String)] = [
            ("grpc-status", "0"),
            ("grpc-message", "OK"),
            ("x-custom", "value"),
        ]
        let validated = try validateTrailers(fields)
        XCTAssertEqual(validated.count, 3)
    }

    func testValidateTrailersAcceptsEmpty() throws {
        let validated = try validateTrailers([])
        XCTAssertTrue(validated.isEmpty)
    }

    func testValidateTrailersRejectsStatusPseudoHeader() {
        let fields: [(String, String)] = [
            (":status", "200"),
            ("grpc-status", "0"),
        ]
        XCTAssertThrowsError(try validateTrailers(fields)) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers(let name) = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
            XCTAssertEqual(name, ":status")
        }
    }

    func testValidateTrailersRejectsMethodPseudoHeader() {
        let fields: [(String, String)] = [
            (":method", "GET")
        ]
        XCTAssertThrowsError(try validateTrailers(fields)) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers(let name) = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
            XCTAssertEqual(name, ":method")
        }
    }

    func testValidateTrailersRejectsPathPseudoHeader() {
        XCTAssertThrowsError(try validateTrailers([(":path", "/")])) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
        }
    }

    func testValidateTrailersRejectsSchemePseudoHeader() {
        XCTAssertThrowsError(try validateTrailers([(":scheme", "https")])) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
        }
    }

    func testValidateTrailersRejectsAuthorityPseudoHeader() {
        XCTAssertThrowsError(try validateTrailers([(":authority", "example.com")])) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
        }
    }

    func testValidateTrailersRejectsUnknownPseudoHeader() {
        // Any name starting with ":" is a pseudo-header
        XCTAssertThrowsError(try validateTrailers([(":x-custom", "val")])) { error in
            guard case HTTP3TypeError.pseudoHeaderInTrailers = error else {
                XCTFail("Expected pseudoHeaderInTrailers, got \(error)")
                return
            }
        }
    }

    // MARK: - Trailer Frame Round-Trip (QPACK + HTTP3FrameCodec)

    func testTrailerQPACKRoundTrip() throws {
        let trailers: [(name: String, value: String)] = [
            ("grpc-status", "0"),
            ("grpc-message", "OK"),
        ]

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let encoded = encoder.encode(trailers)
        let decoded = try decoder.decode(encoded)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "grpc-status")
        XCTAssertEqual(decoded[0].value, "0")
        XCTAssertEqual(decoded[1].name, "grpc-message")
        XCTAssertEqual(decoded[1].value, "OK")
    }

    func testTrailerFrameEncodeDecodeRoundTrip() throws {
        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let trailers: [(name: String, value: String)] = [
            ("x-checksum", "sha256:abc123")
        ]

        // Encode trailers as a HEADERS frame (same as initial headers on the wire)
        let encodedBlock = encoder.encode(trailers)
        let frame = HTTP3Frame.headers(encodedBlock)
        let wireData = HTTP3FrameCodec.encode(frame)

        // Decode the frame
        let (decodedFrame, _) = try HTTP3FrameCodec.decode(from: wireData)
        guard case .headers(let headerBlock) = decodedFrame else {
            XCTFail("Expected HEADERS frame")
            return
        }

        // Decode the QPACK header block
        let decodedFields = try decoder.decode(headerBlock)
        XCTAssertEqual(decodedFields.count, 1)
        XCTAssertEqual(decodedFields[0].name, "x-checksum")
        XCTAssertEqual(decodedFields[0].value, "sha256:abc123")

        // Validate as trailers (no pseudo-headers)
        let validated = try validateTrailers(decodedFields)
        XCTAssertEqual(validated.count, 1)
    }

    // MARK: - Full Message Frame Sequence with Trailers

    func testRequestFrameSequenceWithTrailers() throws {
        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let request = HTTP3Request(
            method: .post,
            authority: "example.com",
            path: "/rpc",
            headers: [("content-type", "application/grpc")],
            body: Data([0x00, 0x00, 0x00, 0x00, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]),
            trailers: [("grpc-status", "0"), ("grpc-message", "OK")]
        )

        // Simulate the on-the-wire frame sequence:
        // 1. HEADERS (initial)
        let headerList = request.toHeaderList()
        let encodedHeaders = encoder.encode(headerList)
        let headersFrame = HTTP3FrameCodec.encode(.headers(encodedHeaders))

        // 2. DATA
        let dataFrame = HTTP3FrameCodec.encode(.data(request.body!))

        // 3. HEADERS (trailers)
        let encodedTrailers = encoder.encode(request.trailers!)
        let trailersFrame = HTTP3FrameCodec.encode(.headers(encodedTrailers))

        // Concatenate all frames (as they would appear on the wire)
        var wireData = Data()
        wireData.append(headersFrame)
        wireData.append(dataFrame)
        wireData.append(trailersFrame)

        // Decode all frames
        let (frames, _) = try HTTP3FrameCodec.decodeAll(from: wireData)
        XCTAssertEqual(frames.count, 3)

        // Frame 0: initial HEADERS
        guard case .headers(let block0) = frames[0] else {
            XCTFail("Expected HEADERS frame at index 0")
            return
        }
        let decodedHeaders = try decoder.decode(block0)
        XCTAssertTrue(
            decodedHeaders.contains(where: { $0.name == ":method" && $0.value == "POST" }))
        XCTAssertTrue(decodedHeaders.contains(where: { $0.name == ":path" && $0.value == "/rpc" }))

        // Frame 1: DATA
        guard case .data(let bodyPayload) = frames[1] else {
            XCTFail("Expected DATA frame at index 1")
            return
        }
        XCTAssertEqual(bodyPayload, request.body)

        // Frame 2: trailing HEADERS
        guard case .headers(let block2) = frames[2] else {
            XCTFail("Expected HEADERS frame at index 2")
            return
        }
        let decodedTrailers = try decoder.decode(block2)
        let validatedTrailers = try validateTrailers(decodedTrailers)
        XCTAssertEqual(validatedTrailers.count, 2)
        XCTAssertEqual(validatedTrailers[0].0, "grpc-status")
        XCTAssertEqual(validatedTrailers[0].1, "0")
        XCTAssertEqual(validatedTrailers[1].0, "grpc-message")
        XCTAssertEqual(validatedTrailers[1].1, "OK")
    }

    func testResponseFrameSequenceWithTrailers() throws {
        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let response = HTTP3Response(
            status: 200,
            headers: [("content-type", "application/grpc")],
            body: Data("response-body".utf8),
            trailers: [("grpc-status", "0")]
        )

        // Simulate on-the-wire frame sequence
        let encodedHeaders = encoder.encode(response.toHeaderList())
        let headersFrame = HTTP3FrameCodec.encode(.headers(encodedHeaders))
        let dataFrame = HTTP3FrameCodec.encode(.data(response.bufferedBodyData))
        let encodedTrailers = encoder.encode(response.trailers!)
        let trailersFrame = HTTP3FrameCodec.encode(.headers(encodedTrailers))

        var wireData = Data()
        wireData.append(headersFrame)
        wireData.append(dataFrame)
        wireData.append(trailersFrame)

        let (frames, _) = try HTTP3FrameCodec.decodeAll(from: wireData)
        XCTAssertEqual(frames.count, 3)

        // Verify initial HEADERS
        guard case .headers(let block0) = frames[0] else {
            XCTFail("Expected HEADERS")
            return
        }
        let headers = try decoder.decode(block0)
        XCTAssertTrue(headers.contains(where: { $0.name == ":status" && $0.value == "200" }))

        // Verify DATA
        guard case .data(let body) = frames[1] else {
            XCTFail("Expected DATA")
            return
        }
        XCTAssertEqual(body, response.bufferedBodyData)

        // Verify trailers
        guard case .headers(let block2) = frames[2] else {
            XCTFail("Expected trailing HEADERS")
            return
        }
        let trailers = try decoder.decode(block2)
        let validated = try validateTrailers(trailers)
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].0, "grpc-status")
        XCTAssertEqual(validated[0].1, "0")
    }

    // MARK: - No Trailers Case (Backward Compatibility)

    func testRequestWithoutTrailersUnchanged() throws {
        let request = HTTP3Request(
            method: .get,
            authority: "example.com",
            path: "/",
            headers: [("accept", "text/html")]
        )
        XCTAssertNil(request.trailers)

        // toHeaderList should not include trailers
        let headerList = request.toHeaderList()
        XCTAssertFalse(headerList.contains(where: { $0.name == "grpc-status" }))
    }

    func testResponseWithoutTrailersUnchanged() throws {
        let response = HTTP3Response(
            status: 200,
            headers: [("content-type", "text/html")],
            body: Data("<html></html>".utf8)
        )
        XCTAssertNil(response.trailers)
    }

    // MARK: - Error Description

    func testPseudoHeaderInTrailersErrorDescription() {
        let error = HTTP3TypeError.pseudoHeaderInTrailers(":status")
        XCTAssertTrue(error.description.contains(":status"))
        XCTAssertTrue(error.description.contains("trailer"))
    }

    // MARK: - Empty Trailers

    func testEmptyTrailersArrayTreatedAsPresent() {
        // An explicit empty array is distinct from nil
        let response = HTTP3Response(status: 200, trailers: [])
        XCTAssertNotNil(response.trailers)
        XCTAssertTrue(response.trailers!.isEmpty)
    }

    func testNilTrailersDifferentFromEmptyTrailers() {
        let a = HTTP3Response(status: 200, trailers: nil)
        let b = HTTP3Response(status: 200, trailers: [])
        // nil vs empty array are distinct values.
        // The key invariant: neither should produce a trailing HEADERS frame on the wire.
        XCTAssertNil(a.trailers)
        XCTAssertNotNil(b.trailers)
    }
}

// MARK: - Extended CONNECT Tests (RFC 9220)

final class HTTP3ExtendedConnectTests: XCTestCase {

    // MARK: - HTTP3Request Extended CONNECT Properties

    func testConnectProtocolDefaultNil() {
        let request = HTTP3Request(authority: "example.com")
        XCTAssertNil(request.connectProtocol)
        XCTAssertFalse(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
        XCTAssertFalse(request.isRegularConnect)
    }

    func testRegularConnect() {
        let request = HTTP3Request(
            method: .connect,
            authority: "proxy.example.com:8080"
        )
        XCTAssertNil(request.connectProtocol)
        XCTAssertEqual(request.method, .connect)
        XCTAssertTrue(request.isRegularConnect)
        XCTAssertFalse(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
    }

    func testExtendedConnect() {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        XCTAssertEqual(request.connectProtocol, "webtransport")
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertTrue(request.isWebTransportConnect)
        XCTAssertFalse(request.isRegularConnect)
    }

    func testExtendedConnectNonWebTransport() {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/tunnel",
            connectProtocol: "connect-tcp"
        )
        XCTAssertEqual(request.connectProtocol, "connect-tcp")
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
        XCTAssertFalse(request.isRegularConnect)
    }

    func testWebTransportConnectFactory() {
        let request = HTTP3Request.webTransportConnect(
            authority: "example.com:443",
            path: "/session"
        )
        XCTAssertEqual(request.method, .connect)
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "example.com:443")
        XCTAssertEqual(request.path, "/session")
        XCTAssertEqual(request.connectProtocol, "webtransport")
        XCTAssertTrue(request.isWebTransportConnect)
    }

    func testWebTransportConnectFactoryWithHeaders() {
        let request = HTTP3Request.webTransportConnect(
            authority: "example.com",
            path: "/wt",
            headers: [("origin", "https://example.com")]
        )
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.headers[0].0, "origin")
        XCTAssertEqual(request.headers[0].1, "https://example.com")
        XCTAssertTrue(request.isWebTransportConnect)
    }

    func testWebTransportConnectFactoryDefaults() {
        let request = HTTP3Request.webTransportConnect(authority: "example.com")
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.path, "/")
        XCTAssertTrue(request.headers.isEmpty)
    }

    // MARK: - Extended CONNECT Description

    func testExtendedConnectDescription() {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        XCTAssertEqual(
            request.description, "CONNECT https://example.com/wt [protocol=webtransport]")
    }

    func testRegularRequestDescription() {
        let request = HTTP3Request(method: .get, url: "https://example.com/path")
        XCTAssertEqual(request.description, "GET https://example.com/path")
    }

    func testRegularConnectDescription() {
        let request = HTTP3Request(method: .connect, authority: "proxy.example.com")
        // Regular CONNECT has no connectProtocol, so no [protocol=...] suffix
        XCTAssertFalse(request.description.contains("[protocol="))
    }

    // MARK: - Extended CONNECT Header Serialization (toHeaderList)

    func testExtendedConnectToHeaderList() {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport",
            headers: [("origin", "https://example.com")]
        )

        let headers = request.toHeaderList()

        // Extended CONNECT: :method, :protocol, :scheme, :authority, :path, then regular headers
        XCTAssertEqual(headers.count, 6)
        XCTAssertEqual(headers[0].name, ":method")
        XCTAssertEqual(headers[0].value, "CONNECT")
        XCTAssertEqual(headers[1].name, ":protocol")
        XCTAssertEqual(headers[1].value, "webtransport")
        XCTAssertEqual(headers[2].name, ":scheme")
        XCTAssertEqual(headers[2].value, "https")
        XCTAssertEqual(headers[3].name, ":authority")
        XCTAssertEqual(headers[3].value, "example.com")
        XCTAssertEqual(headers[4].name, ":path")
        XCTAssertEqual(headers[4].value, "/wt")
        XCTAssertEqual(headers[5].name, "origin")
        XCTAssertEqual(headers[5].value, "https://example.com")
    }

    func testRegularConnectToHeaderList() {
        let request = HTTP3Request(
            method: .connect,
            authority: "proxy.example.com:8080"
        )

        let headers = request.toHeaderList()

        // Regular CONNECT: only :method and :authority (no :scheme, :path)
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0].name, ":method")
        XCTAssertEqual(headers[0].value, "CONNECT")
        XCTAssertEqual(headers[1].name, ":authority")
        XCTAssertEqual(headers[1].value, "proxy.example.com:8080")
    }

    func testRegularRequestToHeaderList() {
        let request = HTTP3Request(
            method: .get,
            scheme: "https",
            authority: "example.com",
            path: "/index.html"
        )

        let headers = request.toHeaderList()

        // Regular request: :method, :scheme, :authority, :path
        XCTAssertEqual(headers.count, 4)
        XCTAssertEqual(headers[0].name, ":method")
        XCTAssertEqual(headers[0].value, "GET")
        XCTAssertEqual(headers[1].name, ":scheme")
        XCTAssertEqual(headers[1].value, "https")
        XCTAssertEqual(headers[2].name, ":authority")
        XCTAssertEqual(headers[2].value, "example.com")
        XCTAssertEqual(headers[3].name, ":path")
        XCTAssertEqual(headers[3].value, "/index.html")
    }

    // MARK: - Extended CONNECT Header Deserialization (fromHeaderList)

    func testExtendedConnectFromHeaderList() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "webtransport"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/wt"),
            ("origin", "https://example.com"),
        ]

        let request = try HTTP3Request.fromHeaderList(headers)
        XCTAssertEqual(request.method, .connect)
        XCTAssertEqual(request.connectProtocol, "webtransport")
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, "example.com")
        XCTAssertEqual(request.path, "/wt")
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertTrue(request.isWebTransportConnect)
        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.headers[0].0, "origin")
    }

    func testRegularConnectFromHeaderList() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":authority", "proxy.example.com:8080"),
        ]

        let request = try HTTP3Request.fromHeaderList(headers)
        XCTAssertEqual(request.method, .connect)
        XCTAssertNil(request.connectProtocol)
        XCTAssertEqual(request.authority, "proxy.example.com:8080")
        XCTAssertTrue(request.isRegularConnect)
        XCTAssertFalse(request.isExtendedConnect)
    }

    func testExtendedConnectFromHeaderListMissingScheme() {
        // Extended CONNECT requires :scheme
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "webtransport"),
            (":authority", "example.com"),
            (":path", "/wt"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .missingPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":scheme")
                } else {
                    XCTFail("Expected missingPseudoHeader(:scheme), got \(typeError)")
                }
            }
        }
    }

    func testExtendedConnectFromHeaderListMissingPath() {
        // Extended CONNECT requires :path
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "webtransport"),
            (":scheme", "https"),
            (":authority", "example.com"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .missingPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":path")
                } else {
                    XCTFail("Expected missingPseudoHeader(:path), got \(typeError)")
                }
            }
        }
    }

    func testExtendedConnectFromHeaderListMissingAuthority() {
        // Extended CONNECT requires :authority
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "webtransport"),
            (":scheme", "https"),
            (":path", "/wt"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .missingPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":authority")
                } else {
                    XCTFail("Expected missingPseudoHeader(:authority), got \(typeError)")
                }
            }
        }
    }

    func testProtocolWithNonConnectMethodRejected() {
        // :protocol MUST only be used with :method=CONNECT
        let headers: [(name: String, value: String)] = [
            (":method", "GET"),
            (":protocol", "webtransport"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/wt"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .protocolWithNonConnect(let proto) = typeError {
                    XCTAssertEqual(proto, "webtransport")
                } else {
                    XCTFail("Expected protocolWithNonConnect, got \(typeError)")
                }
            }
        }
    }

    func testDuplicateProtocolPseudoHeaderRejected() {
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "webtransport"),
            (":protocol", "connect-tcp"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":path", "/wt"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .duplicatePseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":protocol")
                } else {
                    XCTFail("Expected duplicatePseudoHeader, got \(typeError)")
                }
            }
        }
    }

    func testRegularConnectWithSchemeRejected() {
        // Regular CONNECT (no :protocol) MUST NOT include :scheme
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":scheme", "https"),
            (":authority", "proxy.example.com"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .connectWithForbiddenPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":scheme")
                } else {
                    XCTFail("Expected connectWithForbiddenPseudoHeader(:scheme), got \(typeError)")
                }
            }
        }
    }

    func testRegularConnectWithPathRejected() {
        // Regular CONNECT (no :protocol) MUST NOT include :path
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":authority", "proxy.example.com"),
            (":path", "/tunnel"),
        ]

        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .connectWithForbiddenPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":path")
                } else {
                    XCTFail("Expected connectWithForbiddenPseudoHeader(:path), got \(typeError)")
                }
            }
        }
    }

    func testRegularConnectWithSchemeAndPathRejected() {
        // Regular CONNECT MUST NOT include :scheme or :path
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":scheme", "https"),
            (":authority", "proxy.example.com"),
            (":path", "/tunnel"),
        ]

        // Should fail on the first forbidden pseudo-header (:scheme)
        XCTAssertThrowsError(try HTTP3Request.fromHeaderList(headers)) { error in
            if let typeError = error as? HTTP3TypeError {
                if case .connectWithForbiddenPseudoHeader(let name) = typeError {
                    XCTAssertEqual(name, ":scheme")
                } else {
                    XCTFail("Expected connectWithForbiddenPseudoHeader, got \(typeError)")
                }
            }
        }
    }

    // MARK: - Extended CONNECT Round-Trip (toHeaderList → fromHeaderList)

    func testExtendedConnectHeaderRoundTrip() throws {
        let original = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com:443",
            path: "/webtransport/session",
            connectProtocol: "webtransport",
            headers: [
                ("origin", "https://example.com"),
                ("sec-webtransport-http3-draft02", "1"),
            ]
        )

        let headerList = original.toHeaderList()
        var roundTripped = try HTTP3Request.fromHeaderList(headerList)
        roundTripped.body = original.body

        XCTAssertEqual(roundTripped.method, original.method)
        XCTAssertEqual(roundTripped.scheme, original.scheme)
        XCTAssertEqual(roundTripped.authority, original.authority)
        XCTAssertEqual(roundTripped.path, original.path)
        XCTAssertEqual(roundTripped.connectProtocol, original.connectProtocol)
        XCTAssertEqual(roundTripped.isExtendedConnect, original.isExtendedConnect)
        XCTAssertEqual(roundTripped.isWebTransportConnect, original.isWebTransportConnect)
        XCTAssertEqual(roundTripped.headers.count, original.headers.count)
        for (a, b) in zip(roundTripped.headers, original.headers) {
            XCTAssertEqual(a.0, b.0)
            XCTAssertEqual(a.1, b.1)
        }
    }

    func testRegularConnectHeaderRoundTrip() throws {
        let original = HTTP3Request(
            method: .connect,
            authority: "proxy.example.com:8080"
        )

        let headerList = original.toHeaderList()
        let roundTripped = try HTTP3Request.fromHeaderList(headerList)

        XCTAssertEqual(roundTripped.method, .connect)
        XCTAssertEqual(roundTripped.authority, "proxy.example.com:8080")
        XCTAssertNil(roundTripped.connectProtocol)
        XCTAssertTrue(roundTripped.isRegularConnect)
    }

    // MARK: - Extended CONNECT QPACK Round-Trip

    func testExtendedConnectQPACKRoundTrip() throws {
        let request = HTTP3Request.webTransportConnect(
            authority: "example.com",
            path: "/wt",
            headers: [("origin", "https://example.com")]
        )

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        let headerList = request.toHeaderList()
        let encoded = encoder.encode(headerList)
        let decoded = try decoder.decode(encoded)

        let roundTripped = try HTTP3Request.fromHeaderList(decoded)
        XCTAssertEqual(roundTripped.method, .connect)
        XCTAssertEqual(roundTripped.connectProtocol, "webtransport")
        XCTAssertEqual(roundTripped.scheme, "https")
        XCTAssertEqual(roundTripped.authority, "example.com")
        XCTAssertEqual(roundTripped.path, "/wt")
        XCTAssertTrue(roundTripped.isWebTransportConnect)
        XCTAssertEqual(roundTripped.headers.count, 1)
        XCTAssertEqual(roundTripped.headers[0].0, "origin")
    }

    // MARK: - Extended CONNECT Frame Round-Trip

    func testExtendedConnectFrameRoundTrip() throws {
        let request = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/webtransport",
            connectProtocol: "webtransport",
            headers: [("origin", "https://example.com")]
        )

        let encoder = QPACKEncoder()
        let decoder = QPACKDecoder()

        // Encode request to HEADERS frame
        let headerList = request.toHeaderList()
        let encodedHeaders = encoder.encode(headerList)
        let headersFrame = HTTP3Frame.headers(encodedHeaders)

        // Encode frame to wire bytes
        let wireData = HTTP3FrameCodec.encode(headersFrame)

        // Decode frame from wire bytes
        let (decodedFrame, _) = try HTTP3FrameCodec.decode(from: wireData)

        guard case .headers(let headerBlock) = decodedFrame else {
            XCTFail("Expected HEADERS frame, got \(decodedFrame)")
            return
        }

        // Decode QPACK headers
        let decodedHeaders = try decoder.decode(headerBlock)
        let decodedRequest = try HTTP3Request.fromHeaderList(decodedHeaders)

        XCTAssertEqual(decodedRequest.method, .connect)
        XCTAssertEqual(decodedRequest.connectProtocol, "webtransport")
        XCTAssertEqual(decodedRequest.scheme, "https")
        XCTAssertEqual(decodedRequest.authority, "example.com")
        XCTAssertEqual(decodedRequest.path, "/webtransport")
        XCTAssertTrue(decodedRequest.isWebTransportConnect)
    }

    // MARK: - Extended CONNECT Equality and Hashing

    func testExtendedConnectEquality() {
        let a = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        let b = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        XCTAssertEqual(a, b)
    }

    func testExtendedConnectInequalityDifferentProtocol() {
        let a = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        let b = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "connect-tcp"
        )
        XCTAssertNotEqual(a, b)
    }

    func testExtendedConnectInequalityVsRegularConnect() {
        let extended = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        let regular = HTTP3Request(
            method: .connect,
            authority: "example.com"
        )
        XCTAssertNotEqual(extended, regular)
    }

    func testExtendedConnectHashing() {
        let a = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        let b = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "webtransport"
        )
        XCTAssertEqual(a.hashValue, b.hashValue)

        // Different protocol → likely different hash
        let c = HTTP3Request(
            method: .connect,
            scheme: "https",
            authority: "example.com",
            path: "/wt",
            connectProtocol: "connect-tcp"
        )
        // Hash collision is possible but unlikely
        // Just verify they're computed without crashing
        _ = c.hashValue
    }

    // MARK: - Error Descriptions

    func testProtocolWithNonConnectErrorDescription() {
        let error = HTTP3TypeError.protocolWithNonConnect("webtransport")
        XCTAssertTrue(error.description.contains(":protocol"))
        XCTAssertTrue(error.description.contains("webtransport"))
        XCTAssertTrue(error.description.contains("CONNECT"))
    }

    func testConnectWithForbiddenPseudoHeaderErrorDescription() {
        let error = HTTP3TypeError.connectWithForbiddenPseudoHeader(":scheme")
        XCTAssertTrue(error.description.contains(":scheme"))
        XCTAssertTrue(error.description.contains("CONNECT"))
    }

    // MARK: - HTTP3Settings WebTransport Factory

    func testWebTransportSettingsFactory() {
        let settings = HTTP3Settings.webTransport(maxSessions: 4)
        XCTAssertTrue(settings.enableConnectProtocol)
        XCTAssertTrue(settings.enableH3Datagram)
        XCTAssertEqual(settings.webtransportMaxSessions, 4)
        XCTAssertTrue(settings.isWebTransportReady)
    }

    func testWebTransportSettingsFactoryDefaults() {
        let settings = HTTP3Settings.webTransport()
        XCTAssertTrue(settings.enableConnectProtocol)
        XCTAssertTrue(settings.enableH3Datagram)
        XCTAssertEqual(settings.webtransportMaxSessions, 1)
        XCTAssertTrue(settings.isWebTransportReady)
    }

    func testWebTransportSettingsNotReadyWithZeroSessions() {
        let settings = HTTP3Settings.webTransport(maxSessions: 0)
        XCTAssertTrue(settings.enableConnectProtocol)
        XCTAssertTrue(settings.enableH3Datagram)
        XCTAssertEqual(settings.webtransportMaxSessions, 0)
        XCTAssertFalse(settings.isWebTransportReady)
    }

    func testEffectiveSendLimitsExtendedConnect() {
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
        // Peer's max sessions is what we can open
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
            enableH3Datagram: false
        )
        let effective = local.effectiveSendLimits(peerSettings: peer)
        XCTAssertFalse(effective.enableConnectProtocol)
        XCTAssertFalse(effective.enableH3Datagram)
        XCTAssertNil(effective.webtransportMaxSessions)
    }

    // MARK: - Server Extended CONNECT Handler Registration

    func testServerHasNoExtendedConnectHandlerByDefault() async {
        let server = HTTP3Server()
        let hasHandler = await server.hasExtendedConnectHandler
        XCTAssertFalse(hasHandler)
    }

    func testServerRegisterExtendedConnectHandler() async {
        let server = HTTP3Server(settings: .webTransport())
        await server.onExtendedConnect { context in
            try await context.accept()
        }
        let hasHandler = await server.hasExtendedConnectHandler
        XCTAssertTrue(hasHandler)
    }

    func testServerWebTransportSettings() async {
        let settings = HTTP3Settings.webTransport(maxSessions: 8)
        let server = HTTP3Server(settings: settings)

        let serverSettings = await server.settings
        XCTAssertTrue(serverSettings.enableConnectProtocol)
        XCTAssertTrue(serverSettings.enableH3Datagram)
        XCTAssertEqual(serverSettings.webtransportMaxSessions, 8)
        XCTAssertTrue(serverSettings.isWebTransportReady)
    }

    // MARK: - Extended CONNECT with Various Protocols

    func testConnectTCPProtocol() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "connect-tcp"),
            (":scheme", "https"),
            (":authority", "target.example.com:80"),
            (":path", "/"),
        ]

        let request = try HTTP3Request.fromHeaderList(headers)
        XCTAssertEqual(request.connectProtocol, "connect-tcp")
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
    }

    func testConnectUDPProtocol() throws {
        let headers: [(name: String, value: String)] = [
            (":method", "CONNECT"),
            (":protocol", "connect-udp"),
            (":scheme", "https"),
            (":authority", "target.example.com:53"),
            (":path", "/.well-known/masque/udp/target.example.com/53/"),
        ]

        let request = try HTTP3Request.fromHeaderList(headers)
        XCTAssertEqual(request.connectProtocol, "connect-udp")
        XCTAssertTrue(request.isExtendedConnect)
        XCTAssertFalse(request.isWebTransportConnect)
    }

    // MARK: - Extended CONNECT Settings Encoding Round-Trip

    func testWebTransportSettingsEncodeDecodeRoundTrip() throws {
        let settings = HTTP3Settings.webTransport(maxSessions: 16)
        let frame = HTTP3Frame.settings(settings)
        let encoded = HTTP3FrameCodec.encode(frame)
        let (decoded, _) = try HTTP3FrameCodec.decode(from: encoded)

        guard case .settings(let decodedSettings) = decoded else {
            XCTFail("Expected SETTINGS frame")
            return
        }

        XCTAssertTrue(decodedSettings.enableConnectProtocol)
        XCTAssertTrue(decodedSettings.enableH3Datagram)
        XCTAssertEqual(decodedSettings.webtransportMaxSessions, 16)
        XCTAssertTrue(decodedSettings.isWebTransportReady)
    }

    // MARK: - ExtendedConnectContext Structure

    func testExtendedConnectContextProperties() async throws {
        // Verify that ExtendedConnectContext correctly stores request info
        let request = HTTP3Request.webTransportConnect(
            authority: "example.com",
            path: "/wt"
        )

        let tracker = AcceptTracker()
        let dummyConn = MinimalMockConnection()
        let h3Conn = HTTP3Connection(
            quicConnection: dummyConn,
            role: .server,
            settings: HTTP3Settings()
        )
        let context = ExtendedConnectContext(
            request: request,
            streamID: 4,
            stream: MockQUICStream(id: 4),
            connection: h3Conn,
            sendResponse: { response in
                XCTAssertEqual(response.status, 200)
                await tracker.markAccepted()
            }
        )

        XCTAssertEqual(context.request.method, .connect)
        XCTAssertEqual(context.request.connectProtocol, "webtransport")
        XCTAssertEqual(context.streamID, 4)
        XCTAssertTrue(context.request.isWebTransportConnect)

        try await context.accept()
        let wasCalled = await tracker.accepted
        XCTAssertTrue(wasCalled)
    }
}

// MARK: - HTTP/3 Body Tests

final class HTTP3BodyTests: XCTestCase {

    // MARK: - data() consumer

    func testDataConsumerReturnsSingleChunk() async throws {
        let payload = Data("hello world".utf8)
        let body = HTTP3Body(data: payload)
        let result = try await body.data()
        XCTAssertEqual(result, payload)
    }

    func testDataConsumerReturnsMultipleChunks() async throws {
        let chunks = [Data("chunk1".utf8), Data("chunk2".utf8), Data("chunk3".utf8)]
        let stream = AsyncStream<Data> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        let result = try await body.data()
        let expected = Data("chunk1chunk2chunk3".utf8)
        XCTAssertEqual(result, expected)
    }

    func testDataConsumerEmptyBody() async throws {
        let body = HTTP3Body(data: Data())
        let result = try await body.data()
        XCTAssertTrue(result.isEmpty)
    }

    func testDataConsumerEmptyStream() async throws {
        let stream = AsyncStream<Data> { $0.finish() }
        let body = HTTP3Body(stream: stream)
        let result = try await body.data()
        XCTAssertTrue(result.isEmpty)
    }

    func testDataConsumerLargePayload() async throws {
        let size = 1_000_000
        let payload = Data(repeating: 0xAB, count: size)
        let body = HTTP3Body(data: payload)
        let result = try await body.data()
        XCTAssertEqual(result.count, size)
        XCTAssertEqual(result, payload)
    }

    // MARK: - text() consumer

    func testTextConsumerReturnsString() async throws {
        let body = HTTP3Body(data: Data("hello".utf8))
        let result = try await body.text()
        XCTAssertEqual(result, "hello")
    }

    func testTextConsumerEmptyBody() async throws {
        let body = HTTP3Body(data: Data())
        let result = try await body.text()
        XCTAssertEqual(result, "")
    }

    func testTextConsumerMultiChunkUTF8() async throws {
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(Data("hel".utf8))
            continuation.yield(Data("lo ".utf8))
            continuation.yield(Data("world".utf8))
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        let result = try await body.text()
        XCTAssertEqual(result, "hello world")
    }

    func testTextConsumerThrowsInvalidUTF8() async {
        let invalidUTF8 = Data([0xC3, 0x28])  // invalid UTF-8 sequence
        let body = HTTP3Body(data: invalidUTF8)
        do {
            _ = try await body.text()
            XCTFail("Expected HTTP3BodyError.invalidUTF8")
        } catch let error as HTTP3BodyError {
            if case .invalidUTF8 = error {
                // expected
            } else {
                XCTFail("Expected .invalidUTF8, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.invalidUTF8, got \(type(of: error))")
        }
    }

    // MARK: - json() consumer

    func testJSONConsumerDecodesStruct() async throws {
        let json = #"{"name":"quiver","version":3}"#
        let body = HTTP3Body(data: Data(json.utf8))
        let result = try await body.json(TestJSONPayload.self)
        XCTAssertEqual(result.name, "quiver")
        XCTAssertEqual(result.version, 3)
    }

    func testJSONConsumerThrowsDecodingError() async {
        let body = HTTP3Body(data: Data("not json".utf8))
        do {
            _ = try await body.json(TestJSONPayload.self)
            XCTFail("Expected DecodingError")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("Expected DecodingError, got \(type(of: error))")
        }
    }

    func testJSONConsumerThrowsOnEmptyBody() async {
        let body = HTTP3Body(data: Data())
        do {
            _ = try await body.json(TestJSONPayload.self)
            XCTFail("Expected DecodingError")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("Expected DecodingError, got \(type(of: error))")
        }
    }

    func testJSONConsumerMultiChunk() async throws {
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(Data(#"{"name""#.utf8))
            continuation.yield(Data(#":"quiver","#.utf8))
            continuation.yield(Data(#""version":3}"#.utf8))
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        let result = try await body.json(TestJSONPayload.self)
        XCTAssertEqual(result.name, "quiver")
        XCTAssertEqual(result.version, 3)
    }

    // MARK: - stream() consumer

    func testStreamConsumerYieldsAllChunks() async throws {
        let chunks = [Data("a".utf8), Data("b".utf8), Data("c".utf8)]
        let stream = AsyncStream<Data> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        let rawStream = body.stream()
        var collected: [Data] = []
        for await chunk in rawStream {
            collected.append(chunk)
        }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected[0], Data("a".utf8))
        XCTAssertEqual(collected[1], Data("b".utf8))
        XCTAssertEqual(collected[2], Data("c".utf8))
    }

    func testStreamConsumerEmptyBody() async {
        let body = HTTP3Body(data: Data())
        let rawStream = body.stream()
        var count = 0
        for await _ in rawStream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    // MARK: - bodyTooLarge

    func testDataThrowsBodyTooLarge() async {
        let body = HTTP3Body(data: Data(repeating: 0xFF, count: 100))
        do {
            _ = try await body.data(maxBytes: 50)
            XCTFail("Expected HTTP3BodyError.bodyTooLarge")
        } catch let error as HTTP3BodyError {
            if case .bodyTooLarge(let limit) = error {
                XCTAssertEqual(limit, 50)
            } else {
                XCTFail("Expected .bodyTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.bodyTooLarge, got \(type(of: error))")
        }
    }

    func testTextThrowsBodyTooLarge() async {
        let body = HTTP3Body(data: Data(repeating: 0x41, count: 200))
        do {
            _ = try await body.text(maxBytes: 100)
            XCTFail("Expected HTTP3BodyError.bodyTooLarge")
        } catch let error as HTTP3BodyError {
            if case .bodyTooLarge(let limit) = error {
                XCTAssertEqual(limit, 100)
            } else {
                XCTFail("Expected .bodyTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.bodyTooLarge, got \(type(of: error))")
        }
    }

    func testJSONThrowsBodyTooLarge() async {
        let bigJSON = Data(String(repeating: " ", count: 200).utf8)
        let body = HTTP3Body(data: bigJSON)
        do {
            _ = try await body.json(TestJSONPayload.self, maxBytes: 10)
            XCTFail("Expected HTTP3BodyError.bodyTooLarge")
        } catch let error as HTTP3BodyError {
            if case .bodyTooLarge(let limit) = error {
                XCTAssertEqual(limit, 10)
            } else {
                XCTFail("Expected .bodyTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.bodyTooLarge, got \(type(of: error))")
        }
    }

    func testDataAtExactLimitDoesNotThrow() async throws {
        let body = HTTP3Body(data: Data(repeating: 0x41, count: 50))
        let result = try await body.data(maxBytes: 50)
        XCTAssertEqual(result.count, 50)
    }

    func testDataOneOverLimitThrows() async {
        let body = HTTP3Body(data: Data(repeating: 0x41, count: 51))
        do {
            _ = try await body.data(maxBytes: 50)
            XCTFail("Expected HTTP3BodyError.bodyTooLarge")
        } catch let error as HTTP3BodyError {
            if case .bodyTooLarge = error {
                // expected
            } else {
                XCTFail("Expected .bodyTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.bodyTooLarge, got \(type(of: error))")
        }
    }

    func testBodyTooLargeMultiChunk() async {
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(Data(repeating: 0x41, count: 30))
            continuation.yield(Data(repeating: 0x42, count: 30))
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        do {
            _ = try await body.data(maxBytes: 50)
            XCTFail("Expected HTTP3BodyError.bodyTooLarge")
        } catch let error as HTTP3BodyError {
            if case .bodyTooLarge(let limit) = error {
                XCTAssertEqual(limit, 50)
            } else {
                XCTFail("Expected .bodyTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTP3BodyError.bodyTooLarge, got \(type(of: error))")
        }
    }

    // MARK: - Error descriptions

    func testBodyTooLargeDescription() {
        let error = HTTP3BodyError.bodyTooLarge(limit: 1024)
        XCTAssertEqual(error.description, "HTTP3Body exceeded maximum allowed size of 1024 bytes.")
    }

    func testInvalidUTF8Description() {
        let error = HTTP3BodyError.invalidUTF8
        XCTAssertEqual(error.description, "HTTP3Body data is not valid UTF-8.")
    }

    // MARK: - Init paths

    func testInitWithDataSingleChunk() async throws {
        let payload = Data("test".utf8)
        let body = HTTP3Body(data: payload)
        let result = try await body.data()
        XCTAssertEqual(result, payload)
    }

    func testInitWithEmptyDataProducesEmptyStream() async throws {
        let body = HTTP3Body(data: Data())
        let stream = body.stream()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testInitWithStreamPassesThrough() async throws {
        let expected = Data("passthrough".utf8)
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(expected)
            continuation.finish()
        }
        let body = HTTP3Body(stream: stream)
        let result = try await body.data()
        XCTAssertEqual(result, expected)
    }

    // MARK: - HTTP3Response body access

    func testResponseBodyDataConsumer() async throws {
        let payload = Data("response body".utf8)
        let response = HTTP3Response(status: 200, body: payload)
        let result = try await response.body().data()
        XCTAssertEqual(result, payload)
    }

    func testResponseBodyTextConsumer() async throws {
        let response = HTTP3Response(status: 200, body: Data("hello text".utf8))
        let result = try await response.body().text()
        XCTAssertEqual(result, "hello text")
    }

    func testResponseBodyJSONConsumer() async throws {
        let json = #"{"name":"resp","version":1}"#
        let response = HTTP3Response(status: 200, body: Data(json.utf8))
        let result = try await response.body().json(TestJSONPayload.self)
        XCTAssertEqual(result.name, "resp")
        XCTAssertEqual(result.version, 1)
    }

    func testResponseEmptyBody() async throws {
        let response = HTTP3Response(status: 204)
        let result = try await response.body().data()
        XCTAssertTrue(result.isEmpty)
    }

    func testResponseBodyStreamConsumer() async throws {
        let payload = Data("streamed".utf8)
        let response = HTTP3Response(status: 200, body: payload)
        let stream = response.body().stream()
        var collected = Data()
        for await chunk in stream {
            collected.append(chunk)
        }
        XCTAssertEqual(collected, payload)
    }

}

/// Decodable helper for JSON consumer tests.
private struct TestJSONPayload: Decodable, Equatable {
    let name: String
    let version: Int
}

// MARK: - Test Helpers

/// Actor for tracking mutable state across Sendable closures in tests.
private actor AcceptTracker {
    var accepted = false
    func markAccepted() { accepted = true }
}

// MARK: - Minimal Mock Connection for Testing

/// A minimal mock QUICConnectionProtocol for unit testing context structures.
/// Only provides the necessary interface; actual I/O is not tested here.
private final class MinimalMockConnection: QUICConnectionProtocol, @unchecked Sendable {
    var localAddress: SocketAddress? { nil }
    var remoteAddress: SocketAddress { SocketAddress(ipAddress: "127.0.0.1", port: 4433) }
    var isEstablished: Bool { true }
    var is0RTTAccepted: Bool { false }

    var incomingStreams: AsyncStream<any QUICStreamProtocol> {
        AsyncStream { $0.finish() }
    }
    var incomingDatagrams: AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    func waitForHandshake() async throws {}
    func openStream() async throws -> any QUICStreamProtocol { MockQUICStream(id: 0) }
    func openUniStream() async throws -> any QUICStreamProtocol { MockQUICStream(id: 2) }
    func sendDatagram(_ data: Data) async throws {}
    func close(error: UInt64?) async {}
    func close(applicationError errorCode: UInt64, reason: String) async {}
}

// MARK: - Mock QUIC Stream for Testing

/// A minimal mock QUICStreamProtocol for unit testing context structures.
/// Only provides the necessary interface; actual I/O is not tested here.
private final class MockQUICStream: QUICStreamProtocol, @unchecked Sendable {
    let id: UInt64
    var isUnidirectional: Bool { false }
    var isBidirectional: Bool { true }

    private var writtenData: [Data] = []
    private var closed = false

    init(id: UInt64) {
        self.id = id
    }

    func read() async throws -> Data { Data() }
    func read(maxBytes: Int) async throws -> Data { Data() }
    func write(_ data: Data) async throws { writtenData.append(data) }
    func closeWrite() async throws { closed = true }
    func reset(errorCode: UInt64) async {}
    func stopSending(errorCode: UInt64) async throws {}
}
