import XCTest
@testable import WanxiangBook

final class BookCoverCacheTests: XCTestCase {

    func test_makeImageRequest_validURL() {
        let req = BookCover.makeImageRequestPublic(from: "https://example.com/cover.jpg")
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.url?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertNotNil(req?.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(req?.value(forHTTPHeaderField: "Referer"))
    }

    func test_makeImageRequest_emptyURL() {
        let req = BookCover.makeImageRequestPublic(from: "")
        XCTAssertNil(req)
    }

    func test_makeImageRequest_withHeaders() {
        let req = BookCover.makeImageRequestPublic(
            from: "https://img.com/a.jpg,{\"headers\":{\"Referer\":\"https://custom.com/\"}}"
        )
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.url?.absoluteString, "https://img.com/a.jpg")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Referer"), "https://custom.com/")
    }

    func test_makeImageRequest_invalidURL() {
        let req = BookCover.makeImageRequestPublic(from: "not a valid url ://")
        XCTAssertNil(req)
    }
}
