//
//  StressTests.swift
//  万象书屋 · 压力测试（模拟器用）
//
//  前置条件: 模拟器数据库已注入 52 本 stress://book/N 测试书 (共 53 本含 demo).
//  验证: 书架大量书籍时启动稳定性 + 滚动流畅性 + 点击进阅读器.
//
//  xcodebuild test ... -only-testing:WanxiangBookUITests/StressTests

import XCTest

final class StressTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_stress_shelf_scroll() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()

        // 书架 Tab 出现
        let tabBar = app.buttons["tab.bookshelf"]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "书架Tab未出现")

        // 第一个压力书出现
        let firstBook = app.staticTexts["压力测试书·第1卷"]
        XCTAssertTrue(firstBook.waitForExistence(timeout: 15), "压力书1未出现")
        let shot1 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot1.name = "压力-初始书架"
        shot1.lifetime = .keepAlways
        add(shot1)

        // 书籍列表 ScrollView 是第二个 (第一个是顶部"全部/未分组"分类栏)
        let scrollView = app.scrollViews.element(boundBy: 1)
        var sawLaterBook = false
        for i in 1...8 {
            scrollView.swipeUp()
            sleep(1)
            // 中途确认滚动真的生效 (能看到后面的书)
            if i >= 4 && app.staticTexts["压力测试书·第30卷"].exists {
                sawLaterBook = true
            }
        }
        XCTAssertTrue(sawLaterBook, "滚动后应能看到压力书第30卷(书架未滚到底)")
        let shot2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot2.name = "压力-滚动8次后"
        shot2.lifetime = .keepAlways
        add(shot2)

        // 向下滚回顶部, 验证反向滚动
        for _ in 1...8 {
            scrollView.swipeDown()
            sleep(1)
        }
        XCTAssertTrue(firstBook.waitForExistence(timeout: 10), "滚回顶部后应能看到压力书1")

        // 滚动全程无崩溃: 进入 demo 书阅读器验证 app 仍正常响应
        let demoBook = app.staticTexts["测试小说·万象之旅"]
        if demoBook.waitForExistence(timeout: 5) {
            demoBook.tap()
            let page = app.otherElements["reader-page-id"]
            XCTAssertTrue(page.waitForExistence(timeout: 20), "滚动后 app 仍可打开阅读器")
            let shot3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot3.name = "压力-滚动后进阅读器"
            shot3.lifetime = .keepAlways
            add(shot3)
        }
    }
}
