import XCTest

/// 回归测试：关键业务路径自动化验证
/// 每次提交前跑一遍，确保核心功能不被破坏
final class RegressionTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)
    }

    // MARK: - R1: 首页 Tab 切换

    func testR1_tabSwitching() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Tab bar 应存在")

        let tabs = tabBar.buttons
        XCTAssertGreaterThanOrEqual(tabs.count, 3, "至少应有3个Tab")

        for i in 0..<min(tabs.count, 4) {
            tabs.element(boundBy: i).tap()
            sleep(1)
        }
        tabs.element(boundBy: 0).tap()
        sleep(1)
    }

    // MARK: - R2: 搜索基本功能

    func testR2_searchBasicFlow() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTFail("Tab bar 未出现"); return
        }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(2)

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("斗破苍穹")
            app.keyboards.buttons["搜索"].tap()
            sleep(5)
            XCTAssertGreaterThan(app.cells.count, 0, "搜索应返回结果")
        }
    }

    // MARK: - R3: 书架存在性

    func testR3_bookshelfLoads() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 0).tap()
        sleep(2)

        let navTitle = app.navigationBars.firstMatch
        XCTAssertTrue(navTitle.exists, "书架导航栏应存在")
    }

    // MARK: - R4: 书城加载

    func testR4_bookStoreLoads() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(3)
            let hasContent = app.cells.count > 0 || app.scrollViews.count > 0
            XCTAssertTrue(hasContent, "书城应加载内容")
        }
    }

    // MARK: - R5: 我的页面

    func testR5_myPageLoads() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        let lastTab = tabBar.buttons.element(boundBy: tabBar.buttons.count - 1)
        lastTab.tap()
        sleep(2)

        let versionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '万象书屋'")
        ).firstMatch
        XCTAssertTrue(versionText.waitForExistence(timeout: 5), "我的页应显示App名")
    }

    // MARK: - R6: 伪装页不应在解锁后出现

    func testR6_disguisePageHiddenWhenUnlocked() throws {
        let qrTitle = app.staticTexts["二维码生成器"]
        XCTAssertFalse(qrTitle.exists, "解锁后不应显示伪装页")
    }

    // MARK: - R7: 应用可以正常退到后台再回来

    func testR7_backgroundForegroundCycle() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "回到前台后Tab bar应存在")
    }
}
