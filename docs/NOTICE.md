# 万象书屋 NOTICE

万象书屋 (Wanxiang Reader) is a derivative of [legado](https://github.com/gedoor/legado) released under GPL-3.0.

## Original Project

- **legado** © 阅读 (gedoor) and contributors
- License: GNU General Public License v3.0
- Source: https://github.com/gedoor/legado

## Our Changes

- Renamed package id to `com.wanxiang.reader`
- Removed bundled book sources (now dynamically fetched from self-hosted backend)
- Removed WebDAV / TTS / community features
- Added ad monetization (Pangle / Tencent YLH SDKs) — see `app/src/main/assets/legal/sdkList.md`
- Added self-hosted backend (book source distribution + analytics + ad config + crash reporting)
- Added compliance pages (privacy policy / user agreement / data collection list / SDK list)
- Bug fixes — see [CHANGELOG] section in repository

Full source code of the derivative is available at:

> **REPO_URL_PLACEHOLDER** — please replace with your public Git repository before release.

## Third-Party Components

| Component | License | Project |
|---|---|---|
| Kotlin | Apache-2.0 | https://kotlinlang.org/ |
| AndroidX | Apache-2.0 | https://developer.android.com/jetpack/androidx |
| OkHttp | Apache-2.0 | https://square.github.io/okhttp/ |
| Retrofit | Apache-2.0 | https://square.github.io/retrofit/ |
| Glide | BSD / MIT / Apache-2.0 | https://github.com/bumptech/glide |
| Cronet | BSD-3-Clause | https://github.com/chromium/chromium/tree/main/components/cronet |
| Room | Apache-2.0 | https://developer.android.com/training/data-storage/room |
| Coroutines | Apache-2.0 | https://github.com/Kotlin/kotlinx.coroutines |
| Material Components | Apache-2.0 | https://github.com/material-components/material-components-android |
| LiveEventBus | Apache-2.0 | https://github.com/JeremyLiao/LiveEventBus |
| Gson | Apache-2.0 | https://github.com/google/gson |
| Splitties | Apache-2.0 | https://github.com/LouisCAD/Splitties |
| Pangle SDK (穿山甲) | Commercial | https://www.csjplatform.com/ |
| Tencent YLH SDK (优量汇) | Commercial | https://e.qq.com/ |

## Backend Components

| Component | License |
|---|---|
| Express | MIT |
| better-sqlite3 | MIT |
| bcryptjs | MIT |
| cookie-parser | MIT |

---

For full license texts of each component, see the `LICENSE` files in their respective package distributions.
