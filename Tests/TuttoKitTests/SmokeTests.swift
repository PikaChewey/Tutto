import XCTest
@testable import TuttoKit
final class SmokeTests: XCTestCase { func testVersion() { XCTAssertFalse(TuttoKit.version.isEmpty) } }
