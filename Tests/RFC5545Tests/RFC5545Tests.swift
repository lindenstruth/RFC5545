import XCTest
@testable import RFC5545

final class RFC5545Tests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(RFC5545().text, "Hello, World!")
    }
}
