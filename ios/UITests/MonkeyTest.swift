import XCTest

// MARK: - Fastbot 风格自动化 UI 遍历测试
//
// 模拟 Fastbot 的智能 UI 遍历：随机点击、滑动、长按、返回等操作
// 自动检测崩溃、卡死，运行指定时长后输出覆盖统计
//
// 运行方式（模拟器）:
//   xcodebuild test -project WanxiangBook.xcodeproj -scheme WanxiangBook \
//     -destination 'platform=iOS Simulator,id=5FFE5D5B-E1BE-4039-9D60-3FA065375B89' \
//     -only-testing:WanxiangUITests/MonkeyTest/testFastbotTraversal \
//     -allowProvisioningUpdates 2>&1 | tee /tmp/monkey_test.log
//
// 运行方式（真机）:
//   xcodebuild test -project WanxiangBook.xcodeproj -scheme WanxiangBook \
//     -destination 'platform=iOS,id=D7B17A32-0B11-58BE-8FE9-43F42752A955' \
//     -only-testing:WanxiangUITests/MonkeyTest/testFastbotTraversal \
//     -allowProvisioningUpdates DEVELOPMENT_TEAM=6UX5G5838X CODE_SIGN_STYLE=Automatic \
//     2>&1 | tee /tmp/monkey_test.log

final class MonkeyTest: XCTestCase {

    var app: XCUIApplication!

    // MARK: - 配置参数
    private var testDuration: TimeInterval {
        let envMin = ProcessInfo.processInfo.environment["MONKEY_DURATION"] ?? "720"
        return TimeInterval(Int(envMin) ?? 720) * 60
    }
    private let actionInterval: TimeInterval = 0.5 // 每次操作间隔
    private let screenshotInterval: Int = 20       // 每 N 次操作截图一次
    private let maxDepth: Int = 8                  // 最大导航深度，超过则回退

    // MARK: - 状态追踪
    private var actionCount = 0
    private var crashDetected = false
    private var visitedScreens: Set<String> = []
    private var currentDepth = 0
    private var lastScreenSignature = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-unlockApp", "-skipSplash", "-uitest"]
        app.launch()
        _ = app.buttons["书架"].waitForExistence(timeout: 15)
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(string: """
            === Monkey Test Report ===
            Total Actions: \(actionCount)
            Unique Screens: \(visitedScreens.count)
            Crash Detected: \(crashDetected)
            Screens Visited: \(visitedScreens.sorted().joined(separator: "\n  "))
            """)
        attachment.name = "MonkeyTestReport"
        attachment.lifetime = .keepAlways
        add(attachment)
        app = nil
    }

    // MARK: - 主测试入口

    func testFastbotTraversal() throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < testDuration {
            guard checkAppAlive() else {
                crashDetected = true
                snapshot("CRASH-detected-action\(actionCount)")
                XCTFail("App crashed after \(actionCount) actions")
                relaunchApp()
                continue
            }

            recordScreen()
            performRandomAction()
            actionCount += 1

            if actionCount % screenshotInterval == 0 {
                snapshot("action-\(actionCount)")
            }

            Thread.sleep(forTimeInterval: actionInterval)

            if currentDepth > maxDepth {
                navigateBack()
            }
        }

        snapshot("FINAL-\(actionCount)-actions")
        print("✅ Monkey test completed: \(actionCount) actions, \(visitedScreens.count) screens, crash: \(crashDetected)")
    }

    // MARK: - 随机操作

    private func performRandomAction() {
        let weights: [(action: () -> Void, weight: Int)] = [
            (randomTap, 35),
            (randomSwipe, 15),
            (tapInteractiveElement, 25),
            (navigateBack, 10),
            (tapTabBar, 10),
            (longPress, 3),
            (doubleTap, 2),
        ]

        let totalWeight = weights.reduce(0) { $0 + $1.weight }
        var random = Int.random(in: 0..<totalWeight)
        for (action, weight) in weights {
            random -= weight
            if random < 0 {
                action()
                return
            }
        }
    }

    private func randomTap() {
        let x = CGFloat.random(in: 0.05...0.95)
        let y = CGFloat.random(in: 0.1...0.9)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    private func randomSwipe() {
        let directions: [(dx: CGFloat, dy: CGFloat, dx2: CGFloat, dy2: CGFloat)] = [
            (0.8, 0.5, 0.2, 0.5),  // left
            (0.2, 0.5, 0.8, 0.5),  // right
            (0.5, 0.8, 0.5, 0.2),  // up
            (0.5, 0.2, 0.5, 0.8),  // down
        ]
        let dir = directions.randomElement()!
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: dir.dx, dy: dir.dy))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: dir.dx2, dy: dir.dy2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func tapInteractiveElement() {
        guard app.state == .runningForeground else { return }

        let candidates: [XCUIElementQuery] = [
            app.buttons,
            app.cells,
            app.staticTexts,
            app.switches,
        ]

        let query = candidates.randomElement()!
        let count = query.count
        guard count > 0 else {
            randomTap()
            return
        }

        let index = Int.random(in: 0..<min(count, 15))
        let element = query.element(boundBy: index)
        if element.exists && element.isHittable {
            element.tap()
            currentDepth += 1
        }
    }

    private func navigateBack() {
        guard app.state == .runningForeground else { return }
        let navBar = app.navigationBars.firstMatch
        if navBar.exists {
            let backBtn = navBar.buttons.firstMatch
            if backBtn.exists && backBtn.isHittable {
                backBtn.tap()
                currentDepth = max(0, currentDepth - 1)
                return
            }
        }
        app.swipeRight()
        currentDepth = max(0, currentDepth - 1)
    }

    private func tapTabBar() {
        let tabs = ["书架", "书城", "我的"]
        let tab = tabs.randomElement()!
        let btn = app.buttons[tab]
        if btn.exists && btn.isHittable {
            btn.tap()
            currentDepth = 0
        }
    }

    private func longPress() {
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            .press(forDuration: 1.5)
    }

    private func doubleTap() {
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).doubleTap()
    }

    // MARK: - 检测与恢复

    private func checkAppAlive() -> Bool {
        let state = app.state
        return state == .runningForeground || state == .runningBackground
    }

    private func relaunchApp() {
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        app.launch()
        _ = app.buttons["书架"].waitForExistence(timeout: 15)
        currentDepth = 0
    }

    private func recordScreen() {
        guard app.state == .runningForeground else { return }
        let sig = screenSignature()
        if sig != lastScreenSignature {
            visitedScreens.insert(sig)
            lastScreenSignature = sig
        }
    }

    private func screenSignature() -> String {
        let navBar = app.navigationBars.firstMatch
        let navTitle = navBar.exists ? (navBar.identifier.isEmpty ? navBar.label : navBar.identifier) : "no-nav"
        var labels: [String] = []
        let count = min(app.buttons.count, 5)
        for i in 0..<count {
            let btn = app.buttons.element(boundBy: i)
            if btn.exists { labels.append(btn.label) }
        }
        return "\(navTitle)|\(labels.prefix(3).joined(separator: ","))"
    }

    private func snapshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
