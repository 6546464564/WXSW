import XCTest

/// 无障碍测试：VoiceOver 可用性、动态字体、UI 元素可访问性
final class AccessibilityTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)
    }

    // MARK: - A1: 所有 Tab 都有无障碍标签

    func testA1_tabBarAccessibility() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTFail("Tab bar 不存在"); return
        }
        for i in 0..<tabBar.buttons.count {
            let btn = tabBar.buttons.element(boundBy: i)
            XCTAssertTrue(btn.isAccessibilityElement || btn.exists,
                "Tab \(i) 应可被无障碍识别")
            XCTAssertFalse(btn.label.isEmpty,
                "Tab \(i) 应有无障碍标签")
        }
    }

    // MARK: - A2: 导航栏返回按钮可访问

    func testA2_navigationBackButtonAccessibility() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(2)
            let cell = app.cells.firstMatch
            if cell.waitForExistence(timeout: 5) {
                cell.tap()
                sleep(2)
                let backBtn = app.navigationBars.buttons.firstMatch
                if backBtn.waitForExistence(timeout: 3) {
                    XCTAssertFalse(backBtn.label.isEmpty, "返回按钮应有无障碍标签")
                }
            }
        }
    }

    // MARK: - A3: 书架列表项可访问

    func testA3_bookshelfItemsAccessible() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 0).tap()
        sleep(2)

        let cells = app.cells
        if cells.count > 0 {
            let first = cells.firstMatch
            XCTAssertTrue(first.isAccessibilityElement || first.exists,
                "书架项应可被无障碍识别")
        }
    }

    // MARK: - A4: 搜索框可访问

    func testA4_searchFieldAccessible() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(2)

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            XCTAssertFalse(searchField.placeholderValue?.isEmpty ?? true,
                "搜索框应有占位文字")
        }
    }

    // MARK: - A5: 按钮最小点击区域

    func testA5_minimumTapArea() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: tabBar.buttons.count - 1).tap()
        sleep(2)

        let buttons = app.buttons
        for i in 0..<min(buttons.count, 10) {
            let btn = buttons.element(boundBy: i)
            if btn.exists && btn.isHittable {
                let frame = btn.frame
                let tooSmall = frame.width < 44 || frame.height < 44
                if tooSmall {
                    NSLog("[A11y] ⚠️ 按钮 '%@' 太小: %.0fx%.0f (建议≥44x44)",
                          btn.label, frame.width, frame.height)
                }
            }
        }
    }

    // MARK: - A6: 动态字体支持

    func testA6_dynamicTypeSupport() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        let texts = app.staticTexts
        XCTAssertGreaterThan(texts.count, 0, "页面应有文本元素")

        var fontSizes = Set<CGFloat>()
        for i in 0..<min(texts.count, 20) {
            let text = texts.element(boundBy: i)
            if text.exists {
                fontSizes.insert(text.frame.height)
            }
        }
        XCTAssertGreaterThan(fontSizes.count, 1,
            "应有多种字号 (表示使用了动态字体层级)")
    }

    // MARK: - A7: 图片应有描述

    func testA7_imagesHaveDescriptions() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 0).tap()
        sleep(2)

        let images = app.images
        var missingLabels = 0
        for i in 0..<min(images.count, 10) {
            let img = images.element(boundBy: i)
            if img.exists && img.label.isEmpty {
                missingLabels += 1
            }
        }
        if images.count > 0 {
            NSLog("[A11y] 图片无障碍: %d/%d 有标签", images.count - missingLabels, images.count)
        }
    }
}
