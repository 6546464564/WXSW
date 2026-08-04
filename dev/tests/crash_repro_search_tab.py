#!/usr/bin/env python3
"""专门复现 search → switch_tabs 崩溃的压力测试"""
import sys, time, random, json, os
sys.stdout.reconfigure(line_buffering=True)
sys.path.insert(0, "/Users/stark/airtest-env/lib/python3.14/site-packages")
import wda

WDA_URL = "http://192.168.88.166:8100"
BUNDLE_ID = "com.wanxiang.reader"
LOG_FILE = os.path.join(os.path.dirname(__file__), "crash_repro_log.jsonl")

def log(msg, **kw):
    entry = {"ts": time.strftime("%H:%M:%S"), "msg": msg, **kw}
    print(f"[{entry['ts']}] {msg}")
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

def app_alive(client, session):
    try:
        session.app_current()
        return session
    except:
        try:
            session = client.session(BUNDLE_ID)
            time.sleep(2)
            return session
        except:
            return None

def main():
    client = wda.Client(WDA_URL)
    try:
        status = client.status()
        print(f"WDA connected. iOS {status.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"Cannot connect WDA: {e}")
        sys.exit(1)

    session = client.session(BUNDLE_ID)
    time.sleep(3)
    log("App started")

    crashes = 0
    iterations = 0
    keywords = ["修仙", "都市", "玄幻", "穿越", "系统", "重生", "武侠", "科幻"]

    for i in range(100):
        iterations += 1
        kw = random.choice(keywords)
        log(f"iter {i+1}: search '{kw}' then switch tab")

        # 1. Go to bookshelf tab
        safe_tap(session, label="书架", type="Button")
        time.sleep(1.5)

        # 2. Open search - toolbar button with label "搜索"
        found_search = False
        for attempt in range(3):
            if safe_tap(session, label="搜索", type="Button"):
                found_search = True
                break
            time.sleep(0.5)
        if not found_search:
            log("cannot find search button, skip")
            time.sleep(1)
            continue
        time.sleep(1.5)

        # 3. Type keyword and search
        tf = session(type="TextField")
        if not tf.exists:
            tf = session(type="SearchField")
        if tf.exists:
            tf.set_text(kw)
            time.sleep(0.5)
            # Submit search via keyboard return
            try:
                tf = session(type="TextField")
                if tf.exists:
                    tf.set_text(kw + "\n")
            except:
                pass
        else:
            log("cannot find text field, skip")
            # Try to go back
            safe_tap(session, label="书架", type="Button")
            time.sleep(0.5)
            continue

        # 4. Wait 2-5 seconds for search to be actively streaming
        wait_time = random.uniform(2, 5)
        time.sleep(wait_time)

        # 5. KEY ACTION: switch tab immediately while search is running
        target_tab = random.choice(["书城", "我的"])
        log(f"  switching to '{target_tab}' while searching...")
        safe_tap(session, label=target_tab, type="Button")
        time.sleep(1)

        # 6. Check if app is still alive
        session = app_alive(client, session)
        if session is None:
            crashes += 1
            log(f"CRASH DETECTED after search→switch_tabs!", crash=True, keyword=kw, target=target_tab)
            time.sleep(3)
            try:
                session = client.session(BUNDLE_ID)
                time.sleep(3)
            except:
                log("Failed to restart app")
                break
        else:
            log(f"  OK - app alive after switch")

        # 7. Quick random tab switches (stress)
        for _ in range(random.randint(1, 3)):
            safe_tap(session, label=random.choice(["书架", "书城", "我的"]), type="Button")
            time.sleep(random.uniform(0.3, 0.8))

        session = app_alive(client, session)
        if session is None:
            crashes += 1
            log(f"CRASH during rapid tab switch!", crash=True)
            time.sleep(3)
            try:
                session = client.session(BUNDLE_ID)
                time.sleep(3)
            except:
                break

    log(f"DONE: {iterations} iterations, {crashes} crashes")

if __name__ == "__main__":
    if os.path.exists(LOG_FILE):
        os.remove(LOG_FILE)
    main()
