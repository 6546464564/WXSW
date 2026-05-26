#!/usr/bin/env python3
"""
万象书屋 — 真实用户模拟 (10倍速阅读)
核心流程: 搜书 → 加书架 → 沉浸阅读翻页 → 偶尔书城浏览
阅读速度: 正常用户30-60秒/页, 10倍速 = 3-6秒/页
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

stats = {"cycles": 0, "errors": 0, "crashes": 0, "actions": 0, "wda_failures": 0,
         "pages_read": 0, "books_searched": 0, "books_added": 0}
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
        log_event("wda_disconnected")
        for attempt in range(5):
            wait(3)
            if check_wda_alive(client):
                log_event("wda_reconnected", attempt=attempt + 1)
                break
        else:
            log_event("wda_dead")
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
        log_event("app_crash", current_app=bid)
        print(f"  ⚠ App 崩溃/退出，第 {stats['crashes']} 次（操作: {current_action}）")
    except Exception as e:
        stats["crashes"] += 1
        log_event("app_crash_check_failed", error=str(e)[:200])

    try:
        session = client.session(BUNDLE_ID)
        wait(3)
        log_event("app_restarted")
    except:
        pass
    return session


def go_home(session):
    safe_tap(session, label="书架", type="Button")
    wait(0.5)


# ═══════════════════════════════════════════════════════
# 核心场景: 10倍速阅读
# ═══════════════════════════════════════════════════════

def read_pages(session, count):
    """翻页阅读 - 10倍速 (3-6秒/页)"""
    for i in range(count):
        session.swipe_left()
        time.sleep(random.uniform(3.0, 6.0))
        stats["pages_read"] += 1
        stats["actions"] += 1


def action_read_from_shelf(session):
    """从书架打开书阅读 — 主要场景"""
    go_home(session)
    wait(0.5)
    cells = session(type="Cell")
    if not cells.exists:
        return
    # 随机选一本书
    cells.tap()
    wait(1.5)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(2)
        # 10倍速阅读 20-80 页
        pages = random.randint(20, 80)
        read_pages(session, pages)
        # 退出阅读
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    wait(0.5)


def action_read_long_session(session):
    """长阅读会话 — 模拟用户连续看100-200页"""
    go_home(session)
    wait(0.5)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(1.5)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(2)
        pages = random.randint(100, 200)
        read_pages(session, pages)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    wait(0.5)


# ═══════════════════════════════════════════════════════
# 搜书 → 加书架
# ═══════════════════════════════════════════════════════

def action_search_and_add(session):
    """搜索书籍并加入书架"""
    go_home(session)
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(0.8)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻",
                "末日", "仙侠", "悬疑", "言情"]
    kw = random.choice(keywords)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        stats["books_searched"] += 1
        # 等搜索结果
        wait(random.uniform(5, 10))
        # 点击一个结果
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(2)
            # 加入书架
            if safe_tap(session, labelContains="加入书架") or safe_tap(session, labelContains="收藏"):
                stats["books_added"] += 1
                wait(1)
            # 开始阅读这本书
            if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
                wait(2)
                pages = random.randint(10, 30)
                read_pages(session, pages)
                safe_tap(session, label="返回") or safe_tap(session, label="Back")
                wait(0.5)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 书城浏览 → 打开书 → 阅读
# ═══════════════════════════════════════════════════════

def action_browse_and_read(session):
    """书城浏览，找到书开始读"""
    safe_tap(session, label="书城", type="Button")
    wait(1.5)
    # 滑动浏览
    for _ in range(random.randint(2, 5)):
        session.swipe_up()
        wait(1)
    # 点击一本感兴趣的书
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(2)
        # 加书架
        if random.random() > 0.5:
            safe_tap(session, labelContains="加入书架") or safe_tap(session, labelContains="收藏")
            wait(0.5)
            stats["books_added"] += 1
        # 开始阅读
        if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
            wait(2)
            pages = random.randint(15, 50)
            read_pages(session, pages)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 辅助场景
# ═══════════════════════════════════════════════════════

def action_switch_book(session):
    """切换到另一本书继续读"""
    go_home(session)
    wait(0.5)
    # 滑动书架
    session.swipe_up()
    wait(0.5)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(1.5)
        if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
            wait(2)
            pages = random.randint(10, 40)
            read_pages(session, pages)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(0.5)
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(0.5)
    stats["actions"] += 1


def action_background_return(session):
    """放下手机一会儿再回来继续看"""
    duration = random.uniform(5, 30)
    session.deactivate(duration)
    wait(1)
    stats["actions"] += 1


# ═══════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════

start_time = time.time()


def print_final_report():
    elapsed = time.time() - start_time
    hours = int(elapsed // 3600)
    minutes = int((elapsed % 3600) // 60)
    print(f"\n╔══════════════════════════════════════════════╗")
    print(f"║  测试完成: {hours}h {minutes:02d}m                            ║")
    print(f"║  翻页: {stats['pages_read']:5d}  搜书: {stats['books_searched']:3d}  加架: {stats['books_added']:3d}  ║")
    print(f"║  操作: {stats['actions']:5d}  崩溃: {stats['crashes']:5d}                ║")
    print(f"║  WDA 断连: {stats['wda_failures']:5d}                         ║")
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
    wait(3)
    print(f"App 已启动，开始模拟...\n")

    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-v1")

    # 权重: 阅读为主 (70%), 搜书加架 (15%), 书城 (10%), 其他 (5%)
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
            print(f"  [{hours:02d}h{minutes:02d}m] 页:{stats['pages_read']}  "
                  f"搜:{stats['books_searched']}  架:{stats['books_added']}  "
                  f"崩:{stats['crashes']}  WDA断:{stats['wda_failures']}")
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
