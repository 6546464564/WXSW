# 万象书屋 · 全量功能矩阵 + iOS 复刻策略

> 起草: 2026-05-04 · 数据源: Android 仓库 4 个并行考古子任务 · 用途: PLAN.md M2 阶段任务源
>
> **方法论**: 4 个 explore agent 同时扫了
> ① 用户视角(46 Activity / 55 Dialog / 39 Fragment)
> ② 程序员视角(model + service + 19 DAO + help + lib + base + utils)
> ③ 万象书屋自定义(相对 legado 上游的 diff)
> ④ 1308 条字符串聚类
>
> **校正过的事实**(覆盖之前 PLAN.md 旧 AGENTS.md 里的错):
> - 主品牌色不是 `0xc8922a`,是 **`#B8956B`**(棕金系)
> - 默认 `bookSources.json` **已是空数组**,不需要手动清空
> - **WebDAV 同步已在 Android 端被移除**(空实现 + 注释),iOS 复刻可以直接跳过
> - **独立 TTS / HttpTTS 已被移除**(数据库 migration 删表),只剩"有声书 = AudioPlay + ExoPlayer"
> - **CHM/CBZ 解析在 Android 也没有**,iOS 不必复刻
> - **RSS 全套 Activity 仍在工程里但 MainActivity Tab 被砍**,普通用户 UI 入不去
> - `BookFinishedDialog` 不是独立 Dialog 类,是 `ReadBookActivity` 内嵌 View
> - Dialog 数量不是 32 是 **55 个成类 Dialog + 大量 inline `alert{}`**

---

## 0. 阅读引导

### 0.1 三种使用方式
- **想知道工作量** → 看 §10(三档工作量结论)
- **想知道实现哪些功能** → 看 §3-§9(各模块 P0/P1/P2 标签)
- **想知道每个 Android 类对应 iOS 怎么写** → 看 §11(技术映射表)

### 0.2 优先级图例
| 标签 | 含义 |
|---|---|
| 🔴 **P0** | MVP 必做(没有就上架不了 / 用户骂街) |
| 🟡 **P1** | v1.0 应做(留给上架后第一次迭代) |
| 🟢 **P2** | v1.x 长期(锦上添花) |
| ⚫ **P3** | iOS 不适用 / 已废弃 / 不复刻 |

### 0.3 复刻难度图例
| 难度 | 含义 |
|---|---|
| ⭐ | 半天-1 天 |
| ⭐⭐ | 1-3 天 |
| ⭐⭐⭐ | 3-7 天 |
| ⭐⭐⭐⭐ | 1-2 周 |
| ⭐⭐⭐⭐⭐ | 2 周+(单点工程难题) |

---

## 1. 总览数字

| 维度 | Android 现状 | 备注 |
|---|---|---|
| Kotlin 文件 | 765 个 | + 10 个 Java |
| Kotlin LOC | 113,000 行 | |
| 万象书屋自定义 LOC | 6,000-12,000 行 | 51 个文件含"万象书屋"注释 + ad/ 模块 11 文件 |
| Activity | 46 个 | manifest 注册 |
| Fragment | 39 个 | |
| Dialog 类 | 55 个 + 内联 alert | 之前误报 32 |
| ViewModel | 60 个 | |
| Service | 5 个 | AudioPlay / Cache / Export 等 |
| Adapter | 数十个 | |
| Room DAO | 19 个 | |
| Layout XML | 190 个 | |
| 字符串资源 | 1,308 条 zh + 多套翻译 | |
| 默认数据 JSON | 9 套 | bookSources(空) / rssSources / themeConfig / dictRules / ... |
| 法律 markdown | 5 份 | userAgreement / privacyPolicy / collectList / sdkList / license |
| 第三方 SDK | CSJ 7.5.1.0 + GDT 4.680.1550 | iOS 复刻要换 iOS 版本 |

---

## 2. 启动流程(Splash / 隐私同意 / 广告 SDK)

### 2.1 屏幕清单

| # | Android 类 | 用户能看到 | 优先级 | iOS 等价 | 难度 | 工作量 |
|---|---|---|---|---|---|---|
| 2.1.1 | `SplashAdActivity` | 启动 → 隐私同意 → 开屏广告 → 主界面 | 🔴 P0 | `LaunchScreen.storyboard` + `AppDelegate.didFinishLaunching` 阶段 + 全屏 `SplashView` | ⭐⭐ | 2 天 |
| 2.1.2 | `AdConsent` (SP 持久化) | 首启隐私 dialog | 🔴 P0 | `UserDefaults` + 首启 SwiftUI sheet + ATT 弹窗 | ⭐⭐ | 1 天 |
| 2.1.3 | `AdManager.bootstrap` (异步初始化广告 SDK) | 不可见 | 🔴 P0 | iOS 端: 同意后 init Pangle iOS + Tencent Ads iOS | ⭐⭐⭐ | 3 天 |
| 2.1.4 | `AdManager.showSplash` | 开屏广告 1.5-3s | 🔴 P0 | Pangle iOS BUSplashAdView | ⭐⭐ | 2 天 |
| 2.1.5 | `AdConsent.revoke()` (设置撤回) | 我的→其它设置→个性化广告 | 🔴 P0 (PIPL 必须) | SwiftUI Toggle + ATT.requestAuthorization 反向引导 | ⭐ | 0.5 天 |

### 2.2 关键差异点
- Android 启动器 = `SplashAdActivity`;iOS 必须用系统 LaunchScreen 而后切到 `SplashView`(苹果不允许第一帧就是广告)
- Android 隐私同意 = 系统 AlertDialog;iOS 应当用 SwiftUI `.fullScreenCover` 自定义页面(信息密度高苹果更容易过审)
- ATT(App Tracking Transparency)是 iOS 独有,Android 没有;iOS 开屏前必须弹 ATT 否则拿不到 IDFA,广告填充率会跌 30-50%

### 2.3 字符串(典型 key)
`ad_consent_title` / `ad_consent_message` / `ad_consent_agree` / `ad_consent_disagree` / `ad_consent_revoked_toast` / `ad_consent_granted_toast` / `ad_consent_manage_*` / `chapter_unlock_*` / `unlock_bar_*` / `unlock_card_*` / `unlock_extended_toast` / `unlock_max_reached_toast`

---

## 3. 主导航 + 我的页

### 3.1 一级 TabBar(3 Tab)

| # | Tab | Android Fragment | iOS 等价 | 优先级 | 工作量 |
|---|---|---|---|---|---|
| 3.1.1 | 书架 | `BookshelfFragment1` / `BookshelfFragment2`(2 套样式可切) | SwiftUI `BookshelfView`,默认网格,可切列表 | 🔴 P0 | 见 §4 |
| 3.1.2 | 书城 | `BookStoreFragment`(走 `QidianRepository`) | SwiftUI `BookStoreView` | 🔴 P0 | 见 §5 |
| 3.1.3 | 我的 | `MyFragment`(内嵌 `MyPreferenceFragment`) | SwiftUI `MyView` | 🔴 P0 | 见 §3.2 |

### 3.2 我的页结构(MyPreferenceFragment + 顶部纯净阅读卡)

| # | 项 | iOS 优先级 | 难度 |
|---|---|---|---|
| 3.2.1 | **顶部"纯净阅读"卡片**:倒计时 / 延长解锁(看激励广告) | 🔴 P0 | ⭐⭐ |
| 3.2.2 | TXT 目录规则 → `TxtTocRuleActivity` | 🟡 P1 | ⭐⭐ |
| 3.2.3 | 替换净化 → `ReplaceRuleActivity` | 🟡 P1 | ⭐⭐⭐ |
| 3.2.4 | 词典规则 → `DictRuleActivity` | 🟢 P2 | ⭐⭐ |
| 3.2.5 | 主题模式(随系统/日间/夜间) | 🔴 P0 | ⭐ |
| 3.2.6 | 主题设置 → `ThemeConfigFragment`(主色/强调色/背景图/字号比例) | 🔴 P0 | ⭐⭐⭐ |
| 3.2.7 | 其它设置 → `OtherConfigFragment`(语言/UA/缓存/直链上传/广告同意管理) | 🔴 P0 | ⭐⭐⭐ |
| 3.2.8 | 书签 → `AllBookmarkActivity` | 🟡 P1 | ⭐⭐ |
| 3.2.9 | 阅读记录 → `ReadRecordActivity`(阅读时长统计) | 🟡 P1 | ⭐⭐ |
| 3.2.10 | 文件管理 → `FileManageActivity` | 🟢 P2 | ⭐⭐ |
| 3.2.11 | 关于 → `LegalActivity?path=about` | 🔴 P0 | ⭐ |
| 3.2.12 | 隐私政策 → `LegalActivity?path=privacyPolicy` | 🔴 P0 | ⭐ |
| 3.2.13 | 用户协议 → `LegalActivity?path=userAgreement` | 🔴 P0 | ⭐ |
| 3.2.14 | 个人信息收集清单 → `LegalActivity?path=collectList` | 🔴 P0 (PIPL) | ⭐ |
| 3.2.15 | 第三方 SDK 清单 → `LegalActivity?path=sdkList` | 🔴 P0 (PIPL) | ⭐ |
| 3.2.16 | 开源协议 → `LegalActivity?path=license` | 🔴 P0 | ⭐ |
| 3.2.17 | 反馈 → `FeedbackActivity` | 🔴 P0 | ⭐⭐ |
| 3.2.18 | 注销账号 → `AccountDeleteActivity` | 🔴 P0 (PIPL) | ⭐⭐ |

---

## 4. 书架(P0 主战场)

### 4.1 视图与排序

| # | 功能 | Android 实现 | iOS 优先级 | 难度 |
|---|---|---|---|---|
| 4.1.1 | 网格视图(3/4/5/6 列) | `bookshelf_layout` 偏好 + Adapter | 🔴 P0 | ⭐⭐ |
| 4.1.2 | 列表视图 | 同上 | 🟡 P1 | ⭐ |
| 4.1.3 | 排序: 最近/更新时间/书名/手动/综合/作者 | `arrays.xml` `book_sort` | 🔴 P0 (基础) / 🟡 P1 (全 6 种) | ⭐⭐ |
| 4.1.4 | 进度条角标 | 自绘 progress | 🔴 P0 | ⭐ |
| 4.1.5 | 缓存状态角标 | `cache_status_*` | 🟡 P1 | ⭐ |
| 4.1.6 | 阅读状态筛选(追更/养肥/完结/全部) | `pursue_more_book` etc | 🟡 P1 | ⭐⭐ |
| 4.1.7 | 长按弹菜单(置顶/分组/删除) | 自带菜单 | 🔴 P0 | ⭐ |

### 4.2 工具栏菜单(11 项)

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 4.2.1 | 搜索 → SearchActivity | 🔴 P0 | 见 §6 |
| 4.2.2 | 更新目录(当前分组所有书) | 🔴 P0 | ⭐⭐ |
| 4.2.3 | 添加本地 → ImportBookActivity | 🔴 P0 | 见 §16 |
| 4.2.4 | 网络导入(URL 加书) | 🟡 P1 | ⭐⭐ |
| 4.2.5 | 书架管理 → BookshelfManageActivity | 🟡 P1 | ⭐⭐⭐ |
| 4.2.6 | 缓存/导出 → CacheActivity | 🟡 P1 | 见 §17 |
| 4.2.7 | 分组管理 → GroupManageDialog | 🟡 P1 | ⭐⭐ |
| 4.2.8 | 书架布局对话框 | 🔴 P0 | ⭐ |
| 4.2.9 | 导出书架 JSON | 🟢 P2 | ⭐ |
| 4.2.10 | 导入书架 JSON | 🟢 P2 | ⭐ |
| 4.2.11 | 日志 → AppLogDialog | 🟢 P2 | ⭐ |

### 4.3 分组管理

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 4.3.1 | 创建/删除/编辑分组 | 🟡 P1 | ⭐⭐ |
| 4.3.2 | 拖拽排序 | 🟢 P2 | ⭐⭐ |
| 4.3.3 | 多选移动到分组 | 🟡 P1 | ⭐ |
| 4.3.4 | 分组进入子书架 | 🟡 P1 | ⭐⭐ |

### 4.4 字符串聚类来源
`bottom_nav_bookshelf` / `bookshelf_layout` / `layout_grid3-6` / `layout_list` / `bookshelf_px_0-5` / `book_sort` / `pursue_more_book` / `fattening_book` / `finish_book` / `show_unread` / `group_manage` / `add_group` / `move_to_group` / `clear_cache` / `change_source_batch` / `bookshelf_empty` / `cache_status_*`

**§4 工作量小计**: 🔴P0 6-8 天 / + 🟡P1 4-6 天 / + 🟢P2 2-3 天

---

## 5. 书城 / 发现(P0)

### 5.1 频道与运营位

| # | 内容 | Android | 优先级 | 难度 |
|---|---|---|---|---|
| 5.1.1 | 男生/女生/出版三 tab | `bs_male` / `bs_female` / `bs_publish` | 🔴 P0 | ⭐⭐ |
| 5.1.2 | 排行 / 分类(library)/ 完结 | `bs_rank` / `bs_library` / `bs_complete_select` | 🟡 P1 | ⭐⭐⭐ |
| 5.1.3 | 推荐卡(今日必读 / 连载专区 / 完结之选) | `bs_today_must_read` 等 | 🟡 P1 | ⭐⭐ |
| 5.1.4 | "换一换"(随机刷新) | 下拉刷新 + button | 🔴 P0 | ⭐ |
| 5.1.5 | 加载状态 | `bs_loading` / `bs_load_failed` / `bs_coming_soon` | 🔴 P0 | ⭐ |
| 5.1.6 | banner 关键词跳搜索 | `bs_banner_*` | 🟢 P2 | ⭐ |
| 5.1.7 | 漫画入口(若 `show_manga_ui = true`) | 切到 `ReadMangaActivity` | 🟢 P2 | 见 §7 |
| 5.1.8 | 会员/英雄角标 | `bs_badge_member` / `bs_hero_badge` | 🟢 P2 | ⭐ |

### 5.2 实现方
Android `QidianRepository` → 起点中文网 OPDS-like 接口。**iOS 复刻有两种路线**:
- **a. 完全复刻**:iOS 直接 hit 同样的起点接口(可能反爬封 IP) — 风险高
- **b. 后端代理**:后端加 `/api/bookstore/feed` 端点,iOS 只调后端,后端去抓起点 — 推荐
- **c. 跨平台一致**:Android 也切到后端代理,统一来源

### 5.3 字符串聚类
`book_store` / `bs_male/female/publish` / `bs_rank/rank_sub/library/library_sub` / `bs_today_must_read` / `bs_serial_zone` / `bs_complete_*` / `bs_recommend_rank` / `bs_full_rank` / `bs_loading/load_failed/coming_soon` / `bs_badge_*` / `bs_banner_*` / `find_on_www` / `discovery` / `find_empty` / `refresh_explore` / `show_manga_ui`

**§5 工作量小计**: 🔴P0 5 天(只男/女/出版) / + 🟡P1 5 天(排行+完结+推荐卡) / + 🟢P2 3 天

---

## 6. 搜索

| # | 功能 | Android | 优先级 | 难度 |
|---|---|---|---|---|
| 6.1 | 关键词输入(防抖 300ms) | `SearchActivity` + `SearchView` | 🔴 P0 | ⭐ |
| 6.2 | 多书源并发抓取 + 边出边渲染 | `SearchModel` + 协程 | 🔴 P0 | ⭐⭐⭐ |
| 6.3 | 按"书名+作者"去重 | 自实现 | 🔴 P0 | ⭐ |
| 6.4 | 按相关度排序(精确/模糊) | `precision_search` 偏好 | 🟡 P1 | ⭐ |
| 6.5 | 搜索范围筛选(全部/分组/单源) | `SearchScopeDialog` | 🟡 P1 | ⭐⭐ |
| 6.6 | 搜索历史(本地 SQLite) | `searchHistory` | 🔴 P0 | ⭐ |
| 6.7 | 清除历史(自动/手动) | `auto_clear_expired` / `clear` | 🟡 P1 | ⭐ |
| 6.8 | 一键加书架 | `add_to_bookshelf` | 🔴 P0 | ⭐ |
| 6.9 | 点搜索结果 → 详情页 | → `BookInfoActivity` | 🔴 P0 | ⭐ |
| 6.10 | 异常源熔断(连续超时禁用) | `SearchModel` | 🟡 P1 | ⭐⭐ |

**§6 工作量**: 🔴P0 4 天 / + 🟡P1 3 天

---

## 7. 阅读器(主战场,40+ 功能点)

> **iOS 复刻最难的就是这一节**。Android 阅读器 `ReadBookActivity.kt` 3000+ 行,加上 `BaseReadBookActivity` / `ReadView` / `PageDelegate` / `ReadMenu` / `SearchMenu` / `TextActionMenu` / 17 个 Dialog 共 ~10000 行。

### 7.1 主入口与生命周期
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.1.1 | `ReadBookActivity` 主屏 | 🔴 P0 | ⭐⭐⭐⭐ |
| 7.1.2 | 进入时恢复上次进度(章节+段落+字符 offset) | 🔴 P0 | ⭐⭐ |
| 7.1.3 | 退出时保存进度 | 🔴 P0 | ⭐ |
| 7.1.4 | 横屏/竖屏自适应 | 🟡 P1 | ⭐⭐ |
| 7.1.5 | 屏幕方向锁定(跟随/竖/横/感应) | `screenOrientation` | 🟡 P1 | ⭐ |
| 7.1.6 | 保持常亮(`keep_light`) | 🟡 P1 | ⭐ |

### 7.2 翻页方式(5 种)
| # | 模式 | Android key | iOS 实现 | 优先级 | 难度 |
|---|---|---|---|---|---|
| 7.2.1 | 覆盖 | `page_anim_cover` | TabView(.page) + 自定义 transition | 🔴 P0 | ⭐⭐ |
| 7.2.2 | 滑动 | `page_anim_slide` | TabView(.page) | 🔴 P0 | ⭐ |
| 7.2.3 | 仿真翻书 | `page_anim_simulation` | UIBezierPath + Metal shader | 🟡 P1 | ⭐⭐⭐⭐⭐ |
| 7.2.4 | 滚动(垂直无限) | `page_anim_scroll` | ScrollView + LazyVStack | 🔴 P0 | ⭐⭐⭐ |
| 7.2.5 | 无动画 | `page_anim_none` | 直接换 view | 🔴 P0 | ⭐ |

### 7.3 排版引擎
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.3.1 | 字号 12-32 sp | 🔴 P0 | ⭐ |
| 7.3.2 | 行间距 0.8-2.5 倍 | 🔴 P0 | ⭐ |
| 7.3.3 | 段间距 | 🔴 P0 | ⭐ |
| 7.3.4 | 字间距 | 🟡 P1 | ⭐ |
| 7.3.5 | 上下左右页边距 | 🔴 P0 | ⭐ |
| 7.3.6 | 首行缩进(0/1/2/3/4 字符) | 🔴 P0 | ⭐ |
| 7.3.7 | 两端对齐 | 🟡 P1 | ⭐⭐ |
| 7.3.8 | 字体粗细切换 | 🟡 P1 | ⭐ |
| 7.3.9 | 中文排版优化(标点压缩) | 🟡 P1 | ⭐⭐⭐ |
| 7.3.10 | 简繁转换 | `convert_s` | 🟢 P2 | ⭐⭐ |
| 7.3.11 | **分页核心算法** | 🔴 P0 | ⭐⭐⭐⭐⭐ ← 工程难点 |
| 7.3.12 | 横屏双页布局 | 🟡 P1 | ⭐⭐⭐ |
| 7.3.13 | 刘海区留白 | 🟡 P1 | ⭐ |

> **7.3.11 难点说明**: SwiftUI 没有直接对应 Android `StaticLayout`。必须用 `CTFramesetter`(CoreText)做精确分页。这是 M2 阶段最容易超时的任务,**预留 1.5 周 buffer**。

### 7.4 主题与配色
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.4.1 | 4 套预设(默认/护眼/夜间/羊皮纸/...) | 🔴 P0 | ⭐⭐ |
| 7.4.2 | 自定义背景色 | 🔴 P0 | ⭐ |
| 7.4.3 | 自定义文字色 | 🔴 P0 | ⭐ |
| 7.4.4 | 自定义背景图(系统相册选) | 🟡 P1 | ⭐⭐ |
| 7.4.5 | 主题列表导入导出 | 🟢 P2 | ⭐⭐ |
| 7.4.6 | 亮度调节(条) | 🔴 P0 | ⭐ |
| 7.4.7 | 自动亮度 | 🟡 P1 | ⭐ |
| 7.4.8 | 沉浸式状态栏 | 🟡 P1 | ⭐⭐ |
| 7.4.9 | E-ink 模式(灰阶) | 🟢 P2 | ⭐⭐ |

### 7.5 菜单(`book_read.xml`,18 项)
| # | 菜单项 | 优先级 | 难度 |
|---|---|---|---|
| 7.5.1 | 换源 → ChangeBookSourceDialog | 🔴 P0 | ⭐⭐⭐ |
| 7.5.2 | 刷新(当前/之后/全部) | 🔴 P0 | ⭐ |
| 7.5.3 | 离线下载 → CacheActivity | 🟡 P1 | 见 §17 |
| 7.5.4 | 编码切换(本地 TXT) | 🟡 P1 | ⭐⭐ |
| 7.5.5 | 添加书签 → BookmarkDialog | 🔴 P0 | ⭐ |
| 7.5.6 | 编辑正文(本地修改) | 🟢 P2 | ⭐⭐ |
| 7.5.7 | 翻页动画切换 | 🔴 P0 | ⭐ |
| 7.5.8 | 获取/覆盖云进度 | ⚫ P3 | iOS 不复刻(WebDAV 已删) |
| 7.5.9 | 倒序正文 | 🟢 P2 | ⭐ |
| 7.5.10 | 模拟阅读(滚动测试) | 🟢 P2 | ⭐ |
| 7.5.11 | 替换规则开关 | 🟡 P1 | ⭐ |
| 7.5.12 | 去重标题 | 🟢 P2 | ⭐ |
| 7.5.13 | 重新分段 | 🟢 P2 | ⭐⭐ |
| 7.5.14 | EPUB 去注音/去 h | 🟢 P2 | ⭐ |
| 7.5.15 | 图片样式 | 🟢 P2 | ⭐ |
| 7.5.16 | 更新目录 | 🔴 P0 | ⭐ |
| 7.5.17 | 生效替换 → EffectiveReplacesDialog | 🟡 P1 | ⭐ |
| 7.5.18 | 帮助 / 日志 | 🟢 P2 | ⭐ |

### 7.6 长按选词菜单(7 项)
`content_select_action.xml`

| # | 项 | 优先级 | 难度 |
|---|---|---|---|
| 7.6.1 | 替换 | 🟡 P1 | ⭐ |
| 7.6.2 | 复制 | 🔴 P0 | ⭐ |
| 7.6.3 | 书签 | 🔴 P0 | ⭐ |
| 7.6.4 | 词典 → DictDialog | 🟢 P2 | ⭐⭐ |
| 7.6.5 | 正文搜索 → SearchContentActivity | 🟡 P1 | ⭐ |
| 7.6.6 | 浏览器 → WebViewActivity | 🟢 P2 | ⭐ |
| 7.6.7 | 分享 | 🔴 P0 | ⭐ |

### 7.7 配置 Dialog(11 个)
| # | Dialog | 优先级 | 难度 |
|---|---|---|---|
| 7.7.1 | ReadStyleDialog(底部大面板:字号/字距/行距/段距/翻页/字体) | 🔴 P0 | ⭐⭐⭐ |
| 7.7.2 | BgTextConfigDialog(背景与文字颜色) | 🔴 P0 | ⭐⭐ |
| 7.7.3 | PaddingConfigDialog(边距) | 🔴 P0 | ⭐ |
| 7.7.4 | TipConfigDialog(页眉页脚:时间/进度/电量) | 🟡 P1 | ⭐⭐ |
| 7.7.5 | ClickActionConfigDialog(九宫格点击区域映射) | 🟡 P1 | ⭐⭐ |
| 7.7.6 | MoreConfigDialog(更多开关) | 🟡 P1 | ⭐ |
| 7.7.7 | AutoReadDialog(自动翻页速度) | 🟡 P1 | ⭐ |
| 7.7.8 | PageKeyDialog(物理键映射) | ⚫ P3 | iOS 不需要 |
| 7.7.9 | ContentEditDialog(本地修改正文) | 🟢 P2 | ⭐⭐ |
| 7.7.10 | EffectiveReplacesDialog(查看当前章生效的替换) | 🟢 P2 | ⭐ |
| 7.7.11 | ChangeBookSourceDialog(换源) | 🔴 P0 | ⭐⭐⭐ |

### 7.8 手势与按键
| # | 交互 | 优先级 | 难度 |
|---|---|---|---|
| 7.8.1 | 中心点击 = 呼出菜单 | 🔴 P0 | ⭐ |
| 7.8.2 | 边缘点击 = 翻页(上一页/下一页) | 🔴 P0 | ⭐ |
| 7.8.3 | 横向滑动 = 翻页 | 🔴 P0 | ⭐ |
| 7.8.4 | 上滑 = 唤出目录 | 🟡 P1 | ⭐ |
| 7.8.5 | 长按 = 选词菜单 | 🔴 P0 | ⭐⭐ |
| 7.8.6 | 音量键翻页 | ⚫ P3 | iOS 不允许劫持音量键 |
| 7.8.7 | 鼠标滚轮翻页 | ⚫ P3 | iOS 端不适用 |
| 7.8.8 | 物理键映射 | ⚫ P3 | iOS 端不适用 |
| 7.8.9 | 双指捏合调字号 | 🟡 P1 (iOS 自加) | ⭐⭐ |
| 7.8.10 | 三指截图(iOS 系统) | 🟢 P2 | ⭐ |

### 7.9 进度与跳章
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.9.1 | 章节跳转 → TocActivity | 🔴 P0 | ⭐⭐ |
| 7.9.2 | 进度条拖拽 | 🔴 P0 | ⭐⭐ |
| 7.9.3 | 上一章 / 下一章 button | 🔴 P0 | ⭐ |
| 7.9.4 | 阅读时长统计(每秒+1 写 SQLite) | 🟡 P1 | ⭐⭐ |

### 7.10 章节内/全书搜索
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.10.1 | SearchMenu(章节内关键词高亮) | 🟡 P1 | ⭐⭐ |
| 7.10.2 | SearchContentActivity(全书搜索) | 🟡 P1 | ⭐⭐⭐ |
| 7.10.3 | 跳到搜索结果位置 | 🟡 P1 | ⭐ |

### 7.11 朗读 (TTS)
| # | 功能 | 备注 | 优先级 |
|---|---|---|---|
| 7.11.1 | 朗读引擎 | **Android 端已删** | ⚫ P3 (不复刻) |
| 7.11.2 | 朗读高亮 | 仅 UI 残留 | ⚫ P3 |
| 7.11.3 | iOS AVSpeechSynthesizer 简易朗读 | iOS 自加(可选) | 🟢 P2 |
| 7.11.4 | iOS Siri 阅读集成 | 系统支持自动 | 🟢 P2 |

### 7.12 万象书屋自定义
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 7.12.1 | **章节付费墙**(读到 freeChapters 后弹解锁) | 🔴 P0 | ⭐⭐⭐ |
| 7.12.2 | **顶部纯净阅读倒计时条** | 🔴 P0 | ⭐⭐ |
| 7.12.3 | **激励视频解锁 30 分钟** | 🔴 P0 | ⭐⭐ |
| 7.12.4 | **看广告延长解锁** | 🔴 P0 | ⭐ |
| 7.12.5 | **解锁冷却**(`AdRateLimiter`) | 🔴 P0 | ⭐⭐ |
| 7.12.6 | **熔断**(连续 N 次失败送短期解锁) | 🟡 P1 | ⭐⭐ |
| 7.12.7 | **读完页**(内嵌 view, 不是 Dialog):去书架/去书城/换源/看广告续读 | 🔴 P0 | ⭐⭐ |

> **iOS 重要风险**: §7.12.1-7.12.4 在 iOS 上可能违反 **3.1.1 In-App Purchase**(看广告 = 解锁付费功能)。
> **建议**: iOS 端这套用 IAP 重做。但 Q2 你选了"完全免费 + 广告",所以如果坚持照搬,**审核必踩 3.1.1**。这是 Q2 的具体兑付。

### 7.13 字符串聚类
`page_mode` / `page_anim*` / `read_aloud*` / `replace` / `bookmark` / `dict` / `search_content` / `browser` / `share` / `text_size` / `line_size` / `paragraph_size` / `padding*` / `text_indent` / `bg_color` / `text_color` / `text_font*` / `auto_next_page*` / `change_origin` / `chapter_unlock_*` / `unlock_bar_*` / `book_finished_*`

**§7 工作量小计**:
- 🔴P0 总计: ~ **15-20 天**(分页算法占 7-10 天)
- 🟡P1 总计: ~ 8-12 天
- 🟢P2 总计: ~ 5-8 天
- 🔴 P0 仅 + 章节付费墙整套: + 4 天

---

## 8. 漫画阅读(可选,默认隐藏)

| # | 功能 | Android 类 | 优先级 | 难度 |
|---|---|---|---|---|
| 8.1 | 漫画主屏 | `ReadMangaActivity` | 🟢 P2 | ⭐⭐⭐ |
| 8.2 | 漫画翻页(竖滚 / 横翻) | book_manga.xml | 🟢 P2 | ⭐⭐ |
| 8.3 | 电子纸模式 | `MangaEpaperDialog` | 🟢 P2 | ⭐ |
| 8.4 | 颜色滤镜 | `MangaColorFilterDialog` | 🟢 P2 | ⭐ |
| 8.5 | 页脚信息 | `MangaFooterSettingDialog` | 🟢 P2 | ⭐ |
| 8.6 | 自动翻页 | `enable_auto_page_scroll` | 🟢 P2 | ⭐ |

> Android 默认 `show_manga_ui = false`,iOS 同样默认隐藏。**v1 不做,v1.x 看用户呼声决定**。

---

## 9. 有声书 / Audio(P1)

| # | 功能 | Android | 优先级 | 难度 |
|---|---|---|---|---|
| 9.1 | AudioPlayActivity 主屏 | `AudioPlayActivity` | 🟡 P1 | ⭐⭐⭐ |
| 9.2 | AudioPlayService(后台播放) | `service/` | 🟡 P1 | ⭐⭐⭐ |
| 9.3 | 通知栏控制 | MediaSession | 🟡 P1 | ⭐⭐ |
| 9.4 | 后台播放权限 | foreground service | 🟡 P1 | ⭐ (iOS BGTaskScheduler) |
| 9.5 | 蓝牙耳机控制 | media button | 🟡 P1 | ⭐⭐ |
| 9.6 | 倍速播放 | ExoPlayer | 🟡 P1 | ⭐ |

> **iOS 等价**: AVPlayer + AVAudioSession.background category + MPNowPlayingInfoCenter + MPRemoteCommandCenter

---

## 10. 书源系统(后端管理,App 端只展示)

### 10.1 当前架构
- **Android 已禁用用户导入入口**(BookSourceActivity 入口隐藏)
- 书源完全由后端 `/api/sources` 下发
- iOS 端要做的:**只读消费 + 本地缓存 + 引擎执行**,**不需要书源编辑器**

### 10.2 必须复刻的子模块
| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 10.2.1 | 拉远端书源 + ETag 304 | 🔴 P0 | ⭐ |
| 10.2.2 | 本地 SQLite 持久化 + reconcile(远端没的本地禁用) | 🔴 P0 | ⭐⭐ |
| 10.2.3 | BookSourceEngine(规则解析 + JS + HTTP) | 🔴 P0 | ⭐⭐⭐⭐⭐ ← 见 PLAN.md M1 |
| 10.2.4 | 自动换源(失败次数到阈值时切下一个) | 🟡 P1 | ⭐⭐ |
| 10.2.5 | 书源调试器(开发者工具) | ⚫ P3 | iOS 不暴露 |
| 10.2.6 | 书源登录(WebView + cookie 持久化) | 🟡 P1 | ⭐⭐⭐ |

### 10.3 BookSource 字段(iOS Swift 模型)
完整对照见 `app/src/main/java/io/legado/app/data/entities/BookSource.kt`,关键字段:
- `bookSourceUrl` / `bookSourceName` / `bookSourceGroup` / `bookSourceType`
- `searchUrl`(搜索 URL 模板)
- `ruleSearch` / `ruleBookInfo` / `ruleToc` / `ruleContent` / `ruleExplore`(5 大子规则结构)
- `header`(自定义请求头) / `loginUrl` / `loginUi` / `cookieStore`
- `jsLib`(共享 JS 库) / `concurrentRate`(并发限速)

---

## 11. RSS 订阅(已隐藏)

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 11.1 | RssFragment | ⚫ P3 (Android 也未挂主导航) | - |
| 11.2 | RssSourceActivity / RuleSubActivity | ⚫ P3 | - |
| 11.3 | ReadRssActivity (WebView 阅读) | ⚫ P3 | - |
| 11.4 | RssFavoritesActivity | ⚫ P3 | - |
| 11.5 | RssSourceDebugActivity | ⚫ P3 | - |

> **iOS 完全跳过**。Android 工程虽留着这些 Activity,主导航早砍了,iOS 端没必要复刻。如果未来产品决定回归 RSS,从 Android 残留代码反推规格,3-4 周一个迭代搞定。

---

## 12. 替换规则(P1)

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 12.1 | ReplaceRuleActivity 列表 | 🟡 P1 | ⭐⭐ |
| 12.2 | ReplaceEditActivity 编辑(正则/范围/作用域) | 🟡 P1 | ⭐⭐⭐ |
| 12.3 | 分组管理 | 🟡 P1 | ⭐ |
| 12.4 | 导入规则(URL/文件) | 🟡 P1 | ⭐⭐ |
| 12.5 | 在阅读器开关 | 🔴 P0 | ⭐ |
| 12.6 | 净化规则引擎(章节内容应用替换) | 🔴 P0 | ⭐⭐ |

---

## 13. 词典规则(P2)

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 13.1 | DictRuleActivity 列表 | 🟢 P2 | ⭐⭐ |
| 13.2 | DictRuleEditDialog | 🟢 P2 | ⭐⭐ |
| 13.3 | 长按选词 → DictDialog 查询 | 🟢 P2 | ⭐⭐ |
| 13.4 | 内置词典(汉典/有道/百度等) | 🟢 P2 | ⭐⭐ |

---

## 14. TXT 目录规则(P1)

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 14.1 | TxtTocRuleActivity 列表 | 🟡 P1 | ⭐⭐ |
| 14.2 | TxtTocRuleEditDialog 正则编辑 | 🟡 P1 | ⭐⭐ |
| 14.3 | 本地 TXT 应用规则切章 | 🔴 P0 (本地阅读必备) | ⭐⭐⭐ |
| 14.4 | 默认规则集(从 assets/defaultData/ 内置) | 🔴 P0 | ⭐ |

---

## 15. 本地导入(P0,iOS 必做)

### 15.1 支持格式
| 格式 | Android | iOS 优先级 | 难度 |
|---|---|---|---|
| TXT | 自实现编码探测 + 切章 | 🔴 P0 | ⭐⭐ |
| EPUB | epublib(modules/book) | 🔴 P0 | ⭐⭐⭐ |
| MOBI / AZW | lib/mobi/(Java) | 🟡 P1 | ⭐⭐⭐ |
| PDF | system pdf | 🟡 P1 | ⭐⭐ |
| UMD | modules/book(Java) | 🟢 P2 | ⭐⭐ |
| ZIP / RAR / 7z | libarchive | 🟢 P2 | ⭐⭐ |
| CHM / CBZ | **Android 也没有** | ⚫ P3 | - |

### 15.2 入口
| # | 入口 | 优先级 | 难度 |
|---|---|---|---|
| 15.2.1 | "添加本地"菜单 → ImportBookActivity | 🔴 P0 | ⭐⭐ |
| 15.2.2 | iOS 文件 App "用万象书屋打开" | 🔴 P0 | ⭐ |
| 15.2.3 | iOS share extension | 🟡 P1 | ⭐⭐ |
| 15.2.4 | 自动扫描 iCloud Documents | 🟢 P2 | ⭐⭐ |

> **iOS 不可能复刻 Android `FileAssociationActivity`**,iOS 用 Document Types + UTI + UISceneDelegate 处理打开。

---

## 16. 缓存 / 离线下载

| # | 功能 | Android | 优先级 | 难度 |
|---|---|---|---|---|
| 16.1 | CacheActivity 列表 | `CacheActivity` | 🟡 P1 | ⭐⭐ |
| 16.2 | 后台批量下载章节 | `CacheBookService` | 🟡 P1 | ⭐⭐⭐ |
| 16.3 | 进度通知栏 | foreground service | 🟡 P1 | ⭐⭐(iOS BGTask) |
| 16.4 | 下载某章之后所有 | `menu_download_after` | 🟡 P1 | ⭐ |
| 16.5 | 下载全部 | `menu_download_all` | 🟡 P1 | ⭐ |
| 16.6 | 导出书 (TXT/EPUB) | export | 🟢 P2 | ⭐⭐⭐ |
| 16.7 | 预下载下一章(阅读时) | 阅读器内 | 🔴 P0 | ⭐⭐ |

---

## 17. 书签 / 笔记 / 阅读记录

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 17.1 | BookmarkDialog(添加/编辑) | 🔴 P0 | ⭐ |
| 17.2 | 跨书全部书签 → AllBookmarkActivity | 🟡 P1 | ⭐⭐ |
| 17.3 | 书签导出 markdown | 🟢 P2 | ⭐ |
| 17.4 | 阅读记录(时长/字数) → ReadRecordActivity | 🟡 P1 | ⭐⭐ |
| 17.5 | 阅读记录排序 | 🟢 P2 | ⭐ |

---

## 18. 内置浏览器 / 二维码

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 18.1 | WebViewActivity(书源登录 / 链接) | 🟡 P1 | ⭐⭐(iOS WKWebView) |
| 18.2 | SourceLoginActivity / SourceLoginDialog | 🟡 P1 | ⭐⭐ |
| 18.3 | QrCodeActivity 扫码 | 🟢 P2 | ⭐⭐(iOS AVCapture) |
| 18.4 | QrCodeResult 二维码生成 | 🟢 P2 | ⭐(iOS CIFilter) |

---

## 19. 文件管理 / 字体加载

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 19.1 | FileManageActivity | 🟢 P2 | ⭐⭐ |
| 19.2 | 字体选择(本地字体文件) | 🟡 P1 | ⭐⭐(iOS UIFont registerFont) |
| 19.3 | 默认字体 | 🟡 P1 | ⭐ |

---

## 20. 同步 / 备份(基本不复刻)

| # | 功能 | Android 现状 | iOS 优先级 |
|---|---|---|---|
| 20.1 | WebDAV 同步 | **已删** | ⚫ P3 |
| 20.2 | 阅读进度云同步 | **已删** | ⚫ P3 |
| 20.3 | 书架 JSON 导出 | 还在 | 🟢 P2 |
| 20.4 | 书架 JSON 导入 | 还在 | 🟢 P2 |
| 20.5 | iCloud 同步(iOS 端自加) | - | 🟢 P2 |

---

## 21. 万象书屋后端通信(P0 全部必做)

详见 `app/src/main/java/io/legado/app/help/WanxiangBackend.kt`。iOS `WanxiangAPI.swift` 一一对齐:

| # | API | 用途 | 优先级 | 难度 |
|---|---|---|---|---|
| 21.1 | `POST /api/device/register` | 设备身份 + HMAC token | 🔴 P0 | ⭐ |
| 21.2 | `GET /api/sources?platform=ios`(M0 后端要加 platform 过滤) | 拉书源 | 🔴 P0 | ⭐ |
| 21.3 | `POST /api/ping` | 4 分钟心跳 | 🔴 P0 | ⭐ |
| 21.4 | `GET /api/ad-config` | 广告配置(含 review_mode 开关) | 🔴 P0 | ⭐ |
| 21.5 | `POST /api/ad-event` | 广告事件 | 🔴 P0 | ⭐ |
| 21.6 | `POST /api/crash-log` | 崩溃上报 | 🔴 P0 | ⭐⭐ |
| 21.7 | `POST /api/feedback` | 反馈 | 🔴 P0 | ⭐ |
| 21.8 | `DELETE /api/me/wipe-data` | PIPL 数据删除 | 🔴 P0 | ⭐ |
| 21.9 | `GET /api/announcement` | 公告 | 🟡 P1 | ⭐ |
| 21.10 | `GET /api/version-check` | 版本检查 | 🟡 P1 | ⭐ |
| 21.11 | `POST /api/iap/verify` | 苹果票据(iOS 仅,后端已支持) | 🟢 P2 (Q2 选了不做 IAP) | ⭐⭐ |
| 21.12 | `GET /api/iap/entitlements` | 内购权益 | 🟢 P2 | ⭐ |

---

## 22. 法律 / 合规(P0 全做)

5 份 markdown 直接复用:
- `app/src/main/assets/legal/userAgreement.md`(用户协议)
- `app/src/main/assets/legal/privacyPolicy.md`(隐私政策)
- `app/src/main/assets/legal/collectList.md`(个人信息收集清单)
- `app/src/main/assets/legal/sdkList.md`(第三方 SDK 清单)
- `app/src/main/assets/legal/license.md`(开源协议)

> **iOS 端必须改写 `sdkList.md`**:Android SDK 列表(CSJ 7.5.1.0 + GDT 4.680.1550)替换为 iOS 版本(BUAdSDK / GDTMobSDK 对应版本)。

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 22.1 | LegalActivity 读 markdown | 🔴 P0 | ⭐ (iOS 用 SwiftUI Markdown) |
| 22.2 | FeedbackActivity(类型/正文/联系方式) | 🔴 P0 | ⭐⭐ |
| 22.3 | AccountDeleteActivity(本地清空 + revoke 同意) | 🔴 P0 | ⭐⭐ |
| 22.4 | AccountDeleteFinishedActivity | 🔴 P0 | ⭐ |
| 22.5 | iOS 隐私清单 PrivacyInfo.xcprivacy(iOS 17+ 强制) | 🔴 P0 | ⭐⭐ |
| 22.6 | ATT 弹窗(iOS) | 🔴 P0 | ⭐ |

---

## 23. 主题 / 字体 / 封面

| # | 功能 | 优先级 | 难度 |
|---|---|---|---|
| 23.1 | 主题模式(随系统/日间/夜间) | 🔴 P0 | ⭐ |
| 23.2 | 主色 / 强调色 / 背景色 | 🔴 P0 | ⭐⭐ |
| 23.3 | 工具栏 elevation | 🟢 P2 | ⭐ |
| 23.4 | 沉浸式状态栏 | 🟡 P1 | ⭐⭐ |
| 23.5 | 主题列表导入导出 | 🟢 P2 | ⭐⭐ |
| 23.6 | 默认主题(万象棕金 #B8956B) | 🔴 P0 | ⭐ |
| 23.7 | 封面规则(从书源自动抓封面) | 🟡 P1 | ⭐⭐⭐ |
| 23.8 | 仅 Wi-Fi 加载封面 | 🟡 P1 | ⭐ |
| 23.9 | 默认封面(日/夜) | 🔴 P0 | ⭐ |
| 23.10 | 封面显示书名/作者覆盖层 | 🟡 P1 | ⭐ |
| 23.11 | 字体下载(系统字体管理) | 🟡 P1 | ⭐⭐(iOS CTFontManagerRegisterFontsForURL) |

---

## 24. 设置项总清单(85+ 项,重要的列出)

### 24.1 阅读偏好(`pref_config_read.xml` ~30 项)
屏幕方向 / 保持常亮 / 隐藏状态栏 / 隐藏导航栏 / 正文两端对齐 / 刘海留白 / 横屏双页 / 进度条行为 / 中文排版 / 对齐 / 鼠标滚轮翻页(⚫ iOS 不需要)/ 音量键翻页(⚫)/ 长按按键翻页(⚫)/ 触摸灵敏度 / 自动换源 / 可选中文本 / 亮度条 / 滚动动画 / 点图预览 / 渲染优化 / 点击区域配置 / 禁用返回键(⚫) / 自定义按键翻页(⚫) / 扩展文本菜单 / 阅读栏跟随页面

### 24.2 主题(`pref_config_theme.xml` ~15 项)
沉浸式状态栏/导航栏 / 工具栏 elevation / 界面字号比例 / 跳转封面配置 / 主题列表 / 日间主色/强调色/背景色/底栏色/背景图 / 夜间主色等 / 保存主题

### 24.3 封面(`pref_config_cover.xml` ~6 项)
仅 Wi-Fi 加载封面 / 封面规则 / 默认封面开关 / 日/夜默认封面图 / 封面显示书名/作者

### 24.4 其它(`pref_config_other.xml` ~30 项)
语言 / 自动刷新书架 / 启动默认打开阅读 / 默认主页 Tab / 本地密码 / UA / 书籍保存目录 / 源编辑器最大行数 / 校验书源 / 直链上传规则 / Cronet(⚫ iOS 用 URLSession) / 抗锯齿 / 位图缓存 / 图片保留 / 预下载章节数 / 默认启用替换 / 蓝牙耳机退出行为 / 音频焦点 / 过期清理 / 加书架提示 / 更新渠道变体 / 显示漫画入口 / 清理缓存 / **广告同意管理** / 清理 WebView / 压缩数据库 / 线程数 / 系统文本菜单接入 / 日志与 heap dump

> **iOS 设置项预计数量**: 比 Android 少 ~30%(去掉物理键 / 蓝牙离线 / Cronet / 压缩 SQLite 等),约 50-60 项。

---

## 25. 底层基础设施

### 25.1 数据库(iOS 直接照搬 schema)
19 个 Room DAO 表,关键的:
- **books**(书架)
- **bookChapters**(章节)
- **bookSources**(书源)
- **searchKeywords**(搜索历史)
- **bookmarks**(书签)
- **replaceRules**(替换规则)
- **dictRules**(词典规则)
- **txtTocRules**(TXT 目录规则)
- **rssSources**(RSS,可不复刻)
- **rssArticles**(RSS 文章,可不复刻)
- **rssReadRecords**(RSS 阅读记录,可不复刻)
- **readRecord**(阅读时长)
- **httpTTS**(已删)
- **server**(已删,WebDAV)
- **groups**(分组)
- **searchBooks**(搜索结果缓存)
- **books_extra**(书籍扩展信息)
- **cookies**(网络 cookie)
- **caches**(KV 缓存)

> iOS 用 sqlite3 C API + actor 直接复刻 schema,**列名/类型 1:1**,**不引 GRDB**。约 5 天工作量。

### 25.2 网络层
| Android | iOS 等价 | 工作量 |
|---|---|---|
| OkHttp | URLSession | ⭐ |
| Cronet(可选 QUIC) | 不复刻(URLSession 自带 HTTP/3) | - |
| Cookie 持久化 | URLSession HTTPCookieStorage | ⭐ |
| 自定义 UA | URLSession httpAdditionalHeaders | ⭐ |
| Glide(图片) | Kingfisher(SwiftPM) **或** SwiftUI AsyncImage | ⭐⭐ |
| Glide AVIF / SVG | iOS 17+ AsyncImage 不支持 SVG → 装 SwiftSVG | ⭐ |

### 25.3 协程 / 并发
Android `Coroutine.kt`(自封装)→ iOS `Task` + `actor` + `AsyncStream` + `withCheckedThrowingContinuation`

### 25.4 EventBus / LiveData
`liveeventbus`(Android)→ iOS Combine `PassthroughSubject` + `@Published` + SwiftUI `@State`/`@Observable`

### 25.5 ViewBinding / DataBinding
Android XML + ViewBinding → SwiftUI 声明式,**完全 1:1 重写**(无 viewbinding 概念)

---

## 26. 第三方 SDK 对照(iOS 复刻必读)

| SDK | Android | iOS 等价 | 备注 |
|---|---|---|---|
| 穿山甲(CSJ) | open_ad_sdk.aar 7.5.1.0 | BUAdSDK iOS(CocoaPods `Ads-Global` 或下载 .xcframework) | iOS 必须 Info.plist 加 ~80 个 SKAdNetworkID |
| 优量汇(GDT/YLH) | GDTSDK 4.680.1550 | GDTMobSDK iOS | 同上,补 SKAdNetworkID |
| Glide | 5.0.5 | Kingfisher 7.x | |
| Room | 2.7.1 | sqlite3 + actor 自封装 | |
| OkHttp | 5.x | URLSession | |
| Markwon | 4.6.2 | SwiftUI Markdown(iOS 15+ 内置)+ swift-markdown(Apple 官方) | |
| QuickChineseTransfer | 0.2.16 | iOS 端自实现简繁(数据集 ~50KB) | |
| HanLP | 自带 | iOS 不做(可选 Swift 端 NLP) | |
| Hutool crypto | 5.8.22 | CryptoKit | |
| Jsoup | 1.16.2 | SwiftSoup | |
| jsoupxpath | 2.5.3 | libxml2(系统) | |
| Rhino(JS) | 1.8.1 | JavaScriptCore(系统) | |
| Mozilla Rhino 兼容垫片 | 自实现 | 自实现(JSC) | iOS 端必须写 java.* 兼容垫片 |
| ExoPlayer / Media3 | 1.8.0 | AVPlayer + AVAudioSession | |
| ZXing(二维码) | zxing-lite 3.3.0 | AVCaptureMetadataOutput(iOS 系统) | |
| ColorPicker | jaredrummler 1.1.0 | SwiftUI ColorPicker | |
| LiveEventBus | 1.8.14 | Combine | |
| Cronet | 自带 | 不需要(URLSession 自带 HTTP/3) | |

---

## 27. iOS 复刻总工作量(三档)

### 档 A · 极简 MVP(能上架的最小集)
> **目标**: 6-8 周通过 App Store 审核,先占位

包含:
- §2 启动 + 同意 + 1 个广告位(开屏)
- §3 主导航 + 我的(基本)
- §4 书架(网格 + 简单排序 + 分组)
- §6 搜索(只搜本地,不连书源)
- §7 阅读器(覆盖/滑动/无 3 种翻页 + 字号/行距/主题 + 长按复制 + 书签 + 进度)
- §10 书源引擎(只解析后端下发的 5 个公版书源)
- §15 本地导入(仅 TXT + EPUB)
- §17 书签(只本地)
- §21 后端通信(全部 P0)
- §22 合规(全部)

**省略**: 漫画 / 有声 / RSS / 词典 / TXT 目录规则 / 替换规则 / 缓存 / 内置浏览器 / 二维码 / WebDAV / 多翻页动画(只 3 种)

**工作量**: **6-8 周**(单人全职)
**风险**: 5.2.3 / 4.2 拒审风险中等(40-50% 首次过审)

### 档 B · 完整 v1(核心阅读体验完整)
> **目标**: 阅读体验跟 Android 当前相当,4-6 个月

档 A + 加:
- §4 书架 P1 全做(批量管理 + 缓存角标 + 6 种排序)
- §5 书城(男/女/出版 + 排行 + 推荐卡)
- §6 搜索 P1(范围筛选 + 历史 + 熔断)
- §7 阅读器 P1 全做(仿真翻页 + 滚动模式 + 9 宫格点击区域 + 自动翻页 + 全书搜索 + 章节内搜索)
- §7.12 章节付费墙 + 看广告解锁(**iOS 风险**:可能违反 3.1.1)
- §9 有声书
- §10 P1(自动换源 + 书源登录)
- §12 替换规则
- §14 TXT 目录规则
- §15 P1(MOBI / PDF)
- §16 缓存离线
- §17 P1(全部书签 + 阅读记录)
- §23 P1(背景图 + 封面规则 + 字体下载)

**工作量**: **4-6 个月**(单人全职)
**风险**: 章节付费墙触发 3.1.1 风险升高至 60-70%

### 档 C · 完美复刻(Android 上有的 iOS 全有)
> **目标**: 1:1 功能对等,8-12 个月

档 B + 加:
- §8 漫画(若产品要)
- §13 词典
- §15 P2(UMD / ZIP / RAR)
- §16 P2(导出 TXT/EPUB)
- §17 P2(书签 markdown 导出 / 阅读记录排序)
- §19 文件管理 + 字体下载
- §20.3-4 书架 JSON 导入导出
- §23 主题列表导入导出
- §24 全部 50-60 项设置

**工作量**: **8-12 个月**(单人全职)
**风险**: 同档 B,但功能多 → 测试覆盖压力指数级上升

---

## 28. 选哪一档?(我的建议)

| 你的目标 | 推荐档 |
|---|---|
| 想 1-2 个月内上 App Store 占坑 + 收集第一批 iOS 用户反馈 | **档 A** |
| 想做出 iOS 端用户能正经用、留存、产生广告变现的 App | **档 B**(承认 3.1.1 风险,M5 阶段补救) |
| 想跟 Android 1:1 完美对等(且接受 8-12 个月成本 + 较高拒审压力) | **档 C** |

---

## 29. 跟 PLAN.md 的对接方式

PLAN.md M2 部分(原 15 个粗 task)将基于本文档重写:
- M2.1-M2.X 每一个 task 对应 FEATURES.md 的一个 P0 项
- 每个 P0 项的"工作量"列直接进 PLAN.md 的 task estimate
- 标 🟡P1 / 🟢P2 的项进 PLAN.md 的"v1.1+ backlog"

**待你拍板**: 档 A / B / C 选哪个,我立刻按那个档把 M2 的 task 列表展开。

---

## 附录 · 总数清算

| 类别 | 数量 |
|---|---|
| FEATURES.md 罗列功能项 | **220+** |
| 🔴 P0(MVP 必做) | **~95** 项 |
| 🟡 P1(v1 应做) | **~75** 项 |
| 🟢 P2(v1.x 长期) | **~40** 项 |
| ⚫ P3(iOS 不适用 / 已废) | **~10** 项 |
| Android 设置项总数 | ~85 |
| iOS 预计设置项 | ~50-60 |
| iOS 必须复刻的后端 API | 8 个(P0)+ 4 个(P1/P2) |
| iOS 必须改写的合规文档 | 5 份(主要改 SDK 清单) |
| iOS 必须的第三方依赖 | 4 个(SwiftSoup / Kingfisher / BUAdSDK / GDTMobSDK) |

---

> **完。** 4 份考古报告整合完毕,功能矩阵 220+ 项全列,iOS 复刻策略已标。等你拍板档位。
