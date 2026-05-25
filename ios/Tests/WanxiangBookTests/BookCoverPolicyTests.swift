import XCTest
@testable import WanxiangBook

final class BookCoverPolicyTests: XCTestCase {

    private let preloadKey = "wanxiang.shelf.preloadCovers"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: preloadKey)
        super.tearDown()
    }

    func test_coverPolicyDefaults() {
        UserDefaults.standard.removeObject(forKey: preloadKey)
        let preload = UserDefaults.standard.object(forKey: preloadKey) as? Bool ?? false
        XCTAssertFalse(preload, "默认不预加载封面")
    }

    func test_preloadCoversCanBeToggled() {
        UserDefaults.standard.set(true, forKey: preloadKey)
        XCTAssertEqual(UserDefaults.standard.object(forKey: preloadKey) as? Bool, true)
    }
}
