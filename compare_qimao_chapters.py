import hashlib
import urllib.parse
import json
import re
import time
import os
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

sys.stdout.reconfigure(line_buffering=True)

SIGN_KEY = 'd3dGiJc651gSQ8w1'
HEADERS_TEMPLATE = {
    'app-version': '51110',
    'platform': 'android',
    'reg': '0',
    'AUTHORIZATION': '',
    'application-id': 'com.****.reader',
    'net-env': '1',
    'channel': 'unknown',
    'qm-params': ''
}

DB_PATH = '/Users/stark/Desktop/WXSW/backend/data/wanxiang.db'


def calculate_md5_signature(params):
    sorted_params = ''.join(sorted([n + '=' + str(params[n]) for n in params]))
    return hashlib.md5((sorted_params + SIGN_KEY).encode()).hexdigest()


def generate_request(url, params):
    headers = HEADERS_TEMPLATE.copy()
    param_sign = calculate_md5_signature(params)
    headers_sign = calculate_md5_signature(headers)
    params['sign'] = param_sign
    headers['sign'] = headers_sign
    body = urllib.parse.urlencode(params)
    final_url = url + "?" + body
    headers_json = json.dumps({"headers": headers})
    headers['headers'] = headers_json
    return final_url, headers


def fetch_online_chapter_count(qimao_id):
    try:
        list_url = "https://api-ks.wtzw.com/api/v1/chapter/chapter-list"
        list_params = {'id': qimao_id}
        list_req_url, list_headers = generate_request(list_url, list_params)
        resp = requests.get(list_req_url, headers=list_headers, timeout=15).json()
        chapters = ((resp.get('data') or {}).get('chapter_lists') or [])
        return len(chapters)
    except Exception as e:
        return -1


print_lock = Lock()
results = []
results_lock = Lock()


def check_book(book, db_counts, total, idx_holder):
    title = book['title']
    author = book['author']
    qimao_id = book['qimao_id']

    db_key = f"{title}|{author}"
    db_count = db_counts.get(db_key, -1)

    online_count = fetch_online_chapter_count(qimao_id)

    with idx_holder['lock']:
        idx_holder['done'] += 1
        done = idx_holder['done']

    diff = db_count - online_count if db_count >= 0 and online_count >= 0 else None
    status = "OK" if diff is not None and abs(diff) <= 2 else "DIFF" if diff is not None else "ERR"

    result = {
        'title': title, 'author': author, 'qimao_id': qimao_id,
        'online': online_count, 'db': db_count, 'diff': diff, 'status': status
    }

    with results_lock:
        results.append(result)

    if status != "OK":
        with print_lock:
            print(f"[{done}/{total}] {status} {title} | 在线:{online_count} 本地:{db_count} 差:{diff}")
    elif done % 50 == 0:
        with print_lock:
            print(f"[{done}/{total}] 已检查...")


def main():
    import sqlite3
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT title, author, cached_chapters FROM cached_books").fetchall()
    db_counts = {f"{r['title']}|{r['author']}": r['cached_chapters'] for r in rows}
    conn.close()
    print(f"数据库中 {len(db_counts)} 本书")

    with open('/Users/stark/Desktop/WXSW/qimao_check_result.json', 'r') as f:
        data = json.load(f)
    books = data['found']
    total = len(books)
    print(f"准备对比 {total} 本书的章节数（七猫在线 vs 本地数据库）")
    print("=" * 70)

    idx_holder = {'done': 0, 'lock': Lock()}
    start = time.time()

    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = [executor.submit(check_book, b, db_counts, total, idx_holder) for b in books]
        for f in as_completed(futures):
            pass

    elapsed = time.time() - start
    print("=" * 70)
    print(f"对比完成，耗时 {elapsed:.1f} 秒")

    ok = sum(1 for r in results if r['status'] == 'OK')
    diff = sum(1 for r in results if r['status'] == 'DIFF')
    err = sum(1 for r in results if r['status'] == 'ERR')
    print(f"匹配: {ok} | 有差异: {diff} | 错误: {err}")

    if diff > 0:
        print("\n=== 有差异的书籍 ===")
        diffs = sorted([r for r in results if r['status'] == 'DIFF'], key=lambda x: abs(x['diff'] or 0), reverse=True)
        for r in diffs:
            flag = "多" if r['diff'] > 0 else "少"
            print(f"  {r['title']} ({r['author']}) | 在线:{r['online']} 本地:{r['db']} {flag}{abs(r['diff'])}章")

    with open('/Users/stark/Desktop/WXSW/qimao_compare_result.json', 'w', encoding='utf-8') as f:
        json.dump({
            'summary': {'total': total, 'ok': ok, 'diff': diff, 'err': err},
            'details': sorted(results, key=lambda x: abs(x['diff'] or 0), reverse=True)
        }, f, ensure_ascii=False, indent=2)
    print("\n详细结果已保存到 qimao_compare_result.json")


if __name__ == '__main__':
    main()
