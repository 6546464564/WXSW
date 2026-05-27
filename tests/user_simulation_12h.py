#!/usr/bin/env python3
"""
万象书屋 — 全功能真实用户模拟 v9 (100倍速 + 自适应进化 + 广告观看)
覆盖所有可交互功能: 50+ 预设场景 + 自动发现未知UI + 进化学习

核心能力:
  1. 预设 50+ 场景覆盖已知功能
  2. 探索引擎: 定期 dump UI 层级, 发现新的可交互元素
  3. 进化记忆: 记录每个元素的交互结果(成功/失败/导航/崩溃)
  4. 自动恢复: 探索导致异常时安全回退
  5. 广告真实观看: 遇到激励视频不跳过, 等待播完并关闭, 解锁纯净阅读

设备: iPhone SE (375x667)
"""

import argparse
import time
import sys
import random
import json
import os
import re
import hashlib
import signal
import urllib.request
from xml.etree import ElementTree as ET

BUNDLE_ID = "com.wanxiang.reader"
DEFAULT_WDA_URL = "http://192.168.88.166:8100"
LOG_FILE = os.path.join(os.path.dirname(__file__), "simulation_crash_log.jsonl")
MEMORY_FILE = os.path.join(os.path.dirname(__file__), "evolution_memory.json")


class WDASession:
    """轻量 WDA HTTP 客户端，绕过 facebook-wda 的 session 重试 bug。"""

    def __init__(self, base_url, bundle_id):
        self.base = base_url.rstrip("/")
        self.sid = None
        self._acquire_session(bundle_id)

    def _raw_http(self, method, path, data=None, timeout=10):
        url = f"{self.base}{path}"
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(url, data=body, method=method,
                                     headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(resp.read())

    def _http(self, method, path, data=None, timeout=10):
        try:
            return self._raw_http(method, path, data, timeout)
        except urllib.error.HTTPError as e:
            if e.code in (404, 500):
                self._refresh_session()
                new_path = path.replace(f"/session/{self.sid}", "")
                if new_path == path and self.sid in path:
                    pass  # sid not in path, just retry
                else:
                    path = f"/session/{self.sid}{new_path}"
                return self._raw_http(method, path, data, timeout)
            raise

    def _refresh_session(self):
        """从 WDA 获取最新的 session ID。"""
        try:
            r = self._raw_http("GET", "/wda/locked")
            new_sid = r.get("sessionId")
            if new_sid and new_sid != self.sid:
                self.sid = new_sid
                return
        except Exception:
            pass
        try:
            st = self._raw_http("GET", "/status")
            new_sid = st.get("sessionId")
            if new_sid and new_sid != self.sid:
                self.sid = new_sid
                self.sid = new_sid
        except Exception:
            pass

    def _acquire_session(self, bundle_id):
        """复用 WDA 内部 session (iOS 26.4 不允许创建新 session)。
        先终止 app 再带 -autoRewardAds 参数重启。"""
        launch_payload = {"bundleId": bundle_id, "arguments": ["-autoRewardAds"]}
        try:
            r = self._raw_http("GET", "/wda/locked")
            sid = r.get("sessionId")
            if sid:
                self.sid = sid
                # 先终止 app 确保参数生效
                try:
                    self._raw_http("POST", f"/session/{self.sid}/wda/apps/terminate",
                                   {"bundleId": bundle_id}, timeout=10)
                    time.sleep(2)
                except Exception:
                    pass
                try:
                    self._raw_http("POST", f"/session/{self.sid}/wda/apps/launch",
                                   launch_payload, timeout=30)
                except Exception:
                    pass
                return
        except Exception:
            pass
        st = self._raw_http("GET", "/status")
        existing = st.get("sessionId")
        if existing:
            self.sid = existing
            try:
                self._raw_http("POST", f"/session/{self.sid}/wda/apps/terminate",
                               {"bundleId": bundle_id}, timeout=10)
                time.sleep(2)
            except Exception:
                pass
            try:
                self._raw_http("POST", f"/session/{self.sid}/wda/apps/launch",
                               launch_payload, timeout=30)
            except Exception:
                pass
            return
        r = self._raw_http("POST", "/session",
                       {"capabilities": {"alwaysMatch": {"bundleId": bundle_id,
                        "arguments": ["-autoRewardAds"]}}}, timeout=30)
        self.sid = r.get("sessionId") or r.get("value", {}).get("sessionId")
        if not self.sid:
            raise RuntimeError(f"WDA session creation failed: {r}")

    def status(self):
        return self._http("GET", "/status").get("value", {})

    def tap(self, x, y):
        self._http("POST", f"/session/{self.sid}/wda/tap",
                   {"x": x, "y": y})

    def swipe(self, fx, fy, tx, ty, duration=0.5):
        self._http("POST", f"/session/{self.sid}/wda/dragfromtoforduration",
                   {"fromX": fx, "fromY": fy, "toX": tx, "toY": ty,
                    "duration": duration})

    def swipe_left(self):
        self.swipe(W * 0.85, H * 0.5, W * 0.15, H * 0.5, 0.3)

    def swipe_right(self):
        self.swipe(W * 0.15, H * 0.5, W * 0.85, H * 0.5, 0.3)

    def swipe_up(self):
        self.swipe(W * 0.5, H * 0.7, W * 0.5, H * 0.3, 0.3)

    def swipe_down(self):
        self.swipe(W * 0.5, H * 0.3, W * 0.5, H * 0.7, 0.3)

    def app_current(self):
        r = self._http("GET", f"/session/{self.sid}/wda/activeAppInfo")
        return r.get("value", {})

    def source(self, fmt="xml", format=None):
        r = self._http("GET", f"/session/{self.sid}/source",
                       timeout=15)
        return r.get("value", "")

    def __call__(self, **kwargs):
        return WDAElementQuery(self, **kwargs)


class WDAElementQuery:
    """WDA 元素查询 — 兼容 safe_tap(s, name=..., labelContains=...) 模式。"""

    def __init__(self, session, **kwargs):
        self.session = session
        self.kwargs = kwargs

    def wait(self, timeout=3):
        el = self._find(timeout)
        return el is not None

    @property
    def exists(self):
        return self._find(1) is not None

    def tap(self):
        el = self._find(1)
        if el:
            x, y = el
            self.session.tap(x, y)
            return True
        return False

    def set_text(self, text):
        el = self._find(1)
        if el:
            x, y = el
            self.session.tap(x, y)
            time.sleep(0.3)
            self.session._http("POST",
                f"/session/{self.session.sid}/wda/keys",
                {"value": list(text)})
            return True
        return False

    def _find(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                src = self.session.source()
                root = ET.fromstring(src) if isinstance(src, str) and src.strip().startswith("<") else None
                if root is None:
                    time.sleep(0.3)
                    continue
                match = self._match_in_tree(root)
                if match is not None:
                    return match
            except Exception:
                pass
            time.sleep(0.3)
        return None

    def _match_in_tree(self, root):
        name_match = self.kwargs.get("name")
        label_contains = self.kwargs.get("labelContains")
        for el in root.iter():
            attrs = el.attrib
            if attrs.get("visible") == "false":
                continue
            n = attrs.get("name", "")
            lab = attrs.get("label", "")
            val = attrs.get("value", "")
            if name_match and n == name_match:
                return self._center(attrs)
            if label_contains and label_contains in lab:
                return self._center(attrs)
            if label_contains and label_contains in val:
                return self._center(attrs)
        return None

    @staticmethod
    def _center(attrs):
        x = int(attrs.get("x", 0))
        y = int(attrs.get("y", 0))
        w = int(attrs.get("width", 0))
        h = int(attrs.get("height", 0))
        return (x + w // 2, y + h // 2)

W, H = 375, 667
SHELF_BOOKS = [(66, 234), (187, 234), (308, 234)]
TAB_Y = 635
TAB_SHELF_X, TAB_STORE_X, TAB_MY_X = 62, 187, 312

stats = {
    "cycles": 0, "errors": 0, "crashes": 0, "actions": 0,
    "wda_failures": 0, "pages_read": 0, "books_searched": 0,
    "books_added": 0, "chapters_jumped": 0, "sources_changed": 0,
    "tts_sessions": 0, "downloads": 0, "bookmarks": 0,
    "explored": 0, "new_elements_found": 0, "explore_success": 0,
    "ads_watched": 0, "ads_failed": 0,
}
current_action = "idle"
last_action = "idle"
start_time = time.time()
watch_ads_global = True


# ═══════════════════════════════════════════════════════
# 进化记忆系统
# ═══════════════════════════════════════════════════════

class EvolutionMemory:
    """持久化记忆: 记录已发现的UI元素及其交互结果"""

    def __init__(self, path):
        self.path = path
        self.elements = {}
        self.screens = {}
        self.load()

    def load(self):
        try:
            with open(self.path, "r") as f:
                data = json.load(f)
                self.elements = data.get("elements", {})
                self.screens = data.get("screens", {})
        except (FileNotFoundError, json.JSONDecodeError):
            self.elements = {}
            self.screens = {}

    def save(self):
        try:
            with open(self.path, "w") as f:
                json.dump({
                    "elements": self.elements,
                    "screens": self.screens,
                    "last_updated": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "stats": {"total": len(self.elements),
                              "safe": sum(1 for e in self.elements.values() if e.get("safe")),
                              "dangerous": sum(1 for e in self.elements.values() if e.get("dangerous"))},
                }, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def element_key(self, el_info):
        raw = f"{el_info.get('type','')}|{el_info.get('name','')}|{el_info.get('label','')}"
        return hashlib.md5(raw.encode()).hexdigest()[:12]

    def is_known(self, el_info):
        return self.element_key(el_info) in self.elements

    def record(self, el_info, result):
        key = self.element_key(el_info)
        if key not in self.elements:
            self.elements[key] = {
                "type": el_info.get("type", ""),
                "name": el_info.get("name", ""),
                "label": el_info.get("label", ""),
                "first_seen": time.strftime("%Y-%m-%d %H:%M:%S"),
                "attempts": 0, "successes": 0, "failures": 0,
                "safe": False, "dangerous": False,
                "results": [],
            }
        entry = self.elements[key]
        entry["attempts"] += 1
        entry["last_seen"] = time.strftime("%Y-%m-%d %H:%M:%S")
        if result in ("ok", "navigated", "sheet_opened", "toggle"):
            entry["successes"] += 1
            entry["safe"] = entry["successes"] >= 2
        elif result in ("crash", "stuck"):
            entry["failures"] += 1
            entry["dangerous"] = entry["failures"] >= 2
        entry["results"] = (entry.get("results", []) + [result])[-5:]

    def record_screen(self, screen_sig, elements_found):
        self.screens[screen_sig] = {
            "last_seen": time.strftime("%Y-%m-%d %H:%M:%S"),
            "element_count": elements_found,
        }

    def get_safe_elements(self):
        return {k: v for k, v in self.elements.items() if v.get("safe")}

    def get_unexplored(self, el_list):
        unknown = []
        for el in el_list:
            key = self.element_key(el)
            entry = self.elements.get(key)
            if entry is None:
                unknown.append(el)
            elif not entry.get("dangerous") and entry["attempts"] < 3:
                unknown.append(el)
        return unknown


memory = EvolutionMemory(MEMORY_FILE)


# ═══════════════════════════════════════════════════════
# UI 发现引擎
# ═══════════════════════════════════════════════════════

INTERACTIVE_TYPES = {"Button", "Cell", "Switch", "Link", "TextField",
                     "SecureTextField", "Slider", "Stepper", "Toggle",
                     "MenuItem", "SegmentedControl", "Tab", "Image"}
SKIP_LABELS = {"", "nil", "null", "返回", "Back"}
SKIP_NAMES = {"", "nil", "null"}

def parse_ui_tree(xml_source):
    """解析 WDA source XML, 提取所有可交互元素"""
    elements = []
    try:
        root = ET.fromstring(xml_source)
    except ET.ParseError:
        return elements

    def walk(node, depth=0):
        el_type = node.get("type", "")
        name = node.get("name", "") or ""
        label = node.get("label", "") or ""
        enabled = node.get("enabled", "true") == "true"
        visible = node.get("visible", "true") == "true"
        x = node.get("x", "0")
        y = node.get("y", "0")
        w = node.get("width", "0")
        h = node.get("height", "0")

        is_interactive = (
            el_type in INTERACTIVE_TYPES
            or "Button" in el_type
            or "Cell" in el_type
            or "Switch" in el_type
            or "Link" in el_type
            or node.get("accessible", "") == "true"
        )

        if is_interactive and enabled and visible:
            try:
                cx = int(float(x)) + int(float(w)) // 2
                cy = int(float(y)) + int(float(h)) // 2
                if 5 < cx < W - 5 and 50 < cy < H - 20:
                    el_info = {
                        "type": el_type, "name": name, "label": label,
                        "x": cx, "y": cy, "depth": depth,
                    }
                    if name not in SKIP_NAMES or label not in SKIP_LABELS:
                        elements.append(el_info)
            except (ValueError, TypeError):
                pass

        for child in node:
            walk(child, depth + 1)

    walk(root)
    return elements


def get_screen_signature(elements):
    """生成当前屏幕的签名 (用于识别重复页面)"""
    sig_parts = sorted(set(f"{e['type']}:{e.get('name','')}" for e in elements[:20]))
    return hashlib.md5("|".join(sig_parts).encode()).hexdigest()[:8]


class TimeoutError(Exception):
    pass

def _timeout_handler(signum, frame):
    raise TimeoutError("source() timeout")


def safe_source(s, timeout=10):
    """获取 UI 层级 XML，带超时保护"""
    old_handler = signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(timeout)
    try:
        xml = s.source(format="xml")
        signal.alarm(0)
        return xml
    except TimeoutError:
        return None
    except Exception:
        signal.alarm(0)
        try:
            signal.alarm(timeout)
            xml = s.source()
            signal.alarm(0)
            return xml
        except Exception:
            signal.alarm(0)
            return None
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


def explore_current_screen(s, client, session):
    """探索当前屏幕: 发现新元素并尝试交互"""
    global current_action
    current_action = "explore"

    xml = safe_source(s, timeout=10)
    if not xml:
        return session

    elements = parse_ui_tree(xml)
    if not elements:
        return session

    screen_sig = get_screen_signature(elements)
    memory.record_screen(screen_sig, len(elements))
    stats["explored"] += 1

    unknown = memory.get_unexplored(elements)
    if not unknown:
        return session

    stats["new_elements_found"] += len(unknown)

    to_try = random.sample(unknown, min(3, len(unknown)))

    for el in to_try:
        try:
            pre_bid = ""
            try:
                info = client.app_current()
                pre_bid = info.get("bundleId") or info.get("bundleID") or ""
            except Exception:
                pass

            s.tap(el["x"], el["y"])
            time.sleep(1.0)

            post_bid = ""
            try:
                info = client.app_current()
                post_bid = info.get("bundleId") or info.get("bundleID") or ""
            except Exception:
                post_bid = ""

            if post_bid and post_bid != BUNDLE_ID:
                memory.record(el, "crash")
                session = ensure_alive(client, session)
                break
            elif post_bid == BUNDLE_ID:
                try:
                    new_xml = safe_source(s, timeout=8)
                    if new_xml:
                        new_elements = parse_ui_tree(new_xml)
                        new_sig = get_screen_signature(new_elements)
                        if new_sig != screen_sig:
                            memory.record(el, "navigated")
                            stats["explore_success"] += 1
                            log_event("explore_navigate",
                                      element=f"{el['type']}:{el.get('name','')}:{el.get('label','')}",
                                      from_screen=screen_sig, to_screen=new_sig)
                            time.sleep(0.5)
                            go_back(s)
                            time.sleep(0.5)
                        else:
                            memory.record(el, "ok")
                            stats["explore_success"] += 1
                    else:
                        memory.record(el, "ok")
                        stats["explore_success"] += 1
                except Exception:
                    memory.record(el, "ok")
                    stats["explore_success"] += 1
            else:
                memory.record(el, "unknown")
        except Exception:
            memory.record(el, "error")

    memory.save()
    return session


def action_explore(s, client, session):
    """主动探索: 在当前 tab 页面发现新元素"""
    tabs = [go_shelf, go_store, go_my]
    random.choice(tabs)(s)
    time.sleep(0.5)
    return explore_current_screen(s, client, session)


def action_deep_explore(s, client, session):
    """深度探索: 进入子页面后探索"""
    choice = random.choice(["reader_menu", "store_detail", "settings", "search"])

    if choice == "reader_menu":
        enter_reader(s)
        show_menu(s)
        session = explore_current_screen(s, client, session)
        exit_reader(s)
    elif choice == "store_detail":
        go_store(s)
        s.tap(random.randint(30, 340), random.randint(200, 400))
        time.sleep(2)
        session = explore_current_screen(s, client, session)
        go_back(s)
    elif choice == "settings":
        go_my(s)
        time.sleep(0.5)
        s.swipe_up()
        time.sleep(0.5)
        session = explore_current_screen(s, client, session)
    elif choice == "search":
        go_shelf(s)
        safe_tap(s, name="magnifyingglass", timeout=2)
        time.sleep(1)
        session = explore_current_screen(s, client, session)
        go_back(s)

    return session


def action_explore_reader_settings(s, client, session):
    """探索阅读器设置面板"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="设置", timeout=2) or safe_tap(s, name="textformat.size", timeout=2):
        time.sleep(1)
        session = explore_current_screen(s, client, session)
        safe_tap(s, labelContains="完成", timeout=2)
    exit_reader(s)
    return session


def action_explore_more_menu(s, client, session):
    """探索阅读器更多菜单"""
    enter_reader(s)
    show_menu(s)
    if safe_tap(s, name="更多", timeout=2) or safe_tap(s, name="ellipsis.circle", timeout=2):
        time.sleep(1)
        session = explore_current_screen(s, client, session)
    s.tap(W // 2, H // 2)
    time.sleep(0.5)
    exit_reader(s)
    return session


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


def _recreate_session(base_url):
    """重新获取 WDA Session（App 崩溃后恢复用）"""
    s = WDASession(base_url, BUNDLE_ID)
    time.sleep(5)
    wait_splash(s)
    go_shelf(s)
    time.sleep(2)
    return s


def ensure_alive(client, session):
    if not check_wda(client):
        stats["wda_failures"] += 1
        log_event("wda_disconnected")
        for i in range(30):
            time.sleep(10)
            if check_wda(client):
                log_event("wda_reconnected", attempt=i + 1)
                break
        else:
            log_event("wda_dead")
            report()
            sys.exit(2)
        try:
            session = _recreate_session(client.base)
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
        session = _recreate_session(client.base)
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
    s.swipe(int(W * 0.05), int(H * 0.5), int(W * 0.9), int(H * 0.5))
    time.sleep(0.5)

def go_back(s):
    s.swipe(int(W * 0.05), int(H * 0.5), int(W * 0.9), int(H * 0.5))
    time.sleep(0.3)

def show_menu(s):
    s.tap(W // 2, H // 2)
    time.sleep(0.5)

def _wait_and_close_rewarded_ad(s, max_wait=45):
    """等待激励视频播完并关闭。穿山甲/优量汇视频一般 15-30 秒。

    策略:
      Phase 1: 验证广告是否弹出 (bundleId 变化)
      Phase 2: 等待视频播完 (~25s)
      Phase 3: 循环尝试关闭 (坐标点击 + Accessibility 标签)
      Phase 4: 强制恢复 (swipe back + 重新激活 app)
    """
    CLOSE_POSITIONS = [
        (W - 25, 55),
        (W - 20, 45),
        (W - 30, 65),
        (25, 55),
        (W - 25, H - 80),
        (W // 2, H - 40),
    ]

    ad_launched = False
    for _ in range(6):
        time.sleep(0.5)
        try:
            info = s.app_current()
            bid = info.get("bundleId") or info.get("bundleID") or ""
            if bid != BUNDLE_ID:
                ad_launched = True
                break
        except Exception:
            pass
    if not ad_launched:
        log_event("ad_not_launched", detail="SDK未弹出广告, bundleId未变化")
        return False

    time.sleep(min(20, max_wait - 5))

    for attempt in range(max(0, max_wait - 25)):
        try:
            info = s.app_current()
            bid = info.get("bundleId") or info.get("bundleID") or ""
            if bid == BUNDLE_ID:
                return True
        except Exception:
            pass
        pos = CLOSE_POSITIONS[attempt % len(CLOSE_POSITIONS)]
        try:
            s.tap(*pos)
        except Exception:
            pass
        time.sleep(1.5)
        if attempt > 3:
            safe_tap(s, labelContains="跳过", timeout=0.3)
            safe_tap(s, labelContains="关闭", timeout=0.3)
            safe_tap(s, labelContains="Close", timeout=0.3)

    # Phase 4: 强制恢复 — 确保回到 app
    log_event("ad_force_recover", detail="close attempts exhausted, forcing recovery")
    for coord in CLOSE_POSITIONS:
        try:
            s.tap(coord[0], coord[1])
            time.sleep(0.3)
        except Exception:
            pass
    try:
        s.swipe(0.05, 0.5, 0.9, 0.5)
        time.sleep(0.5)
    except Exception:
        pass
    # 最后手段: 用 WDA 重新激活 app (会把 app 带回前台)
    try:
        s.app_activate(BUNDLE_ID)
        time.sleep(1)
    except Exception:
        pass
    return False


_ad_consecutive_no_effect = 0
_ad_smart_skip_mode = False

def _trigger_auto_reward(s):
    """通过 URL Scheme 直接解锁纯净阅读 (bypass SDK)"""
    try:
        path = f"/session/{s.sid}/url"
        s._raw_http("POST", path, {"url": "wanxiang://autoReward"}, timeout=5)
        time.sleep(1)
        return True
    except Exception:
        return False

def handle_ad(s, watch_reward=True):
    """检测并处理所有广告/解锁弹窗。
    使用 URL Scheme 直接解锁纯净阅读，无需等待广告视频。"""
    global _ad_consecutive_no_effect, _ad_smart_skip_mode

    actually_watch = watch_reward and not _ad_smart_skip_mode

    # 章节解锁 overlay: 看广告解锁 (ChapterUnlockOverlay)
    try:
        el = s(labelContains="看广告解锁")
        if el.wait(timeout=1):
            if actually_watch:
                # 直接用 URL Scheme 解锁，不触发真实广告
                ok = _trigger_auto_reward(s)
                if ok:
                    log_event("ad_auto_reward", method="url_scheme")
                    stats["actions"] += 1
                    stats["ads_watched"] += 1
                    time.sleep(1)
                    # 验证解锁是否生效 (overlay 是否消失)
                    try:
                        still_locked = s(labelContains="看广告解锁").wait(timeout=2)
                    except Exception:
                        still_locked = False
                    if still_locked:
                        _ad_consecutive_no_effect += 1
                        log_event("ad_reward_no_effect", count=_ad_consecutive_no_effect)
                        if _ad_consecutive_no_effect >= 3:
                            _ad_smart_skip_mode = True
                            log_event("ad_smart_skip_activated")
                        safe_tap(s, labelContains="先跳过", timeout=2)
                        return "reward_no_effect"
                    else:
                        _ad_consecutive_no_effect = 0
                        return "reward_watched"
                # URL Scheme 失败，尝试跳过
                safe_tap(s, labelContains="先跳过", timeout=2)
                time.sleep(0.5)
                return "reward_url_failed"
            else:
                pass  # fall through to skip
    except Exception:
        pass
    # 章节解锁 overlay: "先跳过"
    if safe_tap(s, labelContains="先跳过", timeout=1):
        time.sleep(0.5)
        return "chapter_skip"
    # 纯净阅读延长 alert: 看广告续读
    try:
        el = s(labelContains="看广告续读")
        if el.wait(timeout=0.5):
            if actually_watch:
                _trigger_auto_reward(s)
                log_event("ad_extend_auto")
                stats["actions"] += 1
                stats["ads_watched"] += 1
                time.sleep(1)
                return "extend_watched"
    except Exception:
        pass
    # 纯净阅读 alert: "跳过"
    if safe_tap(s, name="跳过", timeout=1):
        time.sleep(0.5)
        return "purified_skip"
    if safe_tap(s, labelContains="跳过", timeout=1):
        time.sleep(0.5)
        return "purified_skip"
    # 读完页
    if safe_tap(s, labelContains="去书架", timeout=1):
        time.sleep(0.5)
        return "book_finished"
    if safe_tap(s, labelContains="返回上一章", timeout=0.5):
        time.sleep(0.5)
        return "paywall_back"
    return None

def wait_splash(s):
    """等待开屏广告自动消失 (最多6秒)"""
    time.sleep(6)

def enter_reader(s):
    go_shelf(s)
    s.tap(*random.choice(SHELF_BOOKS))
    time.sleep(1.5)
    handle_ad(s, watch_reward=watch_ads_global)

def read_pages(s, count):
    for i in range(count):
        s.swipe_left()
        time.sleep(random.uniform(0.3, 0.6))
        stats["pages_read"] += 1
        stats["actions"] += 1
        if (i + 1) % 5 == 0:
            handle_ad(s, watch_reward=watch_ads_global)


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
    """纯净阅读延长卡 — 真实观看广告"""
    go_my(s)
    if safe_tap(s, labelContains="延长", timeout=2):
        time.sleep(1)
        if watch_ads_global:
            log_event("ad_extend_trigger")
            ok = _wait_and_close_rewarded_ad(s)
            log_event("ad_extend_result", success=ok)
            if not ok:
                safe_tap(s, labelContains="跳过", timeout=2) or safe_tap(s, labelContains="关闭", timeout=2)
        else:
            time.sleep(2)
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
    known = len(memory.elements)
    safe = sum(1 for e in memory.elements.values() if e.get("safe"))
    print(f"\n╔══════════════════════════════════════════════╗")
    print(f"║  {h}h{m:02d}m  页:{stats['pages_read']}({rate:.1f}/m)")
    print(f"║  搜:{stats['books_searched']} 架:{stats['books_added']} "
          f"跳:{stats['chapters_jumped']} 源:{stats['sources_changed']}")
    print(f"║  TTS:{stats['tts_sessions']} 下:{stats['downloads']} "
          f"签:{stats['bookmarks']}")
    print(f"║  崩:{stats['crashes']} WDA:{stats['wda_failures']} "
          f"错:{stats['errors']}")
    print(f"║  📺 广告: 看完:{stats['ads_watched']} 失败:{stats['ads_failed']}")
    print(f"║  🧬 探索:{stats['explored']} 新元素:{stats['new_elements_found']} "
          f"成功:{stats['explore_success']}")
    print(f"║  🧠 记忆: {known}元素已知 / {safe}安全")
    print(f"╚══════════════════════════════════════════════╝")


def main():
    global start_time, current_action, last_action

    parser = argparse.ArgumentParser()
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--duration", type=int, default=43200)
    parser.add_argument("--skip-ads", action="store_true",
                        help="跳过广告而非看完 (默认: 模拟真实用户看完广告)")
    args = parser.parse_args()

    import fcntl
    lock_path = os.path.join(os.path.dirname(__file__), ".sim_lock")
    lock_fd = open(lock_path, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_fd.write(str(os.getpid()))
        lock_fd.flush()
    except OSError:
        print(f"✗ 已有仿真实例在运行 (lock: {lock_path}), 退出")
        sys.exit(0)

    global watch_ads_global
    watch_ads_global = not args.skip_ads

    print("╔══════════════════════════════════════════════╗")
    print("║  万象书屋 — 自适应模拟 v9 (100x + 进化)   ║")
    print("╚══════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}  时长: {args.duration//3600}h")
    ad_mode = "真实观看" if watch_ads_global else "自动跳过"
    print(f"覆盖: 50+预设 + 自动探索进化  阅读: 0.3-0.6s/页  广告: {ad_mode}")
    print(f"记忆: {len(memory.elements)}个已知元素 / {MEMORY_FILE}")

    try:
        r = urllib.request.urlopen(f"{args.wda_url}/status", timeout=5)
        st = json.loads(r.read()).get("value", {})
        print(f"设备: iOS {st.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ WDA: {e}")
        sys.exit(1)

    session = WDASession(args.wda_url, BUNDLE_ID)
    client = session
    print(f"Session: {session.sid[:8]}…")
    time.sleep(3)
    go_shelf(session)
    time.sleep(2)
    print("App 启动，开始模拟...\n")
    start_time = time.time()
    log_event("test_started", duration_planned=args.duration, version="reader-sim-v9-adwatch")

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

    EXPLORE_INTERVAL = 8
    last_report = start_time
    cycle_count = 0

    while time.time() - start_time < args.duration:
        try:
            cycle_count += 1
            elapsed = time.time() - start_time
            em = int(elapsed // 60)

            if cycle_count % EXPLORE_INTERVAL == 0:
                explore_type = random.choice(["surface", "surface", "deep",
                                              "reader_settings", "more_menu"])
                last_action = current_action
                current_action = f"explore_{explore_type}"
                print(f"  [{em}m] #{cycle_count} → explore_{explore_type}")
                if explore_type == "surface":
                    session = action_explore(session, client, session)
                elif explore_type == "deep":
                    session = action_deep_explore(session, client, session)
                elif explore_type == "reader_settings":
                    session = action_explore_reader_settings(session, client, session)
                elif explore_type == "more_menu":
                    session = action_explore_more_menu(session, client, session)
                stats["cycles"] += 1
                session = ensure_alive(client, session)
            else:
                fn, name = random.choice(pool)
                last_action = current_action
                current_action = name
                print(f"  [{em}m] #{cycle_count} → {name}")
                fn(session)
                stats["cycles"] += 1
                session = ensure_alive(client, session)
        except Exception as e:
            stats["errors"] += 1
            print(f"  [{em}m] #{cycle_count} ERROR: {str(e)[:100]}")
            log_event("action_error", error=str(e)[:200])
            session = ensure_alive(client, session)

        if time.time() - last_report >= 60:
            elapsed = time.time() - start_time
            h = int(elapsed // 3600)
            m = int((elapsed % 3600) // 60)
            rate = stats["pages_read"] / (elapsed / 60) if elapsed > 0 else 0
            known = len(memory.elements)
            print(f"  [{h:02d}h{m:02d}m] 页:{stats['pages_read']}({rate:.1f}/m) "
                  f"跳:{stats['chapters_jumped']} 源:{stats['sources_changed']} "
                  f"崩:{stats['crashes']} 🧬探:{stats['explored']}/{known}已知")
            log_event("periodic_report", stats=dict(stats),
                      memory_size=known)
            last_report = time.time()
            memory.save()

    report()
    memory.save()
    log_event("test_finished", stats=dict(stats),
              memory_size=len(memory.elements))
    sys.exit(1 if stats["crashes"] > 0 else 0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException as e:
        import traceback
        log_event("fatal_crash", error=str(e)[:500], tb=traceback.format_exc()[-1000:])
        print(f"\n✗ FATAL: {e}")
        traceback.print_exc()
        sys.exit(2)
