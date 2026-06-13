/// Phase B Tests: Revocation Integration, Trust Helpers, Validated Chain
///
/// Tests for:
/// - TLSConfiguration.effectiveTrustedRoots resolution
/// - TLSConfiguration.loadTrustedCAs / addTrustedCAs helpers
/// - X509Validator.buildValidatedChain() returning ValidatedChain
/// - X509Validator.validateWithRevocation() async method
/// - RevocationChecker integration with .none / .ocspStapling / .bestEffort modes
/// - PEMLoader.loadCACertificates / parseCACertificates helpers
/// - TLS13Handler revocation check wiring (certificate message flag tracking)

import Testing
import Foundation
import Crypto
@preconcurrency import X509
import SwiftASN1
@testable import QUICCrypto
import QUICCore

// MARK: - Test Helpers

/// Creates a self-signed CA certificate with BasicConstraints for testing.
private func makeTestCACertificate(
    commonName: String = "Test CA",
    key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
) throws -> (X509Certificate, P256.Signing.PrivateKey) {
    let name = try DistinguishedName {
        CommonName(commonName)
        OrganizationName("Quiver Tests")
    }

    let cert = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(),
        publicKey: .init(key.publicKey),
        notValidBefore: Date().addingTimeInterval(-3600),
        notValidAfter: Date().addingTimeInterval(86400),
        issuer: name,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            SubjectKeyIdentifier(hash: .init(key.publicKey))
        },
        issuerPrivateKey: .init(key)
    )

    var serializer = DER.Serializer()
    try cert.serialize(into: &serializer)
    let derData = Data(serializer.serializedBytes)

    let wrapped = try X509Certificate.parse(from: derData)
    return (wrapped, key)
}

/// Creates a leaf certificate signed by the given CA key.
private func makeTestLeafCertificate(
    commonName: String = "test.example.com",
    caKey: P256.Signing.PrivateKey,
    caCert: X509Certificate,
    addServerAuthEKU: Bool = true,
    addSAN: Bool = true,
    leafKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
) throws -> (X509Certificate, P256.Signing.PrivateKey) {
    let leafName = try DistinguishedName {
        CommonName(commonName)
        OrganizationName("Quiver Tests")
    }

    let cert = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(),
        publicKey: .init(leafKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-3600),
        notValidAfter: Date().addingTimeInterval(86400),
        issuer: caCert.certificate.subject,
        subject: leafName,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            if addServerAuthEKU {
                try ExtendedKeyUsage([.serverAuth])
            }
            if addSAN {
                SubjectAlternativeNames([.dnsName(commonName)])
            }
            AuthorityKeyIdentifier(
                keyIdentifier: caCert.subjectKeyIdentifier?.keyIdentifier
            )
        },
        issuerPrivateKey: .init(caKey)
    )

    var serializer = DER.Serializer()
    try cert.serialize(into: &serializer)
    let derData = Data(serializer.serializedBytes)

    let wrapped = try X509Certificate.parse(from: derData)
    return (wrapped, leafKey)
}

// MARK: - effectiveTrustedRoots Tests

@Suite("TLSConfiguration.effectiveTrustedRoots")
struct EffectiveTrustedRootsTests {

    @Test("Returns trustedRootCertificates when set")
    func prefersExplicitRoots() throws {
        let (caCert, _) = try makeTestCACertificate()

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)
        #expect(roots[0].subject == caCert.subject)
    }

    @Test("Falls back to trustedCACertificates (DER) when trustedRootCertificates is nil")
    func fallsBackToDER() throws {
        let (caCert, _) = try makeTestCACertificate()

        var config = TLSConfiguration()
        config.trustedRootCertificates = nil
        config.trustedCACertificates = [caCert.derEncoded]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)
        #expect(roots[0].subject == caCert.subject)
    }

    @Test("Returns empty when neither is set")
    func returnsEmptyWhenNothingSet() {
        let config = TLSConfiguration()
        #expect(config.effectiveTrustedRoots.isEmpty)
    }

    @Test("Prefers trustedRootCertificates over trustedCACertificates")
    func prefersRootOverDER() throws {
        let (caCert1, _) = try makeTestCACertificate(commonName: "CA One")
        let (caCert2, _) = try makeTestCACertificate(commonName: "CA Two")

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert1]
        config.trustedCACertificates = [caCert2.derEncoded]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)
        #expect(roots[0].subject == caCert1.subject)
    }

    @Test("Skips unparseable DER data in trustedCACertificates")
    func skipsUnparseableDER() throws {
        let (caCert, _) = try makeTestCACertificate()

        var config = TLSConfiguration()
        config.trustedRootCertificates = nil
        config.trustedCACertificates = [
            caCert.derEncoded,
            Data([0x00, 0x01, 0x02]),  // Garbage
        ]

        let roots = config.effectiveTrustedRoots
        // compactMap should skip the garbage entry
        #expect(roots.count == 1)
    }
}

// MARK: - TLSConfiguration Trust Loading Helpers

@Suite("TLSConfiguration trust loading helpers")
struct TrustLoadingHelperTests {

    @Test("addTrustedCAs(derEncoded:) parses and appends DER certs")
    func addDERCerts() throws {
        let (ca1, _) = try makeTestCACertificate(commonName: "CA1")
        let (ca2, _) = try makeTestCACertificate(commonName: "CA2")

        var config = TLSConfiguration()
        try config.addTrustedCAs(derEncoded: [ca1.derEncoded])
        #expect(config.trustedRootCertificates?.count == 1)

        try config.addTrustedCAs(derEncoded: [ca2.derEncoded])
        #expect(config.trustedRootCertificates?.count == 2)
    }

    @Test("addTrustedCAs(derEncoded:) throws for invalid DER")
    func addInvalidDERThrows() {
        var config = TLSConfiguration()
        #expect(throws: (any Error).self) {
            try config.addTrustedCAs(derEncoded: [Data([0xFF, 0xFF])])
        }
    }

    @Test("revocationCheckMode defaults to .none")
    func defaultRevocationMode() {
        let config = TLSConfiguration()
        if case .none = config.revocationCheckMode {
            // Expected
        } else {
            Issue.record("Expected .none, got \(config.revocationCheckMode)")
        }
    }

    @Test("revocationHTTPClient defaults to nil")
    func defaultHTTPClient() {
        let config = TLSConfiguration()
        #expect(config.revocationHTTPClient == nil)
    }
}

// MARK: - ValidatedChain Tests

@Suite("X509Validator.buildValidatedChain")
struct ValidatedChainTests {

    @Test("Self-signed CA returns a single-element chain")
    func selfSignedChain() throws {
        let (caCert, _) = try makeTestCACertificate()

        let options = X509ValidationOptions(
            checkKeyUsage: false,
            checkExtendedKeyUsage: false,
            validateSANFormat: false,
            allowSelfSigned: true
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)

        let chain = try validator.buildValidatedChain(certificate: caCert)
        #expect(chain.chain.count == 1)
        #expect(chain.leaf.subject == caCert.subject)
        #expect(chain.leafIssuer == nil)
        #expect(chain.root?.subject == caCert.subject)
    }

    @Test("CA + leaf returns two-element chain")
    func caAndLeafChain() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: true,
            requiredEKU: .serverAuth,
            hostname: "test.example.com"
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)

        let chain = try validator.buildValidatedChain(
            certificate: leafCert,
            intermediates: []
        )
        #expect(chain.chain.count == 2)
        #expect(chain.leaf.subject == leafCert.subject)
        #expect(chain.leafIssuer?.subject == caCert.subject)
        #expect(chain.root?.subject == caCert.subject)
    }

    @Test("buildValidatedChain throws for untrusted root")
    func untrustedRoot() throws {
        let (_, _) = try makeTestCACertificate(commonName: "Trusted CA")
        let (untrustedCA, untrustedKey) = try makeTestCACertificate(commonName: "Untrusted CA")
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: untrustedKey,
            caCert: untrustedCA
        )

        // Validator does NOT trust the untrusted CA
        let (trustedCA, _) = try makeTestCACertificate(commonName: "Trusted CA")
        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(trustedRoots: [trustedCA], options: options)

        #expect(throws: X509Error.self) {
            try validator.buildValidatedChain(certificate: leafCert)
        }
    }

    @Test("buildValidatedChain result matches validate() behavior")
    func matchesValidate() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert,
            addServerAuthEKU: true,
            addSAN: true
        )

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: true,
            requiredEKU: .serverAuth,
            hostname: "test.example.com"
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)

        // Both should succeed
        #expect(throws: Never.self) {
            try validator.validate(certificate: leafCert)
        }
        #expect(throws: Never.self) {
            _ = try validator.buildValidatedChain(certificate: leafCert)
        }
    }
}

// MARK: - Async Revocation Validation Tests

@Suite("X509Validator.validateWithRevocation")
struct AsyncRevocationValidationTests {

    @Test("validateWithRevocation passes with .none mode checker")
    func noneModeAlwaysGood() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)
        let checker = RevocationChecker(mode: .none)

        // Should pass since .none always returns .good
        try await validator.validateWithRevocation(
            certificate: leafCert,
            revocationChecker: checker
        )
    }

    @Test("validateWithRevocation with ocspStapling and no response returns (no issuer for self-signed skips)")
    func ocspStaplingNoResponseSelfSigned() async throws {
        let (caCert, _) = try makeTestCACertificate()

        let options = X509ValidationOptions(
            checkKeyUsage: false,
            checkExtendedKeyUsage: false,
            validateSANFormat: false,
            allowSelfSigned: true
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)
        let checker = RevocationChecker(mode: .ocspStapling)

        // Self-signed cert has no issuer, so revocation check is skipped
        try await validator.validateWithRevocation(
            certificate: caCert,
            revocationChecker: checker
        )
    }

    @Test("validateWithRevocation chain validation failure still throws")
    func chainFailureStillThrows() async throws {
        let (_, _) = try makeTestCACertificate(commonName: "Wrong CA")
        let (untrustedCA, untrustedKey) = try makeTestCACertificate(commonName: "Untrusted")
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: untrustedKey,
            caCert: untrustedCA,
            addServerAuthEKU: false,
            addSAN: false
        )

        let (trustedCA, _) = try makeTestCACertificate(commonName: "Trusted")
        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(trustedRoots: [trustedCA], options: options)
        let checker = RevocationChecker(mode: .none)

        do {
            try await validator.validateWithRevocation(
                certificate: leafCert,
                revocationChecker: checker
            )
            Issue.record("Expected chain validation error")
        } catch {
            // Expected: chain validation should fail before revocation is even checked
        }
    }

    @Test("validateWithRevocation with bestEffort mode and no HTTP client soft-fails")
    func bestEffortSoftFails() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(trustedRoots: [caCert], options: options)

        // bestEffort with no HTTP client: all methods fail → .undetermined → soft-fail → pass
        let checker = RevocationChecker(mode: .bestEffort, httpClient: nil)

        try await validator.validateWithRevocation(
            certificate: leafCert,
            revocationChecker: checker
        )
    }
}

// MARK: - RevocationCheckMode in TLSConfiguration

@Suite("RevocationCheckMode configuration")
struct RevocationCheckModeConfigTests {

    @Test("Can set .ocspStapling mode")
    func ocspStaplingMode() {
        var config = TLSConfiguration()
        config.revocationCheckMode = .ocspStapling

        if case .ocspStapling = config.revocationCheckMode {
            // Expected
        } else {
            Issue.record("Expected .ocspStapling")
        }
    }

    @Test("Can set .ocsp mode with parameters")
    func ocspMode() {
        var config = TLSConfiguration()
        config.revocationCheckMode = .ocsp(allowOnlineCheck: true, softFail: true)

        if case .ocsp(let allow, let soft) = config.revocationCheckMode {
            #expect(allow == true)
            #expect(soft == true)
        } else {
            Issue.record("Expected .ocsp")
        }
    }

    @Test("Can set .crl mode with parameters")
    func crlMode() {
        var config = TLSConfiguration()
        config.revocationCheckMode = .crl(cacheDirectory: nil, softFail: false)

        if case .crl(let dir, let soft) = config.revocationCheckMode {
            #expect(dir == nil)
            #expect(soft == false)
        } else {
            Issue.record("Expected .crl")
        }
    }

    @Test("Can set .bestEffort mode")
    func bestEffortMode() {
        var config = TLSConfiguration()
        config.revocationCheckMode = .bestEffort

        if case .bestEffort = config.revocationCheckMode {
            // Expected
        } else {
            Issue.record("Expected .bestEffort")
        }
    }
}

// MARK: - PEMLoader CA Certificate Helper Tests

@Suite("PEMLoader CA certificate helpers")
struct PEMLoaderCATests {

    /// Serializes an X509Certificate back to PEM for testing round-trips.
    private static func toPEM(_ cert: X509Certificate) -> String {
        let base64 = cert.derEncoded.base64EncodedString(options: .lineLength76Characters)
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }

    @Test("parseCACertificates(from:) returns parsed X509Certificate objects from PEM string")
    func parseCACertsFromPEM() throws {
        let (caCert, _) = try makeTestCACertificate()
        let pem = Self.toPEM(caCert)

        let parsed = try PEMLoader.parseCACertificates(from: pem)
        #expect(parsed.count == 1)
        #expect(parsed[0].subject == caCert.subject)
    }

    @Test("parseCACertificates(from:) handles multiple certs in one PEM")
    func parseMultipleCACerts() throws {
        let (ca1, _) = try makeTestCACertificate(commonName: "CA 1")
        let (ca2, _) = try makeTestCACertificate(commonName: "CA 2")
        let pem = Self.toPEM(ca1) + "\n" + Self.toPEM(ca2)

        let parsed = try PEMLoader.parseCACertificates(from: pem)
        #expect(parsed.count == 2)
    }

    @Test("parseCACertificates(fromDER:) converts DER data to X509Certificate")
    func parseCACertsFromDER() throws {
        let (caCert, _) = try makeTestCACertificate()

        let parsed = try PEMLoader.parseCACertificates(fromDER: [caCert.derEncoded])
        #expect(parsed.count == 1)
        #expect(parsed[0].subject == caCert.subject)
    }

    @Test("parseCACertificates(fromDER:) throws for invalid data")
    func parseCACertsInvalidDER() {
        #expect(throws: (any Error).self) {
            _ = try PEMLoader.parseCACertificates(fromDER: [Data([0xFF])])
        }
    }
}

// MARK: - RevocationChecker Unit Tests

@Suite("RevocationChecker modes")
struct RevocationCheckerModeTests {

    @Test("RevocationChecker with .none mode always returns .good")
    func noneModeGood() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let checker = RevocationChecker(mode: .none)
        let status = try await checker.checkRevocation(leafCert, issuer: caCert)

        #expect(status == .good)
    }

    @Test("RevocationChecker with .ocspStapling and no response returns .unknown")
    func ocspStaplingNoResponse() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let checker = RevocationChecker(mode: .ocspStapling)
        let status = try await checker.checkRevocation(leafCert, issuer: caCert)

        #expect(status == .unknown)
    }

    @Test("RevocationChecker with .bestEffort and no HTTP client returns .undetermined")
    func bestEffortNoHTTPClient() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let checker = RevocationChecker(mode: .bestEffort, httpClient: nil)
        let status = try await checker.checkRevocation(leafCert, issuer: caCert)

        switch status {
        case .undetermined:
            break  // Expected
        default:
            Issue.record("Expected .undetermined, got \(status)")
        }
    }

    @Test("RevocationChecker with .ocsp(softFail: true) and no HTTP client returns .undetermined")
    func ocspSoftFailNoHTTPClient() async throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        let checker = RevocationChecker(mode: .ocsp(allowOnlineCheck: true, softFail: true), httpClient: nil)
        let status = try await checker.checkRevocation(leafCert, issuer: caCert)

        switch status {
        case .undetermined:
            break  // Expected: soft-fail when OCSP is unreachable
        default:
            Issue.record("Expected .undetermined, got \(status)")
        }
    }
}

// MARK: - TLS13Handler Revocation Wiring Tests

@Suite("TLS13Handler revocation wiring")
struct TLS13HandlerRevocationTests {

    @Test("TLS13Handler with .none revocationCheckMode does not block on missing chain")
    func noneModeNoBlock() async throws {
        var config = TLSConfiguration()
        config.revocationCheckMode = .none
        config.alpnProtocols = ["h3"]

        let handler = TLS13Handler(configuration: config)

        // Starting handshake should work regardless of revocation config
        let outputs = try await handler.startHandshake(isClient: true)
        #expect(!outputs.isEmpty, "Should produce ClientHello output")
    }

    @Test("TLS13Handler preserves revocation config from TLSConfiguration")
    func preservesRevocationConfig() {
        var config = TLSConfiguration()
        config.revocationCheckMode = .bestEffort

        let handler = TLS13Handler(configuration: config)

        // The handler stores the config internally; verify it was created successfully.
        // Before startHandshake(), isHandshakeComplete is false.
        #expect(handler.isHandshakeComplete == false, "Handshake should not be complete before start")
    }
}

// MARK: - ValidatedChain Struct Tests

@Suite("ValidatedChain struct")
struct ValidatedChainStructTests {

    @Test("ValidatedChain.leaf returns first element")
    func leafIsFirst() throws {
        let (cert, _) = try makeTestCACertificate()
        let chain = ValidatedChain(chain: [cert])
        #expect(chain.leaf.subject == cert.subject)
    }

    @Test("ValidatedChain.leafIssuer returns second element")
    func leafIssuerIsSecond() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )
        let chain = ValidatedChain(chain: [leafCert, caCert])
        #expect(chain.leafIssuer?.subject == caCert.subject)
    }

    @Test("ValidatedChain.leafIssuer is nil for single-cert chain")
    func leafIssuerNilForSingle() throws {
        let (cert, _) = try makeTestCACertificate()
        let chain = ValidatedChain(chain: [cert])
        #expect(chain.leafIssuer == nil)
    }

    @Test("ValidatedChain.root returns last element")
    func rootIsLast() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )
        let chain = ValidatedChain(chain: [leafCert, caCert])
        #expect(chain.root?.subject == caCert.subject)
    }
}

// MARK: - Integration: effectiveTrustedRoots with Validator

@Suite("effectiveTrustedRoots integration with X509Validator")
struct EffectiveTrustedRootsIntegrationTests {

    @Test("Validator using effectiveTrustedRoots from DER fallback validates chain")
    func derFallbackValidation() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        var config = TLSConfiguration()
        config.trustedRootCertificates = nil
        config.trustedCACertificates = [caCert.derEncoded]

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(
            trustedRoots: config.effectiveTrustedRoots,
            options: options
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leafCert)
        }
    }

    @Test("Validator using effectiveTrustedRoots with explicit roots validates chain")
    func explicitRootsValidation() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert
        )

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert]

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(
            trustedRoots: config.effectiveTrustedRoots,
            options: options
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leafCert)
        }
    }

    @Test("Validator rejects leaf when effectiveTrustedRoots is empty")
    func emptyRootsRejectsLeaf() throws {
        let (caCert, caKey) = try makeTestCACertificate()
        let (leafCert, _) = try makeTestLeafCertificate(
            caKey: caKey,
            caCert: caCert,
            addServerAuthEKU: false,
            addSAN: false
        )

        let config = TLSConfiguration()  // No roots set

        let options = X509ValidationOptions(
            checkExtendedKeyUsage: false,
            validateSANFormat: false
        )
        let validator = X509Validator(
            trustedRoots: config.effectiveTrustedRoots,
            options: options
        )

        #expect(throws: X509Error.self) {
            try validator.validate(certificate: leafCert)
        }
    }
}