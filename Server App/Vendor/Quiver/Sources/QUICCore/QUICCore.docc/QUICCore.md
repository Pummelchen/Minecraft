# ``QUICCore``

Core QUIC protocol types with no I/O dependencies.

## Overview

QUICCore provides the fundamental data types for the QUIC protocol as defined in RFC 9000. This module has no external dependencies and can be used independently for packet parsing and frame encoding/decoding.

### Wire Format Support

QUICCore implements QUIC's wire format specifications:

- **Variable-length integers (Varint)** - Compact encoding for integers up to 2^62
- **Packet headers** - Long and short header formats
- **Frames** - All 19 frame types defined in RFC 9000

## Topics

### Packet Types

- ``PacketHeader``
- ``LongHeader``
- ``ShortHeader``
- ``ConnectionID``
- ``QUICVersion``

### Frame Types

- ``Frame``
- ``StreamFrame``
- ``AckFrame``
- ``CryptoFrame``

### Encoding

- ``Varint``
- ``DataReader``
- ``DataWriter``
- ``PacketEncoder``
- ``PacketDecoder``
- ``StandardFrameCodec``

### Transport Parameters

- ``TransportParameters``

### Errors

- ``QUICError``
- ``TransportErrorCode``

### QLOG Support

- ``QLOGEvent``
- ``QLOGConfiguration``
