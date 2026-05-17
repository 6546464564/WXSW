# 万象书屋 iOS · M4 上架前清单

> 这份清单列出 M4 阶段你**必须自己完成或外包**的事项。
> 我(代码生成 AI)能做的代码部分都已经写完;以下都是需要人工/资源/账户的工作。

---

## 1. App 图标(必须)

### 1024×1024 主图标
- [ ] 找设计师做 1024×1024 PNG (无圆角,无透明,无 Alpha 通道)
- [ ] 设计建议:沿用 Android `app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` 的视觉风格
- [ ] 万象书屋品牌色:**棕金 #B8956B**
- [ ] 推荐预算:¥500-1500 (设计师 1-2 天)

### 各尺寸自动生成
- [ ] 用 [App Icon Generator](https://appicon.co/) 上传 1024×1024 → 下载全套
- [ ] 把生成的 `Assets.xcassets/AppIcon.appiconset/` 拖进 Xcode 项目根

---

## 2. 启动屏(已配置占位,可改)

当前 `Info.plist` 用 `UILaunchScreen.UIColorName=""` 表示纯色启动屏(默认白)。

### 升级建议
- [ ] 在 `Sources/WanxiangBook/Resources/Assets.xcassets/` 加 `LaunchLogo.imageset`(192×192 万象 logo)
- [ ] 改 `project.yml` 的 `Info.plist properties.UILaunchScreen` 加:
  ```yaml
  UILaunchScreen:
    UIImageName: "LaunchLogo"
    UIColorName: "LaunchBackground"
    UIImageRespectsSafeAreaInsets: true
  ```

---

## 3. App Store 截图(必须)

### 尺寸要求
| 设备 | 分辨率 | 必填? | 说明 |
|---|---|---|---|
| 6.9" iPhone Pro Max (15/16) | 1320 × 2868 | **必填** | iPhone 15 Pro Max 截 |
| 6.5" iPhone | 1242 × 2688 | **必填** | iPhone 11 Pro Max 截 |
| 13" iPad Pro | 2048 × 2732 | **必填** | iPad Pro 第 6 代截 |

### 内容(每尺寸 5 张)
1. 书架(网格视图,有 6-9 本书,展示进度条)
2. 阅读器(羊皮纸主题,Lorem ipsum 中文示例文本)
3. 阅读器(夜间主题,展示对比)
4. 书城(展示 banner + 推荐网格)
5. 我的页(展示纯净阅读卡片 + 完整菜单)

### 操作步骤
1. Xcode 跑模拟器 (iPhone 15 Pro Max / iPad Pro M4)
2. 用 ⌘S 截屏(自动保存到 Mac 桌面)
3. **必须叠加文案**(用 Sketch / Figma / Canva 加大字标题)
4. 推荐预算:¥500-1500 找设计师做 5 张 × 3 尺寸 = 15 张

---

## 4. App Store Connect 配置(必须自己做)

### 4.1 创建 App
1. https://appstoreconnect.apple.com → My Apps → +
2. **Bundle ID**: `com.wanxiang.reader` (跟 project.yml 一致)
3. **Primary Language**: 中文(简体)
4. **Name**: 万象书屋(后续可改,但建议想清楚)
5. **SKU**: `wanxiang-reader-ios-001` (内部使用)
6. **In-App Purchase capability**: 即使不上 SKU 也勾上,留后路

### 4.2 必填信息
- [ ] **App 名字** (30 字符内,不能含 "best/top/free" 等敏感词)
- [ ] **副标题** (30 字符,搜索权重高)
- [ ] **关键词** (100 字符,逗号分隔,不要重复 App 名)
- [ ] **促销文本** (170 字符,可不固定版本更新)
- [ ] **描述** (4000 字符)
- [ ] **支持网址** (我们的官网或 GitHub)
- [ ] **隐私政策网址** (必填,可用 https://api.wanxiangbook.com/legal/privacy.html)
- [ ] **关于本 App 的隐私问卷** (跟 PrivacyInfo.xcprivacy 字段精确对齐)

### 4.3 应用分级
- 中国大陆: 12+
- 国际: 12+
- 必填:暴力/性/恐怖/赌博等 14 项 → 全选"无"

### 4.4 主类别 / 副类别
- 主类别: **图书 (Books)**
- 副类别: **教育 (Education)** 或 **参考 (Reference)**

### 4.5 测试账号(给苹果审核员用)
- [ ] 创建一个 demo 账号(或留空)
- [ ] **重点**:在"备注"里写清楚书架预填示例,让审核员能跑流程
  > 建议留言:
  > "首次启动后,书架空。请点'我的→书签'查看跨书书签功能。
  >  书城点任意书可加入书架。本 App 不预填任何第三方书源,
  >  所有书源均由用户主动添加,App 本身不提供盗版内容。"

---

## 5. ICP 备案(必须自己做)

### 5.1 域名
- [ ] 注册 `wanxiangbook.com` (或类似) 在阿里云/腾讯云
- [ ] 推荐预算:¥55/年 (阿里云 .com)

### 5.2 备案
- [ ] 阿里云/腾讯云控制台 → ICP 备案 → 提交个人/企业信息
- [ ] 准备:身份证 / 域名证书 / 服务器接入信息(我们用 wxsw.app,需要让阿里云/腾讯云做你的 ISP)
- [ ] **审核 7-14 工作日**
- [ ] **必须**在 M5 提审前 2 周完成,否则 iOS App 用 IP 后端会被苹果拒(5.2.5)

### 5.3 备案完成后
- [ ] iOS 端 `WanxiangAPI.baseURL` 改成 `https://api.wanxiangbook.com`
- [ ] 删 `Info.plist` 的 `NSAppTransportSecurity.NSExceptionDomains.wxsw.app` 整段
- [ ] 后端 nginx 配 HTTPS (用 `backend/deploy/nginx-wanxiang-https.conf` 模板)

---

## 6. Apple Developer Program(必须自己做)

- [ ] 注册 https://developer.apple.com (¥688/年)
- [ ] 个人或企业账号都行,个人开发者审核 1-3 天
- [ ] 注册成功后:
  - [ ] Xcode → Settings → Accounts → 加 Apple ID
  - [ ] project.yml 的 `DEVELOPMENT_TEAM: ""` 填你的 Team ID
  - [ ] 改 `CODE_SIGNING_ALLOWED: NO` → `YES` (Archive 时)

---

## 7. TestFlight 内测(强烈建议)

### 流程
1. Xcode → Product → Archive → 上传到 App Store Connect
2. 在 App Store Connect 启用 TestFlight
3. 邀请 5-10 个真人(同事 / 早期用户 / 老婆老公)
4. 收集 24-72h 反馈

### 关注点
- [ ] 启动耗时(> 3s 算慢)
- [ ] 内存占用(后台不要 > 200MB)
- [ ] 翻页流畅度(60fps)
- [ ] 暗夜模式所有页面都对
- [ ] 真机 vs 模拟器是否有差异

---

## 8. 提审材料(M5 用)

### 必备文档
- [ ] 苹果审核回复模板(预防"5.2.3 第三方内容"被拒):
  ```
  Dear App Review Team,

  万象书屋 (Wanxiang Book) is an open-source book reader (GPLv3).
  - The app does NOT bundle any third-party content sources by default.
  - All sources are user-added, similar to RSS readers like Reeder.
  - We comply with PIPL (China's privacy law) by providing
    a "Delete My Data" button in Settings → Account.
  - Privacy manifest (PrivacyInfo.xcprivacy) is included.

  Test account: not required (no login).
  Test sources URL: https://www.gutenberg.org/ (Project Gutenberg, public domain).

  Thanks for your time.
  ```
- [ ] 操作演示视频(2-3 分钟)展示完整流程

### 提审检查
- [ ] App Store Connect → 该 App → "提交以供审核"
- [ ] 等 24-72h
- [ ] 第一次 80% 概率被拒,准备第二轮提交

---

## 9. 我已经做完的事(确认列表)

- [x] iOS 项目工程结构
- [x] SwiftUI 主体 (TabBar / 书架 / 书城 / 我的)
- [x] 阅读器 (4 套主题, 4 种翻页, 分页算法, 选词菜单, 书签, 倒计时条, 读完页)
- [x] 书源引擎 (CSS/XPath/JSONPath/JS Dispatcher + 4 大 Parser)
- [x] 漫画 + 有声 (基础)
- [x] 3 种规则系统 UI (替换/词典/TXT 目录)
- [x] 本地导入 (TXT)
- [x] 缓存管理
- [x] 二维码 + 浏览器 + 词典查词
- [x] 5 份合规 markdown 文档
- [x] 反馈 + 注销 + ATT + PrivacyInfo.xcprivacy
- [x] 广告骨架 (AdProvider / AdManager / Stub 实现)
- [x] CrashHandler 全局崩溃捕获
- [x] Document Types (用万象书屋打开 .txt/.epub)
- [x] 后端 platform=ios 过滤 + 4 个测试 case
- [x] 本文档

---

## 10. 我做不了的事(必须你来)

- [ ] App 图标设计 (找设计师 ¥500-1500)
- [ ] 截图设计 (找设计师 ¥500-1500)
- [ ] App Store Connect 注册和填表
- [ ] ICP 备案 (¥0-300, 7-14 天)
- [ ] Apple Developer Program 注册 (¥688/年)
- [ ] 真机签名 / Archive
- [ ] 真接 Pangle iOS / GDT iOS SDK (需要它们的 appId, 需要 Info.plist 加 80+ 个 SKAdNetworkID, ~250MB framework)
- [ ] EPUB / MOBI / PDF / UMD / RAR 解析 (需要找 Swift 库或自实现)
- [ ] 仿真翻书 Metal shader (1-2 周专项工程)
- [ ] 横屏双页布局 (1-2 周)
- [ ] WebDAV 同步 (Android 已删, 评估是否要做)
- [ ] 真实书城后端 /api/bookstore/feed (后端工程, 1 周)
- [ ] 字体下载 + 注册 (CTFontManager)

预算:**5-10 万元** (找一个全职 iOS 工程师 1-2 个月把上面 #10 全做完)
或者:你自己花 6 个月慢慢推
