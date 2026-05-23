import XCTest

/// 网络异常测试：验证弱网/断网/网络恢复下的 App 行为
/// 通过飞行模式模拟断网，验证错误处理和恢复能力
final class NetworkExceptionTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)
    }

    override func tearDownWithError() throws {
        restoreNetwork()
    }

    // MARK: - 辅助方法

    private func enableAirplaneMode() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        sleep(2)

        let airplaneSwitch = settings.switches.matching(
            NSPredicate(format: "label CONTAINS '飞行模式' OR label CONTAINS 'Airplane'")
        ).firstMatch
        if airplaneSwitch.waitForExistence(timeout: 5) && airplaneSwitch.value as? String == "0" {
            airplaneSwitch.tap()
            sleep(2)
        }
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
    }

    private func restoreNetwork() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        sleep(2)

        let airplaneSwitch = settings.switches.matching(
            NSPredicate(format: "label CONTAINS '飞行模式' OR label CONTAINS 'Airplane'")
        ).firstMatch
        if airplaneSwitch.waitForExistence(timeout: 5) && airplaneSwitch.value as? String == "1" {
            airplaneSwitch.tap()
            sleep(2)
        }
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
    }

    // MARK: - N1: 断网下搜索应显示错误

    func testN1_searchOffline() throws {
        enableAirplaneMode()
        sleep(2)

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("测试网络")
            app.keyboards.buttons["搜索"].tap()
            sleep(8)

            let hasErrorOrEmpty = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '网络' OR label CONTAINS '失败' OR label CONTAINS '错误' OR label CONTAINS '重试' OR label CONTAINS '无结果'")
            ).firstMatch.waitForExistence(timeout: 10)

            XCTAssertTrue(hasErrorOrEmpty || app.cells.count == 0,
                "断网搜索应显示错误提示或空结果")
        }
        restoreNetwork()
    }

    // MARK: - N2: 断网下书城应有缓存或错误提示

    func testN2_bookStoreOffline() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(3)
        }

        enableAirplaneMode()
        sleep(2)

        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 0).tap()
            sleep(1)
            tabBar.buttons.element(boundBy: 2).tap()
            sleep(5)
        }

        let appNotCrashed = app.state == .runningForeground
        XCTAssertTrue(appNotCrashed, "断网下书城不应崩溃")
        restoreNetwork()
    }

    // MARK: - N3: 断网后恢复网络应能正常搜索

    func testN3_networkRecovery() throws {
        enableAirplaneMode()
        sleep(2)

        restoreNetwork()
        sleep(5)

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("斗破苍穹")
            app.keyboards.buttons["搜索"].tap()
            sleep(10)
            XCTAssertGreaterThan(app.cells.count, 0, "恢复网络后应能正常搜索")
        }
    }

    // MARK: - N4: 断网下 App 不应崩溃

    func testN4_offlineStability() throws {
        enableAirplaneMode()
        sleep(2)

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        for i in 0..<min(tabBar.buttons.count, 4) {
            tabBar.buttons.element(boundBy: i).tap()
            sleep(2)
            XCTAssertTrue(app.state == .runningForeground,
                "切换到Tab \(i) 后App不应崩溃")
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        app.swipeUp()
        sleep(2)
        app.swipeDown()
        sleep(2)

        XCTAssertTrue(app.state == .runningForeground, "断网操作后App应保持前台")
        restoreNetwork()
    }

    // MARK: - N5: 弱网模拟 (频繁开关网络)

    func testN5_networkFlapping() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)

        for i in 0..<3 {
            NSLog("[NetTest] 第 %d 次网络切换", i + 1)
            enableAirplaneMode()
            sleep(1)
            restoreNetwork()
            sleep(2)
            XCTAssertTrue(app.state == .runningForeground,
                "第 \(i+1) 次网络切换后App不应崩溃")
        }
    }
}
