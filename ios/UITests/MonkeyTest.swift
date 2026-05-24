import XCTest

// MARK: - Fastbot 风格智能化 UI 遍历测试
//
// 特性：
//   - 基于状态图模型的智能遍历（优先探索未访问页面/元素）
//   - 卡死/ANR 检测（UI 无响应检测）
//   - 系统弹窗自动处理（权限弹窗、Alert 等）
//   - 操作序列记录与崩溃复现
//   - 内存使用监控与泄漏趋势检测
//   - 丰富元素交互（文本输入、Picker、搜索等）
//
// 运行方式（模拟器）:
//   xcodebuild test -project WanxiangBook.xcodeproj -scheme WanxiangBook \
//     -destination 'platform=iOS Simulator,id=<UDID>' \
//     -only-testing:WanxiangUITests/MonkeyTest/testFastbotTraversal \
//     -allowProvisioningUpdates 2>&1 | tee /tmp/monkey_test.log

// MARK: - 状态图模型

/// GUI 页面状态节点
private struct ScreenState: Hashable {
    let signature: String
    var visitCount: Int = 0
    var elements: [ElementInfo] = []

    func hash(into hasher: inout Hasher) { hasher.combine(signature) }
    static func == (lhs: ScreenState, rhs: ScreenState) -> Bool { lhs.signature == rhs.signature }
}

/// 可交互元素信息
private struct ElementInfo: Hashable {
    let type: String
    let identifier: String
    let label: String
    let frame: CGRect
    var tapCount: Int = 0

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(identifier)
        hasher.combine(label)
    }

    static func == (lhs: ElementInfo, rhs: ElementInfo) -> Bool {
        lhs.type == rhs.type && lhs.identifier == rhs.identifier && lhs.label == rhs.label
    }
}

/// 操作记录（用于崩溃复现）
private struct ActionRecord {
    let timestamp: TimeInterval
    let actionType: String
    let target: String
    let screenSignature: String
}

/// 状态转移边
private struct Transition: Hashable {
    let fromState: String
    let action: String
    let toState: String
    var count: Int = 0
}

// MARK: - MonkeyTest

final class MonkeyTest: XCTestCase {

    var app: XCUIApplication!

    // MARK: - 配置参数

    private var testDuration: TimeInterval {
        let envMin = ProcessInfo.processInfo.environment["MONKEY_DURATION"] ?? "720"
        return TimeInterval(Int(envMin) ?? 720) * 60
    }

    private var actionInterval: TimeInterval {
        let envMs = ProcessInfo.processInfo.environment["MONKEY_THROTTLE"] ?? "400"
        return TimeInterval(Int(envMs) ?? 400) / 1000.0
    }

    private let screenshotInterval: Int = 50
    private let maxDepth: Int = 10
    private let stuckThreshold: Int = 8
    private let memoryCheckInterval: Int = 30
    private let maxActionHistory: Int = 200

    // MARK: - 状态图

    private var stateGraph: [String: ScreenState] = [:]
    private var transitions: Set<Transition> = []
    private var currentStateSig = ""

    // MARK: - 统计与追踪

    private var actionCount = 0
    private var crashCount = 0
    private var stuckCount = 0
    private var alertsDismissed = 0
    private var currentDepth = 0
    private var consecutiveSameScreen = 0
    private var lastScreenSig = ""

    // MARK: - 操作序列记录

    private var actionHistory: [ActionRecord] = []
    private var crashLogs: [[ActionRecord]] = []

    // MARK: - 内存监控

    private var memorySnapshots: [(action: Int, mb: Double)] = []
    private var peakMemoryMB: Double = 0
    private var baselineMemoryMB: Double = 0

    // MARK: - 文本输入池

    private let textInputPool = [
        "测试文本", "Hello World", "搜索内容",
        "小说名称", "作者名", "你好",
        "12345", "test@example.com",
        "~!@#$%^&*()", "很长的文本内容用来测试输入框的边界情况和溢出处理",
        "", " ", "🎉📚✨"
    ]

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-unlockApp", "-skipSplash", "-uitest"]
        app.launch()
        _ = app.buttons["书架"].waitForExistence(timeout: 15)

        addUIInterruptionMonitor(withDescription: "SystemAlerts") { [weak self] alert -> Bool in
            return self?.handleSystemAlert(alert) ?? false
        }

        baselineMemoryMB = currentMemoryMB()
        memorySnapshots.append((action: 0, mb: baselineMemoryMB))
    }

    override func tearDownWithError() throws {
        let report = generateReport()
        let attachment = XCTAttachment(string: report)
        attachment.name = "FastbotReport"
        attachment.lifetime = .keepAlways
        add(attachment)

        if !crashLogs.isEmpty {
            let crashReport = generateCrashReproSteps()
            let crashAttachment = XCTAttachment(string: crashReport)
            crashAttachment.name = "CrashReproSteps"
            crashAttachment.lifetime = .keepAlways
            add(crashAttachment)
        }

        app = nil
    }

    // MARK: - 主测试入口

    func testFastbotTraversal() throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < testDuration {
            dismissSystemAlertsIfNeeded()

            guard checkAppAlive() else {
                crashCount += 1
                saveCrashLog()
                snapshot("CRASH-\(crashCount)-action\(actionCount)")
                XCTFail("[Monkey] crash #\(crashCount) after \(actionCount) actions")
                relaunchApp()
                continue
            }

            let prevSig = currentStateSig
            updateStateGraph()
            detectStuck()

            let action = selectSmartAction()
            executeAction(action)
            actionCount += 1

            if let newSig = currentStateSig as String?,
               newSig != prevSig && !prevSig.isEmpty {
                let t = Transition(fromState: prevSig, action: action.type, toState: newSig)
                transitions.insert(t)
            }

            if actionCount % screenshotInterval == 0 {
                snapshot("action-\(actionCount)")
            }

            if actionCount % memoryCheckInterval == 0 {
                trackMemory()
            }

            if actionCount % 100 == 0 {
                printProgress(startTime: startTime)
            }

            Thread.sleep(forTimeInterval: actionInterval)

            if currentDepth > maxDepth {
                executeAction(SmartAction(type: "navigateBack", target: "depth-limit"))
            }
        }

        snapshot("FINAL-\(actionCount)-actions")
        let summary = "[Monkey] completed: actions=\(actionCount) screens=\(stateGraph.count) crashes=\(crashCount) stucks=\(stuckCount) peak_mem=\(String(format: "%.1f", peakMemoryMB))MB"
        print(summary)
    }

    // MARK: - 智能动作选择（核心）

    private struct SmartAction {
        let type: String
        let target: String
        var element: XCUIElement?
        var elementInfo: ElementInfo?
    }

    /// 基于状态图的智能动作选择：优先探索未访问/低频元素和页面
    private func selectSmartAction() -> SmartAction {
        guard app.state == .runningForeground else {
            return SmartAction(type: "wait", target: "app-not-foreground")
        }

        if consecutiveSameScreen >= stuckThreshold {
            consecutiveSameScreen = 0
            return SmartAction(type: "escapeStuck", target: "stuck-escape")
        }

        let explorationRatio = calculateExplorationRatio()

        // 探索率高时（前期）偏向探索未知元素，低时做更多随机操作
        if explorationRatio > 0.3 {
            if let untapped = findLeastTappedElement() {
                return SmartAction(type: "tapElement", target: untapped.label, element: nil, elementInfo: untapped)
            }
        }

        let dice = Int.random(in: 0..<100)
        switch dice {
        case 0..<30:
            return SmartAction(type: "tapInteractive", target: "interactive-element")
        case 30..<45:
            return SmartAction(type: "randomTap", target: "random-coordinate")
        case 45..<58:
            return SmartAction(type: "swipe", target: "random-direction")
        case 58..<68:
            return SmartAction(type: "navigateBack", target: "back")
        case 68..<78:
            return SmartAction(type: "tapTabBar", target: "tab")
        case 78..<85:
            return SmartAction(type: "textInput", target: "text-field")
        case 85..<90:
            return SmartAction(type: "longPress", target: "random")
        case 90..<94:
            return SmartAction(type: "doubleTap", target: "random")
        case 94..<97:
            return SmartAction(type: "picker", target: "picker")
        default:
            return SmartAction(type: "scrollView", target: "scroll")
        }
    }

    private func executeAction(_ action: SmartAction) {
        let record = ActionRecord(
            timestamp: Date().timeIntervalSince1970,
            actionType: action.type,
            target: action.target,
            screenSignature: currentStateSig
        )
        appendActionRecord(record)

        switch action.type {
        case "tapElement":
            if let info = action.elementInfo {
                tapSpecificElement(info)
            }
        case "tapInteractive":
            tapInteractiveElement()
        case "randomTap":
            randomTap()
        case "swipe":
            randomSwipe()
        case "navigateBack":
            navigateBack()
        case "tapTabBar":
            tapTabBar()
        case "textInput":
            performTextInput()
        case "longPress":
            longPress()
        case "doubleTap":
            doubleTap()
        case "picker":
            interactWithPicker()
        case "scrollView":
            scrollRandomView()
        case "escapeStuck":
            escapeStuckState()
        case "wait":
            Thread.sleep(forTimeInterval: 1.0)
        default:
            randomTap()
        }
    }

    // MARK: - 状态图管理

    private func updateStateGraph() {
        guard app.state == .runningForeground else { return }

        let sig = computeScreenSignature()
        currentStateSig = sig

        if sig == lastScreenSig {
            consecutiveSameScreen += 1
        } else {
            consecutiveSameScreen = 0
        }
        lastScreenSig = sig

        if stateGraph[sig] == nil {
            var state = ScreenState(signature: sig)
            state.elements = discoverElements()
            stateGraph[sig] = state
        }
        stateGraph[sig]?.visitCount += 1
    }

    private func computeScreenSignature() -> String {
        let navBar = app.navigationBars.firstMatch
        let navTitle: String
        if navBar.exists {
            navTitle = navBar.identifier.isEmpty ? navBar.label : navBar.identifier
        } else {
            navTitle = "no-nav"
        }

        let alerts = app.alerts.count
        let sheets = app.sheets.count

        var labelParts: [String] = []
        let btnCount = min(app.buttons.count, 8)
        for i in 0..<btnCount {
            let btn = app.buttons.element(boundBy: i)
            if btn.exists { labelParts.append(btn.label) }
        }

        let tabBarItems = app.tabBars.firstMatch.buttons.count

        return "\(navTitle)|\(alerts)a\(sheets)s|\(tabBarItems)t|\(labelParts.prefix(5).joined(separator: ","))"
    }

    private func discoverElements() -> [ElementInfo] {
        var elements: [ElementInfo] = []
        let queries: [(String, XCUIElementQuery)] = [
            ("button", app.buttons),
            ("cell", app.cells),
            ("text", app.staticTexts),
            ("switch", app.switches),
            ("textField", app.textFields),
            ("searchField", app.searchFields),
            ("slider", app.sliders),
            ("stepper", app.steppers),
            ("picker", app.pickers),
            ("link", app.links),
            ("image", app.images),
        ]

        for (typeName, query) in queries {
            let count = min(query.count, 20)
            for i in 0..<count {
                let el = query.element(boundBy: i)
                if el.exists && el.isHittable {
                    let info = ElementInfo(
                        type: typeName,
                        identifier: el.identifier,
                        label: el.label,
                        frame: el.frame
                    )
                    elements.append(info)
                }
            }
        }
        return elements
    }

    /// 找到当前页面中被点击次数最少的元素
    private func findLeastTappedElement() -> ElementInfo? {
        guard let state = stateGraph[currentStateSig] else { return nil }
        return state.elements
            .filter { $0.type == "button" || $0.type == "cell" || $0.type == "link" }
            .min(by: { $0.tapCount < $1.tapCount })
    }

    private func calculateExplorationRatio() -> Double {
        guard !stateGraph.isEmpty else { return 1.0 }
        let totalElements = stateGraph.values.reduce(0) { $0 + $1.elements.count }
        let tappedElements = stateGraph.values.reduce(0) { sum, state in
            sum + state.elements.filter { $0.tapCount > 0 }.count
        }
        guard totalElements > 0 else { return 1.0 }
        return 1.0 - Double(tappedElements) / Double(totalElements)
    }

    // MARK: - 基础操作

    private func randomTap() {
        let x = CGFloat.random(in: 0.05...0.95)
        let y = CGFloat.random(in: 0.1...0.9)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    private func randomSwipe() {
        let directions: [(dx: CGFloat, dy: CGFloat, dx2: CGFloat, dy2: CGFloat)] = [
            (0.8, 0.5, 0.2, 0.5),
            (0.2, 0.5, 0.8, 0.5),
            (0.5, 0.8, 0.5, 0.3),
            (0.5, 0.3, 0.5, 0.8),
        ]
        let dir = directions.randomElement()!
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: dir.dx, dy: dir.dy))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: dir.dx2, dy: dir.dy2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func tapInteractiveElement() {
        guard app.state == .runningForeground else { return }

        let candidates: [(query: XCUIElementQuery, weight: Int)] = [
            (app.buttons, 40),
            (app.cells, 25),
            (app.staticTexts, 15),
            (app.switches, 10),
            (app.links, 10),
        ]

        let totalWeight = candidates.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<totalWeight)
        var selectedQuery = app.buttons as XCUIElementQuery

        for (query, weight) in candidates {
            roll -= weight
            if roll < 0 {
                selectedQuery = query
                break
            }
        }

        let count = selectedQuery.count
        guard count > 0 else {
            randomTap()
            return
        }

        let index = Int.random(in: 0..<min(count, 20))
        let element = selectedQuery.element(boundBy: index)
        if element.exists && element.isHittable {
            element.tap()
            currentDepth += 1
            markElementTapped(label: element.label, type: "interactive")
        }
    }

    private func tapSpecificElement(_ info: ElementInfo) {
        let queryMap: [String: XCUIElementQuery] = [
            "button": app.buttons,
            "cell": app.cells,
            "text": app.staticTexts,
            "switch": app.switches,
            "textField": app.textFields,
            "searchField": app.searchFields,
            "link": app.links,
        ]

        guard let query = queryMap[info.type] else {
            randomTap()
            return
        }

        let element: XCUIElement
        if !info.identifier.isEmpty {
            element = query[info.identifier]
        } else if !info.label.isEmpty {
            element = query[info.label]
        } else {
            randomTap()
            return
        }

        if element.exists && element.isHittable {
            element.tap()
            currentDepth += 1
            markElementTapped(label: info.label, type: info.type)
        } else {
            randomTap()
        }
    }

    private func markElementTapped(label: String, type: String) {
        guard var state = stateGraph[currentStateSig] else { return }
        if let idx = state.elements.firstIndex(where: { $0.label == label && $0.type == type }) {
            state.elements[idx].tapCount += 1
            stateGraph[currentStateSig] = state
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

        let closeBtn = app.buttons["关闭"]
        if closeBtn.exists && closeBtn.isHittable {
            closeBtn.tap()
            currentDepth = max(0, currentDepth - 1)
            return
        }

        let cancelBtn = app.buttons["取消"]
        if cancelBtn.exists && cancelBtn.isHittable {
            cancelBtn.tap()
            currentDepth = max(0, currentDepth - 1)
            return
        }

        app.swipeRight()
        currentDepth = max(0, currentDepth - 1)
    }

    private func tapTabBar() {
        let tabs = ["书架", "书城", "我的"]
        let tab = tabs.randomElement()!
        let btn = app.tabBars.firstMatch.buttons[tab]
        if btn.exists && btn.isHittable {
            btn.tap()
            currentDepth = 0
        }
    }

    private func longPress() {
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            .press(forDuration: TimeInterval.random(in: 1.0...3.0))
    }

    private func doubleTap() {
        let x = CGFloat.random(in: 0.1...0.9)
        let y = CGFloat.random(in: 0.15...0.85)
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).doubleTap()
    }

    // MARK: - 丰富交互操作

    private func performTextInput() {
        guard app.state == .runningForeground else { return }

        let textFields = app.textFields
        let searchFields = app.searchFields
        let textViews = app.textViews

        let allFields: [(XCUIElementQuery, String)] = [
            (textFields, "textField"),
            (searchFields, "searchField"),
            (textViews, "textView"),
        ]

        for (query, _) in allFields.shuffled() {
            let count = query.count
            guard count > 0 else { continue }
            let index = Int.random(in: 0..<min(count, 5))
            let field = query.element(boundBy: index)
            if field.exists && field.isHittable {
                field.tap()
                Thread.sleep(forTimeInterval: 0.3)

                let text = textInputPool.randomElement()!
                field.typeText(text)

                if Bool.random() {
                    field.typeText("\n")
                }
                return
            }
        }
    }

    private func interactWithPicker() {
        guard app.state == .runningForeground else { return }

        let pickers = app.pickers
        guard pickers.count > 0 else { return }
        let picker = pickers.element(boundBy: Int.random(in: 0..<min(pickers.count, 3)))
        guard picker.exists else { return }

        let wheels = picker.pickerWheels
        guard wheels.count > 0 else { return }
        let wheel = wheels.element(boundBy: Int.random(in: 0..<wheels.count))
        if wheel.exists {
            wheel.adjust(toPickerWheelValue: wheel.value as? String ?? "")
            if Bool.random() {
                wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            } else {
                wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
            }
        }
    }

    private func scrollRandomView() {
        guard app.state == .runningForeground else { return }

        let scrollViews = app.scrollViews
        let tables = app.tables
        let collections = app.collectionViews

        let queries: [XCUIElementQuery] = [scrollViews, tables, collections].shuffled()

        for query in queries {
            guard query.count > 0 else { continue }
            let view = query.firstMatch
            if view.exists && view.isHittable {
                let swipes: [() -> Void] = [
                    { view.swipeUp() },
                    { view.swipeDown() },
                ]
                swipes.randomElement()?()
                return
            }
        }

        randomSwipe()
    }

    // MARK: - 卡死/ANR 检测

    private func detectStuck() {
        if consecutiveSameScreen >= stuckThreshold {
            stuckCount += 1
            print("[Monkey] ⚠️ stuck detected at action \(actionCount), screen: \(currentStateSig)")
            snapshot("STUCK-\(stuckCount)-action\(actionCount)")
        }
    }

    private func escapeStuckState() {
        let escapeStrategies: [() -> Void] = [
            { [weak self] in self?.navigateBack() },
            { [weak self] in self?.tapTabBar() },
            { [weak self] in self?.app.swipeDown() },
            { [weak self] in
                self?.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            },
            { [weak self] in
                self?.dismissAnyOverlay()
            },
        ]

        for strategy in escapeStrategies.shuffled().prefix(2) {
            strategy()
            Thread.sleep(forTimeInterval: 0.5)
            updateStateGraph()
            if consecutiveSameScreen == 0 { break }
        }
    }

    private func dismissAnyOverlay() {
        let dismissLabels = ["关闭", "取消", "确定", "OK", "Cancel", "Done", "完成", "跳过", "知道了", "我知道了"]
        for label in dismissLabels {
            let btn = app.buttons[label]
            if btn.exists && btn.isHittable {
                btn.tap()
                return
            }
        }
    }

    // MARK: - 系统弹窗处理

    private func handleSystemAlert(_ alert: XCUIElement) -> Bool {
        alertsDismissed += 1
        let allowLabels = ["允许", "Allow", "Allow While Using App",
                           "Allow Full Access", "确定", "OK",
                           "好", "Continue", "同意"]

        for label in allowLabels {
            let btn = alert.buttons[label]
            if btn.exists {
                btn.tap()
                return true
            }
        }

        let denyLabels = ["不允许", "Don't Allow", "拒绝", "Deny"]
        for label in denyLabels {
            let btn = alert.buttons[label]
            if btn.exists {
                btn.tap()
                return true
            }
        }

        if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
            return true
        }

        return false
    }

    private func dismissSystemAlertsIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertBtn = springboard.alerts.firstMatch
        if alertBtn.waitForExistence(timeout: 0.3) {
            _ = handleSystemAlert(alertBtn)
        }

        app.tap()
    }

    // MARK: - 操作序列记录

    private func appendActionRecord(_ record: ActionRecord) {
        actionHistory.append(record)
        if actionHistory.count > maxActionHistory {
            actionHistory.removeFirst(actionHistory.count - maxActionHistory)
        }
    }

    private func saveCrashLog() {
        let recentActions = Array(actionHistory.suffix(50))
        crashLogs.append(recentActions)
    }

    private func generateCrashReproSteps() -> String {
        var report = "=== Crash Reproduction Steps ===\n"
        report += "Total crashes: \(crashLogs.count)\n\n"

        for (i, log) in crashLogs.enumerated() {
            report += "--- Crash #\(i + 1) ---\n"
            for (step, record) in log.enumerated() {
                report += "  \(step + 1). [\(record.actionType)] \(record.target) @ \(record.screenSignature)\n"
            }
            report += "\n"
        }
        return report
    }

    // MARK: - 内存监控

    private func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / (1024.0 * 1024.0)
        }
        return 0
    }

    private func trackMemory() {
        let mb = currentMemoryMB()
        memorySnapshots.append((action: actionCount, mb: mb))
        if mb > peakMemoryMB { peakMemoryMB = mb }

        let growth = mb - baselineMemoryMB
        if growth > 100 {
            print("[Monkey] ⚠️ memory growth: \(String(format: "%.1f", growth))MB above baseline at action \(actionCount)")
        }
    }

    // MARK: - App 生命周期

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
        currentStateSig = ""
        consecutiveSameScreen = 0
    }

    // MARK: - 截图

    private func snapshot(_ name: String) {
        guard app.state == .runningForeground else { return }
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: - 进度输出

    private func printProgress(startTime: Date) {
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let elapsedMin = elapsed / 60
        let remaining = Int(testDuration) - elapsed
        let remainingMin = max(0, remaining / 60)
        let mem = currentMemoryMB()

        print("[Monkey] progress: actions=\(actionCount) screens=\(stateGraph.count) transitions=\(transitions.count) crashes=\(crashCount) stucks=\(stuckCount) alerts=\(alertsDismissed) mem=\(String(format: "%.0f", mem))MB elapsed=\(elapsedMin)m remaining=\(remainingMin)m")
    }

    // MARK: - 报告生成

    private func generateReport() -> String {
        let memGrowth = peakMemoryMB - baselineMemoryMB
        let avgVisits: Double = stateGraph.isEmpty ? 0 :
            Double(stateGraph.values.reduce(0) { $0 + $1.visitCount }) / Double(stateGraph.count)

        var report = """
        ╔══════════════════════════════════════════╗
        ║       Fastbot 智能遍历测试报告           ║
        ╚══════════════════════════════════════════╝

        📊 总体统计
        ─────────────────────────────
          总操作数:       \(actionCount)
          发现页面数:     \(stateGraph.count)
          状态转移数:     \(transitions.count)
          崩溃次数:       \(crashCount)
          卡死次数:       \(stuckCount)
          弹窗处理:       \(alertsDismissed) 次

        🧠 智能化指标
        ─────────────────────────────
          页面平均访问:   \(String(format: "%.1f", avgVisits)) 次
          探索覆盖率:     \(String(format: "%.1f%%", (1.0 - calculateExplorationRatio()) * 100))

        💾 内存监控
        ─────────────────────────────
          基线内存:       \(String(format: "%.1f", baselineMemoryMB)) MB
          峰值内存:       \(String(format: "%.1f", peakMemoryMB)) MB
          内存增长:       \(String(format: "%.1f", memGrowth)) MB
          疑似泄漏:       \(memGrowth > 80 ? "⚠️ 是" : "✅ 否")

        📱 页面详情
        ─────────────────────────────
        """

        let sortedStates = stateGraph.values.sorted { $0.visitCount > $1.visitCount }
        for state in sortedStates.prefix(20) {
            let elementCount = state.elements.count
            let tappedCount = state.elements.filter { $0.tapCount > 0 }.count
            report += "  [\(state.visitCount)次] \(state.signature) (元素:\(elementCount) 已交互:\(tappedCount))\n"
        }

        if !memorySnapshots.isEmpty {
            report += "\n📈 内存趋势\n─────────────────────────────\n"
            let step = max(1, memorySnapshots.count / 10)
            for i in stride(from: 0, to: memorySnapshots.count, by: step) {
                let snap = memorySnapshots[i]
                report += "  action \(snap.action): \(String(format: "%.1f", snap.mb)) MB\n"
            }
        }

        return report
    }
}
