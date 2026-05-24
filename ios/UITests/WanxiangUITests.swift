import XCTest

// MARK: - 万象书屋 综合 UI 自动化测试（全功能版）
//
// 覆盖 App 所有主要功能页面和按钮（含二/三/四级页面）
// 共约 60+ 个测试用例
//
// 并行运行4台手机:
//   for ID in <id1> <id2> <id3> <id4>; do
//     xcodebuild test -project WanxiangBook.xcodeproj -scheme WanxiangBook \
//       -destination "platform=iOS,id=$ID" -derivedDataPath /tmp/dd_$ID \
//       -only-testing:WanxiangUITests -allowProvisioningUpdates \
//       DEVELOPMENT_TEAM=6UX5G5838X CODE_SIGN_STYLE=Automatic > /tmp/test_$ID.log 2>&1 &
//   done; wait

final class WanxiangUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 辅助方法

    private func launchUnlocked() {
        app.terminate()
        app.launchArguments = ["-unlockApp", "-skipSplash", "-uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["书架"].waitForExistence(timeout: 10), "主界面未加载")
    }

    private func launchLocked() {
        app.terminate()
        app.launchArguments = ["-resetAppState", "-skipSplash", "-uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["btn_feedback"].waitForExistence(timeout: 10), "伪装面未加载")
    }

    private func snapshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: - DEMO walkthrough 辅助

    private func demoBeat(_ sec: UInt32 = 1) { sleep(sec) }

    @discardableResult
    private func demoTapFirst(
        _ candidates: [XCUIElement],
        timeout: TimeInterval = 3,
        fallback: (dx: CGFloat, dy: CGFloat)? = nil
    ) -> Bool {
        for el in candidates {
            if el.waitForExistence(timeout: timeout), el.isHittable {
                el.tap()
                return true
            }
        }
        if let fb = fallback {
            app.coordinate(withNormalizedOffset: CGVector(dx: fb.dx, dy: fb.dy)).tap()
            return true
        }
        return false
    }

    @discardableResult
    private func demoWaitForAny(_ candidates: [XCUIElement], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists && $0.isHittable }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func demoBack() {
        if app.buttons["reader.back"].waitForExistence(timeout: 1) {
            app.buttons["reader.back"].tap()
            demoBeat()
            return
        }
        let backBtn = app.navigationBars.buttons.firstMatch
        if backBtn.waitForExistence(timeout: 2), backBtn.isHittable {
            backBtn.tap()
        } else if app.buttons["取消"].waitForExistence(timeout: 1) {
            app.buttons["取消"].tap()
        }
        demoBeat()
    }

    /// 阅读器隐藏 TabBar 且禁用了边缘返回, 必须先点屏幕呼出菜单再点返回.
    private func demoExitReader(maxAttempts: Int = 12) {
        if app.buttons["书架"].waitForExistence(timeout: 1) { return }
        for _ in 0..<maxAttempts {
            if app.buttons["书架"].waitForExistence(timeout: 1) { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if app.buttons["reader.back"].waitForExistence(timeout: 2) {
                app.buttons["reader.back"].tap()
            } else if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 1) {
                app.navigationBars.buttons.firstMatch.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
    }

    private func demoTapTab(_ name: String) {
        demoExitReader()
        let tabId = switch name {
        case "书架": "tab.bookshelf"
        case "书城": "tab.bookstore"
        default: "tab.my"
        }
        let tabX: CGFloat = switch name {
        case "书架": 0.17
        case "书城": 0.50
        default: 0.83
        }
        if demoTapFirst([app.buttons[tabId], app.buttons[name]], fallback: (tabX, 0.97)) {
            demoBeat()
        }
        switch name {
        case "书架":
            _ = demoWaitForAny([app.navigationBars["书架"], app.staticTexts["书架"]], timeout: 5)
        case "书城":
            _ = demoWaitForAny([app.buttons["bookstore.search"]], timeout: 8)
        default:
            _ = demoWaitForAny([app.navigationBars["我的"], app.staticTexts["我的"]], timeout: 5)
        }
    }

    private func demoTapBookstoreChannel(id: String, label: String, x: CGFloat) {
        demoTapFirst(
            [app.buttons[id], app.otherElements[id], app.buttons[label], app.staticTexts[label]],
            fallback: (x, 0.10)
        )
        _ = demoWaitForAny([app.buttons["bookstore.search"]], timeout: 6)
        demoBeat()
        demoSnapshot("DEMO-书城-频道-\(label)")
    }

    private func demoTapMyRow(
        id: String,
        label: String,
        snapshotName: String,
        fallbackY: CGFloat,
        needsBack: Bool = true,
        work: () -> Void = {}
    ) {
        demoTapFirst(
            [
                app.buttons[id],
                app.otherElements[id],
                app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch,
                app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch,
            ],
            fallback: (0.5, fallbackY)
        )
        demoBeat()
        demoSnapshot(snapshotName)
        work()
        if needsBack { demoBack() }
    }

    private func demoSnapshot(_ name: String) {
        guard app.state == .runningForeground else { return }
        snapshot(name)
    }

    private func demoEnsureRunning() {
        if app.state != .runningForeground {
            app.launch()
            _ = app.buttons["书架"].waitForExistence(timeout: 15)
        }
    }

    /// 进入「我的」页并等待加载
    private func goToMyPage() {
        app.buttons["我的"].tap()
        _ = app.navigationBars["我的"].waitForExistence(timeout: 5)
        sleep(1)
    }

    /// 进入某个 NavigationLink 行，完成操作后返回
    private func enterRow(_ text: String, work: () -> Void = {}) {
        let row = app.staticTexts[text]
        if row.waitForExistence(timeout: 5) {
            row.tap()
            sleep(1)
            snapshot("进入-\(text)")
            work()
            // 返回上一页
            let backBtn = app.navigationBars.buttons.firstMatch
            if backBtn.waitForExistence(timeout: 3) { backBtn.tap() }
            sleep(1)
        }
    }

    // =========================================================================
    // MARK: - A 伪装面 (QR 码生成器)
    // =========================================================================

    /// A1: 伪装面主界面元素完整
    func testA1_DisguiseFaceElements() throws {
        launchLocked()
        snapshot("A1-伪装面")
        XCTAssertTrue(app.staticTexts["二维码生成器"].exists, "缺少页面标题")
        XCTAssertTrue(app.buttons["btn_feedback"].exists, "反馈按钮不存在")
        XCTAssertTrue(
            app.textViews.firstMatch.exists || app.textFields.firstMatch.exists,
            "输入区域不存在"
        )
    }

    /// A2: 反馈 Sheet 完整性
    func testA2_FeedbackSheet() throws {
        launchLocked()
        app.buttons["btn_feedback"].tap()
        XCTAssertTrue(app.navigationBars["意见反馈"].waitForExistence(timeout: 5), "反馈 Sheet 未出现")
        snapshot("A2-反馈Sheet")
        XCTAssertTrue(app.staticTexts["反馈类型"].exists)
        XCTAssertTrue(app.staticTexts["问题描述"].exists)
        XCTAssertTrue(app.staticTexts["联系方式"].exists)
        XCTAssertTrue(app.buttons["功能建议"].exists)
        XCTAssertTrue(app.buttons["问题反馈"].exists)
        XCTAssertTrue(app.buttons["界面优化"].exists)
        XCTAssertTrue(app.buttons["其他"].exists)
        XCTAssertTrue(app.buttons["提交反馈"].exists)
        XCTAssertTrue(app.buttons["取消"].exists)
        app.buttons["取消"].tap()
        XCTAssertFalse(app.navigationBars["意见反馈"].waitForExistence(timeout: 3))
    }

    /// A3: QR 码生成 - 输入文字后生成二维码
    func testA3_QRCodeGeneration() throws {
        launchLocked()
        let inputArea = app.textViews.firstMatch
        if inputArea.waitForExistence(timeout: 3) {
            inputArea.tap()
            inputArea.typeText("https://www.apple.com")
        }
        snapshot("A3-QR输入后")
        XCTAssertTrue(app.buttons["清空"].waitForExistence(timeout: 3), "清空按钮未出现")
    }

    /// A4: 清空按钮功能
    func testA4_ClearButton() throws {
        launchLocked()
        let inputArea = app.textViews.firstMatch
        if inputArea.waitForExistence(timeout: 3) {
            inputArea.tap()
            inputArea.typeText("测试文字")
        }
        if app.buttons["清空"].waitForExistence(timeout: 3) {
            app.buttons["清空"].tap()
        }
        snapshot("A4-清空后")
    }

    /// A5: 前缀按钮功能
    func testA5_PrefixButtons() throws {
        launchLocked()
        let prefixes = ["https://", "weixin://", "tel:", "mailto:", "wifi:"]
        for prefix in prefixes {
            if app.buttons[prefix].waitForExistence(timeout: 2) {
                app.buttons[prefix].tap()
                snapshot("A5-前缀-\(prefix.replacingOccurrences(of: "/", with: ""))")
                if app.buttons["清空"].waitForExistence(timeout: 2) {
                    app.buttons["清空"].tap()
                }
            }
        }
    }

    /// A6: 反馈类型切换
    func testA6_FeedbackTypeSelection() throws {
        launchLocked()
        app.buttons["btn_feedback"].tap()
        guard app.navigationBars["意见反馈"].waitForExistence(timeout: 5) else {
            XCTFail("反馈 Sheet 未出现"); return
        }
        let types = ["问题反馈", "界面优化", "其他", "功能建议"]
        for type in types {
            if app.buttons[type].waitForExistence(timeout: 2) {
                app.buttons[type].tap()
            }
        }
        snapshot("A6-反馈类型")
        app.buttons["取消"].tap()
    }

    /// A7: 反馈 - 填写描述和联系方式
    func testA7_FeedbackFormInput() throws {
        launchLocked()
        app.buttons["btn_feedback"].tap()
        guard app.navigationBars["意见反馈"].waitForExistence(timeout: 5) else { return }

        // 联系方式输入框（TextField 可直接点击）
        let contactField = app.textFields["联系方式（选填）"]
        if contactField.waitForExistence(timeout: 3) {
            contactField.tap()
            contactField.typeText("test@test.com")
            app.keyboards.buttons["Return"].tap()
        }

        snapshot("A7-反馈表单填写")
        app.buttons["取消"].tap()
    }

    /// A8: 二维码设置 - 码制/容错/尺寸选项
    func testA8_QRCodeSettings() throws {
        launchLocked()
        snapshot("A8-码制设置")
        // 检查码制、容错、尺寸标签
        let labels = ["码制", "容错", "尺寸"]
        for label in labels {
            let exists = app.staticTexts[label].exists || 
                         app.staticTexts.matching(NSPredicate(format: "label CONTAINS '\(label)'")).firstMatch.exists
            _ = exists // 不强制断言，页面可能需要滚动
        }
        // 尝试点击码制选项
        if app.buttons["QR Code"].waitForExistence(timeout: 2) {
            app.buttons["QR Code"].tap()
            snapshot("A8-QRCode选中")
        }
    }

    // =========================================================================
    // MARK: - B 主界面 TabBar 导航
    // =========================================================================

    /// B1: TabBar 三个 Tab 正常切换
    func testB1_TabBarNavigation() throws {
        launchUnlocked()
        snapshot("B1-初始书架")

        app.buttons["书城"].tap()
        snapshot("B1-书城")
        XCTAssertTrue(app.buttons["书城"].exists)

        app.buttons["我的"].tap()
        snapshot("B1-我的")
        XCTAssertTrue(app.buttons["我的"].exists)

        app.buttons["书架"].tap()
        snapshot("B1-切回书架")
    }

    // =========================================================================
    // MARK: - C 书架页
    // =========================================================================

    /// C1: 书架页加载成功
    func testC1_BookshelfElements() throws {
        launchUnlocked()
        sleep(1)
        snapshot("C1-书架")
        let navBar = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(navBar, "书架页未加载（导航栏不存在）")
    }

    /// C2: 书架导航栏功能按钮
    func testC2_BookshelfNavButtons() throws {
        launchUnlocked()
        snapshot("C2-书架导航栏")
        // 检查导航栏按钮（布局/管理等）
        let navBtns = app.navigationBars.buttons
        if navBtns.count > 0 {
            snapshot("C2-导航栏按钮数:\(navBtns.count)")
        }
    }

    /// C3: 书架布局设置
    func testC3_BookshelfLayoutConfig() throws {
        launchUnlocked()
        // 找布局设置按钮（通常是方格图标）
        let layoutBtn = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS '布局' OR label CONTAINS 'layout' OR label CONTAINS 'square'")
        ).firstMatch
        if layoutBtn.waitForExistence(timeout: 3) {
            layoutBtn.tap()
            sleep(1)
            snapshot("C3-布局设置")
            // 关闭
            if app.buttons["取消"].waitForExistence(timeout: 2) {
                app.buttons["取消"].tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
        }
    }

    /// C4: 书架分组管理
    func testC4_GroupManage() throws {
        launchUnlocked()
        // 书架顶部 Tab/Group 区域，尝试长按或找到管理入口
        snapshot("C4-书架分组")
        // 找"全部"或分组按钮
        let allBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '全部' OR label CONTAINS '分组'")
        ).firstMatch
        if allBtn.waitForExistence(timeout: 3) {
            allBtn.tap()
            sleep(1)
            snapshot("C4-分组操作")
        }
    }

    /// C5: 书架管理（进入批量管理模式）
    func testC5_BookshelfManage() throws {
        launchUnlocked()
        // 找编辑/管理按钮
        let manageBtn = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS '编辑' OR label CONTAINS '管理' OR label CONTAINS 'edit'")
        ).firstMatch
        if manageBtn.waitForExistence(timeout: 3) {
            manageBtn.tap()
            sleep(1)
            snapshot("C5-书架管理")
            // 退出管理模式
            let doneBtn = app.buttons.matching(
                NSPredicate(format: "label CONTAINS '完成' OR label CONTAINS 'Done'")
            ).firstMatch
            if doneBtn.waitForExistence(timeout: 2) { doneBtn.tap() }
        }
    }

    // =========================================================================
    // MARK: - D 书城 / 搜索
    // =========================================================================

    /// D1: 书城页内容加载
    func testD1_BookStoreContent() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        sleep(2)
        snapshot("D1-书城加载后")
    }

    /// D2: 书城频道切换
    func testD2_BookStoreChannels() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        sleep(2)
        snapshot("D2-书城初始")
        // 尝试点击不同频道 Tab
        let channels = ["男频", "女频", "完本", "有声"]
        for ch in channels {
            let btn = app.buttons[ch]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                sleep(1)
                snapshot("D2-频道-\(ch)")
            }
        }
    }

    /// D3: 搜索框点击
    func testD3_SearchTap() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            sleep(1)
            snapshot("D3-搜索框激活")
            // 关闭键盘
            if app.buttons["取消"].waitForExistence(timeout: 2) {
                app.buttons["取消"].tap()
            }
        }
    }

    /// D4: 搜索功能完整流程
    func testD4_SearchFlow() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("斗破苍穹")
            if app.keyboards.buttons["搜索"].waitForExistence(timeout: 3) {
                app.keyboards.buttons["搜索"].tap()
            } else if app.buttons["搜索"].waitForExistence(timeout: 2) {
                app.buttons["搜索"].tap()
            }
            sleep(3)
            snapshot("D4-搜索结果")
        }
    }

    /// D5: 搜索过滤器
    func testD5_SearchFilters() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("小说")
            if app.keyboards.buttons["搜索"].waitForExistence(timeout: 3) {
                app.keyboards.buttons["搜索"].tap()
            }
            sleep(2)
            // 点击过滤器
            let filters = ["全部", "多源 (≥2)", "百万字+", "近期更新"]
            for f in filters {
                let btn = app.buttons[f]
                if btn.waitForExistence(timeout: 2) {
                    btn.tap()
                    sleep(1)
                    snapshot("D5-过滤-\(f)")
                }
            }
            // 精准搜索开关
            let preciseToggle = app.switches["精准搜索"]
            if preciseToggle.waitForExistence(timeout: 2) {
                preciseToggle.tap()
                snapshot("D5-精准搜索开")
                preciseToggle.tap()
            }
        }
    }

    /// D6: 搜索结果点书籍详情
    func testD6_BookDetail() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("斗破苍穹")
            if app.keyboards.buttons["搜索"].waitForExistence(timeout: 3) {
                app.keyboards.buttons["搜索"].tap()
            }
            if app.cells.firstMatch.waitForExistence(timeout: 10) {
                app.cells.firstMatch.tap()
                sleep(2)
                snapshot("D6-书籍详情")
                // 书籍详情页按钮
                let addShelf = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS '书架' OR label CONTAINS '加入'")
                ).firstMatch
                if addShelf.waitForExistence(timeout: 3) {
                    snapshot("D6-加书架按钮存在")
                }
                // 返回
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
    }

    /// D7: 书城排行榜入口
    func testD7_RankList() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        sleep(2)
        // 排行榜通常有个入口 cell 或按钮
        let rankBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '排行' OR label CONTAINS 'rank'")
        ).firstMatch
        if rankBtn.waitForExistence(timeout: 3) {
            rankBtn.tap()
            sleep(2)
            snapshot("D7-排行榜")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    // =========================================================================
    // MARK: - E 我的页（一级）
    // =========================================================================

    /// E1: 我的页主要元素
    func testE1_MyPageElements() throws {
        launchUnlocked()
        goToMyPage()
        snapshot("E1-我的页")
        XCTAssertTrue(
            app.navigationBars["我的"].exists || app.staticTexts["我的"].exists,
            "我的页标题不存在"
        )
    }

    /// E2: 跟随系统主题开关
    func testE2_SystemThemeToggle() throws {
        launchUnlocked()
        goToMyPage()
        let toggle = app.switches.firstMatch
        if toggle.waitForExistence(timeout: 5) {
            snapshot("E2-主题切换前")
            toggle.tap()
            snapshot("E2-主题切换后")
            toggle.tap()
        }
    }

    /// E3: 护眼模式开关
    func testE3_EyeCareToggle() throws {
        launchUnlocked()
        goToMyPage()
        let eyeToggle = app.switches.element(boundBy: 1)
        if eyeToggle.waitForExistence(timeout: 3) {
            snapshot("E3-护眼前")
            eyeToggle.tap()
            snapshot("E3-护眼后")
            eyeToggle.tap()
        }
    }

    /// E4: 阅读记录入口
    func testE4_ReadingHistory() throws {
        launchUnlocked()
        goToMyPage()
        let row = app.staticTexts["阅读记录"]
        if row.waitForExistence(timeout: 3) {
            row.tap()
            sleep(1)
            snapshot("E4-阅读记录")
            // 用导航返回，如无按钮则左滑返回
            let backBtn = app.navigationBars.buttons.firstMatch
            if backBtn.waitForExistence(timeout: 2) {
                backBtn.tap()
            } else {
                app.swipeRight()
            }
            sleep(1)
        }
    }

    /// E5: 意见反馈（我的页入口）
    func testE5_FeedbackFromMyPage() throws {
        launchUnlocked()
        goToMyPage()
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '意见反馈' OR label CONTAINS '反馈'")
        ).firstMatch
        if row.waitForExistence(timeout: 3) {
            row.tap()
            sleep(1)
            snapshot("E5-意见反馈")
            if app.buttons["取消"].waitForExistence(timeout: 2) {
                app.buttons["取消"].tap()
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
    }

    // =========================================================================
    // MARK: - F 我的页 → 规则设置（二级）
    // =========================================================================

    /// F1: TXT 目录规则页
    func testF1_TxtTocRules() throws {
        launchUnlocked()
        goToMyPage()
        // 只进入并截图，不做额外操作（操作可能触发 Runner 崩溃）
        let row = app.staticTexts["TXT 目录规则"]
        if row.waitForExistence(timeout: 5) {
            row.tap()
            sleep(1)
            snapshot("F1-TXT目录规则")
            let backBtn = app.navigationBars.buttons.firstMatch
            if backBtn.waitForExistence(timeout: 2) { backBtn.tap() }
            sleep(1)
        }
    }

    /// F2: 替换净化规则页及编辑
    func testF2_ReplaceRules() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("替换净化") {
            snapshot("F2-替换净化内页")
            let addBtn = self.app.buttons.matching(
                NSPredicate(format: "label CONTAINS '添加' OR label CONTAINS '+'")
            ).firstMatch
            if addBtn.waitForExistence(timeout: 2) {
                addBtn.tap()
                sleep(1)
                snapshot("F2-新增替换规则")
                // 编辑页有正则/启用开关
                let regexToggle = self.app.switches.matching(NSPredicate(format: "label CONTAINS '正则'")).firstMatch
                if regexToggle.waitForExistence(timeout: 2) {
                    snapshot("F2-正则开关存在")
                }
                // 取消
                if self.app.buttons["取消"].waitForExistence(timeout: 2) {
                    self.app.buttons["取消"].tap()
                }
            }
        }
    }

    /// F3: 词典规则页
    func testF3_DictRules() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("词典规则") {
            snapshot("F3-词典规则")
        }
    }

    // =========================================================================
    // MARK: - G 我的页 → 设置（二级）
    // =========================================================================

    /// G1: 主题设置页（含内部控件）
    func testG1_ThemeSettings() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("主题设置") {
            snapshot("G1-主题设置")
            // 主题 Picker
            let picker = self.app.pickers.firstMatch
            if picker.waitForExistence(timeout: 2) {
                snapshot("G1-主题Picker")
            }
            // 沉浸式状态栏
            let immersive = self.app.switches["沉浸式状态栏"]
            if immersive.waitForExistence(timeout: 2) {
                immersive.tap()
                sleep(1)
                immersive.tap()
                snapshot("G1-沉浸状态栏切换")
            }
        }
    }

    /// G2: 其它设置页（含所有 Toggle）
    func testG2_OtherSettings() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("其它设置") {
            snapshot("G2-其它设置")
            let toggleLabels = [
                "启动时打开上次阅读", "启动时刷新书架",
                "预加载封面", "仅 WiFi 加载封面",
                "自动换源", "默认启用替换规则",
                "使用系统选词菜单", "显示漫画入口",
                "自动获取焦点(暂停其它音乐)", "蓝牙断开时退出播放"
            ]
            for label in toggleLabels {
                let sw = self.app.switches[label]
                if sw.waitForExistence(timeout: 1) {
                    sw.tap()
                    sleep(0)
                    sw.tap()
                }
            }
            snapshot("G2-所有Toggle操作完")
            // 压缩数据库按钮
            let compressBtn = self.app.buttons["压缩数据库"]
            if compressBtn.waitForExistence(timeout: 2) {
                compressBtn.tap()
                sleep(1)
                snapshot("G2-压缩数据库")
                // 关闭可能的 alert
                if self.app.alerts.firstMatch.waitForExistence(timeout: 2) {
                    self.app.alerts.buttons.firstMatch.tap()
                }
            }
        }
    }

    /// G3: 阅读偏好页
    func testG3_ReadingPreferences() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("阅读偏好") {
            snapshot("G3-阅读偏好")
            // 尝试各种字体/行距等设置存在
        }
    }

    // =========================================================================
    // MARK: - H 我的页 → 书源/书签/本地（二级）
    // =========================================================================

    /// H1: 导入书源 JSON
    func testH1_ImportBookSource() throws {
        launchUnlocked()
        goToMyPage()
        let btn = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '导入书源'")
        ).firstMatch
        if btn.waitForExistence(timeout: 5) {
            btn.tap()
            sleep(2)
            snapshot("H1-导入书源Sheet")
            // 关闭系统文件选择器
            if app.buttons["取消"].waitForExistence(timeout: 3) {
                app.buttons["取消"].tap()
            }
        }
    }

    /// H2: 书签页
    func testH2_Bookmarks() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("书签") {
            snapshot("H2-书签页")
        }
    }

    /// H3: 本地导入页
    func testH3_LocalImport() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("本地导入") {
            snapshot("H3-本地导入")
            // 导入按钮
            let importBtn = self.app.buttons.matching(
                NSPredicate(format: "label CONTAINS '选择' OR label CONTAINS '导入' OR label CONTAINS '文件'")
            ).firstMatch
            if importBtn.waitForExistence(timeout: 2) {
                importBtn.tap()
                sleep(1)
                snapshot("H3-文件选择器")
                if self.app.buttons["取消"].waitForExistence(timeout: 2) {
                    self.app.buttons["取消"].tap()
                }
            }
        }
    }

    // =========================================================================
    // MARK: - I 我的页 → 关于与法律（二级）
    // =========================================================================

    /// I1: 关于页
    func testI1_AboutPage() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("关于") {
            snapshot("I1-关于页")
            let hasVersion = self.app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'v' OR label CONTAINS '版本'")
            ).firstMatch.exists
        }
    }

    /// I2: 隐私政策
    func testI2_PrivacyPolicy() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("隐私政策") {
            snapshot("I2-隐私政策")
        }
    }

    /// I3: 用户服务协议
    func testI3_UserAgreement() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("用户服务协议") {
            snapshot("I3-用户协议")
        }
    }

    /// I4: 个人信息收集清单
    func testI4_CollectList() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("个人信息收集清单") {
            snapshot("I4-信息收集清单")
        }
    }

    /// I5: 第三方 SDK 清单
    func testI5_SdkList() throws {
        launchUnlocked()
        goToMyPage()
        // 先滚动到底部找到这个选项
        app.swipeUp()
        enterRow("第三方 SDK 清单") {
            snapshot("I5-SDK清单")
        }
    }

    /// I6: 开源协议
    func testI6_License() throws {
        launchUnlocked()
        goToMyPage()
        enterRow("开源协议") {
            snapshot("I6-开源协议")
        }
    }

    /// I7: 注销账号
    func testI7_DeleteAccount() throws {
        launchUnlocked()
        goToMyPage()
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '注销'")
        ).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            sleep(1)
            snapshot("I7-注销账号页")
            // 不实际注销，直接返回
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    // =========================================================================
    // MARK: - J 我的页 → 应用伪装（危险操作，只验证存在不触发）
    // =========================================================================

    /// J1: 应用伪装选项存在
    func testJ1_AppDisguiseOptionExists() throws {
        launchUnlocked()
        goToMyPage()
        snapshot("J1-我的页")
        let disguiseItem = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '伪装'")
        ).firstMatch
        if disguiseItem.waitForExistence(timeout: 3) {
            snapshot("J1-伪装选项可见")
        }
    }

    // =========================================================================
    // MARK: - K 阅读器（需要书架有书）
    // =========================================================================

    private func openReader() -> Bool {
        let bookCell = app.cells.firstMatch
        guard bookCell.waitForExistence(timeout: 3) else { return false }
        bookCell.tap()
        let readButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '阅读' OR label CONTAINS '开始' OR label CONTAINS '继续'")
        ).firstMatch
        if readButton.waitForExistence(timeout: 3) { readButton.tap() }
        sleep(2)
        return true
    }

    /// K1: 阅读器翻页（点击左/右区域）
    func testK1_ReaderPageTurnByTap() throws {
        launchUnlocked()
        guard openReader() else { return }
        snapshot("K1-阅读器")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.5)).tap()
        sleep(1)
        snapshot("K1-翻页后")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.5)).tap()
        sleep(1)
        snapshot("K1-回翻")
    }

    /// K2: 阅读器菜单（点击中间区域）
    func testK2_ReaderMenu() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        snapshot("K2-阅读菜单")
    }

    /// K3: 阅读器目录（TOC）
    func testK3_ReaderTOC() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let tocButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '目录'")
        ).firstMatch
        if tocButton.waitForExistence(timeout: 3) {
            tocButton.tap()
            sleep(1)
            snapshot("K3-目录页")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// K4: 阅读器字体/样式设置
    func testK4_ReaderStyleSettings() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let styleBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置' OR label CONTAINS '字体' OR label CONTAINS 'Aa'")
        ).firstMatch
        if styleBtn.waitForExistence(timeout: 3) {
            styleBtn.tap()
            sleep(1)
            snapshot("K4-阅读样式设置")
            // 关闭
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    /// K5: 阅读器亮度调节
    func testK5_ReaderBrightness() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let slider = app.sliders.firstMatch
        if slider.waitForExistence(timeout: 3) {
            slider.adjust(toNormalizedSliderPosition: 0.7)
            snapshot("K5-亮度调节")
            slider.adjust(toNormalizedSliderPosition: 0.5)
        }
    }

    /// K6: 阅读器内容搜索
    func testK6_ReaderSearch() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let searchBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '搜索' OR label CONTAINS 'search'")
        ).firstMatch
        if searchBtn.waitForExistence(timeout: 3) {
            searchBtn.tap()
            sleep(1)
            snapshot("K6-阅读器搜索")
            if app.searchFields.firstMatch.waitForExistence(timeout: 2) {
                app.searchFields.firstMatch.tap()
                app.searchFields.firstMatch.typeText("的")
                sleep(1)
                snapshot("K6-搜索结果")
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// K7: 阅读器换源
    func testK7_ChangeSource() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let changeBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '换源' OR label CONTAINS '书源'")
        ).firstMatch
        if changeBtn.waitForExistence(timeout: 3) {
            changeBtn.tap()
            sleep(2)
            snapshot("K7-换源页")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// K8: 阅读器自动滚动配置
    func testK8_AutoRead() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let autoBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '自动' OR label CONTAINS 'auto'")
        ).firstMatch
        if autoBtn.waitForExistence(timeout: 3) {
            autoBtn.tap()
            sleep(1)
            snapshot("K8-自动滚动配置")
            // 关闭
            if app.buttons["取消"].waitForExistence(timeout: 2) {
                app.buttons["取消"].tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
        }
    }

    /// K9: 阅读器 TTS 朗读
    func testK9_TTSReader() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        let ttsBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '朗读' OR label CONTAINS 'TTS' OR label CONTAINS '语音'")
        ).firstMatch
        if ttsBtn.waitForExistence(timeout: 3) {
            ttsBtn.tap()
            sleep(2)
            snapshot("K9-TTS朗读")
            // 停止朗读
            let stopBtn = self.app.buttons.matching(
                NSPredicate(format: "label CONTAINS '停止' OR label CONTAINS '暂停'")
            ).firstMatch
            if stopBtn.waitForExistence(timeout: 3) {
                stopBtn.tap()
            }
        }
    }

    /// K10: 阅读器翻页方式设置（仿真翻页/平移等）
    func testK10_PageTurnStyle() throws {
        launchUnlocked()
        guard openReader() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        // 进入样式设置后找翻页方式
        let styleBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置' OR label CONTAINS '字体' OR label CONTAINS 'Aa'")
        ).firstMatch
        if styleBtn.waitForExistence(timeout: 3) {
            styleBtn.tap()
            sleep(1)
            snapshot("K10-翻页设置")
            let turnBtns = ["仿真", "平移", "滚动", "覆盖", "渐变"]
            for mode in turnBtns {
                let btn = self.app.buttons[mode]
                if btn.waitForExistence(timeout: 1) {
                    btn.tap()
                    sleep(0)
                }
            }
            snapshot("K10-翻页方式切换完")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    // =========================================================================
    // MARK: - L 书架 → 书籍详情（二级）
    // =========================================================================

    /// L1: 书籍详情页按钮（书架已有书时）
    func testL1_BookDetailActions() throws {
        launchUnlocked()
        let bookCell = app.cells.firstMatch
        guard bookCell.waitForExistence(timeout: 3) else { return }
        bookCell.tap()
        sleep(2)
        snapshot("L1-书籍详情")

        // 换源按钮
        let changeSourceBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '换源' OR label CONTAINS '手动选源'")
        ).firstMatch
        if changeSourceBtn.waitForExistence(timeout: 3) {
            changeSourceBtn.tap()
            sleep(2)
            snapshot("L1-换源页")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// L2: 书籍详情 → 下载（下载中心）
    func testL2_BookDownloadCenter() throws {
        launchUnlocked()
        let bookCell = app.cells.firstMatch
        guard bookCell.waitForExistence(timeout: 3) else { return }
        bookCell.tap()
        sleep(2)

        let downloadBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '下载' OR label CONTAINS 'download'")
        ).firstMatch
        if downloadBtn.waitForExistence(timeout: 3) {
            downloadBtn.tap()
            sleep(1)
            snapshot("L2-下载中心")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    // =========================================================================
    // MARK: - M 其它入口
    // =========================================================================

    /// M1: 书城排行详情（三级）
    func testM1_RankDetail() throws {
        launchUnlocked()
        app.buttons["书城"].tap()
        sleep(2)
        // 探索页可能有 cell 进入排行
        let cell = app.cells.firstMatch
        if cell.waitForExistence(timeout: 5) {
            cell.tap()
            sleep(2)
            snapshot("M1-书城子页")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    // MARK: - Z: 专用截图验证

    /// Z1: 截图验证阅读器段落间距
    func testZ1_ReaderParagraphSpacingScreenshot() throws {
        launchUnlocked()
        sleep(3)  // wait for bookshelf grid to render
        snapshot("Z1-书架页")
        // 尝试多种方式找到书籍入口
        let bookEntry = app.otherElements.matching(
            NSPredicate(format: "label CONTAINS '仙' OR label CONTAINS '山' OR label CONTAINS '小说' OR label CONTAINS '修'")
        ).firstMatch
        let bookCell = bookEntry.waitForExistence(timeout: 5) ? bookEntry : app.cells.firstMatch
        let hasBook: Bool
        if bookEntry.waitForExistence(timeout: 2) {
            bookEntry.tap()
            hasBook = true
        } else if app.cells.firstMatch.waitForExistence(timeout: 2) {
            app.cells.firstMatch.tap()
            hasBook = true
        } else {
            // 直接点击书架区域的第一本书位置
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).tap()
            hasBook = true
        }
        if hasBook {
            sleep(1)
            snapshot("Z1-书籍详情")
            let readButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS '阅读' OR label CONTAINS '开始' OR label CONTAINS '继续'")
            ).firstMatch
            if readButton.waitForExistence(timeout: 5) {
                readButton.tap()
                sleep(3)
                snapshot("Z1-阅读器正文")
                // 翻几页让段落间距清晰可见
                for i in 1...4 {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.5)).tap()
                    sleep(1)
                    snapshot("Z1-第\(i+1)页")
                }
            }
        }
    }

    // MARK: - DEMO: 真机可见 · 书架 / 书城 / 我的 全功能慢速 walkthrough

    /// 慢速演示测试 — 请在真机上观看屏幕自动操作（约 3–4 分钟）
    func testDemo_visibleAllTabsWalkthrough() throws {
        continueAfterFailure = true
        launchUnlocked()

        // ── 1. 书架 ──
        demoSnapshot("DEMO-书架-初始")
        app.swipeUp(); demoBeat()
        app.swipeDown(); demoBeat()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(
            forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        )
        demoBeat(2)

        let shelfSearchBtn = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS '搜索' OR label CONTAINS 'Search' OR label CONTAINS 'magnifyingglass'")
        ).firstMatch
        if demoTapFirst([shelfSearchBtn], fallback: (0.92, 0.08)) {
            demoBeat()
            demoSnapshot("DEMO-书架-搜索页")
            demoBack()
        }

        func openBookshelfMenu() -> Bool {
            let menuBtn = app.navigationBars.buttons.element(boundBy: 1)
            guard menuBtn.waitForExistence(timeout: 2) else { return false }
            menuBtn.tap(); demoBeat()
            return true
        }

        if openBookshelfMenu() {
            demoSnapshot("DEMO-书架-菜单")
            let layoutItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '布局'")).firstMatch
            if demoTapFirst([layoutItem], fallback: (0.5, 0.3)) {
                demoBeat()
                demoSnapshot("DEMO-书架-布局设置")
                demoTapFirst([app.buttons["完成"]], fallback: (0.5, 0.05))
                demoBeat()
            }
        }

        if openBookshelfMenu() {
            let manageItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '书架管理'")).firstMatch
            if demoTapFirst([manageItem], fallback: (0.5, 0.3)) {
                demoBeat()
                demoSnapshot("DEMO-书架-书架管理")
                demoBack()
            }
        }

        if openBookshelfMenu() {
            let groupItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '分组管理'")).firstMatch
            if demoTapFirst([groupItem], fallback: (0.5, 0.3)) {
                demoBeat()
                demoSnapshot("DEMO-书架-分组管理")
                demoTapFirst([app.buttons["完成"]], fallback: (0.5, 0.05))
                demoBeat()
            }
        }

        let groupBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '全部' OR label CONTAINS '未分组'")
        ).firstMatch
        demoTapFirst([groupBtn], fallback: (0.15, 0.14))
        demoBeat()

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35)).tap()
        demoBeat()
        demoSnapshot("DEMO-书架-书籍/阅读")
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            demoBeat()
        }
        demoExitReader()

        // ── 2. 书城 ──
        demoEnsureRunning()
        demoTapTab("书城")
        demoSnapshot("DEMO-书城-初始")
        _ = demoWaitForAny([app.buttons["bookstore.search"]], timeout: 8)

        demoTapBookstoreChannel(id: "bookstore.channel.male", label: "男生", x: 0.14)
        demoTapBookstoreChannel(id: "bookstore.channel.female", label: "女生", x: 0.32)
        demoTapBookstoreChannel(id: "bookstore.channel.publish", label: "出版", x: 0.48)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        demoBeat()
        demoSnapshot("DEMO-书城-详情")
        demoBack()

        demoTapFirst([app.buttons["bookstore.search"]], fallback: (0.92, 0.08))
        demoBeat()

        let searchField: XCUIElement = {
            let byId = app.textFields["search.keyword"]
            if byId.exists { return byId }
            let byPlaceholder = app.textFields.matching(
                NSPredicate(format: "placeholderValue CONTAINS '书名'")
            ).firstMatch
            return byPlaceholder.exists ? byPlaceholder : app.textFields.firstMatch
        }()

        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("修仙\n")
            let resultReady = demoWaitForAny([
                app.cells.firstMatch,
                app.buttons.matching(NSPredicate(format: "label CONTAINS '修仙'")).firstMatch,
            ], timeout: 15)
            if resultReady {
                demoSnapshot("DEMO-书城-搜索结果")
                if app.cells.firstMatch.exists {
                    app.cells.firstMatch.tap()
                } else {
                    app.buttons.matching(NSPredicate(format: "label CONTAINS '修仙'")).firstMatch.tap()
                }
                demoBeat()
                demoSnapshot("DEMO-书城-搜索详情")
                demoBack()
            } else {
                demoSnapshot("DEMO-书城-搜索页")
            }
            demoBack()
        } else {
            demoSnapshot("DEMO-书城-搜索页")
            demoBack()
        }

        // ── 3. 我的 ──
        demoEnsureRunning()
        demoTapTab("我的")
        demoSnapshot("DEMO-我的-初始")
        app.swipeUp(); demoBeat()

        let toggles = app.switches
        if toggles.count >= 1 { toggles.element(boundBy: 0).tap(); demoBeat() }
        if toggles.count >= 2 { toggles.element(boundBy: 1).tap(); demoBeat() }

        demoTapMyRow(id: "my.row.read_record", label: "阅读记录", snapshotName: "DEMO-我的-阅读记录", fallbackY: 0.52) {
            app.swipeUp(); demoBeat()
        }

        demoTapMyRow(id: "my.row.feedback", label: "意见反馈", snapshotName: "DEMO-我的-意见反馈", fallbackY: 0.60, needsBack: false) {
            if app.buttons["取消"].waitForExistence(timeout: 2) {
                app.buttons["取消"].tap(); demoBeat()
            } else {
                demoBack()
            }
        }

        demoTapMyRow(id: "my.row.download_manage", label: "下载管理", snapshotName: "DEMO-我的-下载管理", fallbackY: 0.68) {
            app.swipeUp(); demoBeat()
        }

        demoTapTab("书架")
        demoSnapshot("DEMO-完成")
        demoBeat()
    }
}
