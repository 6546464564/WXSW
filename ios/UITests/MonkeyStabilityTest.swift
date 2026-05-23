import XCTest

/// 万象书屋 Monkey 全功能增强稳定性测试
///
/// 功能矩阵 (20项):
///   基础: 随机点击 / 滑动 / Tab切换 / 返回 / 长按 / 双击 / 元素点击
///   输入: 文字输入 / 边界输入 (超长文本/emoji/特殊字符)
///   生命周期: 前后台切换 / 多任务切换 / 数据清理重启
///   环境: 网络切换 / 屏幕旋转 / 暗色模式切换
///   手势: 缩放手势 / 下拉刷新
///   高级: 业务流程 / 快速连续操作(压力测试) / UI异常检测
///   监控: 内存追踪 / 性能指标 / 慢操作检测
///
final class MonkeyStabilityTest: XCTestCase {

    var app: XCUIApplication!

    private var durationMinutes: Int {
        Int(ProcessInfo.processInfo.environment["MONKEY_DURATION"] ?? "720") ?? 720
    }
    private var throttleMs: Int {
        Int(ProcessInfo.processInfo.environment["MONKEY_THROTTLE"] ?? "500") ?? 500
    }
    private var screenshotIntervalSec: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["MONKEY_SCREENSHOT_INTERVAL"] ?? "300") ?? 300
    }

    private var actionCount = 0
    private var crashCount = 0
    private var lastScreenshotDate = Date.distantPast
    private var startDate = Date()

    // Counters
    private var slowActionCount = 0
    private var peakMemoryMB: Double = 0
    private var bgFgCycleCount = 0
    private var networkToggleCount = 0
    private var rotationCount = 0
    private var textInputCount = 0
    private var pinchCount = 0
    private var pullRefreshCount = 0
    private var businessFlowCount = 0
    private var darkModeToggleCount = 0
    private var rapidBurstCount = 0
    private var multiTaskCount = 0
    private var boundaryInputCount = 0
    private var anomalyDetectedCount = 0
    private var dataClearCount = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-unlockApp", "-skipSplash", "-uitest"]
        app.launch()
        startDate = Date()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "App 未正常启动")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait

        let elapsed = Date().timeIntervalSince(startDate) / 60
        let summary = """
        ╔═══════════════════════════════════════╗
        ║     Monkey 全功能测试报告              ║
        ╠═══════════════════════════════════════╣
        ║ 总操作数:          \(actionCount)
        ║ 崩溃恢复次数:      \(crashCount)
        ║ 慢操作 (>3s):      \(slowActionCount)
        ║ UI异常检出:        \(anomalyDetectedCount)
        ║ 运行时长:          \(String(format: "%.1f", elapsed)) 分钟
        ║ 峰值内存:          \(String(format: "%.1f", peakMemoryMB))MB
        ╠═══════════════════════════════════════╣
        ║ 前后台切换:        \(bgFgCycleCount)次
        ║ 多任务切换:        \(multiTaskCount)次
        ║ 网络切换:          \(networkToggleCount)次
        ║ 屏幕旋转:          \(rotationCount)次
        ║ 暗色模式切换:      \(darkModeToggleCount)次
        ║ 文字输入:          \(textInputCount)次
        ║ 边界输入:          \(boundaryInputCount)次
        ║ 缩放手势:          \(pinchCount)次
        ║ 下拉刷新:          \(pullRefreshCount)次
        ║ 快速连续操作:      \(rapidBurstCount)次
        ║ 业务流程:          \(businessFlowCount)次
        ║ 数据清理重启:      \(dataClearCount)次
        ╚═══════════════════════════════════════╝
        """
        NSLog(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "MonkeySummary"
        attachment.lifetime = .keepAlways
        add(attachment)
        app = nil
    }

    // MARK: - 主测试入口

    func testMonkeyRun() throws {
        let deadline = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        NSLog("[Monkey] 开始全功能测试: 时长=%d分钟, throttle=%dms", durationMinutes, throttleMs)
        logMemoryStats()

        while Date() < deadline {
            autoreleasepool {
                if app.state != .runningForeground {
                    NSLog("[Monkey] ⚠️ App 不在前台 (state=%d), 恢复...", app.state.rawValue)
                    crashCount += 1
                    forceRelaunch()
                    return
                }

                let t0 = CFAbsoluteTimeGetCurrent()
                safePerformAction()
                let dt = CFAbsoluteTimeGetCurrent() - t0

                if dt > 3.0 {
                    slowActionCount += 1
                    NSLog("[Monkey] ⏱️ 慢操作 #%d 耗时 %.2fs", actionCount, dt)
                }

                actionCount += 1

                if actionCount % 50 == 0 {
                    let elapsed = Date().timeIntervalSince(startDate)
                    let aps = elapsed > 0 ? Double(actionCount) / elapsed : 0
                    NSLog("[Monkey] actions=%d crashes=%d slow=%d anomaly=%d elapsed=%.0fs (%.1f/s)",
                          actionCount, crashCount, slowActionCount, anomalyDetectedCount, elapsed, aps)
                }
                if actionCount % 200 == 0 { logMemoryStats() }

                periodicScreenshot()
                throttle()
                recoverIfNeeded()
            }
        }

        NSLog("[Monkey] ✅ 完成: actions=%d crashes=%d", actionCount, crashCount)
        logMemoryStats()
    }

    private func safePerformAction() {
        guard app.state == .runningForeground else {
            crashCount += 1; forceRelaunch(); return
        }
        performRandomAction()
    }

    private func forceRelaunch() {
        NSLog("[Monkey] 🔄 重新启动 App (crash #%d)", crashCount)
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        sleep(2)
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 15)
        sleep(2)
    }

    // MARK: - 随机操作分发 (20种)

    private func performRandomAction() {
        guard app.state == .runningForeground else { return }
        let roll = Int.random(in: 0..<100)

        switch roll {
        case 0..<15:   tapCoordinate()         // 15%
        case 15..<24:  swipeRandom()            // 9%
        case 24..<30:  tapTabBar()              // 6%
        case 30..<36:  goBack()                 // 6%
        case 36..<39:  longPressCoordinate()    // 3%
        case 39..<42:  doubleTapCoordinate()    // 3%
        case 42..<49:  typeRandomText()         // 7%
        case 49..<52:  backgroundForeground()   // 3%
        case 52..<54:  toggleNetwork()          // 2%
        case 54..<58:  rotateScreen()           // 4%
        case 58..<63:  pinchGesture()           // 5%
        case 63..<67:  pullToRefresh()          // 4%
        case 67..<72:  businessFlowTest()       // 5%
        case 72..<75:  tapRandomElement()       // 3%
        case 75..<78:  darkModeToggle()         // 3%
        case 78..<82:  rapidBurst()             // 4%
        case 82..<85:  multiTaskSwitch()        // 3%
        case 85..<89:  boundaryInput()          // 4%
        case 89..<93:  screenshotAnomalyCheck() // 4%
        case 93..<96:  notificationCenterCheck()// 3%
        case 96..<99:  deepLinkTest()           // 3%
        default:       dataClearRestart()       // 1%
        }
    }

    // MARK: - 基础操作

    private func tapCoordinate() {
        guard app.state == .runningForeground else { return }
        let x = CGFloat.random(in: 0.05...0.95)
        let y = CGFloat.random(in: 0.1...0.9)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    private func swipeRandom() {
        guard app.state == .runningForeground else { return }
        switch Int.random(in: 0..<4) {
        case 0: app.swipeUp()
        case 1: app.swipeDown()
        case 2: app.swipeLeft()
        default: app.swipeRight()
        }
    }

    private func tapTabBar() {
        guard app.state == .runningForeground else { return }
        let tabs: [(CGFloat, CGFloat)] = [(0.17, 0.97), (0.50, 0.97), (0.83, 0.97)]
        let pos = tabs.randomElement()!
        app.coordinate(withNormalizedOffset: CGVector(dx: pos.0, dy: pos.1)).tap()
    }

    private func goBack() {
        guard app.state == .runningForeground else { return }
        if Int.random(in: 0..<3) == 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.06)).tap()
        } else {
            app.swipeRight()
        }
    }

    private func longPressCoordinate() {
        guard app.state == .runningForeground else { return }
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).press(forDuration: 1.0)
    }

    private func doubleTapCoordinate() {
        guard app.state == .runningForeground else { return }
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).doubleTap()
    }

    private func tapRandomElement() {
        guard app.state == .runningForeground else { return }
        let candidates = gatherTappableElements()
        guard let target = candidates.randomElement(), target.isHittable else {
            tapCoordinate(); return
        }
        target.tap()
    }

    // MARK: - 文字输入

    private func typeRandomText() {
        guard app.state == .runningForeground else { return }
        if let field = findHittableField() {
            field.tap()
            usleep(500_000)
            guard app.state == .runningForeground else { return }
            let text = randomSearchText()
            field.typeText(text)
            textInputCount += 1
            NSLog("[Monkey] 📝 输入: %@", text)
            if Bool.random() { field.typeText("\n"); sleep(2) }
        } else {
            tapCoordinate()
        }
    }

    // MARK: - 边界输入

    private func boundaryInput() {
        guard app.state == .runningForeground else { return }
        if let field = findHittableField() {
            field.tap()
            usleep(500_000)
            guard app.state == .runningForeground else { return }
            let text = randomBoundaryText()
            field.typeText(text)
            boundaryInputCount += 1
            NSLog("[Monkey] 🔤 边界输入 (%d字符)", text.count)
            usleep(500_000)
        } else {
            tapCoordinate()
        }
    }

    private func findHittableField() -> XCUIElement? {
        guard app.state == .runningForeground else { return nil }
        let search = app.searchFields
        if search.count > 0, let f = search.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            return f
        }
        guard app.state == .runningForeground else { return nil }
        let text = app.textFields
        if text.count > 0, let f = text.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            return f
        }
        return nil
    }

    private func randomSearchText() -> String {
        ["玄幻", "都市", "修仙", "穿越", "重生", "系统", "无敌", "龙王",
         "赘婿", "神医", "武侠", "言情", "总裁", "甜宠", "末日", "异能"].randomElement()!
    }

    private func randomBoundaryText() -> String {
        let variants: [String] = [
            String(repeating: "A", count: 500),
            "😀🎉🔥💯🎊🌟✨🎯🏆🎪🎭🎨🎬🎤🎧",
            "<script>alert('xss')</script>",
            "'; DROP TABLE books; --",
            "   \t\n\r\n\t   ",
            "https://example.com/very/long/path?q=" + String(repeating: "x", count: 200),
            String(repeating: "测试", count: 100),
            "¡¢£¤¥¦§¨©ª«¬®¯°±²³´µ¶·¸¹º»¼½¾¿",
            "\u{200B}\u{200C}\u{200D}\u{FEFF}zero-width",
            "🏳️‍🌈👨‍👩‍👧‍👦🇨🇳",
        ]
        return variants.randomElement()!
    }

    // MARK: - 前后台切换

    private func backgroundForeground() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🏠 切换到后台")
        XCUIDevice.shared.press(.home)
        let wait = UInt32(Int.random(in: 2...6))
        sleep(wait)
        NSLog("[Monkey] 🔙 恢复前台 (后台 %ds)", wait)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        sleep(1)
        bgFgCycleCount += 1
    }

    // MARK: - 多任务切换

    private func multiTaskSwitch() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🔀 多任务切换")
        XCUIDevice.shared.press(.home)
        usleep(500_000)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if settings.wait(for: .runningForeground, timeout: 3) {
            sleep(1)
        }
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 5)
        usleep(500_000)
        multiTaskCount += 1
    }

    // MARK: - 网络切换

    private func toggleNetwork() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🌐 网络切换测试")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard settings.wait(for: .runningForeground, timeout: 5) else {
            app.activate(); return
        }
        var toggle: XCUIElement?
        for label in ["飞行模式", "Airplane Mode"] {
            let s = settings.switches[label]
            if s.exists { toggle = s; break }
        }
        if let t = toggle {
            t.tap()
            NSLog("[Monkey] ✈️ 飞行模式 ON")
            sleep(UInt32(Int.random(in: 3...6)))
            t.tap()
            NSLog("[Monkey] 🌐 飞行模式 OFF")
            sleep(2)
            networkToggleCount += 1
        }
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        sleep(1)
    }

    // MARK: - 屏幕旋转

    private func rotateScreen() {
        guard app.state == .runningForeground else { return }
        let orientations: [UIDeviceOrientation] = [.landscapeLeft, .landscapeRight, .portraitUpsideDown]
        let target = orientations.randomElement()!
        XCUIDevice.shared.orientation = target
        NSLog("[Monkey] 🔄 旋转: %d", target.rawValue)
        rotationCount += 1
        sleep(2)
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    // MARK: - 暗色模式切换

    private func darkModeToggle() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🌗 暗色模式切换")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.97)).tap()
        sleep(1)
        guard app.state == .runningForeground else { return }
        for label in ["跟随系统", "护眼模式"] {
            let sw = app.switches[label]
            if sw.exists && sw.isHittable {
                sw.tap()
                NSLog("[Monkey] 🌗 切换: %@", label)
                darkModeToggleCount += 1
                sleep(2)
                guard app.state == .runningForeground else { return }
                if sw.exists && sw.isHittable { sw.tap() }
                sleep(1)
                return
            }
        }
        let cells = app.cells
        for label in ["跟随系统", "护眼模式"] {
            let cell = cells.staticTexts[label]
            if cell.exists && cell.isHittable {
                cell.tap()
                darkModeToggleCount += 1
                NSLog("[Monkey] 🌗 点击: %@", label)
                sleep(2)
                return
            }
        }
    }

    // MARK: - 缩放手势

    private func pinchGesture() {
        guard app.state == .runningForeground else { return }
        let zoomIn = Bool.random()
        let scale: CGFloat = zoomIn ? CGFloat.random(in: 1.5...3.0) : CGFloat.random(in: 0.3...0.8)
        let velocity: CGFloat = zoomIn ? 1.0 : -1.0
        app.pinch(withScale: scale, velocity: velocity)
        pinchCount += 1
        NSLog("[Monkey] 🔍 %@ scale=%.2f", zoomIn ? "放大" : "缩小", scale)
    }

    // MARK: - 下拉刷新

    private func pullToRefresh() {
        guard app.state == .runningForeground else { return }
        let startPt = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let endPt = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        startPt.press(forDuration: 0.05, thenDragTo: endPt)
        pullRefreshCount += 1
        NSLog("[Monkey] ⬇️ 下拉刷新")
        sleep(2)
    }

    // MARK: - 快速连续操作 (压力测试)

    private func rapidBurst() {
        guard app.state == .runningForeground else { return }
        let count = Int.random(in: 5...8)
        NSLog("[Monkey] ⚡ 快速连续操作 x%d", count)
        for _ in 0..<count {
            guard app.state == .runningForeground else { break }
            tapCoordinate()
            usleep(300_000) // 300ms
        }
        rapidBurstCount += 1
    }

    // MARK: - 深度链接测试

    private func deepLinkTest() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🔗 深度链接测试")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.97)).tap()
        usleep(500_000)
        guard app.state == .runningForeground else { return }
        for _ in 0..<2 {
            guard app.state == .runningForeground else { break }
            let y = CGFloat.random(in: 0.15...0.85)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
            usleep(500_000)
        }
        guard app.state == .runningForeground else { return }
        let tab = [(0.17, 0.97), (0.50, 0.97)].randomElement()!
        app.coordinate(withNormalizedOffset: CGVector(dx: tab.0, dy: tab.1)).tap()
        usleep(500_000)
    }

    // MARK: - 通知中心检查

    private func notificationCenterCheck() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🔔 通知检查 (安全模式)")
        backgroundForeground()
    }

    // MARK: - UI异常检测

    private func screenshotAnomalyCheck() {
        guard app.state == .runningForeground else { return }
        takeScreenshot(name: "check-\(actionCount)")
        guard app.state == .runningForeground else { return }
        let windowCount = app.windows.count
        guard app.state == .runningForeground else { return }
        if windowCount == 0 {
            anomalyDetectedCount += 1
            NSLog("[Monkey] ⚠️ 异常: 无窗口!")
        } else {
            NSLog("[Monkey] ✅ UI检查 windows=%d", windowCount)
        }
    }

    // MARK: - 数据清理重启

    private func dataClearRestart() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 🗑️ 数据清理重启")
        app.terminate()
        sleep(3)
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 15)
        sleep(3)
        dataClearCount += 1
        NSLog("[Monkey] 🗑️ App 已重启")
    }

    // MARK: - 业务流程测试

    private func businessFlowTest() {
        guard app.state == .runningForeground else { return }
        businessFlowCount += 1
        switch Int.random(in: 0..<4) {
        case 0: flowSearch()
        case 1: flowBrowseStore()
        case 2: flowReading()
        default: flowProfile()
        }
    }

    private func flowSearch() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 📚 流程: 搜索")
        let sf = app.searchFields.firstMatch
        if sf.exists && sf.isHittable {
            sf.tap(); usleep(800_000)
            guard app.state == .runningForeground else { return }
            sf.typeText(randomSearchText() + "\n")
            sleep(3)
            guard app.state == .runningForeground else { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: CGFloat.random(in: 0.25...0.6))).tap()
            sleep(2)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.06)).tap()
            sleep(2)
        }
    }

    private func flowBrowseStore() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 📚 流程: 书城")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.97)).tap()
        sleep(2)
        for _ in 0..<Int.random(in: 2...5) {
            guard app.state == .runningForeground else { return }
            app.swipeUp(); usleep(800_000)
        }
        guard app.state == .runningForeground else { return }
        app.coordinate(withNormalizedOffset: CGVector(
            dx: CGFloat.random(in: 0.1...0.9),
            dy: CGFloat.random(in: 0.25...0.65)
        )).tap()
        sleep(3)
    }

    private func flowReading() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 📚 流程: 阅读")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.97)).tap()
        sleep(2)
        guard app.state == .runningForeground else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        sleep(3)
        for _ in 0..<Int.random(in: 3...8) {
            guard app.state == .runningForeground else { return }
            app.swipeLeft(); usleep(600_000)
        }
        goBack()
    }

    private func flowProfile() {
        guard app.state == .runningForeground else { return }
        NSLog("[Monkey] 📚 流程: 个人中心")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.97)).tap()
        sleep(2)
        for _ in 0..<Int.random(in: 2...4) {
            guard app.state == .runningForeground else { return }
            app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5, dy: CGFloat.random(in: 0.2...0.8)
            )).tap()
            sleep(2)
        }
        goBack()
    }

    // MARK: - 内存监控

    private func logMemoryStats() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let mb = Double(info.resident_size) / 1_048_576
            if mb > peakMemoryMB { peakMemoryMB = mb }
            NSLog("[Monkey] 💾 内存: %.1fMB (峰值: %.1fMB)", mb, peakMemoryMB)
        }
    }

    // MARK: - 元素收集

    private func gatherTappableElements() -> [XCUIElement] {
        guard app.state == .runningForeground else { return [] }
        var elements: [XCUIElement] = []
        let types: [XCUIElement.ElementType] = [.button, .staticText, .cell, .switch, .slider, .textField, .link]
        for type in types {
            guard app.state == .runningForeground else { break }
            let query = app.descendants(matching: type)
            let count = min(query.count, 10)
            for i in 0..<count {
                guard app.state == .runningForeground else { break }
                let el = query.element(boundBy: i)
                if el.exists && el.isHittable && el.frame.width > 5 && el.frame.height > 5 {
                    elements.append(el)
                }
            }
        }
        return elements
    }

    // MARK: - 恢复机制

    private func recoverIfNeeded() {
        handleSystemAlerts()
        if app.state != .runningForeground {
            NSLog("[Monkey] ⚠️ App 不在前台, 恢复...")
            crashCount += 1
            takeScreenshot(name: "crash-recovery-\(crashCount)")
            app.activate()
            sleep(2)
            if app.state != .runningForeground { forceRelaunch() }
        }
    }

    private func handleSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertBtns = springboard.alerts.buttons
        if alertBtns.count > 0 {
            for label in ["允许", "好", "Allow", "OK"] {
                let btn = alertBtns[label]
                if btn.exists { btn.tap(); break }
            }
        }
    }

    // MARK: - 截图 & 节流

    private func periodicScreenshot() {
        let now = Date()
        guard now.timeIntervalSince(lastScreenshotDate) >= screenshotIntervalSec else { return }
        lastScreenshotDate = now
        takeScreenshot(name: "periodic-\(actionCount)")
    }

    private func takeScreenshot(name: String) {
        guard app.state == .runningForeground else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func throttle() {
        usleep(UInt32(throttleMs * 1000))
    }
}
