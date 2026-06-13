# WebTransport Over HTTP/3 Contract

Pummelchen targets WebTransport over HTTP/3 for near-realtime client/server control traffic. The implementation follows `draft-ietf-webtrans-http3-15` and keeps the protocol constants in `PummelchenCore/WebTransportH3.swift` so the macOS client and Debian server use one shared contract.

## Required Wire Features

A production WebTransport session is only valid when the server proves all of the following:

- HTTP/3 SETTINGS include `SETTINGS_WT_ENABLED > 0`.
- HTTP/3 SETTINGS include `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.
- HTTP/3 SETTINGS include `SETTINGS_H3_DATAGRAM = 1`.
- QUIC transport parameters include `max_datagram_frame_size > 0`.
- QUIC transport parameters include `reset_stream_at`.
- The control session is established with Extended CONNECT and `:protocol = webtransport-h3`.

The Swift server exposes `/api/v1/transport/webtransport/preflight` so clients and operators can verify whether the live edge is ready before retiring the current HTTP/3 long-poll control path.

## nginx Role

nginx remains the HTTPS, static download, and HTTP/3 public edge. Current nginx HTTP/3 support does not expose the WebTransport session primitives the Swift app needs: Extended CONNECT dispatch, HTTP Datagram/Capsule forwarding, QUIC datagram access, or WebTransport stream ownership.

Until nginx exposes those primitives, it can only help with ordinary HTTP/3 APIs and public downloads. A real WebTransport cutover requires one of these production paths:

- the Swift server directly owns the QUIC/H3/WebTransport UDP listener and certificate material;
- nginx gains a WebTransport upstream/proxy feature that forwards sessions to the Swift app;
- a dedicated QUIC/H3 terminator is introduced, which is currently outside the one Swift service architecture.

## Retirement Gate

The existing authenticated control APIs must not be removed until:

- `/api/v1/transport/webtransport/preflight` returns `ready = true`;
- the macOS client can open a WebTransport session and record a successful negotiated session;
- control events `release_available`, `sync_required`, `defaults_changed`, and `client_sync_requested` are delivered over WebTransport;
- acknowledgements, heartbeats, inventory, diagnostics, and sync run reports are sent over the same WebTransport control plane;
- tests cover update latency, reconnect, missed-event replay, corrupt download repair, and blocked-UDP fallback behavior.
