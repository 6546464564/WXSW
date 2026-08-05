//
//  UserJourneyUITests.swift
//  万象书屋 · 用户完整旅程测试 (层5 操作路径审计)
//
//  模拟真实用户一条龙操作, 验证跨页面状态流转不崩:
//    解锁 → 书架 → 搜索 → 点结果 → 详情页 → 开始阅读 → 阅读器翻页 → 返回 → 书架
//
//  用法: xcodebuild test -scheme WanxiangBook -destination 'platform=iOS,id=<UDID>' \
//          -only-testing:WanxiangBookUITests/UserJourneyUITests
//
//  说明: 搜索依赖线上后端, 结果可能为空。旅程测试用 demo 书保证核心阅读链路稳定,
//  搜索段只做"尽力而为" (能搜到就点, 搜不到就跳过), 不把网络结果当硬断言.
//

import XCTest

final class UserJourneyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 20, name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "元素未出现: \(name)")
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    // MARK: - 旅程 1: demo 书完整阅读链路 (稳定, 不依赖网络)

    func test_journey_demo_book_read() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-AddDemoBook"])

        // 1. 书架 + demo 书
        let shelfTab = app.buttons["tab.bookshelf"]
        waitFor(shelfTab, timeout: 20, name: "书架Tab")
        let book = app.staticTexts["测试小说·万象之旅"]
        waitFor(book, timeout: 15, name: "Demo书")
        shot("J1-书架")

        // 2. 书架点书 → 直接进阅读器 (书架书的交互是直进阅读器, 不进详情页)
        book.tap()
        let page = app.otherElements["reader-page-id"]
        waitFor(page, timeout: 25, name: "阅读器页面")

        // 3. 阅读器 → 翻页
        // 万象书屋 (真机加固): 用坐标点击页面中部唤菜单 — reader-page-id 在分页渲染时
        // 会被重建 (SwiftUI identity 竞态), page.tap() 偶发 "No matches found".
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()  // 唤出菜单
        sleep(2)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()  // 收菜单
        sleep(1)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // 翻下一页
        shot("J3-阅读器翻页")

        // 4. 返回书架
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()  // 唤出菜单
        let backBtn = app.buttons["reader.back"]
        waitFor(backBtn, timeout: 10, name: "阅读器返回")
        backBtn.tap()
        shot("J4-回到书架")
        waitFor(book, timeout: 15, name: "回到书架demo书")
    }

    // MARK: - 旅程 2: 搜索 → 详情 (尽力而为, 网络依赖)

    func test_journey_search_to_detail() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-Search", "测试"])

        let searchField = app.textFields["search.keyword"]
        waitFor(searchField, timeout: 25, name: "搜索框")
        searchField.typeText("\n")

        // 等结果 (最多 40s, 线上后端)
        let deadline = Date().addingTimeInterval(40)
        var foundResult = false
        while Date() < deadline {
            let hasResult = (try? app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '条结果'")
            ).firstMatch.exists) ?? false
            let noResult = (try? app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '没有搜到'")
            ).firstMatch.exists) ?? false
            if hasResult { foundResult = true; break }
            if noResult { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        shot("J10-搜索结果")

        // 有结果 → 点第一条 → 详情页
        if foundResult {
            let firstRow = app.cells.firstMatch
            if firstRow.exists {
                firstRow.tap()
                sleep(4)
                shot("J11-详情页")
                // 详情页应有"换源"入口
                let sourceBtn = app.buttons["换源"]
                if sourceBtn.exists {
                    sourceBtn.tap()
                    sleep(2)
                    shot("J12-换源sheet")
                }
                goBack(app)
                shot("J13-返回搜索结果")
            }
        }
    }
}
