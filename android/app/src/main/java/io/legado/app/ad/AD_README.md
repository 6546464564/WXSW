# 万象书屋广告模块

整个模块在 `io.legado.app.ad` 包下, 与业务代码物理隔离.

```
ad/
├─ AdConfig.kt           远端配置数据类 (与 backend /api/ad-config 同构)
├─ AdRepository.kt       配置仓库 (远端 → SP → assets 兜底)
├─ AdRateLimiter.kt      30 分钟节奏控制 (单纯时间记账, 与 SDK 无关)
├─ AdConsent.kt          PIPL 隐私同意弹窗 + 持久化
├─ AdProvider.kt         SDK 适配器抽象接口
├─ AdManager.kt          调度入口: 按需 init / 权重路由 / Lifecycle 安全
├─ provider/
│   └─ StubAdProvider.kt 三家 SDK 的反射骨架 + Stub fallback
├─ ui/
│   ├─ SplashAdActivity.kt   开屏门面 (LAUNCHER 入口)
│   └─ RewardedAdHelper.kt   阅读器内激励位触发器
```

## 一、配置流转

```
┌────────────────────────┐    HTTPS GET /api/ad-config (ETag 缓存)
│ backend/server.js     │ ◄────────────────────────────── App
│ db: ad_config        │                                   │
│ admin 面板可编辑     │                                   ▼
└────────────────────────┘                          AdRepository (SP 持久)
                                                          │
                                                          ▼
                                                     AdManager (按需 init SDK)
                                                          │
                                  ┌───────────────────────┼───────────────────┐
                                  ▼                       ▼                   ▼
                         SplashAdActivity         ReadBookActivity     (其他场景预留)
                         (开屏)                   30min 激励 dialog
```

**前端不持有真实账号 ID**, 全部由 admin 后台填写并下发. 任意账号被封, 在
`/admin` 把对应 `sdk.<csj|ylh|ks>.appId` 改成新账号即可, App 在 `pollIntervalSec`
(默认 6 小时) 内自动切换. 想立即生效, 把 `pollIntervalSec` 临时调到 60 即可.

## 二、接入真实 SDK 流程

当前接入状态:

| SDK | 状态 | 说明 |
|---|---|---|
| 穿山甲 CSJ | **已真实接入** | `app/libs/ad/open_ad_sdk.aar` (v7.5.1.0), 见 `provider/CsjProvider.kt` |
| 优量汇 YLH | **已真实接入** | `app/libs/ad/GDTSDK.unionNormal.4.680.1550.aar`, 见 `provider/YlhProvider.kt` |

要接 KS / 百度 / Sigmob 等其他 SDK:

### 1. 在平台注册账号 + 拿 SDK

| SDK | 注册地址 | 联盟规则文档 |
|---|---|---|
| 穿山甲 CSJ | https://www.csjplatform.com | 《巨量引擎联盟服务协议》 |
| 优量汇 YLH | https://e.qq.com/dev/ | 《优量汇联盟广告投放规范》 |
| 快手联盟 KS (可选) | https://u.kuaishou.com | 《快手联盟广告主服务协议》 |

每家都需要:
- 完成主体认证 (个人 / 企业)
- 上传 App 包名 `io.legado.app` (生产) 或 `io.legado.app.debug` (测试)
- 创建广告位: 一个 "开屏 (Splash)" + 一个 "激励视频 (Rewarded Video)"
- 拿到 **appId** + 两个 **posId**

### 2. 把 SDK 文件扔进 `app/libs/ad/`

仓库已经收纳 `app/libs/ad/open_ad_sdk.aar`. 同样路径下扔 GDTSDK / kssdk-ad 的 aar 即可,
`build.gradle` 里的 `fileTree(dir: 'libs/ad', include: ['*.aar'])` 会自动 include.

### 3. 在 `AndroidManifest.xml` 注册各 SDK 必需声明

每家 SDK 都会要求注册若干 Activity / Provider / Service. 直接复制各自接入文档里
"清单文件配置" 一节贴进 `<application>` 即可.

CSJ 的清单声明已经写在仓库的 `AndroidManifest.xml` 里 (`TTFileProvider` + `csj_file_paths.xml`).

### 4. 写真实 Provider, 替换 `provider/StubAdProvider.kt` 中对应的反射类

参考 `provider/CsjProvider.kt`. 关键步骤:

```kotlin
// init: SDK 文档里的"初始化" 一节, 通常是
GDTAdSdk.initWithoutStart(appContext, appId)
GDTAdSdk.start(object : GDTAdSdk.OnStartListener {
    override fun onStartSuccess() { available = true }
    override fun onStartFailed(e: Exception?) { available = false }
})

// loadSplashAd: 创建 SplashAD / SplashAd 对象, 在 onADLoaded 里调 showAd(container),
//   把 onADDismissed / onADClicked / onADTimeOver / onError 都桥到 listener.

// loadRewardedAd: 创建 RewardVideoAD / KsRewardVideoAd, onVideoComplete + isRewardArrived 时
//   调 listener.onRewardVerified(), onADClose 调 listener.onAdClosed().
```

完成后在 `AdManager.providers` 里登记新的 provider:
```kotlin
"ks" to KsProvider(),     // 新增一行
"baidu" to BaiduProvider() // 同理
```

## 三、已经合规处理的事

- [x] 隐私同意: 首启弹 `AdConsent.ensureConsent`, 用户**主动点同意**才会 init 任何 SDK.
- [x] 激励视频: 必须用户主动点 "观看广告" 按钮才播 (`RewardedAdHelper`), 没有自动播.
- [x] 频次保护: `AdRateLimiter` 保证激励位每 30 分钟最多弹一次, 看完后再有 30 分钟
      纯净阅读窗口.
- [x] 应急熔断: 后端 admin 一键 `disabled=true`, App 拉到立即下线全部广告.
- [x] 失败兜底: SDK 加载失败 / 没接真实 SDK / 用户拒绝同意 → 都不影响主流程, 跳过广告直接进 Main.
- [x] Lifecycle 安全: 激励视频奖励回调用 `lifecycleScope` 包住, Activity destroyed 后不再触发.

## 四、本地联调

```bash
# 后端 (项目根)
node backend/server.js

# 编译 + 装 (gradle 命令行注入后端 URL, 不用改文件)
gradlew.bat :app:assembleAppDebug -PWANXIANG_BACKEND_URL=http://10.0.2.2:3000
adb install -r app/build/outputs/apk/app/debug/legado_app_*.apk
```

打开 http://127.0.0.1:3000/admin, 在 "广告配置" 卡片里改 SDK appId / 各 posId 与权重,
保存. 客户端 6 小时内自动拉新版本; 调试想立即拉, 把 `pollIntervalSec` 改成 60 即可.
