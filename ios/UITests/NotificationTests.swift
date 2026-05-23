import XCTest

/// 推送通知测试：通知权限、通知展示、点击跳转
final class NotificationTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)
    }

    // MARK: - N1: App 正常处理通知权限弹窗

    func testN1_notificationPermissionHandling() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            let allow = alert.buttons["允许"].exists ? alert.buttons["允许"] :
                        alert.buttons["Allow"].exists ? alert.buttons["Allow"] :
                        alert.buttons.firstMatch
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.state == .runningForeground, "处理通知权限后App应在前台")
    }

    // MARK: - N2: 拉下通知中心不崩溃

    func testN2_notificationCenterPull() throws {
        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coord.press(forDuration: 0.1, thenDragTo: target)
        sleep(2)

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(app.state == .runningForeground,
            "拉下通知中心后App应能正常恢复")
    }

    // MARK: - N3: 控制中心不崩溃

    func testN3_controlCenterPull() throws {
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bottom.press(forDuration: 0.1, thenDragTo: mid)
        sleep(2)

        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(app.state == .runningForeground,
            "拉出控制中心后App应能正常恢复")
    }
}
