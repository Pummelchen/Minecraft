// Silences verbose logging during test execution.
// The `AAA_` prefix ensures this XCTestCase sorts first alphabetically,
// so its `setUp()` runs before any other test class in this target.
// XCTest classes are also processed before Swift Testing suites.
//
// The actual override is delegated to `QuiverTestSupport.TestLogging`
// which guards against double-initialization across test targets.

import XCTest
import QuiverTestSupport

final class AAA_TestLoggingBootstrap: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestLogging.silenceIfNeeded()
    }

    func testLoggingBootstrapped() {
        // Ensures this class is discovered by XCTest
    }
}