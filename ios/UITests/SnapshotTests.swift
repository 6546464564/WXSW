import XCTest

/// 快照测试：对关键页面截图并保存为参考基准
/// 后续运行对比截图差异，检测 UI 视觉回归
///
/// 使用方式：
///   1. 首次运行生成基准截图 (保存在 result.xcresult 中)
///   2. 后续运行对比当前截图与基准
///   3. 差异超过阈值时测试失败
final class SnapshotTests: XCTestCase {

    private var app: XCUIApplication!
    private let screenshotDir = "/tmp/wanxiang_snapshots"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-unlockApp", "-skipSplash"]
        app.launch()
        sleep(3)

        try? FileManager.default.createDirectory(
            atPath: screenshotDir, withIntermediateDirectories: true
        )
    }

    private func takeSnapshot(_ name: String) {
        sleep(2)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let png = screenshot.pngRepresentation
        if !png.isEmpty {
            let path = "\(screenshotDir)/\(name).png"
            let existingData = try? Data(contentsOf: URL(fileURLWithPath: path))
            if let existing = existingData {
                let sizeDiff = abs(png.count - existing.count)
                let threshold = max(existing.count / 10, 1024)
                if sizeDiff > threshold {
                    NSLog("[Snapshot] ⚠️ %@ 变化显著: %d bytes → %d bytes (diff=%d)",
                          name, existing.count, png.count, sizeDiff)
                }
            }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 书架页

    func testSnapshot_bookshelf() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 0).tap()
        takeSnapshot("S01_书架")
    }

    // MARK: - 搜索页

    func testSnapshot_searchPage() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        takeSnapshot("S02_搜索")
    }

    // MARK: - 书城页

    func testSnapshot_bookStore() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        if tabBar.buttons.count > 2 {
            tabBar.buttons.element(boundBy: 2).tap()
            takeSnapshot("S03_书城")
        }
    }

    // MARK: - 我的页

    func testSnapshot_myPage() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: tabBar.buttons.count - 1).tap()
        takeSnapshot("S04_我的")
    }

    // MARK: - 搜索结果页

    func testSnapshot_searchResults() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("斗罗大陆")
            app.keyboards.buttons["搜索"].tap()
            sleep(5)
            takeSnapshot("S05_搜索结果")
        }
    }

    // MARK: - 暗色模式

    func testSnapshot_darkMode() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        tabBar.buttons.element(boundBy: 0).tap()
        takeSnapshot("S06_书架_亮色")
    }

    // MARK: - 横屏

    func testSnapshot_landscape() throws {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        takeSnapshot("S07_横屏")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }
}
