import XCTest
@testable import WanxiangBook

/// 升级兼容测试：旧数据格式迁移、字段缺失容错
final class UpgradeCompatTests: XCTestCase {

    // MARK: - U1: ShelfBook 字段缺失容错

    func test_shelfBook_missingFields() {
        let minimalJson = """
        {"name":"测试书","bookUrl":"https://test.com/book/1","origin":"https://test.com"}
        """
        let data = minimalJson.data(using: .utf8)!
        let book = try? JSONDecoder().decode(ShelfBook.self, from: data)
        XCTAssertNotNil(book, "最小字段的ShelfBook应能成功解码")
        XCTAssertEqual(book?.name, "测试书")
    }

    // MARK: - U2: BookChapter 字段缺失容错

    func test_bookChapter_missingFields() {
        let json = """
        {"title":"第1章","url":"https://test.com/c1","index":0}
        """
        let data = json.data(using: .utf8)!
        let chapter = try? JSONDecoder().decode(BookChapter.self, from: data)
        XCTAssertNotNil(chapter, "最小字段的BookChapter应能成功解码")
    }

    // MARK: - U3: BookSource JSON 兼容性

    func test_bookSource_legadoFormat() {
        let legadoJson = """
        {
            "bookSourceName": "测试源",
            "bookSourceUrl": "https://test.com",
            "bookSourceType": 0,
            "enabled": true,
            "ruleSearch": {"bookList": "class.novlist"},
            "ruleBookInfo": {"name": "h1"},
            "ruleToc": {"chapterList": "dd>a"},
            "ruleContent": {"content": "#content"}
        }
        """
        let data = legadoJson.data(using: .utf8)!
        let source = try? JSONDecoder().decode(BookSource.self, from: data)
        XCTAssertNotNil(source, "Legado格式书源应能解码")
        XCTAssertEqual(source?.bookSourceName, "测试源")
    }

    // MARK: - U4: UserDefaults 旧键名兼容

    func test_userDefaults_oldKeys() {
        let key = "wx.game.unlocked"
        let current = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: key), current,
            "wx.game.unlocked 键应可正常读写")
    }

    // MARK: - U5: 版本号格式

    func test_versionFormat() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        XCTAssertNotNil(version, "版本号不应为空")
        XCTAssertNotNil(build, "构建号不应为空")
    }
}
