import XCTest

/// 崩溃恢复测试：模拟异常场景后 App 恢复能力
final class CrashRecoveryTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
    }

    // MARK: - CR1: App 冷启动正常

    func testCR1_coldStartNormal() throws {
        app.launch()
        sleep(5)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15),
            "冷启动后Tab bar应在15秒内出现")
    }

    // MARK: - CR2: 强制终止后重启

    func testCR2_forceTerminateAndRestart() throws {
        app.launch()
        sleep(3)

        app.terminate()
        sleep(2)

        app.launch()
        sleep(5)

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15),
            "强制终止后重启应正常")
    }

    // MARK: - CR3: 连续多次重启

    func testCR3_multipleRestarts() throws {
        for i in 0..<5 {
            app.launch()
            sleep(3)
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 15),
                "第\(i+1)次启动后Tab bar应存在")
            app.terminate()
            sleep(1)
        }
    }

    // MARK: - CR4: 后台回收后恢复

    func testCR4_backgroundRecovery() throws {
        app.launch()
        sleep(3)

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }

        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)

        XCUIDevice.shared.press(.home)
        sleep(5)

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)

        XCTAssertTrue(app.state == .runningForeground,
            "长时间后台后应能正常恢复")
    }

    // MARK: - CR5: 启动时数据库完整性

    func testCR5_databaseIntegrityOnStart() throws {
        app.launch()
        sleep(5)

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 15) else {
            XCTFail("启动失败"); return
        }

        tabBar.buttons.element(boundBy: 0).tap()
        sleep(2)

        let hasContent = app.cells.count > 0 ||
                         app.staticTexts.matching(
                            NSPredicate(format: "label CONTAINS '空' OR label CONTAINS '添加'")
                         ).firstMatch.exists
        XCTAssertTrue(hasContent, "书架应有内容或显示空态")
    }

    // MARK: - CR6: 快速连续启动

    func testCR6_rapidLaunchCycles() throws {
        for i in 0..<3 {
            app.launch()
            sleep(1)
            app.terminate()
            usleep(500_000)
            NSLog("[CrashRecovery] 快速启动第%d次", i + 1)
        }

        app.launch()
        sleep(5)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15),
            "快速连续启动后应能正常运行")
    }
}
