import XCTest
@testable import WanxiangBook

final class StorageTests: XCTestCase {

    func test_fileManager_tempDir_writable() {
        let tmpDir = FileManager.default.temporaryDirectory
        let testFile = tmpDir.appendingPathComponent("wxsw_storage_test_\(UUID()).txt")
        let data = "hello storage test".data(using: .utf8)!
        do {
            try data.write(to: testFile)
            let readBack = try Data(contentsOf: testFile)
            XCTAssertEqual(readBack, data, "临时目录应可写可读")
            try FileManager.default.removeItem(at: testFile)
        } catch {
            XCTFail("临时目录写入失败: \(error)")
        }
    }

    func test_documentsDir_exists() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        XCTAssertNotNil(docs, "Documents 目录应存在")
    }

    func test_userDefaults_readWrite() {
        let key = "wxsw_test_storage_\(UUID())"
        UserDefaults.standard.set("test_value", forKey: key)
        let loaded = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(loaded, "test_value")
        UserDefaults.standard.removeObject(forKey: key)
    }

    func test_specialCharacterStorage() {
        let key = "wxsw_test_special_\(UUID())"
        let specialContent = "中文测试 🎉 <html>&amp; \"quoted\" 'single'"
        UserDefaults.standard.set(specialContent, forKey: key)
        let loaded = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(loaded, specialContent, "特殊字符应能正确存取")
        UserDefaults.standard.removeObject(forKey: key)
    }

    @MainActor
    func test_userDefaults_readConfig() {
        let config = ReadConfig.shared
        XCTAssertGreaterThan(config.textSize, 0, "字号应大于0")
        XCTAssertGreaterThan(config.lineSpacing, 0, "行距应大于0")
    }
}
