//
//  UIDebugTests.swift
//  万象书屋 · UI 元素树诊断（模拟器用）
//
//  跑完直接 print 整个 accessibility 元素树到日志, 用 grep 提取.
//  xcodebuild test ... -only-testing:WanxiangBookUITests/UIDebugTests

import XCTest

final class UIDebugTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func dump(_ app: XCUIApplication, _ label: String) {
        let text = "========= UI-DUMP:\(label) =========\n\(app.debugDescription)\n========= END-DUMP:\(label) ========="
        let attachment = XCTAttachment(string: text)
        attachment.name = "dump-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_dump_shelf() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest", "--unlockApp", "--skipSplash", "--AddDemoBook"]
        app.launch()
        sleep(8)
        dump(app, "SHELF")
    }

    func test_dump_gate() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-skipSplash", "-resetAppState"]
        app.launch()
        sleep(8)
        dump(app, "GATE")
    }

    func test_dump_reader() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest", "--unlockApp", "--skipSplash", "--AddDemoBook", "--OpenDemoReader"]
        app.launch()
        sleep(10)
        dump(app, "READER")
    }
}
