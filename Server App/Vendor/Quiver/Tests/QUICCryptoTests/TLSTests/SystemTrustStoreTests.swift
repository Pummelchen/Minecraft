/// Phase C Tests: System Trust Store, Validator Strictness, API Cleanup
///
/// Tests for:
/// - SystemTrustStore loading and caching behavior
/// - SystemTrustStoreError types
/// - TLSConfiguration.useSystemTrustStore() / addSystemTrustStore() integration
/// - TLSConfiguration.effectiveTrustedRootsWithSystemFallback resolution
/// - X509Validator findIssuer AKI serial number matching
/// - X509Validator verifyTrust multi-factor trust (SPKI + DN + SKI/AKI cross-check)

import Testing
import Foundation
import Crypto
@preconcurrency import X509
import SwiftASN1
@testable import QUICCrypto

// MARK: - Test Certificate Helpers

/// Creates a self-signed CA certificate for testing.
private func makeCA(
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
    return (try X509Certificate.parse(from: derData), key)
}

/// Creates a leaf certificate signed by the given CA.
private func makeLeaf(
    commonName: String = "test.example.com",
    caKey: P256.Signing.PrivateKey,
    caCert: X509Certificate,
    leafKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    addAKI: Bool = true,
    addSAN: Bool = true,
    addEKU: Bool = true
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
            if addEKU {
                try ExtendedKeyUsage([.serverAuth])
            }
            if addSAN {
                SubjectAlternativeNames([.dnsName(commonName)])
            }
            if addAKI {
                AuthorityKeyIdentifier(
                    keyIdentifier: caCert.subjectKeyIdentifier?.keyIdentifier
                )
            }
        },
        issuerPrivateKey: .init(caKey)
    )

    var serializer = DER.Serializer()
    try cert.serialize(into: &serializer)
    let derData = Data(serializer.serializedBytes)
    return (try X509Certificate.parse(from: derData), leafKey)
}

/// Creates an intermediate CA certificate signed by the given root CA.
private func makeIntermediateCA(
    commonName: String = "Test Intermediate CA",
    rootKey: P256.Signing.PrivateKey,
    rootCert: X509Certificate,
    intermediateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    pathLenConstraint: Int? = 0
) throws -> (X509Certificate, P256.Signing.PrivateKey) {
    let name = try DistinguishedName {
        CommonName(commonName)
        OrganizationName("Quiver Tests")
    }

    let cert = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(),
        publicKey: .init(intermediateKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-3600),
        notValidAfter: Date().addingTimeInterval(86400),
        issuer: rootCert.certificate.subject,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: pathLenConstraint))
            Critical(KeyUsage(keyCertSign: true))
            SubjectKeyIdentifier(hash: .init(intermediateKey.publicKey))
            AuthorityKeyIdentifier(
                keyIdentifier: rootCert.subjectKeyIdentifier?.keyIdentifier
            )
        },
        issuerPrivateKey: .init(rootKey)
    )

    var serializer = DER.Serializer()
    try cert.serialize(into: &serializer)
    let derData = Data(serializer.serializedBytes)
    return (try X509Certificate.parse(from: derData), intermediateKey)
}

// MARK: - SystemTrustStore Cache Tests

@Suite("SystemTrustStore cache behavior")
struct SystemTrustStoreCacheTests {

    @Test("clearCache resets cache state")
    func clearCacheResetsState() {
        // Clear to ensure clean state
        SystemTrustStore.clearCache()
        #expect(SystemTrustStore.isCachePopulated == false)
        #expect(SystemTrustStore.cachedRootCount == nil)
    }

    @Test("cachedRootCount is nil before loading")
    func cachedRootCountNilBeforeLoad() {
        SystemTrustStore.clearCache()
        #expect(SystemTrustStore.cachedRootCount == nil)
    }

    @Test("isCachePopulated is false after clear")
    func isCachePopulatedFalseAfterClear() {
        SystemTrustStore.clearCache()
        #expect(SystemTrustStore.isCachePopulated == false)
    }

    #if os(macOS)
    @Test("loadSystemRoots succeeds on macOS")
    func loadSystemRootsOnMacOS() throws {
        SystemTrustStore.clearCache()
        let roots = try SystemTrustStore.loadSystemRoots()
        #expect(!roots.isEmpty)
        #expect(roots.count > 10) // macOS should have many root CAs
    }

    @Test("loadSystemRoots caches results")
    func loadSystemRootsCaches() throws {
        SystemTrustStore.clearCache()
        let roots1 = try SystemTrustStore.loadSystemRoots()
        #expect(SystemTrustStore.isCachePopulated == true)
        #expect(SystemTrustStore.cachedRootCount == roots1.count)

        // Second call should return cached results
        let roots2 = try SystemTrustStore.loadSystemRoots()
        #expect(roots1.count == roots2.count)
    }

    @Test("loadSystemRoots forceReload reloads")
    func forceReloadReloads() throws {
        SystemTrustStore.clearCache()
        let roots1 = try SystemTrustStore.loadSystemRoots()
        let count1 = roots1.count

        // Force reload should succeed and return same count
        let roots2 = try SystemTrustStore.loadSystemRoots(forceReload: true)
        #expect(roots2.count == count1)
    }

    @Test("loaded roots are valid CA certificates")
    func loadedRootsAreValidCAs() throws {
        let roots = try SystemTrustStore.loadSystemRoots()

        // Most system roots should be CAs (some may be cross-signed)
        var caCount = 0
        for root in roots {
            if root.isCA {
                caCount += 1
            }
        }

        // At least 80% should be marked as CA
        let caPercentage = Double(caCount) / Double(roots.count)
        #expect(caPercentage > 0.8, "Expected most system roots to be CA certificates, got \(caPercentage * 100)%")
    }

    @Test("loaded roots have non-empty SPKI")
    func loadedRootsHaveNonEmptySPKI() throws {
        let roots = try SystemTrustStore.loadSystemRoots()

        for root in roots {
            #expect(!root.subjectPublicKeyInfoDER.isEmpty,
                    "Root CA \(root.subject.string) should have non-empty SPKI")
        }
    }
    #endif

    #if os(Linux)
    @Test("loadSystemRoots on Linux with ca-certificates installed")
    func loadSystemRootsOnLinux() throws {
        // This test may fail if ca-certificates is not installed
        do {
            SystemTrustStore.clearCache()
            let roots = try SystemTrustStore.loadSystemRoots()
            #expect(!roots.isEmpty)
        } catch let error as SystemTrustStoreError {
            // If no certs installed, expect a specific error
            if case .noRootsFound = error {
                // Acceptable: ca-certificates not installed in this environment
                return
            }
            throw error
        }
    }
    #endif
}

// MARK: - SystemTrustStoreError Tests

@Suite("SystemTrustStoreError")
struct SystemTrustStoreErrorTests {

    @Test("unsupportedPlatform description")
    func unsupportedPlatformDescription() {
        let error = SystemTrustStoreError.unsupportedPlatform
        #expect(error.description.contains("not supported"))
    }

    @Test("noRootsFound description")
    func noRootsFoundDescription() {
        let error = SystemTrustStoreError.noRootsFound("test detail")
        #expect(error.description.contains("test detail"))
    }

    @Test("platformRootsNotEnumerable description")
    func platformRootsNotEnumerableDescription() {
        let error = SystemTrustStoreError.platformRootsNotEnumerable("iOS note")
        #expect(error.description.contains("iOS note"))
    }

    @Test("securityFrameworkError description")
    func securityFrameworkErrorDescription() {
        let error = SystemTrustStoreError.securityFrameworkError("SecTrust error")
        #expect(error.description.contains("SecTrust error"))
    }

    @Test("fileSystemError description")
    func fileSystemErrorDescription() {
        let error = SystemTrustStoreError.fileSystemError("read failed")
        #expect(error.description.contains("read failed"))
    }

    @Test("parseError description")
    func parseErrorDescription() {
        let error = SystemTrustStoreError.parseError("bad DER")
        #expect(error.description.contains("bad DER"))
    }

    @Test("conforms to LocalizedError")
    func conformsToLocalizedError() {
        let error: Error = SystemTrustStoreError.unsupportedPlatform
        #expect(error.localizedDescription.contains("not supported"))
    }
}

// MARK: - TLSConfiguration System Trust Store Integration

@Suite("TLSConfiguration system trust store integration")
struct TLSConfigSystemTrustStoreTests {

    #if os(macOS)
    @Test("useSystemTrustStore populates trustedRootCertificates")
    func useSystemTrustStorePopulates() throws {
        var config = TLSConfiguration.client(serverName: "example.com")
        #expect(config.trustedRootCertificates == nil)

        try config.useSystemTrustStore()
        #expect(config.trustedRootCertificates != nil)
        #expect(config.trustedRootCertificates!.count > 0)
    }

    @Test("useSystemTrustStore replaces existing roots")
    func useSystemTrustStoreReplaces() throws {
        let (caCert, _) = try makeCA()

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert]
        #expect(config.trustedRootCertificates?.count == 1)

        try config.useSystemTrustStore()
        #expect(config.trustedRootCertificates!.count > 1)
    }

    @Test("addSystemTrustStore preserves existing roots")
    func addSystemTrustStorePreserves() throws {
        let (caCert, _) = try makeCA()

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert]

        let originalCount = config.trustedRootCertificates!.count
        try config.addSystemTrustStore()

        // Should have original + system roots
        #expect(config.trustedRootCertificates!.count > originalCount)
    }

    @Test("addSystemTrustStore initializes when nil")
    func addSystemTrustStoreInitializesWhenNil() throws {
        var config = TLSConfiguration()
        #expect(config.trustedRootCertificates == nil)

        try config.addSystemTrustStore()
        #expect(config.trustedRootCertificates != nil)
        #expect(config.trustedRootCertificates!.count > 0)
    }
    #endif

    @Test("effectiveTrustedRootsWithSystemFallback prefers explicit roots")
    func effectiveWithSystemFallbackPrefersExplicit() throws {
        let (caCert, _) = try makeCA()

        var config = TLSConfiguration()
        config.trustedRootCertificates = [caCert]

        let roots = config.effectiveTrustedRootsWithSystemFallback
        #expect(roots.count == 1)
        #expect(roots[0].subject == caCert.subject)
    }

    @Test("effectiveTrustedRootsWithSystemFallback falls back to DER")
    func effectiveWithSystemFallbackFallsToDER() throws {
        let (caCert, _) = try makeCA()

        var config = TLSConfiguration()
        config.trustedCACertificates = [caCert.derEncoded]

        let roots = config.effectiveTrustedRootsWithSystemFallback
        #expect(roots.count == 1)
    }

    @Test("effectiveTrustedRootsWithSystemFallback returns empty when verifyPeer is false")
    func effectiveWithSystemFallbackEmptyWhenNoVerify() {
        var config = TLSConfiguration()
        config.verifyPeer = false

        // With verifyPeer false, system trust store is not loaded
        let roots = config.effectiveTrustedRootsWithSystemFallback
        // On platforms where system trust store is available, it won't be loaded
        // because verifyPeer is false. On other platforms, it's always empty.
        // The key behavior: no system fallback when verifyPeer is false.
        #expect(roots.isEmpty)
    }

    #if os(macOS)
    @Test("effectiveTrustedRootsWithSystemFallback loads system roots when nothing configured")
    func effectiveWithSystemFallbackLoadsSystemRoots() {
        var config = TLSConfiguration()
        config.verifyPeer = true

        let roots = config.effectiveTrustedRootsWithSystemFallback
        // On macOS, this should load system roots
        #expect(!roots.isEmpty)
    }
    #endif
}

// MARK: - Validator Strictness: findIssuer AKI Serial Number Matching

@Suite("X509Validator findIssuer AKI serial number matching")
struct FindIssuerAKISerialTests {

    @Test("findIssuer resolves by AKI keyIdentifier when multiple candidates")
    func findIssuerByAKIKeyIdentifier() throws {
        // Create two CAs with the same subject DN but different keys
        let key1 = P256.Signing.PrivateKey()
        let key2 = P256.Signing.PrivateKey()

        let (ca1, caKey1) = try makeCA(commonName: "Test CA", key: key1)
        let (ca2, _) = try makeCA(commonName: "Test CA", key: key2)

        // Create leaf signed by ca1 with AKI pointing to ca1
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: caKey1,
            caCert: ca1,
            addAKI: true
        )

        // Validate with both CAs as trusted roots — validator should pick ca1
        let validator = X509Validator(
            trustedRoots: [ca1, ca2],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        // Should succeed because AKI disambiguates to the correct CA
        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf, intermediates: [])
        }
    }

    @Test("chain building succeeds with AKI pointing to correct intermediate")
    func chainBuildingWithAKI() throws {
        let (rootCert, rootKey) = try makeCA(commonName: "Root CA")
        let (intermediateCert, intermediateKey) = try makeIntermediateCA(
            commonName: "Intermediate CA",
            rootKey: rootKey,
            rootCert: rootCert
        )
        let (leafCert, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: intermediateKey,
            caCert: intermediateCert
        )

        let validator = X509Validator(
            trustedRoots: [rootCert],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        // Chain: leaf -> intermediate -> root
        let chain = try validator.buildValidatedChain(
            certificate: leafCert,
            intermediates: [intermediateCert]
        )

        #expect(chain.chain.count == 3)
        #expect(chain.leaf.subject == leafCert.subject)
        #expect(chain.root?.subject == rootCert.subject)
    }

    @Test("chain validation fails with wrong CA despite same subject DN")
    func chainValidationFailsWithWrongCA() throws {
        let key1 = P256.Signing.PrivateKey()
        let key2 = P256.Signing.PrivateKey()

        let (ca1, caKey1) = try makeCA(commonName: "Ambiguous CA", key: key1)
        let (_, _) = try makeCA(commonName: "Ambiguous CA", key: key2)

        // Create leaf signed by ca1
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: caKey1,
            caCert: ca1,
            addAKI: true
        )

        // Only trust ca2 (the wrong one) — validation should fail
        // because the leaf was signed by ca1's key
        let ca2Only = try makeCA(commonName: "Ambiguous CA", key: key2)
        let validator = X509Validator(
            trustedRoots: [ca2Only.0],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        #expect(throws: (any Error).self) {
            try validator.validate(certificate: leaf, intermediates: [])
        }
    }
}

// MARK: - Validator Strictness: Multi-Factor Trust Verification

@Suite("X509Validator multi-factor trust verification")
struct MultiFactorTrustTests {

    @Test("trust requires SPKI match")
    func trustRequiresSPKI() throws {
        let (ca1, caKey1) = try makeCA(commonName: "Test CA")
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: caKey1,
            caCert: ca1
        )

        // Create a different CA with same name but different key
        let differentKey = P256.Signing.PrivateKey()
        let (differentCA, _) = try makeCA(commonName: "Test CA", key: differentKey)

        // Validator trusts the different CA (different SPKI)
        let validator = X509Validator(
            trustedRoots: [differentCA],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        // Should fail because SPKI doesn't match (leaf was signed by ca1)
        #expect(throws: (any Error).self) {
            try validator.validate(certificate: leaf, intermediates: [])
        }
    }

    @Test("trust requires subject DN match")
    func trustRequiresSubjectDN() throws {
        let (ca, caKey) = try makeCA(commonName: "Real CA")
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: caKey,
            caCert: ca
        )

        // Trust only a CA with a different name (even if key were the same)
        let (differentNameCA, _) = try makeCA(commonName: "Fake CA")
        let validator = X509Validator(
            trustedRoots: [differentNameCA],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        #expect(throws: (any Error).self) {
            try validator.validate(certificate: leaf, intermediates: [])
        }
    }

    @Test("trust succeeds with matching SPKI and DN")
    func trustSucceedsWithMatchingSPKIAndDN() throws {
        let (ca, caKey) = try makeCA(commonName: "Trusted CA")
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: caKey,
            caCert: ca
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf, intermediates: [])
        }
    }

    @Test("trust with intermediate chain and AKI/SKI cross-check")
    func trustWithIntermediateChainAKISKICrossCheck() throws {
        let (rootCert, rootKey) = try makeCA(commonName: "Root CA")
        let (intermediateCert, intermediateKey) = try makeIntermediateCA(
            commonName: "Intermediate CA",
            rootKey: rootKey,
            rootCert: rootCert
        )
        let (leafCert, _) = try makeLeaf(
            commonName: "deep.example.com",
            caKey: intermediateKey,
            caCert: intermediateCert
        )

        let validator = X509Validator(
            trustedRoots: [rootCert],
            options: X509ValidationOptions(hostname: "deep.example.com")
        )

        // Should succeed: full chain with AKI/SKI linkage
        let chain = try validator.buildValidatedChain(
            certificate: leafCert,
            intermediates: [intermediateCert]
        )

        #expect(chain.chain.count == 3)
        #expect(chain.leaf.subject.commonName?.contains("deep.example.com") == true)
        #expect(chain.root?.subject.commonName?.contains("Root CA") == true)
    }

    @Test("self-signed certificate rejected without allowSelfSigned")
    func selfSignedRejectedByDefault() throws {
        let (selfSigned, _) = try makeCA(commonName: "Self-Signed")

        let validator = X509Validator(
            trustedRoots: [],
            options: X509ValidationOptions(
                checkExtendedKeyUsage: false,
                allowSelfSigned: false
            )
        )

        #expect(throws: (any Error).self) {
            try validator.validate(certificate: selfSigned)
        }
    }

    @Test("self-signed certificate accepted with allowSelfSigned")
    func selfSignedAcceptedWhenAllowed() throws {
        let (selfSigned, _) = try makeCA(commonName: "Self-Signed")

        let validator = X509Validator(
            trustedRoots: [],
            options: X509ValidationOptions(
                checkExtendedKeyUsage: false,
                allowSelfSigned: true
            )
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: selfSigned)
        }
    }
}

// MARK: - ValidatedChain Advanced Tests

@Suite("ValidatedChain with multi-level chains")
struct ValidatedChainAdvancedTests {

    @Test("three-level chain has correct structure")
    func threeLevelChain() throws {
        let (root, rootKey) = try makeCA(commonName: "Root CA")
        let (intermediate, intKey) = try makeIntermediateCA(
            commonName: "Intermediate CA",
            rootKey: rootKey,
            rootCert: root
        )
        let (leaf, _) = try makeLeaf(
            commonName: "leaf.example.com",
            caKey: intKey,
            caCert: intermediate
        )

        let validator = X509Validator(
            trustedRoots: [root],
            options: X509ValidationOptions(hostname: "leaf.example.com")
        )

        let chain = try validator.buildValidatedChain(
            certificate: leaf,
            intermediates: [intermediate]
        )

        #expect(chain.chain.count == 3)
        #expect(chain.leaf.subject.commonName?.contains("leaf.example.com") == true)
        #expect(chain.leafIssuer?.subject.commonName?.contains("Intermediate CA") == true)
        #expect(chain.root?.subject.commonName?.contains("Root CA") == true)
    }

    @Test("two-level chain (leaf + root) has correct structure")
    func twoLevelChain() throws {
        let (root, rootKey) = try makeCA(commonName: "Direct Root CA")
        let (leaf, _) = try makeLeaf(
            commonName: "direct.example.com",
            caKey: rootKey,
            caCert: root
        )

        let validator = X509Validator(
            trustedRoots: [root],
            options: X509ValidationOptions(hostname: "direct.example.com")
        )

        let chain = try validator.buildValidatedChain(
            certificate: leaf,
            intermediates: []
        )

        #expect(chain.chain.count == 2)
        #expect(chain.leaf.subject.commonName?.contains("direct.example.com") == true)
        #expect(chain.leafIssuer?.subject.commonName?.contains("Direct Root CA") == true)
        #expect(chain.root?.subject.commonName?.contains("Direct Root CA") == true)
    }

    @Test("buildValidatedChain rejects untrusted root")
    func buildValidatedChainRejectsUntrusted() throws {
        let (ca, caKey) = try makeCA(commonName: "Unknown CA")
        let (leaf, _) = try makeLeaf(
            commonName: "untrusted.example.com",
            caKey: caKey,
            caCert: ca
        )

        let validator = X509Validator(
            trustedRoots: [], // no trusted roots
            options: X509ValidationOptions(hostname: "untrusted.example.com")
        )

        #expect(throws: X509Error.self) {
            _ = try validator.buildValidatedChain(
                certificate: leaf,
                intermediates: [ca]
            )
        }
    }
}

// MARK: - CertificateStore Tests

@Suite("QUICCrypto.CertificateStore")
struct CertificateStoreTests {

    @Test("empty store has no certificates")
    func emptyStore() {
        let store = QUICCrypto.CertificateStore()
        #expect(store.all.isEmpty)
    }

    @Test("add certificates to store")
    func addCertificates() throws {
        let (cert, _) = try makeCA()

        var store = QUICCrypto.CertificateStore()
        store.add(cert)
        #expect(store.all.count == 1)
    }

    @Test("add DER-encoded certificate")
    func addDEREncoded() throws {
        let (cert, _) = try makeCA()

        var store = QUICCrypto.CertificateStore()
        try store.add(derEncoded: cert.derEncoded)
        #expect(store.all.count == 1)
    }

    @Test("add invalid DER throws")
    func addInvalidDERThrows() {
        var store = QUICCrypto.CertificateStore()
        #expect(throws: (any Error).self) {
            try store.add(derEncoded: Data([0x00, 0x01, 0x02]))
        }
    }

    @Test("initialize store with certificates array")
    func initWithCertificates() throws {
        let (cert1, _) = try makeCA(commonName: "CA 1")
        let (cert2, _) = try makeCA(commonName: "CA 2")

        let store = QUICCrypto.CertificateStore(certificates: [cert1, cert2])
        #expect(store.all.count == 2)
    }

    @Test("validator from store uses stored certificates as trusted roots")
    func validatorFromStore() throws {
        let (ca, caKey) = try makeCA(commonName: "Store CA")
        let (leaf, _) = try makeLeaf(
            commonName: "store.example.com",
            caKey: caKey,
            caCert: ca
        )

        let store = QUICCrypto.CertificateStore(certificates: [ca])
        let validator = store.validator(
            options: X509ValidationOptions(hostname: "store.example.com")
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }
}

// MARK: - TLSConfiguration Convenience Method Tests

@Suite("TLSConfiguration client/server factory methods")
struct TLSConfigFactoryTests {

    @Test("client factory sets serverName and ALPN")
    func clientFactory() {
        let config = TLSConfiguration.client(
            serverName: "example.com",
            alpnProtocols: ["h3", "h3-29"]
        )

        #expect(config.serverName == "example.com")
        #expect(config.alpnProtocols == ["h3", "h3-29"])
        #expect(config.verifyPeer == true) // default
    }

    @Test("client factory defaults to h3 ALPN")
    func clientFactoryDefaultALPN() {
        let config = TLSConfiguration.client(serverName: "example.com")
        #expect(config.alpnProtocols == ["h3"])
    }

    @Test("client factory with nil serverName")
    func clientFactoryNilServerName() {
        let config = TLSConfiguration.client()
        #expect(config.serverName == nil)
    }

    @Test("default config has verifyPeer true")
    func defaultVerifyPeer() {
        let config = TLSConfiguration()
        #expect(config.verifyPeer == true)
    }

    @Test("default config has revocation mode none")
    func defaultRevocationMode() {
        let config = TLSConfiguration()
        if case .none = config.revocationCheckMode {
            // expected
        } else {
            Issue.record("Expected .none revocation mode")
        }
    }

    @Test("default config has no HTTP client")
    func defaultNoHTTPClient() {
        let config = TLSConfiguration()
        #expect(config.revocationHTTPClient == nil)
    }

    @Test("default config has supportedGroups")
    func defaultSupportedGroups() {
        let config = TLSConfiguration()
        #expect(config.supportedGroups.contains(.x25519))
        #expect(config.supportedGroups.contains(.secp256r1))
    }

    @Test("default config has requireClientCertificate false")
    func defaultNoMTLS() {
        let config = TLSConfiguration()
        #expect(config.requireClientCertificate == false)
    }

    @Test("hasCertificate when certificateChain and signingKey are set")
    func hasCertificateWithChainAndKey() {
        var config = TLSConfiguration()
        config.certificateChain = [Data([0x30])]
        config.signingKey = nil
        #expect(config.hasCertificate == false)

        // Both must be set
        // (We can't easily create a real SigningKey without PEM, so just test the logic path)
    }
}

// MARK: - effectiveTrustedRoots Tests (Original Behavior Preserved)

@Suite("TLSConfiguration.effectiveTrustedRoots original behavior")
struct EffectiveTrustedRootsOriginalTests {

    @Test("returns explicit roots when set")
    func returnsExplicitRoots() throws {
        let (ca, _) = try makeCA()
        var config = TLSConfiguration()
        config.trustedRootCertificates = [ca]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)
    }

    @Test("falls back to DER certificates")
    func fallsBackToDER() throws {
        let (ca, _) = try makeCA()
        var config = TLSConfiguration()
        config.trustedCACertificates = [ca.derEncoded]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)
    }

    @Test("returns empty when nothing set")
    func returnsEmptyWhenNothing() {
        let config = TLSConfiguration()
        let roots = config.effectiveTrustedRoots
        #expect(roots.isEmpty)
    }

    @Test("effectiveTrustedRoots does NOT fall back to system store")
    func noSystemStoreFallback() {
        // effectiveTrustedRoots (without "WithSystemFallback") should NOT
        // load system roots — that's the behavior of effectiveTrustedRootsWithSystemFallback
        var config = TLSConfiguration()
        config.verifyPeer = true

        let roots = config.effectiveTrustedRoots
        #expect(roots.isEmpty)
    }
}

// MARK: - Hostname Verification Tests

@Suite("X509Validator hostname verification")
struct HostnameVerificationTests {

    @Test("exact hostname match")
    func exactMatch() throws {
        let (ca, caKey) = try makeCA()
        let (leaf, _) = try makeLeaf(
            commonName: "exact.example.com",
            caKey: caKey,
            caCert: ca
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(hostname: "exact.example.com")
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }

    @Test("hostname mismatch fails")
    func hostnameMismatch() throws {
        let (ca, caKey) = try makeCA()
        let (leaf, _) = try makeLeaf(
            commonName: "correct.example.com",
            caKey: caKey,
            caCert: ca
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(hostname: "wrong.example.com")
        )

        #expect(throws: X509Error.self) {
            try validator.validate(certificate: leaf)
        }
    }

    @Test("validation without hostname check succeeds")
    func noHostnameCheck() throws {
        let (ca, caKey) = try makeCA()
        let (leaf, _) = try makeLeaf(
            commonName: "any.example.com",
            caKey: caKey,
            caCert: ca
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(hostname: nil)
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }
}

// MARK: - EKU Verification Tests

@Suite("X509Validator EKU verification")
struct EKUVerificationTests {

    @Test("serverAuth EKU passes with requiredEKU .serverAuth")
    func serverAuthPasses() throws {
        let (ca, caKey) = try makeCA()
        let (leaf, _) = try makeLeaf(
            commonName: "server.example.com",
            caKey: caKey,
            caCert: ca,
            addEKU: true
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(
                requiredEKU: .serverAuth,
                hostname: "server.example.com"
            )
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }

    @Test("no EKU extension passes when EKU checking enabled but no requiredEKU")
    func noEKUPassesWithoutRequirement() throws {
        let (ca, caKey) = try makeCA()
        let (leaf, _) = try makeLeaf(
            commonName: "no-eku.example.com",
            caKey: caKey,
            caCert: ca,
            addEKU: false
        )

        let validator = X509Validator(
            trustedRoots: [ca],
            options: X509ValidationOptions(
                checkExtendedKeyUsage: true,
                requiredEKU: nil,
                hostname: "no-eku.example.com"
            )
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }
}

// MARK: - Comprehensive Integration Test

@Suite("Phase C integration tests")
struct PhaseCIntegrationTests {

    @Test("full chain validation with all checks enabled")
    func fullChainValidation() throws {
        let (root, rootKey) = try makeCA(commonName: "Phase C Root CA")
        let (intermediate, intKey) = try makeIntermediateCA(
            commonName: "Phase C Intermediate CA",
            rootKey: rootKey,
            rootCert: root
        )
        let (leaf, _) = try makeLeaf(
            commonName: "phase-c.example.com",
            caKey: intKey,
            caCert: intermediate
        )

        let validator = X509Validator(
            trustedRoots: [root],
            options: X509ValidationOptions(
                checkValidity: true,
                checkBasicConstraints: true,
                checkKeyUsage: true,
                checkExtendedKeyUsage: true,
                requiredEKU: .serverAuth,
                validateSANFormat: true,
                checkNameConstraints: true,
                hostname: "phase-c.example.com",
                allowSelfSigned: false
            )
        )

        let chain = try validator.buildValidatedChain(
            certificate: leaf,
            intermediates: [intermediate]
        )

        #expect(chain.chain.count == 3)
        #expect(chain.leaf.subject.commonName?.contains("phase-c.example.com") == true)
        #expect(chain.leafIssuer?.subject.commonName?.contains("Phase C Intermediate CA") == true)
        #expect(chain.root?.subject.commonName?.contains("Phase C Root CA") == true)
    }

    @Test("TLSConfiguration with DER trusted roots validates correctly")
    func tlsConfigWithDERRoots() throws {
        let (root, rootKey) = try makeCA(commonName: "DER Root CA")
        let (leaf, _) = try makeLeaf(
            commonName: "der-test.example.com",
            caKey: rootKey,
            caCert: root
        )

        // Use DER-encoded trusted roots (effectiveTrustedRoots path)
        var config = TLSConfiguration()
        config.trustedCACertificates = [root.derEncoded]

        let roots = config.effectiveTrustedRoots
        #expect(roots.count == 1)

        let validator = X509Validator(
            trustedRoots: roots,
            options: X509ValidationOptions(hostname: "der-test.example.com")
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }

    @Test("TLSConfiguration addTrustedCAs then validate")
    func addTrustedCAsThenValidate() throws {
        let (root, rootKey) = try makeCA(commonName: "Added Root CA")
        let (leaf, _) = try makeLeaf(
            commonName: "added.example.com",
            caKey: rootKey,
            caCert: root
        )

        var config = TLSConfiguration()
        try config.addTrustedCAs(derEncoded: [root.derEncoded])

        let roots = config.effectiveTrustedRoots
        let validator = X509Validator(
            trustedRoots: roots,
            options: X509ValidationOptions(hostname: "added.example.com")
        )

        #expect(throws: Never.self) {
            try validator.validate(certificate: leaf)
        }
    }

    @Test("async revocation validation with .none mode passes")
    func asyncRevocationNonePasses() async throws {
        let (root, rootKey) = try makeCA(commonName: "Revocation Root")
        let (leaf, _) = try makeLeaf(
            commonName: "revcheck.example.com",
            caKey: rootKey,
            caCert: root
        )

        let validator = X509Validator(
            trustedRoots: [root],
            options: X509ValidationOptions(hostname: "revcheck.example.com")
        )

        let checker = RevocationChecker(mode: .none)

        // Should pass: .none mode always returns .good
        try await validator.validateWithRevocation(
            certificate: leaf,
            intermediates: [],
            revocationChecker: checker
        )
    }
}