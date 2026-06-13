# WebTransport Over HTTP/3 Contract

Pummelchen targets WebTransport over HTTP/3 for near-realtime client/server control traffic. The implementation follows `draft-ietf-webtrans-http3-15`, the latest active IETF working group draft checked for this project, and keeps the protocol constants in `PummelchenCore/WebTransportH3.swift` so the macOS client and Debian server use one shared contract.

## Required Wire Features

A production WebTransport session is only valid when the server proves all of the following:

- HTTP/3 SETTINGS include `SETTINGS_WT_ENABLED > 0`.
- HTTP/3 SETTINGS include `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.
- HTTP/3 SETTINGS include `SETTINGS_H3_DATAGRAM = 1`.
- QUIC transport parameters include `max_datagram_frame_size > 0`.
- QUIC transport parameters include `reset_stream_at`.
- The control session is established with Extended CONNECT and `:protocol = webtransport-h3`.

The Swift server exposes `/api/v1/transport/webtransport/preflight` so clients and operators can verify whether the live Swift-owned WebTransport endpoint is ready. Once ready, the macOS client uses the dedicated WebTransport session engine as its primary control plane.

## Option 2 Deployment

WebTransport is deliberately kept away from nginx.

- nginx keeps serving the website, normal HTTPS APIs, and release downloads.
- The Swift server app owns the WebTransport control endpoint on its own UDP port.
- Default public session URL: `https://pummelchen.91.99.176.243.nip.io:7443/webtransport/v1/control`.
- The client discovers the session URL through `/api/v1/transport/webtransport/preflight`.
- The preflight payload must include `uses_nginx = false`.

The Swift server can advertise a different endpoint with:

```text
pummelchen-server serve --project-root <repo> --webtransport-host <host> --webtransport-port 7443 --webtransport-path /webtransport/v1/control
```

## nginx Role

nginx remains the HTTPS, static download, and optional ordinary HTTP/3 public edge. It is not in the WebTransport path. Current nginx HTTP/3 support does not expose the WebTransport session primitives the Swift app needs: Extended CONNECT dispatch, HTTP Datagram/Capsule forwarding, QUIC datagram access, or WebTransport stream ownership.

The chosen production path is Swift-owned QUIC/H3/WebTransport on the dedicated UDP port. nginx can keep serving ordinary HTTP traffic without affecting the WebTransport control plane.

## Session Engine

The Swift session engine is implemented by `PummelchenWebTransportService` on the server and `ClientWebTransportControlChannel` on macOS. The service uses QUIC/TLS production mode, HTTP/3 Extended CONNECT, WebTransport bidirectional streams, and QUIC datagram support. Requests are JSON control frames on WebTransport streams; large release files still stay on nginx download URLs and are verified by SHA-256 after download.

Supported stream actions:

- `fetch_events`
- `ack_event`
- `register_client`
- `status_report`
- `sync_run_report`
- `heartbeat_report`
- `inventory_upload`
- `diagnostics_upload`
- `defaults_events_upload`

The old authenticated HTTPS control APIs remain available as an operational fallback for blocked UDP/QUIC networks and for ordinary HTTP status/report compatibility. The client tries WebTransport first whenever preflight reports `ready = true`; if the QUIC session fails, it falls back per message so acknowledgements and client health data are not lost.

## Production Gate

The deployment is production-ready when:

- `/api/v1/transport/webtransport/preflight` returns `ready = true`;
- the Swift server app logs `pummelchen_webtransport=ready`;
- the macOS client can open a WebTransport session to the advertised URL;
- control events `release_available`, `sync_required`, `defaults_changed`, and `client_sync_requested` are delivered over WebTransport;
- acknowledgements, heartbeat/status reports, inventory, diagnostics, sync run reports, and defaults reports are accepted over WebTransport;
- release downloads continue through nginx and pass SHA-256 manifest verification.
