#!/usr/bin/env python3
"""
万象书屋 — 12 小时真实用户行为模拟 v3
覆盖所有主要场景：阅读、搜索、书城、书源管理、设置、前后台、快速切换等
增强版：崩溃诊断、WDA 断连检测、操作追踪、更多边缘场景
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

stats = {"cycles": 0, "errors": 0, "crashes": 0, "actions": 0, "wda_failures": 0}
current_action = "idle"
last_action = "idle"


def wait(sec=1.0):
    time.sleep(sec)


def log_event(event_type, **data):
    entry = {
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "elapsed_s": int(time.time() - start_time) if 'start_time' in globals() else 0,
        "type": event_type,
        "action": current_action,
        "last_action": last_action,
        **data,
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def safe_tap(session, **kwargs):
    try:
        el = session(**kwargs)
        if el.exists:
            el.tap()
            return True
    except:
        pass
    return False


def safe_tap_coord(session, x, y):
    try:
        session.tap(x, y)
        return True
    except:
        return False


def check_wda_alive(client):
    try:
        client.status()
        return True
    except:
        return False


def ensure_app_alive(client, session):
    global current_action

    if not check_wda_alive(client):
        stats["wda_failures"] += 1
        log_event("wda_disconnected", stats=dict(stats))
        print(f"  ✗ WDA 断连（第 {stats['wda_failures']} 次），尝试重连...")
        for attempt in range(5):
            wait(3)
            if check_wda_alive(client):
                print(f"    WDA 重连成功 (尝试 {attempt + 1})")
                log_event("wda_reconnected", attempt=attempt + 1)
                break
        else:
            log_event("wda_dead", message="WDA 5次重连失败，终止测试")
            print(f"  ✗✗ WDA 完全失联，终止测试")
            print_final_report()
            sys.exit(2)
        try:
            session = client.session(BUNDLE_ID)
            wait(3)
        except:
            pass
        return session

    try:
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID") or ""
        if bid == BUNDLE_ID:
            return session
        stats["crashes"] += 1
        log_event("app_crash", current_app=bid, stats=dict(stats))
        print(f"  ⚠ App 真实崩溃/退出，第 {stats['crashes']} 次"
              f"（当前前台: {bid}，操作: {current_action}）")
    except Exception as e:
        stats["crashes"] += 1
        log_event("app_crash_check_failed", error=str(e), stats=dict(stats))
        print(f"  ⚠ App 状态检测异常，第 {stats['crashes']} 次（{e}）")

    try:
        session = client.session(BUNDLE_ID)
        wait(3)
        log_event("app_restarted")
    except Exception as e:
        log_event("app_restart_failed", error=str(e))
    return session


def random_pause():
    time.sleep(random.uniform(0.3, 1.5))


def go_home(session):
    """回到书架首页"""
    safe_tap(session, label="书架", type="Button")
    wait(0.5)


# ═══════════════════════════════════════════════════════
# 场景 1: 阅读
# ═══════════════════════════════════════════════════════

def action_read_book(session):
    """模拟阅读：进入书籍，翻几页，退出"""
    go_home(session)
    wait(0.3)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(1)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(1)
        pages = random.randint(3, 10)
        for _ in range(pages):
            session.swipe_left()
            time.sleep(random.uniform(0.2, 1.0))
        stats["actions"] += pages
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    wait(0.3)


def action_read_long(session):
    """长时间阅读 — 模拟用户沉浸阅读 15-30 页"""
    go_home(session)
    wait(0.3)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(1)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(1)
        pages = random.randint(15, 30)
        for i in range(pages):
            session.swipe_left()
            time.sleep(random.uniform(0.3, 1.5))
            if i % 10 == 0:
                stats["actions"] += 10
        stats["actions"] += pages % 10
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    wait(0.3)


def action_read_change_settings(session):
    """阅读中更改设置（字号、主题等）"""
    go_home(session)
    wait(0.5)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(2)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(2)
        for _ in range(random.randint(2, 5)):
            session.swipe_left()
            wait(0.5)
        # 点击屏幕中间呼出设置面板
        w, h = session.window_size()
        safe_tap_coord(session, w // 2, h // 2)
        wait(1)
        # 尝试点击底部设置栏的字号/主题等
        safe_tap(session, labelContains="设置") or safe_tap(session, labelContains="Aa")
        wait(1)
        # 点击增大/减小字号
        safe_tap(session, label="A+") or safe_tap(session, labelContains="增大")
        wait(0.5)
        safe_tap(session, label="A-") or safe_tap(session, labelContains="减小")
        wait(0.5)
        # 关闭设置面板
        safe_tap_coord(session, w // 2, h // 4)
        wait(1)
        # 继续翻几页验证新设置
        for _ in range(3):
            session.swipe_left()
            wait(0.8)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(1)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    stats["actions"] += 1


def action_read_chapter_jump(session):
    """阅读中跳转章节"""
    go_home(session)
    wait(0.5)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(2)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(2)
        # 呼出菜单
        w, h = session.window_size()
        safe_tap_coord(session, w // 2, h // 2)
        wait(1)
        # 点击目录
        if safe_tap(session, labelContains="目录") or safe_tap(session, labelContains="章节"):
            wait(2)
            # 滑动目录列表
            session.swipe_up()
            wait(0.5)
            session.swipe_up()
            wait(0.5)
            # 随机点击一个章节
            cells = session(type="Cell")
            if cells.exists:
                cells.tap()
                wait(3)
                # 翻几页
                for _ in range(random.randint(2, 5)):
                    session.swipe_left()
                    wait(1)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 2: 搜索
# ═══════════════════════════════════════════════════════

def action_search(session):
    """模拟搜索"""
    go_home(session)
    wait(0.3)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(0.5)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻",
                "末日", "网游", "仙侠", "悬疑", "推理", "言情", "历史", "军事"]
    kw = random.choice(keywords)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.3)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(random.uniform(3, 7))
        # 有时滚动结果
        if random.random() > 0.5:
            session.swipe_up()
            wait(0.5)
        stats["actions"] += 1
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.3)


def action_search_rapid(session):
    """快速连续搜索 — 压力测试搜索取消/重启"""
    go_home(session)
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(1)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统"]
    for _ in range(random.randint(2, 4)):
        kw = random.choice(keywords)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.clear_text()
            wait(0.3)
            tf.set_text(kw)
            wait(0.3)
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(random.uniform(1, 3))
        stats["actions"] += 1
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


def action_search_then_switch(session):
    """搜索后立即切换 Tab — 之前的崩溃场景"""
    go_home(session)
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(1)
    keywords = ["修仙", "玄幻", "重生"]
    kw = random.choice(keywords)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.3)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(random.uniform(1, 3))
    # 不等搜索完成直接取消切换
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.3)
    safe_tap(session, label="书城", type="Button")
    wait(0.5)
    safe_tap(session, label="我的", type="Button")
    wait(0.5)
    safe_tap(session, label="书架", type="Button")
    stats["actions"] += 1


def action_search_enter_detail(session):
    """搜索后进入书籍详情"""
    go_home(session)
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(1)
    keywords = ["修仙", "都市", "玄幻"]
    kw = random.choice(keywords)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(random.uniform(6, 12))
        # 点击搜索结果
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            # 可能看到书籍详情
            session.swipe_up()
            wait(1)
            # 尝试加入书架
            if random.random() > 0.7:
                safe_tap(session, labelContains="加入书架") or safe_tap(session, labelContains="收藏")
                wait(1)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


# ═══════════════════════════════════════════════════════
# 场景 3: 书城
# ═══════════════════════════════════════════════════════

def action_browse_store(session):
    """模拟浏览书城"""
    safe_tap(session, label="书城", type="Button")
    wait(2)
    scrolls = random.randint(2, 8)
    for _ in range(scrolls):
        session.swipe_up()
        time.sleep(random.uniform(0.5, 1.5))
    if random.random() > 0.5:
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            session.swipe_up()
            wait(1)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(1)
    for _ in range(min(scrolls, 3)):
        session.swipe_down()
        time.sleep(0.3)
    stats["actions"] += scrolls + 1


def action_store_pull_refresh(session):
    """书城下拉刷新"""
    safe_tap(session, label="书城", type="Button")
    wait(2)
    # 下拉刷新
    w, h = session.window_size()
    session.swipe(w // 2, h // 4, w // 2, h * 3 // 4, duration=0.5)
    wait(3)
    stats["actions"] += 1


def action_store_category(session):
    """浏览书城分类"""
    safe_tap(session, label="书城", type="Button")
    wait(2)
    # 点击分类 Tab 或 segment
    safe_tap(session, labelContains="分类") or safe_tap(session, labelContains="排行")
    wait(2)
    session.swipe_up()
    wait(1)
    session.swipe_up()
    wait(1)
    if random.random() > 0.6:
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(1)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 4: 设置/个人中心
# ═══════════════════════════════════════════════════════

def action_check_settings(session):
    """模拟查看设置"""
    safe_tap(session, label="我的", type="Button")
    wait(1)
    session.swipe_up()
    wait(0.5)
    session.swipe_down()
    wait(0.5)
    stats["actions"] += 1


def action_settings_deep(session):
    """深入设置页面"""
    safe_tap(session, label="我的", type="Button")
    wait(1)
    # 尝试进入各种子设置
    settings_items = ["阅读设置", "缓存管理", "关于", "书源管理", "通用"]
    random.shuffle(settings_items)
    for item in settings_items[:2]:
        if safe_tap(session, labelContains=item):
            wait(2)
            session.swipe_up()
            wait(0.5)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
    stats["actions"] += 1


def action_source_manage(session):
    """书源管理 — 进入列表、滚动、退出"""
    safe_tap(session, label="我的", type="Button")
    wait(1)
    if safe_tap(session, labelContains="书源管理") or safe_tap(session, labelContains="书源"):
        wait(2)
        for _ in range(random.randint(2, 5)):
            session.swipe_up()
            wait(0.5)
        session.swipe_down()
        wait(0.5)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 5: 快速切换/压力
# ═══════════════════════════════════════════════════════

def action_switch_tabs(session):
    """快速切换 Tab"""
    tabs = ["书架", "书城", "我的"]
    for _ in range(random.randint(2, 6)):
        safe_tap(session, label=random.choice(tabs), type="Button")
        time.sleep(random.uniform(0.2, 0.8))
    stats["actions"] += 1


def action_rapid_switch(session):
    """极速切换 Tab — 压力场景"""
    tabs = ["书架", "书城", "我的"]
    for _ in range(random.randint(8, 15)):
        safe_tap(session, label=random.choice(tabs), type="Button")
        time.sleep(random.uniform(0.05, 0.3))
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 6: 前后台/系统
# ═══════════════════════════════════════════════════════

def action_background(session):
    """模拟按 Home 后回来"""
    duration = random.uniform(2, 15)
    session.deactivate(duration)
    wait(1)
    stats["actions"] += 1


def action_background_long(session):
    """长时间后台 — 模拟用户离开一段时间"""
    duration = random.uniform(10, 30)
    session.deactivate(duration)
    wait(1)
    stats["actions"] += 1


def action_idle(session):
    """模拟用户放下手机"""
    idle_time = random.uniform(3, 10)
    time.sleep(idle_time)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 7: 书架管理
# ═══════════════════════════════════════════════════════

def action_bookshelf_scroll(session):
    """书架滚动浏览"""
    go_home(session)
    wait(0.5)
    scrolls = random.randint(3, 8)
    for _ in range(scrolls):
        session.swipe_up()
        wait(0.5)
    for _ in range(min(scrolls, 3)):
        session.swipe_down()
        wait(0.3)
    stats["actions"] += scrolls


def action_bookshelf_pull_refresh(session):
    """书架下拉更新"""
    go_home(session)
    wait(0.5)
    w, h = session.window_size()
    session.swipe(w // 2, h // 4, w // 2, h * 3 // 4, duration=0.5)
    wait(5)
    stats["actions"] += 1


def action_bookshelf_long_press(session):
    """长按书籍 — 触发管理菜单"""
    go_home(session)
    wait(0.5)
    cells = session(type="Cell")
    if cells.exists:
        try:
            w, h = session.window_size()
            # 长按第一本书
            session.tap_hold(w // 4, h // 3, duration=1.5)
            wait(1)
            # 取消/关闭菜单
            safe_tap(session, label="取消") or safe_tap(session, labelContains="Cancel")
            wait(0.5)
        except:
            pass
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 场景 8: 混合高压
# ═══════════════════════════════════════════════════════

def action_search_read_switch(session):
    """搜索 → 加入书架 → 阅读 → 切Tab — 组合场景"""
    go_home(session)
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(1)
    kw = random.choice(["修仙", "都市", "玄幻"])
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.3)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(random.uniform(5, 10))
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            safe_tap(session, labelContains="加入书架") or safe_tap(session, labelContains="收藏")
            wait(1)
            if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
                wait(2)
                for _ in range(random.randint(2, 5)):
                    session.swipe_left()
                    wait(0.5)
                safe_tap(session, label="返回") or safe_tap(session, label="Back")
                wait(0.5)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.3)
    safe_tap(session, label="书城", type="Button")
    wait(0.5)
    safe_tap(session, label="书架", type="Button")
    stats["actions"] += 1


def action_memory_pressure(session):
    """模拟内存压力场景 — 快速进出多个书籍详情"""
    go_home(session)
    wait(0.5)
    for _ in range(random.randint(3, 6)):
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(2)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
        session.swipe_up()
        wait(0.3)
    session.swipe_down()
    session.swipe_down()
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════

start_time = time.time()


def print_final_report():
    elapsed = time.time() - start_time
    hours = int(elapsed // 3600)
    minutes = int((elapsed % 3600) // 60)
    print(f"\n╔══════════════════════════════════════════╗")
    print(f"║  测试完成: {hours}h {minutes:02d}m                       ║")
    print(f"║  操作: {stats['actions']:5d}  循环: {stats['cycles']:5d}         ║")
    print(f"║  错误: {stats['errors']:5d}  崩溃: {stats['crashes']:5d}         ║")
    print(f"║  WDA 断连: {stats['wda_failures']:5d}                    ║")
    print(f"╚══════════════════════════════════════════╝")
    print(f"\n日志文件: {LOG_FILE}")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser(description="12 小时真实用户模拟 v3")
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200, help="测试时长(秒)，默认 43200=12h")
    args = parser.parse_args()

    print("╔══════════════════════════════════════════╗")
    print("║  万象书屋 — 12h 真实用户行为模拟 v3     ║")
    print("╚══════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}")
    print(f"计划时长: {args.duration // 3600}h {(args.duration % 3600) // 60}m")
    print(f"日志: {LOG_FILE}")

    client = wda.Client(args.wda_url)
    try:
        status = client.status()
        print(f"设备: iOS {status.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ 无法连接 WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    wait(3)
    print(f"App 已启动，开始模拟...\n")
    print(f"场景覆盖: 阅读(长/短/设置/章节跳转)、搜索(普通/快速/详情/切Tab)、")
    print(f"          书城(浏览/刷新/分类)、设置(浅/深/书源)、Tab切换(普通/极速)、")
    print(f"          前后台(短/长)、书架(滚动/刷新/长按)、混合高压\n")

    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="v3")

    actions = [
        # 阅读 (总权重 28)
        (action_read_book, "read_book", 12),
        (action_read_long, "read_long", 5),
        (action_read_change_settings, "read_settings", 5),
        (action_read_chapter_jump, "read_chapter_jump", 6),
        # 搜索 (总权重 20)
        (action_search, "search", 6),
        (action_search_rapid, "search_rapid", 4),
        (action_search_then_switch, "search_then_switch", 5),
        (action_search_enter_detail, "search_detail", 5),
        # 书城 (总权重 15)
        (action_browse_store, "browse_store", 8),
        (action_store_pull_refresh, "store_refresh", 3),
        (action_store_category, "store_category", 4),
        # 设置 (总权重 10)
        (action_check_settings, "settings", 4),
        (action_settings_deep, "settings_deep", 3),
        (action_source_manage, "source_manage", 3),
        # Tab 切换 (总权重 10)
        (action_switch_tabs, "switch_tabs", 6),
        (action_rapid_switch, "rapid_switch", 4),
        # 前后台 (总权重 7)
        (action_background, "background", 4),
        (action_background_long, "background_long", 3),
        # 书架管理 (总权重 8)
        (action_bookshelf_scroll, "shelf_scroll", 3),
        (action_bookshelf_pull_refresh, "shelf_refresh", 3),
        (action_bookshelf_long_press, "shelf_longpress", 2),
        # 混合高压 (总权重 7)
        (action_search_read_switch, "search_read_switch", 4),
        (action_memory_pressure, "memory_pressure", 3),
        # 空闲 (总权重 5)
        (action_idle, "idle", 5),
    ]
    action_list = []
    for act, name, weight in actions:
        action_list.extend([(act, name)] * weight)

    last_report = start_time

    while time.time() - start_time < args.duration:
        try:
            act_fn, act_name = random.choice(action_list)
            last_action = current_action
            current_action = act_name
            act_fn(session)
            stats["cycles"] += 1

            session = ensure_app_alive(client, session)
            random_pause()

        except Exception as e:
            stats["errors"] += 1
            if "Connection refused" in str(e) or "ConnectionError" in str(e):
                log_event("wda_error_in_action", action=current_action, error=str(e)[:200])
            else:
                log_event("action_error", action=current_action, error=str(e)[:200])
            session = ensure_app_alive(client, session)

        if time.time() - last_report >= 600:
            elapsed = time.time() - start_time
            hours = int(elapsed // 3600)
            minutes = int((elapsed % 3600) // 60)
            print(f"  [{hours:02d}h{minutes:02d}m] 操作: {stats['actions']}  "
                  f"循环: {stats['cycles']}  错误: {stats['errors']}  "
                  f"崩溃: {stats['crashes']}  WDA断连: {stats['wda_failures']}")
            log_event("periodic_report", stats=dict(stats))
            last_report = time.time()

    print_final_report()
    log_event("test_finished", stats=dict(stats))

    if stats["crashes"] > 0:
        print(f"\n⚠ 测试期间 App 真实崩溃 {stats['crashes']} 次！")
        sys.exit(1)
    else:
        print(f"\n✓ App 在测试期间保持稳定")
        sys.exit(0)


if __name__ == "__main__":
    main()
