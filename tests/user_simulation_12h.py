#!/usr/bin/env python3
"""
万象书屋 — 全功能真实用户模拟 (10倍速)
覆盖所有功能模块: 阅读 / 跳章 / 换源 / TTS / 下载 / 书签 / 主题 / 书城 / 搜索 等

设备: iPhone SE (375x667)
优化: 坐标点击为主, safe_tap 兜底
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

# iPhone SE 屏幕 375x667
W, H = 375, 667
# 书架 3 列书中心坐标
SHELF_BOOKS = [(66, 234), (187, 234), (308, 234)]
# Tab bar y=635
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
        "type": event_type,
        "action": current_action,
        "last_action": last_action,
        **data,
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


# ─── 导航辅助 ───────────────────────────────────────
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

def show_reader_menu(s):
    s.tap(W // 2, H // 2)
    time.sleep(1.0)

def enter_book_from_shelf(s):
    go_shelf(s)
    pos = random.choice(SHELF_BOOKS)
    s.tap(*pos)
    time.sleep(2.5)

def read_pages(s, count):
    for _ in range(count):
        s.swipe_left()
        time.sleep(random.uniform(3.0, 6.0))
        stats["pages_read"] += 1
        stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 阅读类场景 (70%)
# ═══════════════════════════════════════════════════════

def action_read_shelf(s):
    """书架选书阅读 20-80 页"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(20, 80))
    exit_reader(s)


def action_read_long(s):
    """长阅读 100-200 页"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(100, 200))
    exit_reader(s)


def action_switch_book(s):
    """换一本书读"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(10, 40))
    exit_reader(s)


def action_chapter_jump(s):
    """跳章: 上/下一章 + 继续读"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(5, 15))
    show_reader_menu(s)
    if random.random() > 0.5:
        safe_tap(s, name="下一章", timeout=2)
    else:
        safe_tap(s, name="上一章", timeout=2)
    stats["chapters_jumped"] += 1
    time.sleep(2)
    read_pages(s, random.randint(10, 30))
    # 再跳一次
    show_reader_menu(s)
    safe_tap(s, name="下一章", timeout=2)
    stats["chapters_jumped"] += 1
    time.sleep(2)
    read_pages(s, random.randint(5, 20))
    exit_reader(s)


def action_toc_jump(s):
    """目录跳转: 打开目录 → 选章 → 读"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(3, 8))
    show_reader_menu(s)
    if safe_tap(s, name="目录", timeout=2):
        time.sleep(2)
        # 滑动目录列表
        for _ in range(random.randint(2, 8)):
            s.swipe_up()
            time.sleep(0.5)
        # 点击一个章节 (目录区域 y=200-500)
        s.tap(W // 2, random.randint(200, 500))
        time.sleep(3)
        stats["chapters_jumped"] += 1
        read_pages(s, random.randint(15, 40))
    exit_reader(s)


def action_auto_read(s):
    """自动翻页模式 — 开启后等待一段时间"""
    enter_book_from_shelf(s)
    show_reader_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(1)
        # 自动翻页通常在更多菜单里
        safe_tap(s, labelContains="自动", timeout=2)
        time.sleep(1)
    # 让自动翻页跑 30-90 秒
    duration = random.uniform(30, 90)
    time.sleep(duration)
    stats["pages_read"] += int(duration / 5)
    # 点击停止
    s.tap(W // 2, H // 2)
    time.sleep(1)
    exit_reader(s)


# ═══════════════════════════════════════════════════════
# 书源/网络类 (15%)
# ═══════════════════════════════════════════════════════

def action_search_add(s):
    """搜索 → 加书架 → 阅读"""
    go_shelf(s)
    if not safe_tap(s, name="magnifyingglass", timeout=3):
        return
    time.sleep(1.5)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻",
                "末日", "仙侠", "悬疑", "言情", "推理", "历史", "军事", "异界"]
    tf = s(type="TextField")
    if not tf.exists:
        go_back(s)
        return
    tf.set_text(random.choice(keywords))
    time.sleep(0.5)
    safe_tap(s, name="Search", type="Button", timeout=3)
    stats["books_searched"] += 1
    time.sleep(random.uniform(6, 12))
    # 点搜索结果
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
    """在阅读器中换源"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(3, 8))
    show_reader_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(1)
        # 找换源选项
        if safe_tap(s, labelContains="换源", timeout=2):
            time.sleep(3)
            # 选第一个源 (坐标点击源列表区域)
            s.tap(W // 2, 300)
            time.sleep(3)
            stats["sources_changed"] += 1
            read_pages(s, random.randint(5, 15))
    exit_reader(s)


def action_download(s):
    """下载章节"""
    go_store(s)
    # 点击一本书
    s.tap(W // 2, 430)
    time.sleep(3)
    # 尝试下载
    if safe_tap(s, labelContains="下载", timeout=2):
        time.sleep(2)
        # 如果弹出下载范围选择，直接确认
        safe_tap(s, labelContains="全部", timeout=2) or safe_tap(s, labelContains="确认", timeout=2)
        stats["downloads"] += 1
        time.sleep(5)
    go_back(s)


# ═══════════════════════════════════════════════════════
# 书城 (5%)
# ═══════════════════════════════════════════════════════

def action_browse_read(s):
    """书城浏览 → 读书"""
    go_store(s)
    for _ in range(random.randint(1, 4)):
        s.swipe_up()
        time.sleep(0.8)
    y = random.randint(400, 560)
    x = random.randint(30, 340)
    s.tap(x, y)
    time.sleep(3)
    if random.random() > 0.4:
        if safe_tap(s, name="加书架", timeout=2):
            stats["books_added"] += 1
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(15, 50))
        exit_reader(s)
    go_back(s)


def action_rankings(s):
    """排行榜浏览"""
    go_store(s)
    # 点热门排行 (y≈265)
    safe_tap(s, labelContains="热门排行", timeout=2) or s.tap(130, 310)
    time.sleep(2)
    # 浏览排行
    for _ in range(random.randint(3, 8)):
        s.swipe_up()
        time.sleep(1)
    # 随机点一本
    s.tap(W // 2, random.randint(200, 500))
    time.sleep(3)
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(3)
        read_pages(s, random.randint(5, 20))
        exit_reader(s)
    go_back(s)
    go_back(s)


# ═══════════════════════════════════════════════════════
# 设置/UI 类 (5%)
# ═══════════════════════════════════════════════════════

def action_theme_font(s):
    """阅读中切换主题/字号"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(5, 15))
    show_reader_menu(s)
    if safe_tap(s, name="设置", timeout=2):
        time.sleep(1)
        # 切主题
        themes = ["阅、默认", "阅、护眼", "阅、夜间", "阅、羊皮纸"]
        safe_tap(s, name=random.choice(themes), timeout=2)
        time.sleep(1)
        # 调字号
        if random.random() > 0.5:
            safe_tap(s, name="A+", timeout=1)
        else:
            safe_tap(s, name="A-", timeout=1)
        time.sleep(0.5)
        # 完成
        safe_tap(s, name="完成", timeout=2)
        time.sleep(1)
    read_pages(s, random.randint(10, 30))
    exit_reader(s)


def action_eye_care(s):
    """护眼模式开关"""
    go_my(s)
    # 护眼模式 switch
    safe_tap(s, labelContains="护眼模式", timeout=2)
    time.sleep(2)
    # 切回去
    safe_tap(s, labelContains="护眼模式", timeout=2)
    time.sleep(1)
    stats["actions"] += 1


def action_tts(s):
    """TTS 语音朗读"""
    enter_book_from_shelf(s)
    show_reader_menu(s)
    # 点 speaker 按钮
    if safe_tap(s, name="speaker.wave.2.fill", timeout=2):
        time.sleep(2)
        # 让 TTS 读 30-60 秒
        tts_duration = random.uniform(30, 60)
        time.sleep(tts_duration)
        stats["tts_sessions"] += 1
        stats["pages_read"] += int(tts_duration / 8)
        # 停止 TTS (点击屏幕)
        s.tap(W // 2, H // 2)
        time.sleep(1)
    exit_reader(s)


# ═══════════════════════════════════════════════════════
# 其他 (5%)
# ═══════════════════════════════════════════════════════

def action_background(s):
    """后台/锁屏再回来"""
    duration = random.uniform(5, 30)
    try:
        s.deactivate(duration)
    except Exception:
        time.sleep(duration)
    time.sleep(1)
    stats["actions"] += 1


def action_bookmark(s):
    """添加书签"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(5, 15))
    show_reader_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(1)
        if safe_tap(s, labelContains="书签", timeout=2):
            stats["bookmarks"] += 1
            time.sleep(1)
    # 继续读
    s.tap(W // 2, H // 2)
    time.sleep(0.5)
    read_pages(s, random.randint(5, 10))
    exit_reader(s)


def action_search_content(s):
    """书内全文搜索"""
    enter_book_from_shelf(s)
    read_pages(s, random.randint(3, 8))
    show_reader_menu(s)
    if safe_tap(s, name="magnifyingglass", timeout=2):
        time.sleep(1)
        tf = s(type="TextField")
        if tf.exists:
            tf.set_text(random.choice(["的", "他", "了", "是", "在"]))
            time.sleep(0.5)
            safe_tap(s, name="Search", type="Button", timeout=2)
            time.sleep(3)
            # 点击一个搜索结果
            s.tap(W // 2, 300)
            time.sleep(2)
            read_pages(s, random.randint(5, 15))
    exit_reader(s)


def action_shelf_manage(s):
    """书架管理 (更新目录/布局)"""
    go_shelf(s)
    # 点更多
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
    """查看阅读记录"""
    go_my(s)
    safe_tap(s, name="my.row.read_record", timeout=2)
    time.sleep(2)
    # 浏览记录
    for _ in range(random.randint(1, 3)):
        s.swipe_up()
        time.sleep(0.8)
    go_back(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════

def report():
    elapsed = time.time() - start_time
    hours = int(elapsed // 3600)
    minutes = int((elapsed % 3600) // 60)
    rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
    print(f"\n╔══════════════════════════════════════════════╗")
    print(f"║  测试: {hours}h{minutes:02d}m  页:{stats['pages_read']}({rate:.1f}/m)")
    print(f"║  搜:{stats['books_searched']} 架:{stats['books_added']} "
          f"跳章:{stats['chapters_jumped']} 换源:{stats['sources_changed']}")
    print(f"║  TTS:{stats['tts_sessions']} 下载:{stats['downloads']} "
          f"书签:{stats['bookmarks']}")
    print(f"║  崩溃:{stats['crashes']} WDA断:{stats['wda_failures']} "
          f"错误:{stats['errors']}")
    print(f"╚══════════════════════════════════════════════╝")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser()
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200)
    args = parser.parse_args()

    print("╔══════════════════════════════════════════════╗")
    print("║  万象书屋 — 全功能用户模拟 (10倍速)        ║")
    print("╚══════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}  时长: {args.duration//3600}h")
    print(f"阅读: 3-6s/页  覆盖: 20+场景")

    client = wda.Client(args.wda_url)
    try:
        st = client.status()
        print(f"设备: iOS {st.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    time.sleep(3)
    print("App 已启动，开始模拟...\n")

    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-sim-v4-full")

    # 场景权重分配
    actions = [
        # 阅读 (70%)
        (action_read_shelf, "read_shelf", 22),
        (action_read_long, "read_long", 13),
        (action_switch_book, "switch_book", 8),
        (action_chapter_jump, "chapter_jump", 12),
        (action_toc_jump, "toc_jump", 7),
        (action_auto_read, "auto_read", 5),
        (action_tts, "tts", 3),
        # 书源/网络 (15%)
        (action_search_add, "search_add", 7),
        (action_change_source, "change_source", 4),
        (action_download, "download", 2),
        (action_browse_read, "browse_read", 2),
        # 书城 (5%)
        (action_rankings, "rankings", 3),
        (action_browse_read, "browse_read2", 2),
        # 设置/UI (5%)
        (action_theme_font, "theme_font", 2),
        (action_eye_care, "eye_care", 1),
        # 其他 (5%)
        (action_background, "background", 2),
        (action_bookmark, "bookmark", 1),
        (action_search_content, "search_content", 1),
        (action_shelf_manage, "shelf_manage", 1),
        (action_reading_record, "reading_record", 1),
    ]
    pool = []
    for fn, name, weight in actions:
        pool.extend([(fn, name)] * weight)

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
