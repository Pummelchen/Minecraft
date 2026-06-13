// QuiverTestSupport – shared test utilities
//
// Provides a process-safe logging override that silences verbose log output
// during test execution. Safe to call from multiple test targets — only the
// first invocation actually sets the override; subsequent calls are no-ops.

import QUICCore

public enum TestLogging {
    nonisolated(unsafe) private static var _bootstrapped = false

    /// Silence all Quiver loggers (quic.*, http3.*, webtransport.*, etc.)
    /// by setting `QuiverLogging.overrideLogLevel` to `.critical`.
    ///
    /// This method is idempotent: only the first call per process performs
    /// the override. It is safe to call from `override class func setUp()`
    /// in every test class without risking duplicate work.
    public static func silenceIfNeeded() {
        guard !_bootstrapped else { return }
        _bootstrapped = true
        QuiverLogging.overrideLogLevel = .critical
    }
}