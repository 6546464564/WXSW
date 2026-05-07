# 万象书屋后端数据保留策略

> PIPL 第 19 条要求"个人信息处理者**应当对个人信息处理活动负责**", 数据保留策略需明文化便于审计.

## 自动清理周期

`db.js#cleanupOldData()` 由 server.js 每 30 分钟跑一次, 涉及表如下:

| 表 | 保留时长 | 清理依据 |
|---|---|---|
| `heartbeats` | **30 天** | 心跳日志, 仅用于活跃统计, 不需长期 |
| `visits` | **90 天** | 按日聚合的访问量, 用于留存分析 |
| `admin_session` | 7 天 | session token, 7 天后自动失效 |
| `ad_events` | **30 天** | 广告事件, 满足广告平台对账期, 之后归零 |
| `crashes` | **90 天** | 崩溃日志, 排障窗口期 |
| `audit_log` | **180 天** | 管理员操作审计, 法律建议保留半年 |
| `feedback` (status=done/spam) | 90 天 | 已处理反馈; pending/in_progress 永久 |
| `device_tokens` (last_seen 超 365 天) | 365 天 | 长期不活跃设备清掉, 重装会重新注册 |
| `admin_login_failures` | 30 天 | 登录失败记录, 锁定窗口最长 30 分钟, 30 天 buffer 用于事后审计 |

## 永久保留 (跟用户主动行为绑定, 不主动删)

| 表 | 说明 |
|---|---|
| `book_sources` | 书源是基础数据, 由管理员维护 |
| `ad_config` / `ad_config_history` | 广告配置, 单行 + 历史 30 版 |
| `app_versions` | 版本管理 |
| `announcements` | 公告; 过期的不删, 用户可能需要查阅 |
| `device_blacklist` | 黑名单, 由管理员维护 |
| `admin_users` | 管理员账户 |
| `redeem_codes` | 兑换码记录 |
| `alert_rules` | 告警规则 |

## 用户主动注销

App 用户在「我的 → 注销账号」点击后:
1. App 端清空本地 SharedPreferences + 数据库
2. 调 `DELETE /api/me/wipe-data?device_id=X` (带设备 token), 后端按 device_id **级联清理**:
   - `heartbeats`
   - `visits`
   - `ad_events`
   - `crashes`
   - `feedback`
   - `device_blacklist` 不删 (黑名单保留, 重装也不能绕过)
   - `device_tokens`
   - `redeem_uses` (已使用的兑换记录)

后端返回 `200 { ok: true, deleted: { table: count } }`, 用户可截图作为证据.

## PIPL 数据导出 (TODO P2)

未实现. 用户调 `POST /api/me/export-request` 应该收到 24h 有效下载链接, 内含该用户所有数据 JSON.

## 应急清空全表 (运营慎用)

```bash
# 停 server
# 清某用户全部数据 (示例: device_id 为 'xxx')
sqlite3 data/wanxiang.db "
DELETE FROM heartbeats WHERE device_id='xxx';
DELETE FROM visits WHERE device_id='xxx';
...
"
# 重启 server
```
