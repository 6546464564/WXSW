#!/usr/bin/env python3
"""专项测试: 未覆盖操作各 100 遍 (独立版)"""
import sys, os, time, json, urllib.request, random

W, H = 375, 667
TAB_SHELF_X, TAB_STORE_X, TAB_MY_X, TAB_Y = 67, 187, 308, 640
WDA_URL = "http://192.168.88.166:8100"
BUNDLE_ID = "com.wanxiang.reader"
REPS = 100

class WDA:
    def __init__(self):
        r = urllib.request.urlopen(f"{WDA_URL}/wda/locked", timeout=5)
        d = json.loads(r.read())
        self.sid = d.get("sessionId")
        print(f"Session: {self.sid[:8]}…")

    def _http(self, method, path, data=None, timeout=10):
        url = f"{WDA_URL}{path}"
        body = json.dumps(data).encode() if data else None
        req = urllib.request.Request(url, data=body, method=method,
                                    headers={"Content-Type": "application/json"})
        r = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(r.read())

    def tap(self, x, y):
        self._http("POST", f"/session/{self.sid}/wda/tap", {"x": x, "y": y})

    def swipe_up(self):
        self._http("POST", f"/session/{self.sid}/wda/dragfromtoforduration",
                   {"fromX": W//2, "fromY": 500, "toX": W//2, "toY": 200, "duration": 0.3})

    def find_tap(self, label=None, name=None, timeout=1.5):
        """尝试找到并点击元素"""
        import time as _t
        end = _t.time() + timeout
        while _t.time() < end:
            try:
                if label:
                    pred = f"label CONTAINS '{label}'"
                elif name:
                    pred = f"name == '{name}'"
                else:
                    return False
                r = self._http("POST", f"/session/{self.sid}/elements",
                               {"using": "predicate string", "value": pred}, timeout=5)
                elems = r.get("value", [])
                if elems:
                    eid = elems[0].get("ELEMENT") or elems[0].get("element-6066-11e4-a52e-4f735466cecf")
                    self._http("POST", f"/session/{self.sid}/element/{eid}/click")
                    return True
            except Exception:
                pass
            _t.sleep(0.3)
        return False

    def app_current(self):
        r = self._http("GET", f"/session/{self.sid}/wda/activeAppInfo")
        return r.get("value", {})

s = None
crashes = 0

def go_shelf():
    s.tap(TAB_SHELF_X, TAB_Y)
    time.sleep(0.3)

def go_my():
    s.tap(TAB_MY_X, TAB_Y)
    time.sleep(0.3)

def go_store():
    s.tap(TAB_STORE_X, TAB_Y)
    time.sleep(0.3)

def go_back():
    s.tap(20, 55)
    time.sleep(0.3)

def check_alive():
    global crashes
    try:
        info = s.app_current()
        bid = info.get("bundleId") or info.get("bundleID", "")
        if bid != BUNDLE_ID:
            crashes += 1
            print(f"  ⚠ CRASH #{crashes} (current={bid})")
            # relaunch
            s._http("POST", f"/session/{s.sid}/wda/apps/launch", {"bundleId": BUNDLE_ID}, timeout=15)
            time.sleep(3)
    except Exception:
        pass

# ─── 操作定义 ───
def fast_eye_care():
    go_my()
    s.find_tap(label="护眼模式", timeout=1.5)
    time.sleep(0.5)
    s.find_tap(label="护眼模式", timeout=1.5)
    time.sleep(0.3)

def fast_follow_sys():
    go_my()
    s.find_tap(label="跟随系统", timeout=1.5)
    time.sleep(0.5)
    s.find_tap(label="跟随系统", timeout=1.5)
    time.sleep(0.3)

def fast_purify_ext():
    go_my()
    s.find_tap(label="延长", timeout=1.5)
    time.sleep(0.5)
    s.find_tap(label="跳过", timeout=1) or s.find_tap(label="关闭", timeout=0.5)
    time.sleep(0.3)

def fast_dl_ops():
    go_my()
    if s.find_tap(name="my.row.download_manage", timeout=1.5):
        time.sleep(0.5)
        s.find_tap(label="重试", timeout=1)
        time.sleep(0.3)
        go_back()

def fast_dl_manage():
    go_my()
    s.find_tap(name="my.row.download_manage", timeout=1.5)
    time.sleep(0.5)
    s.swipe_up()
    time.sleep(0.3)
    go_back()

def fast_complete_lib():
    go_store()
    s.swipe_up()
    time.sleep(0.3)
    s.swipe_up()
    time.sleep(0.3)
    s.find_tap(label="完本", timeout=1.5)
    time.sleep(0.8)
    go_back()
    time.sleep(0.3)

ACTIONS = [
    (fast_eye_care, "eye_care"),
    (fast_follow_sys, "follow_sys"),
    (fast_purify_ext, "purify_ext"),
    (fast_dl_ops, "dl_ops"),
    (fast_dl_manage, "dl_manage"),
    (fast_complete_lib, "complete_lib"),
]

def main():
    global s
    s = WDA()
    time.sleep(1)
    go_shelf()
    time.sleep(1)
    print(f"开始: {len(ACTIONS)} 操作 × {REPS} 遍\n")
    sys.stdout.flush()

    results = {}
    for fn, name in ACTIONS:
        ok = err = 0
        t0 = time.time()
        for i in range(REPS):
            try:
                fn()
                ok += 1
            except Exception as e:
                err += 1
            check_alive()
            if (i + 1) % 25 == 0:
                print(f"  {name} {i+1}/{REPS} ✓{ok} ✗{err} ({time.time()-t0:.0f}s)")
                sys.stdout.flush()
        results[name] = {"ok": ok, "err": err}
        print(f"✓ {name}: {ok}/{REPS} ({time.time()-t0:.0f}s)\n")
        sys.stdout.flush()

    print("=" * 40)
    print("结果汇总:")
    all_ok = True
    for name, r in results.items():
        st = "✓" if r["err"] == 0 else "✗"
        print(f"  {st} {name}: {r['ok']}/{REPS} (错误: {r['err']})")
        if r["err"] > 0: all_ok = False
    print(f"\n崩溃: {crashes}")
    print(f"总结: {'全部通过 ✓' if all_ok else '有错误 ✗'}")
    sys.stdout.flush()

if __name__ == "__main__":
    main()
