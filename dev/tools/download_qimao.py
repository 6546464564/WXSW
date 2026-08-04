import hashlib
import urllib.parse
import json
import re
import time
import base64
import os
import sys
import requests
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

OUTPUT_DIR = '/Users/stark/Desktop/WXSW/七猫下载'
CONCURRENT_BOOKS = 30
CHAPTER_SEMAPHORE = Semaphore(100)

print_lock = Lock()
counter_lock = Lock()
counters = {'success': 0, 'skipped': 0, 'failed': 0, 'done': 0}


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


def fetch_chapter(book_id, chapter_id):
    CHAPTER_SEMAPHORE.acquire()
    try:
        content_url = "https://api-ks.wtzw.com/api/v1/chapter/content"
        content_params = {'chapterId': chapter_id, 'id': book_id}
        content_req_url, content_headers = generate_request(content_url, content_params)
        content_resp = requests.get(content_req_url, headers=content_headers, timeout=15).json()

        if 'errors' in content_resp:
            err_code = (content_resp.get('errors') or {}).get('code', '')
            if err_code == '17010104':
                content_params['reader_agent'] = 1
                content_req_url, content_headers = generate_request(content_url, content_params)
                content_resp = requests.get(content_req_url, headers=content_headers, timeout=15).json()
            else:
                return None

        encrypted = ((content_resp.get('data') or {}).get('content') or '')
        if not encrypted:
            return None

        return decode(encrypted)
    except Exception:
        return None
    finally:
        CHAPTER_SEMAPHORE.release()


def download_book(book_info, total):
    title = book_info['title']
    author = book_info['author']
    qimao_id = book_info['qimao_id']

    safe_name = re.sub(r'[\\/:*?"<>|]', '_', f"{title} - {author}")
    output_path = os.path.join(OUTPUT_DIR, f"{safe_name}.txt")

    if os.path.exists(output_path) and os.path.getsize(output_path) > 100:
        with counter_lock:
            counters['skipped'] += 1
            counters['done'] += 1
            done = counters['done']
        with print_lock:
            print(f"[{done}/{total}] ⏭ {title} - 已存在跳过")
        return

    try:
        list_url = "https://api-ks.wtzw.com/api/v1/chapter/chapter-list"
        list_params = {'id': qimao_id}
        list_req_url, list_headers = generate_request(list_url, list_params)
        list_resp = requests.get(list_req_url, headers=list_headers, timeout=15).json()
        chapters = ((list_resp.get('data') or {}).get('chapter_lists') or [])

        if not chapters:
            with counter_lock:
                counters['failed'] += 1
                counters['done'] += 1
                done = counters['done']
            with print_lock:
                print(f"[{done}/{total}] ✗ {title} - 无章节")
            return

        parts = [f"书名：{title}", f"作者：{author}", ""]

        ok_count = 0
        std_pattern = re.compile(r'^第[零一二三四五六七八九十百千万〇\d]+[章节回卷]')
        for idx, ch in enumerate(chapters, 1):
            chapter_id = str(ch.get('id') or '')
            if not chapter_id:
                continue
            chapter_text = fetch_chapter(qimao_id, chapter_id)
            if chapter_text:
                ch_title = strip_html(ch.get('title', ''))
                if not std_pattern.match(ch_title):
                    ch_title = f"第{idx}章 {ch_title}"
                parts.append(ch_title)
                parts.append("")
                parts.append(chapter_text)
                parts.append("")
                ok_count += 1

        with open(output_path, 'w', encoding='utf-8') as f:
            f.write("\n".join(parts))

        with counter_lock:
            counters['success'] += 1
            counters['done'] += 1
            done = counters['done']
        with print_lock:
            print(f"[{done}/{total}] ✓ {title} - ok({ok_count}/{len(chapters)}章)")

    except Exception as e:
        with counter_lock:
            counters['failed'] += 1
            counters['done'] += 1
            done = counters['done']
        with print_lock:
            print(f"[{done}/{total}] ✗ {title} - 错误: {str(e)[:60]}")


def main():
    with open('/Users/stark/Desktop/WXSW/qimao_check_result.json', 'r') as f:
        data = json.load(f)

    found_books = data['found']
    total = len(found_books)
    print(f"准备下载 {total} 本书到 {OUTPUT_DIR}")
    print(f"并发: {CONCURRENT_BOOKS} 本同时下载, 最多 {CHAPTER_SEMAPHORE._value} 个并发请求")
    print("=" * 60)

    start_time = time.time()

    with ThreadPoolExecutor(max_workers=CONCURRENT_BOOKS) as executor:
        futures = [executor.submit(download_book, book, total) for book in found_books]
        for future in as_completed(futures):
            pass

    elapsed = time.time() - start_time
    print("=" * 60)
    print(f"全部完成！耗时: {elapsed/60:.1f} 分钟")
    print(f"成功: {counters['success']} | 跳过: {counters['skipped']} | 失败: {counters['failed']}")


if __name__ == '__main__':
    main()
