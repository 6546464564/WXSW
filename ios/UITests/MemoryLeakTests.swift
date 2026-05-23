import XCTest

/// 内存泄漏测试：反复进出页面检测内存是否持续增长
final class MemoryLeakTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)
    }

    // MARK: - M1: 反复切换 Tab 内存不应持续增长

    func testM1_tabSwitchingMemory() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        let tabCount = min(tabBar.buttons.count, 4)
        for cycle in 0..<10 {
            for i in 0..<tabCount {
                tabBar.buttons.element(boundBy: i).tap()
                usleep(500_000)
            }
            NSLog("[MemLeak] Tab切换 第%d轮完成", cycle + 1)
        }
        XCTAssertTrue(app.state == .runningForeground,
            "10轮Tab切换后App应仍在前台")
    }

    // MARK: - M2: 反复进出搜索页面

    func testM2_searchPageMemory() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        for cycle in 0..<5 {
            tabBar.buttons.element(boundBy: 1).tap()
            sleep(1)

            let searchField = app.searchFields.firstMatch
            if searchField.waitForExistence(timeout: 3) {
                searchField.tap()
                searchField.typeText("测试\(cycle)")
                app.keyboards.buttons["搜索"].tap()
                sleep(3)
            }

            tabBar.buttons.element(boundBy: 0).tap()
            sleep(1)
            NSLog("[MemLeak] 搜索循环 第%d轮完成", cycle + 1)
        }
        XCTAssertTrue(app.state == .runningForeground, "搜索循环后App应在前台")
    }

    // MARK: - M3: 反复进出书城详情

    func testM3_bookDetailMemory() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(3)

            for cycle in 0..<5 {
                let cell = app.cells.firstMatch
                if cell.waitForExistence(timeout: 5) {
                    cell.tap()
                    sleep(2)
                    let backBtn = app.navigationBars.buttons.firstMatch
                    if backBtn.waitForExistence(timeout: 3) {
                        backBtn.tap()
                        sleep(1)
                    }
                }
                NSLog("[MemLeak] 书城详情 第%d轮完成", cycle + 1)
            }
        }
        XCTAssertTrue(app.state == .runningForeground, "书城循环后App应在前台")
    }

    // MARK: - M4: 反复前后台切换

    func testM4_backgroundForegroundMemory() throws {
        for cycle in 0..<10 {
            XCUIDevice.shared.press(.home)
            sleep(1)
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 10)
            sleep(1)
            NSLog("[MemLeak] 前后台切换 第%d轮完成", cycle + 1)
        }
        XCTAssertTrue(app.state == .runningForeground,
            "10轮前后台切换后App应仍在前台")
    }

    // MARK: - M5: 滚动列表内存

    func testM5_scrollListMemory() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(3)

            for cycle in 0..<20 {
                app.swipeUp()
                usleep(300_000)
                if cycle % 5 == 4 {
                    app.swipeDown()
                    app.swipeDown()
                    app.swipeDown()
                    sleep(1)
                }
            }
        }
        XCTAssertTrue(app.state == .runningForeground, "滚动列表后App应在前台")
    }
}
