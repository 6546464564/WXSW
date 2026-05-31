import hashlib
import urllib.parse
import json
import re
import time
import os
import sys
import sqlite3
import requests
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock, Semaphore
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad

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
CONCURRENT_BOOKS = 10
CHAPTER_SEMAPHORE = Semaphore(80)
MAX_RETRY = 3

print_lock = Lock()
counter_lock = Lock()
counters = {'success': 0, 'failed': 0, 'done': 0, 'total_chapters': 0, 'failed_chapters': 0}


def calculate_md5_signature(params):
    sorted_params = ''.join(sorted([n + '=' + str(params[n]) for n in params]))
    return hashlib.md5((sorted_params + SIGN_KEY).encode()).hexdigest()


def strip_html(text):
    return re.sub(r"<[^>]+>", "", str(text or "")).strip()


def decode(content):
    iv_enc_data = base64.b64decode(content)
    key = b"242ccb8230d709e1"
    iv = iv_enc_data[:16]
    cipher = AES.new(key, AES.MODE_CBC, iv)
    decrypted_data = cipher.decrypt(iv_enc_data[16:])
    unpadded_data = unpad(decrypted_data, AES.block_size)
    return unpadded_data.decode('utf-8')


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


def fetch_chapter_content(book_id, chapter_id):
    CHAPTER_SEMAPHORE.acquire()
    try:
        content_url = "https://api-ks.wtzw.com/api/v1/chapter/content"
        content_params = {'chapterId': chapter_id, 'id': book_id}
        content_req_url, content_headers = generate_request(content_url, content_params)
        resp = requests.get(content_req_url, headers=content_headers, timeout=15).json()

        if 'errors' in resp:
            err_code = (resp.get('errors') or {}).get('code', '')
            if err_code == '17010104':
                content_params['reader_agent'] = 1
                content_req_url, content_headers = generate_request(content_url, content_params)
                resp = requests.get(content_req_url, headers=content_headers, timeout=15).json()
            else:
                return None

        encrypted = ((resp.get('data') or {}).get('content') or '')
        if not encrypted:
            return None
        return decode(encrypted)
    except Exception:
        return None
    finally:
        CHAPTER_SEMAPHORE.release()


def fetch_chapter_with_retry(book_id, chapter_id):
    for attempt in range(MAX_RETRY):
        result = fetch_chapter_content(book_id, chapter_id)
        if result is not None:
            return result
        if attempt < MAX_RETRY - 1:
            time.sleep(0.5 * (attempt + 1))
    return None


def get_chapter_list(qimao_id):
    list_url = "https://api-ks.wtzw.com/api/v1/chapter/chapter-list"
    list_params = {'id': qimao_id}
    list_req_url, list_headers = generate_request(list_url, list_params)
    resp = requests.get(list_req_url, headers=list_headers, timeout=15).json()
    return (resp.get('data') or {}).get('chapter_lists') or []


def import_book(book_info, total, db_lock):
    title = book_info['title']
    author = book_info['author']
    qimao_id = book_info['qimao_id']

    try:
        chapters = get_chapter_list(qimao_id)
        if not chapters:
            with counter_lock:
                counters['failed'] += 1
                counters['done'] += 1
                done = counters['done']
            with print_lock:
                print(f"[{done}/{total}] ✗ {title} - 无章节列表")
            return

        chapter_data = []
        fail_count = 0

        with ThreadPoolExecutor(max_workers=20) as executor:
            future_map = {}
            for idx, ch in enumerate(chapters):
                ch_id = str(ch.get('id') or '')
                if not ch_id:
                    continue
                f = executor.submit(fetch_chapter_with_retry, qimao_id, ch_id)
                future_map[f] = (idx, ch)

            for f in as_completed(future_map):
                idx, ch = future_map[f]
                content = f.result()
                ch_title = strip_html(ch.get('title', ''))
                if content:
                    chapter_data.append((idx, ch_title, content))
                else:
                    fail_count += 1

        chapter_data.sort(key=lambda x: x[0])

        now = int(time.time() * 1000)
        with db_lock:
            conn = sqlite3.connect(DB_PATH, timeout=30)
            try:
                conn.execute("BEGIN")
                cursor = conn.execute(
                    "INSERT INTO cached_books (title, author, category, total_chapters, cached_chapters, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'done', ?, ?)",
                    (title, author, book_info.get('category', ''), len(chapters), len(chapter_data), now, now)
                )
                book_id = cursor.lastrowid

                for idx, ch_title, content in chapter_data:
                    word_count = len(content)
                    conn.execute(
                        "INSERT INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at) VALUES (?, ?, ?, ?, ?, 'done', ?)",
                        (book_id, idx, ch_title, content, word_count, now)
                    )
                conn.commit()
            except Exception as e:
                conn.rollback()
                raise e
            finally:
                conn.close()

        with counter_lock:
            counters['success'] += 1
            counters['done'] += 1
            counters['total_chapters'] += len(chapter_data)
            counters['failed_chapters'] += fail_count
            done = counters['done']

        status = f"✓ {title} - {len(chapter_data)}/{len(chapters)}章"
        if fail_count > 0:
            status += f" (失败{fail_count}章)"
        with print_lock:
            print(f"[{done}/{total}] {status}")

    except Exception as e:
        with counter_lock:
            counters['failed'] += 1
            counters['done'] += 1
            done = counters['done']
        with print_lock:
            print(f"[{done}/{total}] ✗ {title} - 错误: {str(e)[:80]}")


def main():
    with open('/Users/stark/Desktop/WXSW/qimao_check_result.json', 'r') as f:
        data = json.load(f)

    books = data['found']
    total = len(books)

    conn = sqlite3.connect(DB_PATH)
    existing = set(r[0] for r in conn.execute("SELECT title FROM cached_books").fetchall())
    conn.close()

    to_import = [b for b in books if b['title'] not in existing]
    skipped = total - len(to_import)
    if skipped > 0:
        print(f"跳过 {skipped} 本已存在的书")
    total_to_do = len(to_import)

    print(f"准备从七猫 API 直接导入 {total_to_do} 本书到数据库")
    print(f"并发: {CONCURRENT_BOOKS} 本 × 20章/本, 章节限流: {CHAPTER_SEMAPHORE._value}")
    print(f"每章最多重试 {MAX_RETRY} 次")
    print("=" * 70)

    db_lock = Lock()
    start = time.time()

    with ThreadPoolExecutor(max_workers=CONCURRENT_BOOKS) as executor:
        futures = [executor.submit(import_book, b, total_to_do, db_lock) for b in to_import]
        for f in as_completed(futures):
            pass

    elapsed = time.time() - start
    print("=" * 70)
    print(f"全部完成！耗时: {elapsed / 60:.1f} 分钟")
    print(f"成功: {counters['success']} | 失败: {counters['failed']}")
    print(f"总章节: {counters['total_chapters']} | 失败章节: {counters['failed_chapters']}")


if __name__ == '__main__':
    main()
