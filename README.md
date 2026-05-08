# 万象书屋 (Wanxiang Reader)

> **License**: GPL-3.0 · **Repo**: https://github.com/6546464564/WXSW · **Upstream**: 基于 [gedoor/legado](https://github.com/gedoor/legado) 二次开发

万象书屋 是一款基于 [legado / 阅读](https://github.com/gedoor/legado)(GPL-3.0)二次开发的多端电子书阅读器,在保留 legado 强大书源引擎的基础上,做了如下定制:

- **品牌重塑**:`com.wanxiang.reader` 包名,自有 UI 与法律页
- **后端化**:书源、广告配置、运营开关全部由自建后端下发,App 内不再内置书源
- **多端**:Android (Kotlin) / iOS (SwiftUI) / Web 管理面板共用一套后端 API
- **合规**:内置隐私政策、用户协议、个人信息收集清单、SDK 列表等中国大陆上架所需法律页
- **广告变现**:接入穿山甲 (Pangle) + 优量汇 (Tencent YLH),激励视频解锁纯净阅读

## 仓库结构

```
WXSW/
├── android/        Android 客户端 (Kotlin, 基于 legado fork)
│   ├── app/        主应用模块
│   └── modules/    功能模块 (book / rhino 等)
├── ios/            iOS 客户端 (SwiftUI, M0-M5 路线图见 ios/docs/PLAN.md)
├── backend/        Node.js + Express + SQLite 后端 + 管理面板
├── docs/           英文 README / API 文档 / 全栈审查报告 / NOTICE
├── scripts/        发布前自检 / Mac 迁移脚本
├── screenshots/    应用截图
└── .github/        CI 工作流 (release / cronet / web / 后端 CI 等)
```

## 子项目文档

| 路径 | 说明 |
|---|---|
| [docs/English.md](docs/English.md) | English README (legacy from legado) |
| [docs/api.md](docs/api.md) | 阅读 API 调用文档(Web / Content Provider) |
| [docs/AUDIT_REPORT.md](docs/AUDIT_REPORT.md) | 万象书屋 · 全栈审查报告(后端 + Android) |
| [docs/NOTICE.md](docs/NOTICE.md) | 第三方组件清单与上游声明 |
| [backend/README.md](backend/README.md) | 后端部署、API、管理面板说明 |
| [ios/README.md](ios/README.md) | iOS 工程快速跑通指南 |
| [android/app/src/main/assets/updateLog.md](android/app/src/main/assets/updateLog.md) | Android 应用内更新日志 |
| [android/app/src/main/assets/legal/privacyPolicy.md](android/app/src/main/assets/legal/privacyPolicy.md) | 隐私政策 |
| [android/app/src/main/assets/legal/userAgreement.md](android/app/src/main/assets/legal/userAgreement.md) | 用户协议 |
| [android/app/src/main/assets/legal/sdkList.md](android/app/src/main/assets/legal/sdkList.md) | 第三方 SDK 列表 |

## 快速开始

### Android

```bash
cd android
./gradlew assembleAppDebug -PWANXIANG_BACKEND_URL=https://www.wxsw.app
# 产物: app/build/outputs/apk/app/debug/app-app-debug.apk
```

### iOS

```bash
cd ios
~/dev-tools/xcodegen/bin/xcodegen generate
open WanxiangBook.xcodeproj
# Xcode 选 iPhone 15 模拟器 → ⌘R
```

### 后端

```bash
cd backend
npm install
npm run init-db
npm run seed                # 从 App 内置 JSON 导入书源(可选)
ADMIN_INITIAL_PASSWORD=<your_password> npm start
# 管理面板: http://localhost:3000/admin.html
```

详见 [backend/README.md](backend/README.md)。

## 主要功能(继承自 legado)

1. 自定义书源,自己设置规则,抓取网页数据,规则简单易懂
2. 列表书架 / 网格书架自由切换
3. 书源规则支持搜索及发现
4. 订阅内容,可订阅任何想看的内容
5. 替换净化,去除广告替换内容
6. 本地 TXT、EPUB 阅读,手动浏览,智能扫描
7. 高度自定义阅读界面(字体、颜色、背景、行距、段距、加粗、简繁转换)
8. 多种翻页模式(覆盖、仿真、滑动、滚动)

## 万象书屋 增量

1. **后端书源分发**:无需手动导入,App 启动时自动从 `/api/sources` 拉取
2. **运营管理面板**:Web 端管理书源、查看在线人数、推送广告配置
3. **激励广告解锁**:观看 30s 激励视频,解锁 30 分钟纯净阅读
4. **多平台账号**:Android / iOS 共享设备身份,后端按 `X-Platform` 区分
5. **崩溃上报**:自建 `/api/crash` 上报,后端面板可视化分析

## 致谢

万象书屋 在 [legado](https://github.com/gedoor/legado) 与如下开源组件之上构建:

> org.jsoup:jsoup · cn.wanghaomiao:JsoupXpath · com.jayway.jsonpath:json-path · com.github.gedoor:rhino-android · com.squareup.okhttp3:okhttp · com.github.bumptech.glide:glide · org.nanohttpd:nanohttpd · com.github.bumptech.glide:glide · com.jaredrummler:colorpicker · org.apache.commons:commons-text · io.noties.markwon:core · com.hankcs:hanlp · com.positiondev.epublib:epublib-core

完整第三方清单见 [docs/NOTICE.md](docs/NOTICE.md)。

## License

万象书屋 沿用 [GPL-3.0](LICENSE),**源代码必须保持开放**。任何基于本项目的衍生发布都需要遵守 GPL-3.0 第 5 节"修改版本必须以同样的协议发布完整源代码"的要求。
