import XCTest

/// 新功能回归 — 书架/书城/我的 近期改动专项
final class FeatureRegressionTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-unlockApp", "-skipSplash", "-uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.bookshelf"].waitForExistence(timeout: 10)
            || app.buttons["书架"].waitForExistence(timeout: 5), "主界面未加载")
    }

    // MARK: - Helpers

    private func tapTab(_ id: String, fallback: String) {
        if app.buttons[id].waitForExistence(timeout: 3) {
            app.buttons[id].tap()
        } else {
            app.buttons[fallback].tap()
        }
        sleep(1)
    }

    private func tapFirst(_ candidates: [XCUIElement]) -> Bool {
        for el in candidates {
            if el.waitForExistence(timeout: 3), el.isHittable {
                el.tap()
                return true
            }
        }
        return false
    }

    private func back() {
        let backBtn = app.navigationBars.buttons.firstMatch
        if backBtn.waitForExistence(timeout: 2), backBtn.isHittable {
            backBtn.tap()
        } else {
            app.swipeRight()
        }
        sleep(1)
    }

    // MARK: - Tab 标识

    func testF1_tabIdentifiersNavigate() throws {
        tapTab("tab.bookstore", fallback: "书城")
        XCTAssertTrue(app.buttons["bookstore.search"].waitForExistence(timeout: 8)
            || app.scrollViews.firstMatch.exists)

        tapTab("tab.my", fallback: "我的")
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS '万象书屋'")).firstMatch.exists)

        tapTab("tab.bookshelf", fallback: "书架")
        XCTAssertTrue(app.navigationBars["书架"].waitForExistence(timeout: 5)
            || app.buttons.matching(NSPredicate(format: "label CONTAINS '全部'")).firstMatch.exists)
    }

    // MARK: - 书城频道 + 搜索

    func testF2_bookstoreChannelSwitch() throws {
        tapTab("tab.bookstore", fallback: "书城")
        _ = app.buttons["bookstore.search"].waitForExistence(timeout: 8)

        for (id, label) in [
            ("bookstore.channel.male", "男生"),
            ("bookstore.channel.female", "女生"),
            ("bookstore.channel.publish", "出版"),
        ] {
            let tapped = tapFirst([
                app.buttons[id],
                app.buttons[label],
            ])
            XCTAssertTrue(tapped, "应能切换到频道 \(label)")
            sleep(1)
        }
    }

    func testF3_bookstoreSearchKeyword() throws {
        tapTab("tab.bookstore", fallback: "书城")
        XCTAssertTrue(app.buttons["bookstore.search"].waitForExistence(timeout: 5))
        app.buttons["bookstore.search"].tap()
        sleep(1)

        let field = app.textFields["search.keyword"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "搜索框应有 search.keyword 标识")
        field.tap()
        field.typeText("修仙\n")
        sleep(4)

        let hasResults = app.cells.firstMatch.waitForExistence(timeout: 12)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS '修仙'")).firstMatch.exists
        XCTAssertTrue(hasResults, "搜索「修仙」应返回结果")
        back()
    }

    // MARK: - 我的页子入口

    func testF4_myDownloadManage() throws {
        tapTab("tab.my", fallback: "我的")
        XCTAssertTrue(tapFirst([
            app.buttons["my.row.download_manage"],
            app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", "下载管理")).firstMatch,
        ]), "应能进入下载管理")
        sleep(1)
        XCTAssertTrue(app.navigationBars.firstMatch.exists || app.staticTexts["下载"].exists)
        back()
    }

    func testF5_myReadRecord() throws {
        tapTab("tab.my", fallback: "我的")
        XCTAssertTrue(tapFirst([
            app.buttons["my.row.read_record"],
            app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", "阅读记录")).firstMatch,
        ]), "应能进入阅读记录")
        sleep(1)
        back()
    }

    func testF6_myFeedback() throws {
        tapTab("tab.my", fallback: "我的")
        XCTAssertTrue(tapFirst([
            app.buttons["my.row.feedback"],
            app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", "意见反馈")).firstMatch,
        ]), "应能进入意见反馈")
        sleep(1)
        if app.buttons["取消"].waitForExistence(timeout: 2) {
            app.buttons["取消"].tap()
        } else {
            back()
        }
    }

    // MARK: - 书架

    func testF7_bookshelfGroupAndMenu() throws {
        tapTab("tab.bookshelf", fallback: "书架")
        let groupChip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '全部' OR label CONTAINS '未分组'")
        ).firstMatch
        XCTAssertTrue(groupChip.waitForExistence(timeout: 5), "书架应有分组 chip")

        let menuBtn = app.navigationBars.buttons.element(boundBy: 1)
        if menuBtn.waitForExistence(timeout: 3) {
            menuBtn.tap()
            sleep(1)
            let layoutItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '布局'")).firstMatch
            XCTAssertTrue(layoutItem.waitForExistence(timeout: 3), "菜单应含布局设置")
            if app.buttons["完成"].exists { app.buttons["完成"].tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap() }
        }
    }

    func testF8_bookshelfLayoutUnreadToggle() throws {
        tapTab("tab.bookshelf", fallback: "书架")
        let menuBtn = app.navigationBars.buttons.element(boundBy: 1)
        guard menuBtn.waitForExistence(timeout: 3) else { return }
        menuBtn.tap()
        sleep(1)

        let layoutItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '布局'")).firstMatch
        guard layoutItem.waitForExistence(timeout: 3) else { return }
        layoutItem.tap()
        sleep(1)

        let unreadToggle = app.switches.matching(
            NSPredicate(format: "label CONTAINS '未读'")
        ).firstMatch
        if unreadToggle.waitForExistence(timeout: 3) {
            unreadToggle.tap()
            sleep(1)
            unreadToggle.tap()
        }
        if app.buttons["完成"].waitForExistence(timeout: 2) {
            app.buttons["完成"].tap()
        }
    }
}
