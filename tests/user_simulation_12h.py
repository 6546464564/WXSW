#!/usr/bin/env python3
"""
万象书屋 — 全功能真实用户模拟 v5 (10倍速)
覆盖所有可交互功能: 28 个独立场景

设备: iPhone SE (375x667)
WDA 元素定位: 坐标 + accessibilityIdentifier/name
"""

import argparse
import time
import sys
import random
import json
import os
import wda

BUNDLE_ID = "com.wanxiang.reader"
DEFAULT_WDA_URL = "http://192.168.88.166:8100"
LOG_FILE = os.path.join(os.path.dirname(__file__), "simulation_crash_log.jsonl")

W, H = 375, 667
SHELF_BOOKS = [(66, 234), (187, 234), (308, 234)]
TAB_Y = 635
TAB_SHELF_X, TAB_STORE_X, TAB_MY_X = 62, 187, 312

stats = {
    "cycles": 0, "errors": 0, "crashes": 0, "actions": 0,
    "wda_failures": 0, "pages_read": 0, "books_searched": 0,
    "books_added": 0, "chapters_jumped": 0, "sources_changed": 0,
    "tts_sessions": 0, "downloads": 0, "bookmarks": 0,
}
current_action = "idle"
last_action = "idle"
start_time = time.time()


def log_event(event_type, **data):
    entry = {
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "elapsed_s": int(time.time() - start_time),
        "type": event_type, "action": current_action,
        "last_action": last_action, **data,
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def safe_tap(s, timeout=3, **kwargs):
    try:
        el = s(**kwargs)
        if el.wait(timeout=timeout):
            el.tap()
            return True
    except Exception:
        pass
    return False


def check_wda(client):
    try:
        client.status()
        return True
    except Exception:
        return False


def ensure_alive(client, session):
    if not check_wda(client):
        stats["wda_failures"] += 1
        log_event("wda_disconnected")
        for i in range(20):
            time.sleep(5)
            if check_wda(client):
                log_event("wda_reconnected", attempt=i + 1)
                break
        else:
            log_event("wda_dead")
            report()
            sys.exit(2)
        try:
            session = client.session(BUNDLE_ID)
            time.sleep(3)
        except Exception:
            pass
        return session
    try:
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID") or ""
        if bid == BUNDLE_ID:
            return session
        stats["crashes"] += 1
        log_event("app_crash", current_app=bid)
        print(f"  ⚠ 崩溃#{stats['crashes']}（{current_action}）")
    except Exception as e:
        stats["crashes"] += 1
        log_event("app_crash_check_failed", error=str(e)[:200])
    try:
        session = client.session(BUNDLE_ID)
        time.sleep(3)
        log_event("app_restarted")
    except Exception:
        pass
    return session


# ─── 基础导航 ─────────────────────────────────────
def go_shelf(s):
    s.tap(TAB_SHELF_X, TAB_Y)
    time.sleep(0.8)

def go_store(s):
    s.tap(TAB_STORE_X, TAB_Y)
    time.sleep(1.0)

def go_my(s):
    s.tap(TAB_MY_X, TAB_Y)
    time.sleep(1.0)

def exit_reader(s):
    s.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(1.0)

def go_back(s):
    s.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.8)

def show_menu(s):
    s.tap(W // 2, H // 2)
    time.sleep(1.0)

def enter_reader(s):
    go_shelf(s)
    s.tap(*random.choice(SHELF_BOOKS))
    time.sleep(2.5)

def read_pages(s, count):
    for _ in range(count):
        s.swipe_left()
        time.sleep(random.uniform(3.0, 6.0))
        stats["pages_read"] += 1
        stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# A. 阅读核心 (65%)
# ═══════════════════════════════════════════════════════

def action_read_shelf(s):
    """书架选书读 20-80 页"""
    enter_reader(s)
    read_pages(s, random.randint(20, 80))
    exit_reader(s)

def action_read_long(s):
    """长阅读 100-200 页"""
    enter_reader(s)
    read_pages(s, random.randint(100, 200))
    exit_reader(s)

def action_switch_book(s):
    """换书读"""
    enter_reader(s)
    read_pages(s, random.randint(10, 40))
    exit_reader(s)

def action_chapter_jump(s):
    """跳章 + 继续读"""
    enter_reader(s)
    read_pages(s, random.randint(5, 15))
    show_menu(s)
    btn = "下一章" if random.random() > 0.3 else "上一章"
    safe_tap(s, name=btn, timeout=2)
    stats["chapters_jumped"] += 1
    time.sleep(2)
    read_pages(s, random.randint(10, 30))
    show_menu(s)
    safe_tap(s, name="下一章", timeout=2)
    stats["chapters_jumped"] += 1
    time.sleep(2)
    read_pages(s, random.randint(5, 20))
    exit_reader(s)

def action_toc_jump(s):
    """目录跳转"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    show_menu(s)
    if safe_tap(s, name="目录", timeout=2):
        time.sleep(2)
        for _ in range(random.randint(2, 10)):
            s.swipe_up()
            time.sleep(0.5)
        s.tap(W // 2, random.randint(200, 500))
        time.sleep(3)
        stats["chapters_jumped"] += 1
        read_pages(s, random.randint(15, 40))
    exit_reader(s)

def action_auto_read(s):
    """自动翻页"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        safe_tap(s, name="play.circle", timeout=2)
        time.sleep(1)
    duration = random.uniform(30, 90)
    time.sleep(duration)
    stats["pages_read"] += int(duration / 5)
    s.tap(W // 2, H // 2)
    time.sleep(1)
    exit_reader(s)

def action_auto_read_settings(s):
    """自动翻页设置"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        safe_tap(s, name="speedometer", timeout=2)
        time.sleep(2)
        go_back(s)
    read_pages(s, random.randint(5, 15))
    exit_reader(s)


# ═══════════════════════════════════════════════════════
# B. 书源/网络 (15%)
# ═══════════════════════════════════════════════════════

def action_search_add(s):
    """搜书 → 加书架 → 读"""
    go_shelf(s)
    if not safe_tap(s, name="magnifyingglass", timeout=3):
        return
    time.sleep(1.5)
    kw = random.choice(["修仙", "都市", "玄幻", "穿越", "系统", "重生",
                         "武侠", "科幻", "末日", "仙侠", "悬疑", "言情",
                         "推理", "历史", "军事", "异界", "洪荒", "无限流"])
    tf = s(type="TextField")
    if not tf.exists:
        go_back(s)
        return
    tf.set_text(kw)
    time.sleep(0.5)
    safe_tap(s, name="Search", type="Button", timeout=3)
    stats["books_searched"] += 1
    time.sleep(random.uniform(6, 12))
    s.tap(W // 2, 200)
    time.sleep(3)
    if safe_tap(s, name="加书架", timeout=2):
        stats["books_added"] += 1
        time.sleep(0.5)
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(10, 30))
        exit_reader(s)
    go_back(s)
    go_back(s)

def action_change_source(s):
    """换源"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        if safe_tap(s, name="arrow.triangle.2.circlepath", timeout=2):
            time.sleep(4)
            s.tap(W // 2, 300)
            time.sleep(3)
            stats["sources_changed"] += 1
            read_pages(s, random.randint(5, 15))
        else:
            time.sleep(0.5)
    exit_reader(s)

def action_change_chapter_source(s):
    """本章换源"""
    enter_reader(s)
    read_pages(s, random.randint(3, 5))
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        if safe_tap(s, name="doc.text.magnifyingglass", timeout=2):
            time.sleep(4)
            s.tap(W // 2, 300)
            time.sleep(3)
            stats["sources_changed"] += 1
            read_pages(s, random.randint(3, 10))
        else:
            time.sleep(0.5)
    exit_reader(s)

def action_reload_chapter(s):
    """重新加载章节"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        safe_tap(s, name="arrow.clockwise", timeout=2)
        time.sleep(3)
    read_pages(s, random.randint(5, 15))
    exit_reader(s)

def action_purify_chapter(s):
    """净化此章"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        if safe_tap(s, name="sparkles", timeout=2):
            time.sleep(2)
            safe_tap(s, labelContains="应用替换规则", timeout=2) or safe_tap(s, labelContains="取消", timeout=2)
            time.sleep(2)
    read_pages(s, random.randint(5, 10))
    exit_reader(s)

def action_download(s):
    """下载本书"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        if safe_tap(s, name="arrow.down.circle", timeout=2):
            time.sleep(2)
            safe_tap(s, labelContains="确", timeout=2)
            stats["downloads"] += 1
            time.sleep(5)
    exit_reader(s)


# ═══════════════════════════════════════════════════════
# C. 书城 (8%)
# ═══════════════════════════════════════════════════════

def action_browse_read(s):
    """书城浏览 → 读"""
    go_store(s)
    for _ in range(random.randint(1, 4)):
        s.swipe_up()
        time.sleep(0.8)
    s.tap(random.randint(30, 340), random.randint(400, 560))
    time.sleep(3)
    if random.random() > 0.4:
        if safe_tap(s, name="加书架", timeout=2):
            stats["books_added"] += 1
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(15, 50))
        exit_reader(s)
    go_back(s)

def action_store_channel(s):
    """书城频道切换 (男生/女生/出版)"""
    go_store(s)
    channels = ["bookstore.channel.male", "bookstore.channel.female", "bookstore.channel.publish"]
    ch = random.choice(channels)
    safe_tap(s, name=ch, timeout=2)
    time.sleep(2)
    for _ in range(random.randint(2, 5)):
        s.swipe_up()
        time.sleep(0.8)
    s.tap(random.randint(30, 340), random.randint(400, 560))
    time.sleep(3)
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(10, 30))
        exit_reader(s)
    go_back(s)

def action_store_search(s):
    """书城内搜索"""
    go_store(s)
    if safe_tap(s, name="bookstore.search", timeout=2):
        time.sleep(1.5)
        tf = s(type="TextField")
        if tf.exists:
            tf.set_text(random.choice(["仙", "龙", "魔", "神", "剑"]))
            time.sleep(0.5)
            safe_tap(s, name="Search", type="Button", timeout=3)
            stats["books_searched"] += 1
            time.sleep(random.uniform(5, 10))
            s.tap(W // 2, 200)
            time.sleep(3)
            if safe_tap(s, name="开始阅读", timeout=2):
                time.sleep(3)
                read_pages(s, random.randint(5, 20))
                exit_reader(s)
            go_back(s)
        go_back(s)

def action_rankings(s):
    """排行榜"""
    go_store(s)
    safe_tap(s, labelContains="热门排行", timeout=2) or s.tap(130, 310)
    time.sleep(2)
    for _ in range(random.randint(3, 8)):
        s.swipe_up()
        time.sleep(0.8)
    s.tap(W // 2, random.randint(200, 500))
    time.sleep(3)
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(5, 20))
        exit_reader(s)
    go_back(s)
    go_back(s)


# ═══════════════════════════════════════════════════════
# D. 设置/UI (7%)
# ═══════════════════════════════════════════════════════

def action_theme_font(s):
    """主题/字号切换"""
    enter_reader(s)
    read_pages(s, random.randint(5, 15))
    show_menu(s)
    if safe_tap(s, name="设置", timeout=2):
        time.sleep(1)
        themes = ["阅、默认", "阅、护眼", "阅、夜间", "阅、羊皮纸"]
        safe_tap(s, name=random.choice(themes), timeout=2)
        time.sleep(0.8)
        for _ in range(random.randint(1, 3)):
            if random.random() > 0.5:
                safe_tap(s, name="A+", timeout=1)
            else:
                safe_tap(s, name="A-", timeout=1)
            time.sleep(0.5)
        safe_tap(s, name="完成", timeout=2)
        time.sleep(0.8)
    read_pages(s, random.randint(10, 30))
    exit_reader(s)

def action_eye_care(s):
    """护眼模式开关"""
    go_my(s)
    safe_tap(s, labelContains="护眼模式", timeout=2)
    time.sleep(2)
    safe_tap(s, labelContains="护眼模式", timeout=2)
    time.sleep(1)
    stats["actions"] += 1

def action_tts(s):
    """TTS 语音朗读"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="speaker.wave.2.fill", timeout=2):
        time.sleep(2)
        dur = random.uniform(30, 60)
        time.sleep(dur)
        stats["tts_sessions"] += 1
        stats["pages_read"] += int(dur / 8)
        s.tap(W // 2, H // 2)
        time.sleep(1)
    exit_reader(s)

def action_disguise(s):
    """应用伪装"""
    go_my(s)
    safe_tap(s, labelContains="应用伪装", timeout=2)
    time.sleep(3)
    go_back(s)
    time.sleep(1)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# E. 其他 (5%)
# ═══════════════════════════════════════════════════════

def action_background(s):
    """后台切回"""
    dur = random.uniform(5, 30)
    try:
        s.deactivate(dur)
    except Exception:
        time.sleep(dur)
    time.sleep(1)
    stats["actions"] += 1

def action_bookmark(s):
    """书签 (阅读器更多菜单)"""
    enter_reader(s)
    read_pages(s, random.randint(5, 15))
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.8)
        if safe_tap(s, labelContains="书签", timeout=2):
            stats["bookmarks"] += 1
            time.sleep(1)
    s.tap(W // 2, H // 2)
    time.sleep(0.5)
    read_pages(s, random.randint(5, 10))
    exit_reader(s)

def action_search_content(s):
    """书内全文搜索"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    show_menu(s)
    if safe_tap(s, name="magnifyingglass", timeout=2):
        time.sleep(1)
        tf = s(type="TextField")
        if tf.exists:
            tf.set_text(random.choice(["她", "他", "说", "了", "的", "人"]))
            time.sleep(0.5)
            safe_tap(s, name="Search", type="Button", timeout=2)
            time.sleep(3)
            s.tap(W // 2, 300)
            time.sleep(2)
            read_pages(s, random.randint(5, 15))
    exit_reader(s)

def action_shelf_manage(s):
    """书架管理"""
    go_shelf(s)
    safe_tap(s, name="更多", type="Button", timeout=2)
    time.sleep(1)
    choice = random.choice(["更新目录", "书架布局", "分组管理"])
    if choice == "更新目录":
        safe_tap(s, labelContains="更新目录", timeout=2)
        time.sleep(5)
    elif choice == "书架布局":
        safe_tap(s, labelContains="书架布局", timeout=2)
        time.sleep(2)
        go_back(s)
    else:
        safe_tap(s, labelContains="分组管理", timeout=2)
        time.sleep(2)
        go_back(s)
    stats["actions"] += 1

def action_reading_record(s):
    """阅读记录"""
    go_my(s)
    safe_tap(s, name="my.row.read_record", timeout=2)
    time.sleep(2)
    for _ in range(random.randint(1, 3)):
        s.swipe_up()
        time.sleep(0.8)
    go_back(s)
    stats["actions"] += 1

def action_download_manage(s):
    """下载管理"""
    go_my(s)
    safe_tap(s, name="my.row.download_manage", timeout=2)
    time.sleep(2)
    for _ in range(random.randint(1, 2)):
        s.swipe_up()
        time.sleep(0.8)
    go_back(s)
    stats["actions"] += 1

def action_feedback(s):
    """意见反馈 (只进入不提交)"""
    go_my(s)
    safe_tap(s, name="my.row.feedback", timeout=2)
    time.sleep(2)
    go_back(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════

def report():
    elapsed = time.time() - start_time
    h = int(elapsed // 3600)
    m = int((elapsed % 3600) // 60)
    rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
    print(f"\n╔══════════════════════════════════════════════╗")
    print(f"║  {h}h{m:02d}m  页:{stats['pages_read']}({rate:.1f}/m)")
    print(f"║  搜:{stats['books_searched']} 架:{stats['books_added']} "
          f"跳:{stats['chapters_jumped']} 源:{stats['sources_changed']}")
    print(f"║  TTS:{stats['tts_sessions']} 下:{stats['downloads']} "
          f"签:{stats['bookmarks']}")
    print(f"║  崩:{stats['crashes']} WDA:{stats['wda_failures']} "
          f"错:{stats['errors']}")
    print(f"╚══════════════════════════════════════════════╝")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser()
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200)
    args = parser.parse_args()

    print("╔══════════════════════════════════════════════╗")
    print("║  万象书屋 — 全功能用户模拟 v5 (10倍速)     ║")
    print("╚══════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}  时长: {args.duration//3600}h")
    print(f"覆盖: 28场景  阅读: 3-6s/页")

    client = wda.Client(args.wda_url)
    try:
        st = client.status()
        print(f"设备: iOS {st.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    time.sleep(3)
    print("App 启动，开始模拟...\n")
    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-sim-v5-full")

    # 28 个场景, 总权重 100
    pool_def = [
        # A. 阅读 (65%)
        (action_read_shelf, "read_shelf", 20),
        (action_read_long, "read_long", 12),
        (action_switch_book, "switch_book", 7),
        (action_chapter_jump, "chapter_jump", 10),
        (action_toc_jump, "toc_jump", 6),
        (action_auto_read, "auto_read", 5),
        (action_auto_read_settings, "auto_settings", 2),
        (action_tts, "tts", 3),
        # B. 书源/网络 (15%)
        (action_search_add, "search_add", 4),
        (action_change_source, "change_source", 3),
        (action_change_chapter_source, "ch_source", 2),
        (action_reload_chapter, "reload", 2),
        (action_purify_chapter, "purify", 2),
        (action_download, "download", 2),
        # C. 书城 (8%)
        (action_browse_read, "browse_read", 2),
        (action_store_channel, "store_channel", 2),
        (action_store_search, "store_search", 2),
        (action_rankings, "rankings", 2),
        # D. 设置 (7%)
        (action_theme_font, "theme_font", 2),
        (action_eye_care, "eye_care", 1),
        (action_disguise, "disguise", 1),
        (action_tts, "tts2", 1),
        (action_feedback, "feedback", 1),
        (action_download_manage, "dl_manage", 1),
        # E. 其他 (5%)
        (action_background, "background", 2),
        (action_bookmark, "bookmark", 1),
        (action_search_content, "search_content", 1),
        (action_shelf_manage, "shelf_manage", 1),
        (action_reading_record, "read_record", 1),
    ]
    pool = []
    for fn, name, w in pool_def:
        pool.extend([(fn, name)] * w)

    last_report = start_time

    while time.time() - start_time < args.duration:
        try:
            fn, name = random.choice(pool)
            last_action = current_action
            current_action = name
            fn(session)
            stats["cycles"] += 1
            session = ensure_alive(client, session)
        except Exception as e:
            stats["errors"] += 1
            log_event("action_error", error=str(e)[:200])
            session = ensure_alive(client, session)

        if time.time() - last_report >= 600:
            elapsed = time.time() - start_time
            h = int(elapsed // 3600)
            m = int((elapsed % 3600) // 60)
            rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
            print(f"  [{h:02d}h{m:02d}m] 页:{stats['pages_read']}({rate:.1f}/m) "
                  f"跳:{stats['chapters_jumped']} 源:{stats['sources_changed']} "
                  f"TTS:{stats['tts_sessions']} 崩:{stats['crashes']}")
            log_event("periodic_report", stats=dict(stats))
            last_report = time.time()

    report()
    log_event("test_finished", stats=dict(stats))
    sys.exit(1 if stats["crashes"] > 0 else 0)


if __name__ == "__main__":
    main()
