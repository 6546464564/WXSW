# 万象书屋 · App Store Connect 文案(可直接复制粘贴)

> 跟 Android 端 strings.xml 风格对齐 · 已规避苹果敏感词 · 中英双语

---

## App 名(30 字符内)

### 中文(简体)
```
万象书屋 - 个性化阅读
```

### 中文(繁体 / 香港)
```
萬象書屋 - 個性化閱讀
```

### English (US)
```
Wanxiang Book - Reader
```

---

## 副标题(30 字符内,搜索权重高)

### 中文(简体)
```
开源阅读器 · 自定义书源 · 离线
```

### English
```
Open-source reader, custom sources
```

---

## 关键词(100 字符,英文逗号分隔,不重复 App 名)

### 中文(简体)
```
小说,阅读器,电子书,TXT,EPUB,书源,翻页,夜间,排版,听书,漫画,金庸,古龙,书架,自定义
```

### English
```
ebook,reader,novel,txt,epub,bookshelf,offline,custom,source,chinese,toc,bookmark
```

---

## 描述(4000 字符内)

### 中文(简体)
```
万象书屋是一款开源的个性化阅读器,为爱书人精心打造。

✦ 核心特点 ✦
• 高度自定义阅读界面:字号、行距、段距、字间距、缩进、页边距全部可调
• 4 套精美主题:默认、护眼、夜间、羊皮纸,支持自定义颜色和背景图
• 4 种翻页方式:覆盖、滑动、滚动、无动画,任选所好
• 双指捏合缩放字号,中心点击呼出菜单,边缘点击翻页
• 完整的目录、书签、阅读时长统计

✦ 强大的书源系统 ✦
• 支持 CSS / XPath / JSONPath / JavaScript 多种规则,兼容主流书源格式
• 自定义书源,自由抓取网页内容
• 多书源并发搜索,自动去重 + 异常熔断
• 替换净化:正则去广告、错别字
• 内置词典:汉典、有道、百度,长按选词即查

✦ 本地阅读 ✦
• 支持 TXT 文件导入,自动识别 UTF-8 / GBK / Big5 编码
• 自定义章节切分规则
• 文件 App "用万象书屋打开" 一键导入

✦ 多种内容形态 ✦
• 网络小说、本地 TXT、漫画、有声书全支持
• 有声书后台播放、锁屏控制、蓝牙耳机支持
• 倍速播放 0.5x-3x,定时关闭

✦ 隐私与合规 ✦
• 不强制注册,不收集真实身份信息
• 完整支持 PIPL,提供"清空我的数据"入口
• 支持广告同意撤回(我的→其它设置→个性化广告)
• 通过 iOS 隐私清单(PrivacyInfo)所有 API 用途透明

✦ 开源精神 ✦
本项目基于 GPLv3 开源协议,源码完全公开。
我们不提供内容,所有书源均由用户自行添加,
请尊重作者版权,从正版渠道阅读。

—— 万象,意为天地间一切事物。
   愿每一位读者,在书海里找到自己的小宇宙。
```

### English
```
Wanxiang Book is an open-source personalized reader for ebook lovers.

✦ Highly Customizable Reader ✦
• Adjust font size, line/paragraph spacing, letter spacing, indent, padding
• 4 beautiful themes: Default, Eye-care, Night, Parchment
• 4 page-turn animations: Cover, Slide, Scroll, None
• Pinch to zoom font size, tap center for menu, tap edges to flip

✦ Powerful Source System ✦
• Supports CSS / XPath / JSONPath / JavaScript rules
• Custom book sources for any web page
• Concurrent multi-source search with auto-dedup
• Regex-based content cleanup
• Built-in dictionaries

✦ Local Reading ✦
• TXT import with auto encoding detection (UTF-8/GBK/Big5)
• Custom chapter regex
• "Open with Wanxiang Book" from Files app

✦ Multi-format Support ✦
• Web novels, local TXT, manga, audiobooks
• Background audio with lock-screen controls
• 0.5x-3x speed, sleep timer

✦ Privacy First ✦
• No registration required
• Full PIPL/GDPR support with "Delete My Data"
• Tracking consent can be revoked any time
• Complete privacy manifest

✦ Open Source ✦
This project is licensed under GPLv3.
All book sources are user-added; we provide no content.
Please respect copyright and use authorized sources only.
```

---

## 推广文本(170 字符,可不固定版本更新)

### 中文(简体)
```
v0.1 首发:开源阅读器、4 套主题、4 种翻页、自定义书源、本地 TXT 导入、漫画与有声书。所有书源用户自添加,App 不预装任何内容。
```

### English
```
v0.1 launch: Open-source reader, 4 themes, 4 page-turn modes, custom sources, TXT import, manga & audiobook support. All sources are user-added.
```

---

## 隐私问卷(App Store Connect → App 隐私 → 数据收集)

### Q1: 您的 App 是否收集任何数据?
**是**

### Q2: 收集哪些数据类型?(逐项勾选)

| 数据类别 | 是否收集 | 是否关联用户身份 | 用途 |
|---|---|---|---|
| **设备 ID**(IDFV / 设备 UUID) | ✅ 是 | ❌ 否 | App 功能 + 分析 |
| **崩溃日志** | ✅ 是 | ❌ 否 | App 功能(崩溃修复) |
| **性能数据**(HTTP 响应时间) | ✅ 是 | ❌ 否 | App 功能 |
| **其它诊断数据**(启动耗时) | ✅ 是 | ❌ 否 | App 功能 |
| 联系信息(姓名/邮箱/电话) | ❌ 否 | - | - |
| 健康/财务/位置等敏感数据 | ❌ 否 | - | - |
| 浏览历史 / 搜索历史 | ✅ 是(本地)| ❌ 否 | App 功能(仅本地存储) |

### Q3: 是否用于第三方追踪?
**否** (NSPrivacyTracking = false)

---

## 审核员留言(每次提审都附,降低拒因)

### 中文 + 英文双语
```
Dear App Review Team,

万象书屋 (Wanxiang Book) is an open-source ebook reader (GPLv3 license).

Important context for review:

1. NO BUILT-IN CONTENT
   The app ships with ZERO book sources by default. Users must
   actively add their own sources, similar to RSS readers.
   We do not provide pirated content.

2. PIPL COMPLIANCE
   - Privacy manifest (PrivacyInfo.xcprivacy) included
   - "Delete My Data" button in Settings → Account
   - Personalized ads can be revoked in Settings → Other → Ads

3. NO LOGIN REQUIRED
   The app works fully without registration.
   Test instructions:
   - Launch app
   - Tap "我的" (Mine) tab to see all features
   - Tap "替换净化"/"词典规则" to see rule management
   - Tap "意见反馈" to test backend connection

4. RECOMMENDED TEST URL
   For testing book parsing, use Project Gutenberg
   (https://www.gutenberg.org), which is public domain.

5. AGE RATING
   12+ recommended (Open web content access).

Please feel free to reach out if you need any clarification.

Thank you for your review!

—— 万象书屋开发团队
```

---

## 应用类别

- 主类别: **图书 (Books)**
- 副类别: **教育 (Education)** 或 **参考 (Reference)**

## 应用分级

- 中国大陆: 12+
- 国际: 12+

## 价格

- **免费** (无 IAP, 通过广告变现)

## 联系信息

- 支持网址: `https://api.wanxiangbook.com/support` (需要后端做)
- 隐私政策: `https://api.wanxiangbook.com/legal/privacy.html`
- 用户协议: `https://api.wanxiangbook.com/legal/terms.html`
- 营销网址(可选): `https://wanxiangbook.com`

> 这些链接都需要 ICP 备案 + nginx 配置完成才能用。
> M4 阶段先用占位 URL,M5 提审前替换成真实 URL。
