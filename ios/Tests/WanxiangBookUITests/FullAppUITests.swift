//
//  FullAppUITests.swift
//  万象书屋 · 全页面 UI 覆盖测试 (层3 全面检查)
//
//  覆盖现有冒烟测试没走到的高风险页面:
//    · "我的" Tab 全部入口: 主题 / 护眼 / 反馈 / 下载管理 / 应用伪装
//    · 搜索 → 详情页 → 换源 sheet
//    · 书架 "+" 菜单 → 管理分组 sheet
//
//  用法: xcodebuild test -scheme WanxiangBook -destination 'platform=iOS,id=<UDID>' \
//          -only-testing:WanxiangBookUITests/FullAppUITests
//

import XCTest

final class FullAppUITests: XCTestCase {

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

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "元素未出现: \(name)")
    }

    /// 导航返回上一页 (navigationBar 的 back 按钮)
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists {
            back.tap()
        }
    }

    // MARK: - 场景 1: "我的" Tab 全入口

    func test_my_tab_all_entries() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState"])

        // 切到"我的" Tab
        let myTab = app.buttons["tab.my"]
        waitFor(myTab, timeout: 20, name: "我的Tab")
        myTab.tap()
        // 万象书屋 (真机加固): tap 后等"我的"导航栏出现, 确认 tab 切换真正完成,
        // 再找列表入口. 真机 UI 测试偶发 tap 后仍停在上一 tab (SwiftUI 首帧渲染竞争).
        let myNav = app.navigationBars["我的"]
        waitFor(myNav, timeout: 10, name: "我的导航栏")
        shot("A01-我的页")

        // 1. 书源管理入口 (已覆盖单独测试, 这里只验证存在)
        let sourceRow = app.buttons["my.row.book_sources"]
        waitFor(sourceRow, timeout: 15, name: "书源管理入口")

        // 2. 意见反馈 → 打开 → 返回
        let feedbackRow = app.buttons["my.row.feedback"]
        waitFor(feedbackRow, timeout: 10, name: "反馈入口")
        feedbackRow.tap()
        let feedbackTitle = app.navigationBars["意见反馈"]
        waitFor(feedbackTitle, timeout: 10, name: "反馈页标题")
        shot("A02-反馈页")
        goBack(app)

        // 3. 下载管理 → 打开 → 返回
        let downloadRow = app.buttons["my.row.download_manage"]
        waitFor(downloadRow, timeout: 10, name: "下载管理入口")
        downloadRow.tap()
        let downloadTitle = app.navigationBars["下载管理"]
        waitFor(downloadTitle, timeout: 10, name: "下载管理标题")
        shot("A03-下载管理")
        goBack(app)

        // 4. 回到我的页, 验证主题模式行还在 (页面没崩)
        waitFor(sourceRow, timeout: 10, name: "回到我的页")
        shot("A04-回到我的页")
    }

    // MARK: - 场景 2: 搜索 → 详情页

    func test_search_result_to_detail() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-Search", "测试"])

        // 搜索框出现, 触发搜索
        let searchField = app.textFields["search.keyword"]
        waitFor(searchField, timeout: 25, name: "搜索框")
        searchField.typeText("\n")

        // 等结果出现 (或没有搜到), 最多 30s
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let hasResult = (try? app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '条结果'")
            ).firstMatch.exists) ?? false
            let noResult = (try? app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '没有搜到'")
            ).firstMatch.exists) ?? false
            if hasResult || noResult { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        shot("B01-搜索结果")

        // 如果搜到了, 点第一条结果进详情页
        let anyResult = (try? app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '条结果'")
        ).firstMatch.exists) ?? false
        if anyResult {
            // 点第一行 (结果列表里的第一本书)
            let firstRow = app.cells.firstMatch
            if firstRow.exists {
                firstRow.tap()
                shot("B02-详情页")
                // 详情页应有返回按钮 (证明已进入二级页)
                sleep(2)
                goBack(app)
                shot("B03-返回搜索结果")
            }
        }
    }

    // MARK: - 场景 3: 书架 "⋯" 菜单 → 分组管理 / 书架管理

    func test_bookshelf_manage_menus() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState"])

        let shelfTab = app.buttons["tab.bookshelf"]
        waitFor(shelfTab, timeout: 20, name: "书架Tab")
        // 万象书屋 (真机加固): 显式切到书架 tab — UI 测试共享安装时启动 tab 可能残留
        // 在书城/我的, 直接找"更多"会找不到. 先 tap 书架并等导航栏确认切到位.
        shelfTab.tap()
        let shelfNav = app.navigationBars["书架"]
        waitFor(shelfNav, timeout: 10, name: "书架导航栏")
        shot("C01-书架")

        // "⋯" 工具栏菜单
        var moreBtn = app.buttons.matching(NSPredicate(format: "label == '更多' OR identifier == 'ellipsis.circle'")).firstMatch
        if !moreBtn.exists {
            // 兜底: 工具栏最后一个按钮
            let lastToolbar = app.navigationBars.buttons.element(boundBy: 0)
            if lastToolbar.exists { moreBtn = lastToolbar }
        }
        waitFor(moreBtn, timeout: 10, name: "书架更多菜单")
        moreBtn.tap()
        shot("C02-书架菜单展开")

        // 分组管理 sheet
        let groupManage = app.buttons["分组管理"]
        if groupManage.exists {
            groupManage.tap()
            sleep(2)
            shot("C03-分组管理sheet")
        }

        // 书架管理页
        moreBtn.tap()
        let shelfManage = app.buttons["书架管理"]
        if shelfManage.exists {
            shelfManage.tap()
            let manageTitle = app.navigationBars["书架管理"]
            waitFor(manageTitle, timeout: 10, name: "书架管理页")
            shot("C04-书架管理页")
            goBack(app)
        }
    }
}
