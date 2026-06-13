# TLS Security Model

> **Module**: `QUICCrypto` — TLS 1.3 Integration for QUIC
> **RFCs**: RFC 8446 (TLS 1.3), RFC 9001 (QUIC-TLS), RFC 5280 (X.509)

## Overview

This document describes the TLS security model implemented in `QUICCrypto`,
including trust modes, certificate validation, revocation checking, and the
system trust store integration. It serves as a reference for developers
integrating this library into production systems.

---

## 1. Trust Modes

The TLS stack supports several trust modes, controlled primarily by
`TLSConfiguration` properties. Each mode represents a different trade-off
between security and flexibility.

### 1.1 Full X.509 Chain Validation (`verifyPeer = true`)

**Default and recommended for production.**

When `verifyPeer` is `true` (the default), the TLS stack performs full
RFC 5280-compliant certificate chain validation:

1. **Chain building**: Constructs a chain from the peer's leaf certificate
   to a trusted root, using provided intermediates and trusted roots.
2. **Signature verification**: Verifies cryptographic signatures at each
   link in the chain (leaf → intermediate → root).
3. **Validity period**: Checks `notBefore` / `notAfter` dates.
4. **BasicConstraints**: Ensures intermediate certificates are marked as CAs.
5. **KeyUsage**: Verifies `keyCertSign` for CAs, `digitalSignature` for leaves.
6. **Extended Key Usage (EKU)**: Optionally requires specific EKU (e.g., `serverAuth`).
7. **Subject Alternative Name (SAN)**: Verifies hostname against SAN DNS names.
8. **Name Constraints**: Enforces permitted/excluded DNS domain constraints from CAs.
9. **Trust verification**: Multi-factor matching against trusted roots using:
   - Subject Public Key Info (SPKI) DER — cryptographic identity
   - Subject DN — organizational identity
   - AKI/SKI cross-check — issuer linkage (when available)

```swift
// Example: Production client configuration
var config = TLSConfiguration.client(serverName: "example.com")
try config.useSystemTrustStore()  // Load OS trust store
// config.verifyPeer is true by default
```

### 1.2 Public Key Pinning (`expectedPeerPublicKey`)

**For simplified verification without full X.509 parsing.**

When `expectedPeerPublicKey` is set, the TLS stack verifies that the peer's
certificate contains the expected public key (x963 format for ECDSA). This
bypasses full chain validation but still verifies the `CertificateVerify`
signature.

- **Use case**: IoT devices, internal services with known keys.
- **Trade-off**: No chain validation, no revocation checking.
- **Risk**: Key rotation requires updating the pinned key in all clients.

```swift
var config = TLSConfiguration.client(serverName: "internal.corp.com")
config.expectedPeerPublicKey = knownServerPublicKeyX963
```

### 1.3 Self-Signed Certificates (`allowSelfSigned = true`)

**For development and testing only.**

When `allowSelfSigned` is `true`, self-signed certificates are accepted
without a trusted root. The certificate's self-signature is still verified.

- **Use case**: Development environments, local testing.
- **Risk**: No third-party trust anchor; any self-signed cert is accepted.

```swift
var config = TLSConfiguration.client(serverName: "localhost")
config.allowSelfSigned = true
```

### 1.4 No Verification (`verifyPeer = false`)

**Never use in production.**

Disables all certificate validation and signature verification. The peer's
certificate (if any) is ignored entirely.

- **Use case**: Debugging, performance testing.
- **Risk**: Vulnerable to man-in-the-middle attacks.

```swift
var config = TLSConfiguration.client(serverName: "test.local")
config.verifyPeer = false  // ⚠️ INSECURE
```

---

## 2. Trusted Root Certificate Sources

The TLS stack resolves trusted roots in the following priority order:

| Priority | Source | Property |
|----------|--------|----------|
| 1 | Explicit parsed certificates | `trustedRootCertificates: [X509Certificate]?` |
| 2 | DER-encoded CA bytes | `trustedCACertificates: [Data]?` |
| 3 | System trust store (via `effectiveTrustedRootsWithSystemFallback`) | Loaded from OS |

### 2.1 Explicit Roots

Provide parsed `X509Certificate` objects directly:

```swift
var config = TLSConfiguration.client(serverName: "example.com")
config.trustedRootCertificates = [myRootCA]
```

### 2.2 DER-Encoded Roots

Provide raw DER bytes; parsed on demand by `effectiveTrustedRoots`:

```swift
var config = TLSConfiguration.client(serverName: "example.com")
config.trustedCACertificates = [rootCADERData]
```

### 2.3 PEM File Loading

Load from PEM files (common for CA bundles):

```swift
var config = TLSConfiguration.client(serverName: "example.com")
try config.loadTrustedCAs(fromPEMFile: "/path/to/ca-bundle.crt")
```

### 2.4 System Trust Store

Load the operating system's trusted root certificates:

```swift
var config = TLSConfiguration.client(serverName: "example.com")
try config.useSystemTrustStore()
```

**Platform support:**

| Platform | Method | Notes |
|----------|--------|-------|
| macOS | `SecTrustCopyAnchorCertificates` | Loads from System Keychain |
| Linux | Filesystem paths | `/etc/ssl/certs/ca-certificates.crt` (Debian), `/etc/pki/tls/certs/ca-bundle.crt` (RHEL), etc. |
| iOS/tvOS/watchOS | Not enumerable | Use `loadTrustedCAs(fromPEMFile:)` or bundle CAs with the app |

The system trust store is cached after first load. Use `SystemTrustStore.clearCache()`
to force a reload, or pass `forceReload: true`.

### 2.5 `effectiveTrustedRoots` vs `effectiveTrustedRootsWithSystemFallback`

- **`effectiveTrustedRoots`**: Resolves from explicit roots → DER roots → empty.
  Does **not** fall back to the system trust store. Use this when you want
  explicit control over which roots are trusted.

- **`effectiveTrustedRootsWithSystemFallback`**: Same resolution order, but
  additionally falls back to the system trust store when `verifyPeer` is `true`
  and no explicit roots are configured. Use this for convenience in production
  where system roots should be the default.

---

## 3. Certificate Revocation

### 3.1 Revocation Check Modes

Configured via `TLSConfiguration.revocationCheckMode`:

| Mode | Description | Latency Impact | Privacy |
|------|-------------|---------------|---------|
| `.none` | No revocation checking (default) | None | N/A |
| `.ocspStapling` | Server-provided OCSP response only | None | Good (no client→OCSP leak) |
| `.ocsp(allowOnlineCheck:, softFail:)` | OCSP with optional online check | Medium | OCSP responder sees client IP |
| `.crl(cacheDirectory:, softFail:)` | CRL-based checking | High (initial) | CRL endpoint sees client IP |
| `.bestEffort` | Try OCSP stapling → OCSP online → CRL, soft-fail | Variable | Variable |

### 3.2 Soft-Fail Behavior

When `softFail` is `true` (or `.bestEffort` mode):
- Network errors during revocation checks are treated as **non-fatal**.
- The connection proceeds even if the OCSP responder or CRL endpoint is unreachable.
- Status `.undetermined` is returned instead of throwing an error.

When `softFail` is `false`:
- Network errors during revocation checks are **fatal**.
- The handshake fails if revocation status cannot be determined.

### 3.3 Architecture

Revocation checking is performed **asynchronously, outside the state machine lock**:

1. Synchronous chain validation runs inside the `Mutex`-protected state machine.
2. If a certificate message was processed and revocation is configured,
   `performRevocationCheckIfNeeded()` runs after the lock is released.
3. This prevents blocking the state machine during network I/O (OCSP/CRL fetches).

### 3.4 HTTP Client

Online revocation checks require an `HTTPClient` implementation:

```swift
var config = TLSConfiguration.client(serverName: "example.com")
config.revocationCheckMode = .ocsp(allowOnlineCheck: true, softFail: true)
config.revocationHTTPClient = MyHTTPClient()  // Implements HTTPClient protocol
```

The `HTTPClient` protocol requires:
- `post(url:body:contentType:) async throws -> (Data, Int)` — for OCSP requests
- `get(url:) async throws -> (Data, Int)` — for CRL downloads

---

## 4. Mutual TLS (mTLS)

### 4.1 Server-Side Configuration

```swift
var config = TLSConfiguration()
config.requireClientCertificate = true
config.trustedRootCertificates = [clientCARoot]
// Server's own certificate and key
config.signingKey = serverKey
config.certificateChain = [serverCertDER]
```

### 4.2 Client-Side Behavior

When the server sends a `CertificateRequest`:
- The client's `clientCertificateRequested` flag is set.
- The client sends its `Certificate` and `CertificateVerify` messages.
- The client must have `signingKey` and `certificateChain` configured.

### 4.3 Custom Certificate Validation

The `certificateValidator` callback allows application-specific validation:

```swift
config.certificateValidator = { certChain in
    guard let leafDER = certChain.first else {
        throw MyError.noCertificate
    }
    // Extract and return application-specific identity
    return try extractPeerIdentity(from: leafDER)
}
```

The returned value is stored in `HandshakeContext.validatedPeerInfo` and
accessible after handshake completion.

---

## 5. Session Resumption and 0-RTT

### 5.1 Session Tickets (PSK)

After a successful handshake, the server may issue a `NewSessionTicket`.
The client can use this ticket for session resumption in subsequent connections:

```swift
// Client: configure resumption
handler.configureResumption(ticket: savedTicket, attemptEarlyData: true)
```

### 5.2 0-RTT Early Data

When `attemptEarlyData` is `true` and the server supports it:
- The client sends early data using the `client_early_traffic_secret`.
- The server may accept or reject 0-RTT.
- Check `is0RTTAccepted` after receiving `EncryptedExtensions`.

**Security considerations:**
- 0-RTT data is **not forward-secret** (uses the PSK).
- 0-RTT data is **replayable** — use `ReplayProtection` on the server.

```swift
// Server: enable replay protection
config.replayProtection = ReplayProtection(windowSize: 1000)
```

---

## 6. Migration Guide

### 6.1 From `QUICConfiguration` TLS Fields to `TLSConfiguration`

The following fields on `QUICConfiguration` are **legacy** and not consumed
by `TLS13Handler`. Migrate to `TLSConfiguration`:

| Legacy (`QUICConfiguration`) | Migration (`TLSConfiguration`) |
|------------------------------|-------------------------------|
| `certificatePath` | `TLSConfiguration.certificatePath` or `.server(certificatePath:privateKeyPath:)` |
| `privateKeyPath` | `TLSConfiguration.privateKeyPath` or `.server(certificatePath:privateKeyPath:)` |
| `verifyPeer` | `TLSConfiguration.verifyPeer` |
| `alpn` | `TLSConfiguration.alpnProtocols` (for TLS-level ALPN) |

### 6.2 Using Factory Methods

**Before (legacy):**
```swift
var config = QUICConfiguration()
config.certificatePath = "/path/to/cert.pem"  // ⚠️ Not consumed by TLS stack
config.privateKeyPath = "/path/to/key.pem"    // ⚠️ Not consumed by TLS stack
config.verifyPeer = true                       // ⚠️ Not consumed by TLS stack
```

**After (recommended):**
```swift
// Production with TLSConfiguration
let tlsConfig = try TLSConfiguration.server(
    certificatePath: "/path/to/cert.pem",
    privateKeyPath: "/path/to/key.pem"
)
let quicConfig = QUICConfiguration.production {
    TLS13Handler(configuration: tlsConfig)
}
```

### 6.3 Adding System Trust Store

**Before:**
```swift
// Had to manually provide CA certificates
var config = TLSConfiguration.client(serverName: "example.com")
// ⚠️ No trusted roots → validation would fail
```

**After:**
```swift
var config = TLSConfiguration.client(serverName: "example.com")
try config.useSystemTrustStore()  // ✅ Loads OS-level trusted roots
```

Or for automatic fallback:
```swift
var config = TLSConfiguration.client(serverName: "example.com")
let roots = config.effectiveTrustedRootsWithSystemFallback
// Automatically falls back to system trust store
```

### 6.4 Enabling Revocation Checking

```swift
var config = TLSConfiguration.client(serverName: "example.com")
try config.useSystemTrustStore()
config.revocationCheckMode = .bestEffort  // Recommended default
config.revocationHTTPClient = myHTTPClient // Required for online checks
```

---

## 7. Security Recommendations

### Production Deployments

1. **Always set `verifyPeer = true`** (default).
2. **Use system trust store** or provide explicit trusted roots.
3. **Enable revocation checking** (at least `.bestEffort` or `.ocspStapling`).
4. **Set `serverName`** for hostname verification.
5. **Enable replay protection** on servers accepting 0-RTT.
6. **Use `QUICConfiguration.production()`** factory method.

### Development / Testing

1. Use `allowSelfSigned = true` for local development.
2. Use `QUICConfiguration.development()` factory method.
3. Use `MockTLSProvider` only in `#if DEBUG` guarded test code.
4. Never deploy with `verifyPeer = false`.

### Key Rotation

1. Plan for CA certificate rotation by supporting multiple trusted roots.
2. Use `addSystemTrustStore()` to trust both custom and system CAs.
3. For pinned keys (`expectedPeerPublicKey`), implement a rotation mechanism.

---

## 8. Threat Model Summary

| Threat | Mitigation | Configuration |
|--------|-----------|---------------|
| MITM (forged certificate) | Chain validation + trusted roots | `verifyPeer = true` + trusted roots |
| MITM (compromised CA) | Certificate pinning | `expectedPeerPublicKey` |
| Revoked certificate | Revocation checking | `revocationCheckMode != .none` |
| Replay attack (0-RTT) | Replay protection | `replayProtection` on server |
| Hostname spoofing | SAN/CN verification | `serverName` set on client |
| Weak key exchange | Modern groups only | `supportedGroups = [.x25519, .secp256r1]` |
| Downgrade attack | TLS 1.3 only | No TLS 1.2 fallback supported |

---

## References

- [RFC 8446 — TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html)
- [RFC 9001 — QUIC-TLS](https://www.rfc-editor.org/rfc/rfc9001.html)
- [RFC 5280 — X.509 PKI](https://www.rfc-editor.org/rfc/rfc5280.html)
- [RFC 6960 — OCSP](https://www.rfc-editor.org/rfc/rfc6960.html)
- [RFC 6066 — TLS Extensions (Certificate Status Request)](https://www.rfc-editor.org/rfc/rfc6066.html)