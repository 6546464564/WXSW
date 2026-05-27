import XCTest
@testable import WanxiangBook

final class BookCoverPolicyTests: XCTestCase {

    func test_bookCoverPreloaderExists() {
        XCTAssertNotNil(BookCoverPreloader.self)
    }
}
