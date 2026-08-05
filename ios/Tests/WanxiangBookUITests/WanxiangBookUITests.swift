//
//  WanxiangBookUITests.swift
//  万象书屋 · 真机 UI 冒烟测试
//
//  用法: xcodebuild test -scheme WanxiangBook -destination 'platform=iOS,id=<UDID>' \
//          -only-testing:WanxiangBookUITests
//
//  每个 test 用 App 内置的测试钩子控制启动状态:
//    -uitest          注入 UITEST 激活码 + 跳过网络初始化
//    -unlockApp       跳过伪装面, 直接解锁主界面
//    -skipSplash      跳过开屏广告
//    -resetAppState   清掉解锁标记 (测伪装门时用)
//    --AddDemoBook    注入一本 5 章 demo 书
//    --OpenDemoReader 直接打开 demo 书阅读器
//    --Search <kw>    直接打开搜索结果
//
//  每一步都调用 shot(name:) 截图, 截图存进 xcresult, 事后可导出人工核对.

import XCTest

final class WanxiangBookUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // 万象书屋: 启动参数横杠规则 —
        // App 级参数 (-uitest / -unlockApp / -skipSplash / -resetAppState) 在代码里
        // 用 CommandLine.arguments.contains("-uitest") 单横杠匹配, 必须传单横杠;
        // RootView 深链参数 (-AddDemoBook / -OpenDemoReader / -Search) 代码里
        // 双横杠/单横杠都匹配, 统一用单横杠避免歧义.
        // 每个测试都带 -resetAppState 保证从确定的解锁状态启动 (UI 测试共享安装,
        // UserDefaults 会跨测试持久化, 必须显式重置).
        app.launchArguments += arguments
        app.launch()
        return app
    }

    /// 截图并附到 xcresult
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 等待元素出现
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "元素未出现: \(name)")
    }

    // MARK: - 场景 1: 伪装门 + 激活码解锁

    func test_disguiseGate_and_unlock() throws {
        let app = launchApp(arguments: ["-uitest", "-skipSplash", "-resetAppState"])

        // 等待伪装门出现 (二维码生成器界面)
        let feedbackBtn = app.buttons["btn_feedback"]
        waitFor(feedbackBtn, timeout: 20, name: "伪装门反馈按钮")
        shot("01-伪装门")

        // 打开反馈 sheet
        feedbackBtn.tap()
        let submitBtn = app.buttons["提交反馈"]
        waitFor(submitBtn, timeout: 10, name: "反馈提交按钮")
        shot("02-反馈sheet")

        // 输入激活码 UITEST (由 -uitest 注入)
        let contactField = app.textFields.firstMatch
        XCTAssertTrue(contactField.waitForExistence(timeout: 8), "联系方式输入框未出现")
        contactField.tap()
        contactField.typeText("UITEST")
        shot("03-输入激活码")

        // 提交 → 触发 onUnlock → 进入主界面
        submitBtn.tap()

        // 解锁后应出现底部 TabBar (书架)
        let tabBar = app.buttons["tab.bookshelf"]
        waitFor(tabBar, timeout: 15, name: "解锁后底部书架Tab")
        shot("04-解锁后书架")
    }

    // MARK: - 场景 2: 书架 + Demo 书 + 阅读器

    func test_bookshelf_and_reader() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-AddDemoBook"])

        // 书架 Tab 应存在 (默认即书架)
        let tabBar = app.buttons["tab.bookshelf"]
        waitFor(tabBar, timeout: 20, name: "书架Tab")
        shot("10-书架")

        // demo 书应在书架里
        let book = app.staticTexts["测试小说·万象之旅"]
        waitFor(book, timeout: 15, name: "Demo书")
        shot("11-书架含Demo书")

        // 点击打开阅读器
        book.tap()
        // 阅读器页面出现后, 先点一下页面唤出菜单 (返回按钮在菜单覆盖层里)
        let page = app.otherElements["reader-page-id"]
        waitFor(page, timeout: 20, name: "阅读器页面")
        // 万象书屋 (真机加固): 坐标点击绕开 reader-page-id 分页渲染重建竞态
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let backBtn = app.buttons["reader.back"]
        waitFor(backBtn, timeout: 10, name: "阅读器返回按钮")
        shot("12-阅读器")
    }

    // MARK: - 场景 3: 直接打开 Demo 书阅读器 + 翻页

    func test_reader_deep_link() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-AddDemoBook", "-OpenDemoReader"])

        // 直接进阅读器: 先等页面, 点一下唤出菜单 (菜单覆盖层默认隐藏)
        let page = app.otherElements["reader-page-id"]
        waitFor(page, timeout: 25, name: "阅读器页面")
        // 万象书屋 (真机加固): 坐标点击绕开 reader-page-id 分页渲染重建竞态
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let backBtn = app.buttons["reader.back"]
        waitFor(backBtn, timeout: 10, name: "阅读器菜单(返回按钮)")
        shot("20-阅读器菜单")

        // reader.back 是"退出阅读器"而非"关菜单", 不能点。点页面中部空白区收起菜单,
        // 再点页面右侧 1/3 → 下一页 (三段点击区: 左翻上页 / 中菜单 / 右翻下页)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)  // 等菜单收起动画
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        shot("21-翻页后")
    }

    // MARK: - 场景 4: 搜索

    func test_search() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState", "-Search", "测试"])

        // 搜索框出现
        let searchField = app.textFields["search.keyword"]
        waitFor(searchField, timeout: 25, name: "搜索框")

        // 触发搜索 (回车), 等待结果或 loading
        searchField.typeText("\n")
        shot("30-搜索页")

        // 万象书屋 (fix): 之前 activeSources 从未赋值 → loading 文案永远 "0 个书源搜索中…".
        // 修复后应显示真实启用书源数 (>0). 搜索很快时 loading 可能一闪而过,
        // 但若观察到 loading, 其计数必须非零 (或搜索已直接出结果).
        // 注意: firstMatch.exists 在 UI 元素不存在时可能抛 snapshot 异常, 用
        //  `count > 0` 判断, 并 try? 包一层, 保证轮询稳定.
        let deadline = Date().addingTimeInterval(30)
        var sawZero = false
        while Date() < deadline {
            let loadingQuery = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '个书源搜索中'")
            )
            let loadingExists = (try? loadingQuery.firstMatch.exists) ?? false
            if loadingExists, let label = try? loadingQuery.firstMatch.label {
                if !label.hasPrefix("0 ") {
                    shot("35-搜索中-真实书源数")
                    break
                }
                sawZero = true
            }
            let doneQuery = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '结果' OR label CONTAINS '没有搜到'")
            )
            let doneExists = (try? doneQuery.firstMatch.exists) ?? false
            if doneExists {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(sawZero, "搜索中仍显示 0 个书源")
        shot("39-搜索结果")
    }

    // MARK: - 场景 5: 书城

    func test_bookstore() throws {
        let app = launchApp(arguments: ["-uitest", "-unlockApp", "-skipSplash", "-resetAppState"])

        let bookstoreTab = app.buttons["tab.bookstore"]
        waitFor(bookstoreTab, timeout: 20, name: "书城Tab")
        bookstoreTab.tap()
        // 书城页面加载 (等待任一文本出现)
        sleep(6) // 等 mirror 或直抓返回
        shot("40-书城")
    }
}
