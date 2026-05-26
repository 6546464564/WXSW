#!/usr/bin/env python3
"""
万象书屋 — 全功能真实用户模拟 v7 (100倍速)
覆盖所有可交互功能: 50+ 场景 + 深层 UI (7级以下全覆盖) + 广告识别跳过

设备: iPhone SE (375x667)
WDA 元素定位: 坐标 + accessibilityIdentifier/name/label
广告: 开屏等待 + 章节解锁"先跳过" + 激励广告"跳过"
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
        wait_splash(session)
        log_event("app_restarted")
    except Exception:
        pass
    return session


# ─── 基础导航 ─────────────────────────────────────
def go_shelf(s):
    s.tap(TAB_SHELF_X, TAB_Y)
    time.sleep(0.3)

def go_store(s):
    s.tap(TAB_STORE_X, TAB_Y)
    time.sleep(0.5)

def go_my(s):
    s.tap(TAB_MY_X, TAB_Y)
    time.sleep(0.5)

def exit_reader(s):
    s.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.5)

def go_back(s):
    s.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.3)

def show_menu(s):
    s.tap(W // 2, H // 2)
    time.sleep(0.5)

def handle_ad(s):
    """检测并处理广告/解锁弹窗 — 优先跳过"""
    # 章节解锁 overlay: "先跳过"
    if safe_tap(s, labelContains="先跳过", timeout=1):
        time.sleep(0.5)
        return "chapter_skip"
    # 激励广告 alert: "跳过"
    if safe_tap(s, name="跳过", timeout=1):
        time.sleep(0.5)
        return "reward_skip"
    # 读完页
    if safe_tap(s, labelContains="去书架", timeout=1):
        time.sleep(0.5)
        return "book_finished"
    return None

def wait_splash(s):
    """等待开屏广告自动消失 (最多6秒)"""
    time.sleep(6)

def enter_reader(s):
    go_shelf(s)
    s.tap(*random.choice(SHELF_BOOKS))
    time.sleep(1.5)
    handle_ad(s)

def read_pages(s, count):
    for i in range(count):
        s.swipe_left()
        time.sleep(random.uniform(0.3, 0.6))
        stats["pages_read"] += 1
        stats["actions"] += 1
        if (i + 1) % 10 == 0:
            handle_ad(s)


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
        time.sleep(0.5)
        safe_tap(s, name="play.circle", timeout=2)
        time.sleep(0.5)
    duration = random.uniform(10, 30)
    time.sleep(duration)
    stats["pages_read"] += int(duration / 3)
    s.tap(W // 2, H // 2)
    time.sleep(0.5)
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
        time.sleep(1)
        dur = random.uniform(10, 30)
        time.sleep(dur)
        stats["tts_sessions"] += 1
        stats["pages_read"] += int(dur / 4)
        s.tap(W // 2, H // 2)
        time.sleep(0.5)
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
    dur = random.uniform(2, 10)
    try:
        s.deactivate(dur)
    except Exception:
        time.sleep(dur)
    time.sleep(0.5)
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
# F. 书架深层交互 (长按/管理/分组/下拉刷新)
# ═══════════════════════════════════════════════════════

def action_shelf_pull_refresh(s):
    """书架下拉刷新"""
    go_shelf(s)
    s.swipe(W // 2, 300, W // 2, 550, duration=0.3)
    time.sleep(3)
    stats["actions"] += 1

def action_shelf_longpress(s):
    """书架长按菜单 (置顶/下载/移分组/删除)"""
    go_shelf(s)
    pos = random.choice(SHELF_BOOKS)
    try:
        s.tap_hold(pos[0], pos[1], duration=1.5)
    except Exception:
        s.tap(pos[0], pos[1])
        time.sleep(1.5)
    time.sleep(1)
    choice = random.choice(["置顶", "下载到本地", "移到分组", "从书架删除"])
    if choice == "从书架删除":
        if safe_tap(s, labelContains="从书架删除", timeout=2):
            time.sleep(0.5)
            safe_tap(s, labelContains="删除", timeout=2) or safe_tap(s, labelContains="取消", timeout=2)
    elif choice == "移到分组":
        if safe_tap(s, labelContains="移到分组", timeout=2):
            time.sleep(1)
            safe_tap(s, labelContains="取消", timeout=2) or go_back(s)
    else:
        safe_tap(s, labelContains=choice, timeout=2)
    time.sleep(1)
    stats["actions"] += 1

def action_shelf_group_switch(s):
    """书架分组切换"""
    go_shelf(s)
    time.sleep(0.5)
    chip_y = 120
    positions = [(60, chip_y), (130, chip_y), (200, chip_y), (270, chip_y)]
    for _ in range(random.randint(2, 4)):
        s.tap(*random.choice(positions))
        time.sleep(0.5)
    stats["actions"] += 1

def action_shelf_batch_manage(s):
    """书架管理 (多选/筛选/批量更新)"""
    go_shelf(s)
    if safe_tap(s, name="ellipsis.circle", timeout=2):
        time.sleep(0.5)
        if safe_tap(s, labelContains="书架管理", timeout=2):
            time.sleep(1)
            for _ in range(random.randint(2, 5)):
                s.tap(random.randint(30, 340), random.randint(200, 500))
                time.sleep(0.3)
            if random.random() > 0.5:
                safe_tap(s, labelContains="更新目录", timeout=2)
                time.sleep(3)
            safe_tap(s, labelContains="完成", timeout=2) or go_back(s)
            time.sleep(0.5)
    stats["actions"] += 1

def action_shelf_layout_config(s):
    """书架布局配置 (列数/排序/开关)"""
    go_shelf(s)
    if safe_tap(s, name="ellipsis.circle", timeout=2):
        time.sleep(0.5)
        if safe_tap(s, labelContains="书架布局", timeout=2):
            time.sleep(1)
            for _ in range(random.randint(2, 4)):
                s.tap(random.randint(50, 320), random.randint(200, 500))
                time.sleep(0.3)
            safe_tap(s, labelContains="完成", timeout=2) or safe_tap(s, name="完成", timeout=2)
            time.sleep(0.5)
    stats["actions"] += 1

def action_shelf_group_manage(s):
    """分组管理 (新建/重命名/删除)"""
    go_shelf(s)
    if safe_tap(s, name="ellipsis.circle", timeout=2):
        time.sleep(0.5)
        if safe_tap(s, labelContains="分组管理", timeout=2):
            time.sleep(1)
            if random.random() > 0.6:
                safe_tap(s, labelContains="新建分组", timeout=2)
                time.sleep(1)
                safe_tap(s, labelContains="取消", timeout=2)
            else:
                s.swipe_up()
                time.sleep(0.5)
            go_back(s)
            time.sleep(0.5)
    stats["actions"] += 1

def action_import_local(s):
    """添加本地书籍 (进入file picker界面然后返回)"""
    go_shelf(s)
    if safe_tap(s, name="ellipsis.circle", timeout=2):
        time.sleep(0.5)
        if safe_tap(s, labelContains="添加本地", timeout=2):
            time.sleep(2)
            safe_tap(s, labelContains="取消", timeout=2) or go_back(s)
            time.sleep(0.5)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# G. 书籍详情页深层交互
# ═══════════════════════════════════════════════════════

def enter_book_detail(s):
    """从书城进入书籍详情"""
    go_store(s)
    time.sleep(0.5)
    s.tap(random.randint(30, 340), random.randint(200, 400))
    time.sleep(2)

def action_detail_change_source(s):
    """详情页换源"""
    enter_book_detail(s)
    if safe_tap(s, name="arrow.triangle.2.circlepath", timeout=2):
        time.sleep(3)
        s.tap(W // 2, 300)
        time.sleep(2)
        stats["sources_changed"] += 1
    go_back(s)
    stats["actions"] += 1

def action_detail_toc_sheet(s):
    """详情页目录 sheet"""
    enter_book_detail(s)
    for _ in range(2):
        s.swipe_up()
        time.sleep(0.3)
    if safe_tap(s, labelContains="目录", timeout=2):
        time.sleep(2)
        for _ in range(random.randint(2, 5)):
            s.swipe_up()
            time.sleep(0.5)
        safe_tap(s, labelContains="关闭", timeout=2) or go_back(s)
        time.sleep(0.5)
    go_back(s)
    stats["actions"] += 1

def action_detail_download(s):
    """详情页下载"""
    enter_book_detail(s)
    if safe_tap(s, labelContains="下载本书", timeout=2):
        time.sleep(3)
        if random.random() > 0.5:
            safe_tap(s, name="xmark.circle.fill", timeout=2)
        stats["downloads"] += 1
    go_back(s)
    stats["actions"] += 1

def action_detail_remove_shelf(s):
    """详情页移除书架 (已加书架再点)"""
    enter_book_detail(s)
    if safe_tap(s, labelContains="已加书架", timeout=2):
        time.sleep(1)
    elif safe_tap(s, name="加书架", timeout=2):
        stats["books_added"] += 1
        time.sleep(0.5)
    go_back(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# H. 阅读器深层交互 (翻页方式/字体/slider/选词/TTS面板)
# ═══════════════════════════════════════════════════════

def action_page_turn_style(s):
    """切换翻页方式 (覆盖/滑动/仿真/滚动/无动画)"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    show_menu(s)
    if safe_tap(s, name="设置", timeout=2) or safe_tap(s, name="textformat.size", timeout=2):
        time.sleep(1)
        styles = ["覆盖", "滑动", "仿真", "滚动", "无动画"]
        safe_tap(s, labelContains=random.choice(styles), timeout=2)
        time.sleep(0.5)
        safe_tap(s, labelContains="完成", timeout=2) or safe_tap(s, name="完成", timeout=2)
        time.sleep(0.5)
    read_pages(s, random.randint(10, 20))
    exit_reader(s)

def action_font_picker(s):
    """切换字体"""
    enter_reader(s)
    read_pages(s, random.randint(3, 5))
    show_menu(s)
    if safe_tap(s, name="设置", timeout=2) or safe_tap(s, name="textformat.size", timeout=2):
        time.sleep(1)
        fonts = ["系统默认", "黑体", "宋体", "楷体", "霞鹜文楷"]
        safe_tap(s, labelContains=random.choice(fonts), timeout=2)
        time.sleep(0.5)
        safe_tap(s, labelContains="完成", timeout=2) or safe_tap(s, name="完成", timeout=2)
        time.sleep(0.5)
    read_pages(s, random.randint(5, 15))
    exit_reader(s)

def action_chapter_slider(s):
    """拖动章节进度条跳章"""
    enter_reader(s)
    show_menu(s)
    time.sleep(0.5)
    slider_y = 560
    start_x = random.randint(60, 150)
    end_x = random.randint(200, 320)
    s.swipe(start_x, slider_y, end_x, slider_y, duration=0.3)
    time.sleep(2)
    stats["chapters_jumped"] += 1
    read_pages(s, random.randint(5, 15))
    exit_reader(s)

def action_swipe_up_toc(s):
    """上滑打开目录"""
    enter_reader(s)
    read_pages(s, random.randint(5, 10))
    s.swipe(W // 2, 600, W // 2, 200, duration=0.3)
    time.sleep(1.5)
    for _ in range(random.randint(2, 5)):
        s.swipe_up()
        time.sleep(0.3)
    s.tap(W // 2, random.randint(200, 450))
    time.sleep(2)
    stats["chapters_jumped"] += 1
    read_pages(s, random.randint(5, 15))
    exit_reader(s)

def action_tts_full(s):
    """TTS 完整面板 (暂停/定时/设置)"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="speaker.wave.2.fill", timeout=2):
        time.sleep(2)
        safe_tap(s, name="pause.fill", timeout=2) or safe_tap(s, name="pause", timeout=2)
        time.sleep(1)
        safe_tap(s, name="play.fill", timeout=2) or safe_tap(s, name="play", timeout=2)
        time.sleep(1)
        if safe_tap(s, name="timer", timeout=2) or safe_tap(s, labelContains="定时", timeout=2):
            time.sleep(1)
            safe_tap(s, labelContains="30分钟", timeout=1) or safe_tap(s, labelContains="取消", timeout=1)
            time.sleep(0.5)
        if safe_tap(s, name="gearshape", timeout=2) or safe_tap(s, labelContains="设置", timeout=2):
            time.sleep(1)
            s.tap(W // 2, 300)
            time.sleep(0.5)
            go_back(s)
        safe_tap(s, name="forward.end.fill", timeout=2)
        time.sleep(2)
        stats["tts_sessions"] += 1
        s.tap(W // 2, H // 2)
        time.sleep(0.5)
    exit_reader(s)

def action_text_selection(s):
    """选词菜单 (词典/书签/搜索/分享)"""
    enter_reader(s)
    read_pages(s, random.randint(3, 8))
    try:
        s.tap_hold(W // 2, H // 2, duration=2.0)
    except Exception:
        s.tap(W // 2, H // 2)
        time.sleep(2)
    time.sleep(1)
    actions = ["书签", "词典", "正文搜索", "分享", "复制"]
    chosen = random.choice(actions)
    if safe_tap(s, labelContains=chosen, timeout=2):
        time.sleep(2)
        if chosen == "词典":
            time.sleep(2)
            safe_tap(s, labelContains="关闭", timeout=2) or go_back(s)
        elif chosen == "正文搜索":
            time.sleep(2)
            go_back(s)
        elif chosen == "分享":
            time.sleep(2)
            safe_tap(s, labelContains="取消", timeout=2) or go_back(s)
        elif chosen == "书签":
            stats["bookmarks"] += 1
    time.sleep(0.5)
    exit_reader(s)

def action_book_finished_page(s):
    """读完页 (去书架/去书城/换源)"""
    enter_reader(s)
    read_pages(s, random.randint(50, 100))
    if safe_tap(s, labelContains="去书城", timeout=1):
        time.sleep(1)
        go_back(s)
    elif safe_tap(s, labelContains="看看其它源", timeout=1):
        time.sleep(2)
        go_back(s)
    elif safe_tap(s, labelContains="去书架", timeout=1):
        time.sleep(0.5)
    else:
        exit_reader(s)
    stats["actions"] += 1

def action_reader_error_retry(s):
    """阅读器错误态 (重试/换源)"""
    enter_reader(s)
    read_pages(s, random.randint(10, 30))
    if safe_tap(s, labelContains="重试", timeout=1):
        time.sleep(3)
    elif safe_tap(s, labelContains="换源", timeout=1):
        time.sleep(3)
        stats["sources_changed"] += 1
    read_pages(s, random.randint(5, 10))
    exit_reader(s)

def action_toc_search(s):
    """目录内搜索章节名"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="目录", timeout=2) or safe_tap(s, name="list.bullet", timeout=2):
        time.sleep(1.5)
        tf = s(type="TextField")
        if tf.exists:
            tf.set_text(random.choice(["第", "章", "卷"]))
            time.sleep(1)
            s.tap(W // 2, random.randint(200, 400))
            time.sleep(2)
            stats["chapters_jumped"] += 1
            read_pages(s, random.randint(5, 15))
        else:
            go_back(s)
    exit_reader(s)

def action_auto_read_stop(s):
    """自动翻页启动后停止"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.5)
        safe_tap(s, name="play.circle", timeout=2)
        time.sleep(0.5)
    time.sleep(random.uniform(5, 10))
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.5)
        safe_tap(s, name="stop.circle", timeout=2)
        time.sleep(0.5)
    exit_reader(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# I. 搜索深层 (精准/过滤/历史)
# ═══════════════════════════════════════════════════════

def action_search_precision(s):
    """精准搜索模式"""
    go_shelf(s)
    if not safe_tap(s, name="magnifyingglass", timeout=3):
        return
    time.sleep(1)
    if safe_tap(s, labelContains="搜索选项", timeout=2):
        time.sleep(0.5)
        safe_tap(s, labelContains="精准搜索", timeout=2)
        time.sleep(0.5)
    tf = s(type="TextField")
    if tf.exists:
        tf.set_text(random.choice(["斗破苍穹", "完美世界", "遮天", "凡人修仙传"]))
        time.sleep(0.5)
        safe_tap(s, name="Search", type="Button", timeout=3)
        stats["books_searched"] += 1
        time.sleep(random.uniform(5, 10))
    go_back(s)
    stats["actions"] += 1

def action_search_filters(s):
    """搜索结果过滤 (多源/百万字+/近期更新)"""
    go_shelf(s)
    if not safe_tap(s, name="magnifyingglass", timeout=3):
        return
    time.sleep(1)
    tf = s(type="TextField")
    if tf.exists:
        tf.set_text(random.choice(["修仙", "都市", "玄幻"]))
        time.sleep(0.5)
        safe_tap(s, name="Search", type="Button", timeout=3)
        stats["books_searched"] += 1
        time.sleep(random.uniform(5, 10))
        filters = ["全部", "多源", "百万字+", "近期更新"]
        for f in random.sample(filters, 2):
            safe_tap(s, labelContains=f, timeout=1)
            time.sleep(1)
        s.tap(W // 2, 250)
        time.sleep(2)
        if safe_tap(s, name="开始阅读", timeout=2):
            time.sleep(2)
            read_pages(s, random.randint(5, 15))
            exit_reader(s)
        go_back(s)
    go_back(s)
    stats["actions"] += 1

def action_search_history(s):
    """搜索历史 (点历史词/清除)"""
    go_shelf(s)
    if not safe_tap(s, name="magnifyingglass", timeout=3):
        return
    time.sleep(1)
    s.tap(W // 2, 200)
    time.sleep(1)
    stats["books_searched"] += 1
    time.sleep(3)
    go_back(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# J. 书城深层 (换一批/完本/下拉刷新)
# ═══════════════════════════════════════════════════════

def action_store_refresh(s):
    """书城下拉刷新"""
    go_store(s)
    s.swipe(W // 2, 200, W // 2, 500, duration=0.3)
    time.sleep(3)
    stats["actions"] += 1

def action_store_shuffle(s):
    """书城换一批"""
    go_store(s)
    for _ in range(random.randint(2, 4)):
        s.swipe_up()
        time.sleep(0.5)
    if safe_tap(s, labelContains="换一批", timeout=2):
        time.sleep(2)
    s.tap(random.randint(30, 340), random.randint(300, 500))
    time.sleep(2)
    if safe_tap(s, name="开始阅读", timeout=2):
        time.sleep(2)
        read_pages(s, random.randint(5, 15))
        exit_reader(s)
    go_back(s)
    stats["actions"] += 1

def action_store_complete_lib(s):
    """完本书库/出版书库"""
    go_store(s)
    for _ in range(random.randint(3, 6)):
        s.swipe_up()
        time.sleep(0.5)
    target = random.choice(["完本书库", "出版书库", "完本精选"])
    if safe_tap(s, labelContains=target, timeout=2):
        time.sleep(2)
        for _ in range(random.randint(2, 5)):
            s.swipe_up()
            time.sleep(0.5)
        s.tap(W // 2, random.randint(200, 400))
        time.sleep(2)
        if safe_tap(s, name="开始阅读", timeout=2):
            time.sleep(2)
            read_pages(s, random.randint(5, 15))
            exit_reader(s)
        go_back(s)
    go_back(s)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# K. 我的/设置深层 (主题跟随/纯净延长/公告/版本)
# ═══════════════════════════════════════════════════════

def action_follow_system_theme(s):
    """跟随系统主题 Toggle"""
    go_my(s)
    safe_tap(s, labelContains="跟随系统", timeout=2)
    time.sleep(1)
    safe_tap(s, labelContains="跟随系统", timeout=2)
    time.sleep(0.5)
    stats["actions"] += 1

def action_purified_extend(s):
    """纯净阅读延长卡"""
    go_my(s)
    safe_tap(s, labelContains="延长", timeout=2)
    time.sleep(3)
    safe_tap(s, labelContains="跳过", timeout=2) or safe_tap(s, labelContains="关闭", timeout=2)
    time.sleep(1)
    stats["actions"] += 1

def action_dismiss_announcement(s):
    """公告/版本弹窗(如果出现就关闭)"""
    safe_tap(s, labelContains="知道了", timeout=1)
    safe_tap(s, labelContains="暂不更新", timeout=1) or safe_tap(s, labelContains="取消", timeout=1)
    stats["actions"] += 1

def action_download_center_ops(s):
    """下载管理 (取消/重试操作)"""
    go_my(s)
    if safe_tap(s, name="my.row.download_manage", timeout=2):
        time.sleep(1.5)
        if random.random() > 0.5:
            safe_tap(s, labelContains="重试", timeout=2)
            time.sleep(2)
        else:
            safe_tap(s, name="xmark.circle.fill", timeout=2)
            time.sleep(1)
        go_back(s)
    stats["actions"] += 1

def action_change_source_deep(s):
    """换源 sheet 深层操作 (过滤/评分/置顶)"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2):
        time.sleep(0.5)
        if safe_tap(s, name="arrow.triangle.2.circlepath", timeout=2):
            time.sleep(3)
            if safe_tap(s, labelContains="过滤", timeout=2) or safe_tap(s, name="line.3.horizontal.decrease", timeout=2):
                time.sleep(1)
                safe_tap(s, labelContains="全部", timeout=1) or go_back(s)
            for _ in range(random.randint(2, 5)):
                s.swipe_up()
                time.sleep(0.5)
            s.tap(W // 2, random.randint(200, 400))
            time.sleep(2)
            stats["sources_changed"] += 1
        else:
            time.sleep(0.5)
    read_pages(s, random.randint(3, 8))
    exit_reader(s)


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
    print("║  万象书屋 — 全功能用户模拟 v7 (100倍速)    ║")
    print("╚══════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}  时长: {args.duration//3600}h")
    print(f"覆盖: 50+场景  阅读: 0.3-0.6s/页(100倍速)  广告: 自动跳过")

    client = wda.Client(args.wda_url)
    try:
        st = client.status()
        print(f"设备: iOS {st.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    time.sleep(3)
    wait_splash(session)
    print("App 启动，广告已跳过，开始模拟...\n")
    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-sim-v7-full-deep+ad")

    # 50+ 场景, 总权重 ~160
    pool_def = [
        # A. 阅读核心 (50%)
        (action_read_shelf, "read_shelf", 15),
        (action_read_long, "read_long", 8),
        (action_switch_book, "switch_book", 5),
        (action_chapter_jump, "chapter_jump", 8),
        (action_toc_jump, "toc_jump", 5),
        (action_auto_read, "auto_read", 3),
        (action_auto_read_settings, "auto_settings", 1),
        (action_auto_read_stop, "auto_stop", 2),
        (action_tts, "tts", 2),
        (action_tts_full, "tts_full", 2),
        (action_page_turn_style, "page_style", 3),
        (action_font_picker, "font_pick", 2),
        (action_chapter_slider, "ch_slider", 3),
        (action_swipe_up_toc, "swipe_toc", 2),
        (action_toc_search, "toc_search", 2),
        (action_text_selection, "text_sel", 3),
        (action_book_finished_page, "book_done", 1),
        (action_reader_error_retry, "error_retry", 2),
        # B. 书源/网络 (15%)
        (action_search_add, "search_add", 4),
        (action_change_source, "change_source", 3),
        (action_change_source_deep, "source_deep", 2),
        (action_change_chapter_source, "ch_source", 2),
        (action_reload_chapter, "reload", 2),
        (action_purify_chapter, "purify", 2),
        (action_download, "download", 2),
        # C. 书城 (10%)
        (action_browse_read, "browse_read", 2),
        (action_store_channel, "store_channel", 2),
        (action_store_search, "store_search", 2),
        (action_rankings, "rankings", 2),
        (action_store_refresh, "store_refresh", 1),
        (action_store_shuffle, "store_shuffle", 2),
        (action_store_complete_lib, "complete_lib", 2),
        # D. 书架深层 (10%)
        (action_shelf_pull_refresh, "shelf_refresh", 2),
        (action_shelf_longpress, "shelf_lp", 3),
        (action_shelf_group_switch, "grp_switch", 2),
        (action_shelf_batch_manage, "batch_manage", 2),
        (action_shelf_layout_config, "layout_cfg", 1),
        (action_shelf_group_manage, "grp_manage", 1),
        (action_import_local, "import_local", 1),
        # E. 详情页 (5%)
        (action_detail_change_source, "dtl_source", 2),
        (action_detail_toc_sheet, "dtl_toc", 2),
        (action_detail_download, "dtl_download", 1),
        (action_detail_remove_shelf, "dtl_remove", 1),
        # F. 搜索深层 (5%)
        (action_search_precision, "srch_prec", 2),
        (action_search_filters, "srch_filter", 2),
        (action_search_history, "srch_hist", 1),
        # G. 设置/UI (5%)
        (action_theme_font, "theme_font", 2),
        (action_eye_care, "eye_care", 1),
        (action_disguise, "disguise", 1),
        (action_follow_system_theme, "follow_sys", 1),
        (action_purified_extend, "purify_ext", 1),
        (action_dismiss_announcement, "dismiss_ann", 1),
        (action_feedback, "feedback", 1),
        (action_download_center_ops, "dl_ops", 1),
        (action_download_manage, "dl_manage", 1),
        # H. 其他 (5%)
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
