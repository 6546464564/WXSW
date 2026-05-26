#!/usr/bin/env python3
"""
万象书屋 — 12 小时真实用户行为模拟
模拟真人使用习惯：阅读、搜索、浏览、暂停、前后台
增强版：崩溃诊断、WDA 断连检测、操作追踪
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
    """写入结构化日志"""
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
    """纯粹检查 WDA 是否可达（不涉及 App 状态）"""
    try:
        client.status()
        return True
    except:
        return False


def ensure_app_alive(client, session):
    """确保 App 在前台，区分 WDA 断连和 App 崩溃"""
    global current_action

    # Step 1: 检查 WDA 是否可达
    if not check_wda_alive(client):
        stats["wda_failures"] += 1
        log_event("wda_disconnected", stats=dict(stats))
        print(f"  ✗ WDA 断连（第 {stats['wda_failures']} 次），尝试重连...")
        # 等待 WDA 恢复
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
        # WDA 恢复后重新启动 App
        try:
            session = client.session(BUNDLE_ID)
            wait(3)
        except:
            pass
        return session

    # Step 2: WDA 可达，检查 App 是否在前台
    try:
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID") or ""
        if bid == BUNDLE_ID:
            return session
        # App 不在前台但 WDA 正常 → 真实崩溃或被系统杀
        stats["crashes"] += 1
        log_event("app_crash", current_app=bid, stats=dict(stats))
        print(f"  ⚠ App 真实崩溃/退出，第 {stats['crashes']} 次"
              f"（当前前台: {bid}，操作: {current_action}）")
    except Exception as e:
        stats["crashes"] += 1
        log_event("app_crash_check_failed", error=str(e), stats=dict(stats))
        print(f"  ⚠ App 状态检测异常，第 {stats['crashes']} 次（{e}）")

    # 尝试重启 App
    try:
        session = client.session(BUNDLE_ID)
        wait(3)
        log_event("app_restarted")
    except Exception as e:
        log_event("app_restart_failed", error=str(e))
    return session


def random_pause():
    time.sleep(random.uniform(1.0, 5.0))


# ═══════════════════════════════════════════════════════
# 用户行为模拟
# ═══════════════════════════════════════════════════════

def action_read_book(session):
    """模拟阅读：进入书籍，翻几页，退出"""
    safe_tap(session, label="书架", type="Button")
    wait(1)
    cells = session(type="Cell")
    if not cells.exists:
        return
    cells.tap()
    wait(2)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(2)
        pages = random.randint(3, 15)
        for _ in range(pages):
            session.swipe_left()
            time.sleep(random.uniform(0.5, 2.0))
        stats["actions"] += pages
        safe_tap(session, label="返回") or safe_tap(session, label="Back")
        wait(1)
    safe_tap(session, label="返回") or safe_tap(session, label="Back")
    wait(0.5)


def action_browse_store(session):
    """模拟浏览书城"""
    safe_tap(session, label="书城", type="Button")
    wait(2)
    scrolls = random.randint(2, 6)
    for _ in range(scrolls):
        session.swipe_up()
        time.sleep(random.uniform(0.5, 1.5))
    if random.random() > 0.5:
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            safe_tap(session, label="返回") or safe_tap(session, label="Back")
            wait(1)
    for _ in range(scrolls):
        session.swipe_down()
        time.sleep(0.3)
    stats["actions"] += scrolls + 1


def action_search(session):
    """模拟搜索"""
    safe_tap(session, label="书架", type="Button")
    wait(0.5)
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        return
    wait(1)
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻"]
    kw = random.choice(keywords)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text(kw)
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(random.uniform(5, 10))
        stats["actions"] += 1
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


def action_check_settings(session):
    """模拟查看设置"""
    safe_tap(session, label="我的", type="Button")
    wait(1)
    session.swipe_up()
    wait(0.5)
    session.swipe_down()
    wait(0.5)
    stats["actions"] += 1


def action_switch_tabs(session):
    """快速切换 Tab"""
    tabs = ["书架", "书城", "我的"]
    for _ in range(random.randint(2, 4)):
        safe_tap(session, label=random.choice(tabs), type="Button")
        time.sleep(random.uniform(0.3, 1.0))
    stats["actions"] += 1


def action_background(session):
    """模拟按 Home 后回来"""
    duration = random.uniform(2, 10)
    session.deactivate(duration)
    wait(1)
    stats["actions"] += 1


def action_idle(session):
    """模拟用户放下手机"""
    idle_time = random.uniform(10, 60)
    time.sleep(idle_time)
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
    print(f"║  测试完成: {hours}h {minutes}m                       ║")
    print(f"║  操作: {stats['actions']:5d}  循环: {stats['cycles']:5d}         ║")
    print(f"║  错误: {stats['errors']:5d}  崩溃: {stats['crashes']:5d}         ║")
    print(f"║  WDA 断连: {stats['wda_failures']:5d}                    ║")
    print(f"╚══════════════════════════════════════════╝")
    print(f"\n日志文件: {LOG_FILE}")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser(description="12 小时真实用户模拟")
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200, help="测试时长(秒)，默认 43200=12h")
    args = parser.parse_args()

    print("╔══════════════════════════════════════════╗")
    print("║  万象书屋 — 12h 真实用户行为模拟 v2     ║")
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

    start_time = time.time()
    log_event("test_started", duration_planned=args.duration)

    actions = [
        (action_read_book, "read_book", 30),
        (action_browse_store, "browse_store", 20),
        (action_search, "search", 10),
        (action_check_settings, "settings", 10),
        (action_switch_tabs, "switch_tabs", 15),
        (action_background, "background", 5),
        (action_idle, "idle", 10),
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
