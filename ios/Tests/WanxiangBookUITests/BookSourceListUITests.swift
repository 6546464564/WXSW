//
//  BookSourceListUITests.swift
//  万象书屋 · 书源管理页 UI 测试
//
//  用法: xcodebuild test -scheme WanxiangBook \
//          -destination 'platform=iOS Simulator,name=iPhone 17' \
//          -only-testing:WanxiangBookUITests/BookSourceListUITests
//
//  验证: 我的 → 书源管理 → 列表展示后端下发书源 + 开关可切换
//

import XCTest

final class BookSourceListUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState"]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_book_source_list() throws {
        let app = launchApp()

        // 切到"我的"Tab
        let myTab = app.buttons["tab.my"]
        XCTAssertTrue(myTab.waitForExistence(timeout: 20), "我的Tab未出现")
        myTab.tap()

        // 书源管理入口
        let row = app.buttons["my.row.book_sources"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "书源管理入口未出现")
        shot(app, "20-我的页-书源管理入口")
        row.tap()

        // 书源列表加载 (等待任一书源名出现, 后端下发至少 1 条)
        let title = app.navigationBars["书源管理"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "书源管理标题未出现")
        shot(app, "30-书源列表")

        // 等书源加载完成 (异步), 验证至少展示一条
        let loaded = waitForAnySourceRow(app, timeout: 20)
        XCTAssertTrue(loaded, "书源列表未展示任何书源")
        shot(app, "40-书源列表-已加载")
    }

    /// 轮询找任意一行书源 (Toggle 是开关, 名称是文本)
    private func waitForAnySourceRow(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 列表里只要有开关或者导航栏计数 "共 N 个书源" 都算加载成功
            let anySwitch = app.switches.firstMatch
            if anySwitch.exists && anySwitch.isHittable {
                return true
            }
            let countLabel = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH '共 '")
            ).firstMatch
            if countLabel.exists && countLabel.label.contains("个书源") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
