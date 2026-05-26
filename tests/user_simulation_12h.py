#!/usr/bin/env python3
"""
万象书屋 — 真实用户模拟 (10倍速阅读)
核心流程: 搜书 → 加书架 → 沉浸阅读翻页 → 偶尔书城浏览
阅读速度: 正常用户30-60秒/页, 10倍速 = 3-6秒/页

设备: iPhone SE (375x667)
优化: 用坐标点击避免慢速 source() 解析, 最大化翻页时间
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

# iPhone SE 屏幕坐标 (375x667)
SCREEN_W, SCREEN_H = 375, 667
# 书架上3列书的中心 x 坐标, y 中心约 234
SHELF_BOOK_POSITIONS = [(66, 234), (187, 234), (308, 234)]
# Tab bar
TAB_Y = 635
TAB_SHELF_X = 62
TAB_STORE_X = 187
TAB_MY_X = 312

stats = {"cycles": 0, "errors": 0, "crashes": 0, "actions": 0, "wda_failures": 0,
         "pages_read": 0, "books_searched": 0, "books_added": 0}
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


def safe_tap(session, timeout=3, **kwargs):
    try:
        el = session(**kwargs)
        if el.wait(timeout=timeout):
            el.tap()
            return True
    except Exception:
        pass
    return False


def check_wda_alive(client):
    try:
        client.status()
        return True
    except Exception:
        return False


def ensure_app_alive(client, session):
    if not check_wda_alive(client):
        stats["wda_failures"] += 1
        log_event("wda_disconnected")
        for attempt in range(20):
            time.sleep(5)
            if check_wda_alive(client):
                log_event("wda_reconnected", attempt=attempt + 1)
                break
        else:
            log_event("wda_dead")
            print_final_report()
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
        print(f"  ⚠ App 崩溃/退出，第 {stats['crashes']} 次（操作: {current_action}）")
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


def tap_tab_shelf(session):
    session.tap(TAB_SHELF_X, TAB_Y)
    time.sleep(0.8)


def tap_tab_store(session):
    session.tap(TAB_STORE_X, TAB_Y)
    time.sleep(1.0)


def exit_reader(session):
    """从阅读器退出 - 右滑手势"""
    session.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(1.0)


def read_pages(session, count):
    """翻页阅读 - 10倍速 (3-6秒/页)"""
    for _ in range(count):
        session.swipe_left()
        time.sleep(random.uniform(3.0, 6.0))
        stats["pages_read"] += 1
        stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 核心场景: 从书架读书 (坐标点击, 极快)
# ═══════════════════════════════════════════════════════

def action_read_from_shelf(session):
    """从书架随机选一本书阅读 20-80 页"""
    tap_tab_shelf(session)
    pos = random.choice(SHELF_BOOK_POSITIONS)
    session.tap(*pos)
    time.sleep(2.5)
    pages = random.randint(20, 80)
    read_pages(session, pages)
    exit_reader(session)


def action_read_long_session(session):
    """长阅读 — 连续看 100-200 页"""
    tap_tab_shelf(session)
    pos = random.choice(SHELF_BOOK_POSITIONS)
    session.tap(*pos)
    time.sleep(2.5)
    pages = random.randint(100, 200)
    read_pages(session, pages)
    exit_reader(session)


def action_switch_book(session):
    """切换到另一本书"""
    tap_tab_shelf(session)
    # 随机选不同位置
    pos = random.choice(SHELF_BOOK_POSITIONS)
    session.tap(*pos)
    time.sleep(2.5)
    pages = random.randint(10, 40)
    read_pages(session, pages)
    exit_reader(session)


# ═══════════════════════════════════════════════════════
# 搜书 → 加书架 → 阅读
# ═══════════════════════════════════════════════════════

def action_search_and_add(session):
    """搜索书籍并加入书架后阅读"""
    tap_tab_shelf(session)
    if not safe_tap(session, name="magnifyingglass", timeout=3):
        return
    time.sleep(1.5)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻",
                "末日", "仙侠", "悬疑", "言情", "推理", "历史", "军事"]
    kw = random.choice(keywords)
    tf = session(type="TextField")
    if not tf.exists:
        session.swipe(0.05, 0.5, 0.9, 0.5)
        time.sleep(0.5)
        return
    tf.set_text(kw)
    time.sleep(0.5)
    safe_tap(session, name="Search", type="Button", timeout=3)
    stats["books_searched"] += 1
    time.sleep(random.uniform(6, 12))

    # 点击搜索结果区域的第一个结果 (大约在 y=150-250 的位置)
    session.tap(SCREEN_W // 2, 200)
    time.sleep(3)
    # 尝试加书架
    if safe_tap(session, name="加书架", timeout=2):
        stats["books_added"] += 1
        time.sleep(0.5)
    # 开始阅读
    if safe_tap(session, name="开始阅读", timeout=2):
        time.sleep(3)
        pages = random.randint(10, 30)
        read_pages(session, pages)
        exit_reader(session)
    # 返回
    session.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.5)
    session.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.5)


# ═══════════════════════════════════════════════════════
# 书城浏览 → 开书阅读
# ═══════════════════════════════════════════════════════

def action_browse_and_read(session):
    """书城浏览书单/排行榜，选一本读"""
    tap_tab_store(session)
    # 滑动浏览
    for _ in range(random.randint(1, 3)):
        session.swipe_up()
        time.sleep(0.8)
    # 点击一本书 (书城书籍区域 y=400-580)
    y = random.randint(400, 560)
    x = random.randint(30, 340)
    session.tap(x, y)
    time.sleep(3)
    # 如果进了详情页
    if random.random() > 0.4:
        if safe_tap(session, name="加书架", timeout=2):
            stats["books_added"] += 1
            time.sleep(0.5)
    if safe_tap(session, name="开始阅读", timeout=2):
        time.sleep(3)
        pages = random.randint(15, 50)
        read_pages(session, pages)
        exit_reader(session)
    # 返回
    session.swipe(0.05, 0.5, 0.9, 0.5)
    time.sleep(0.5)


# ═══════════════════════════════════════════════════════
# 辅助
# ═══════════════════════════════════════════════════════

def action_background_return(session):
    """后台再回来"""
    duration = random.uniform(5, 20)
    try:
        session.deactivate(duration)
    except Exception:
        time.sleep(duration)
    time.sleep(1)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════

def print_final_report():
    elapsed = time.time() - start_time
    hours = int(elapsed // 3600)
    minutes = int((elapsed % 3600) // 60)
    rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
    print(f"\n╔══════════════════════════════════════════════╗")
    print(f"║  测试完成: {hours}h {minutes:02d}m                            ║")
    print(f"║  翻页: {stats['pages_read']:5d} ({rate:.1f}页/分)              ║")
    print(f"║  搜书: {stats['books_searched']:3d}  加架: {stats['books_added']:3d}              ║")
    print(f"║  崩溃: {stats['crashes']:5d}                                ║")
    print(f"║  WDA断连: {stats['wda_failures']:5d}                          ║")
    print(f"╚══════════════════════════════════════════════╝")
    print(f"\n日志: {LOG_FILE}")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser(description="真实用户模拟 (10倍速阅读)")
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200, help="测试时长(秒)")
    args = parser.parse_args()

    print("╔══════════════════════════════════════════════╗")
    print("║  万象书屋 — 真实用户模拟 (10倍速阅读)       ║")
    print("╚══════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}")
    print(f"时长: {args.duration // 3600}h {(args.duration % 3600) // 60}m")
    print(f"阅读速度: 3-6秒/页 (正常用户10倍)")
    print(f"日志: {LOG_FILE}")

    client = wda.Client(args.wda_url)
    try:
        status = client.status()
        print(f"设备: iOS {status.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ 无法连接 WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    time.sleep(3)
    print(f"App 已启动，开始模拟...\n")

    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-sim-v3")

    # 权重: 阅读为主 (70%), 搜书 (15%), 书城 (10%), 其他 (5%)
    actions = [
        (action_read_from_shelf, "read_shelf", 35),
        (action_read_long_session, "read_long", 20),
        (action_switch_book, "switch_book", 15),
        (action_search_and_add, "search_add", 15),
        (action_browse_and_read, "browse_read", 10),
        (action_background_return, "background", 5),
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
        except Exception as e:
            stats["errors"] += 1
            log_event("action_error", error=str(e)[:200])
            session = ensure_app_alive(client, session)

        if time.time() - last_report >= 600:
            elapsed = time.time() - start_time
            hours = int(elapsed // 3600)
            minutes = int((elapsed % 3600) // 60)
            rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
            print(f"  [{hours:02d}h{minutes:02d}m] 页:{stats['pages_read']}({rate:.1f}/m)  "
                  f"搜:{stats['books_searched']}  架:{stats['books_added']}  "
                  f"崩:{stats['crashes']}")
            log_event("periodic_report", stats=dict(stats))
            last_report = time.time()

    print_final_report()
    log_event("test_finished", stats=dict(stats))

    if stats["crashes"] > 0:
        print(f"\n⚠ 崩溃 {stats['crashes']} 次")
        sys.exit(1)
    else:
        print(f"\n✓ App 稳定")
        sys.exit(0)


if __name__ == "__main__":
    main()
