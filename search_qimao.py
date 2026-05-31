import json
import time
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

sys.stdout.reconfigure(line_buffering=True)

API_BASE = 'http://140.143.165.56/searchNovel'

def search_book(title, author):
    try:
        resp = requests.get(API_BASE, params={'title': title}, timeout=15)
        data = resp.json()
        if data.get('code') != 0:
            return None

        books = data.get('data', {}).get('book_data', [])
        qimao_books = [b for b in books if '七猫' in str(b.get('source', '')) or '七猫' in str(b.get('media', ''))]

        for b in qimao_books:
            b_title = (b.get('book_name') or '').strip()
            b_author = (b.get('author') or '').strip()
            if b_title == title and b_author == author:
                qid = str(b.get('book_id', '')).replace('_qimao', '')
                return {
                    'qimao_id': qid,
                    'title': b_title,
                    'author': b_author,
                    'status': b.get('status', ''),
                    'word_count': b.get('word_number', ''),
                    'match': 'exact',
                }
        for b in qimao_books:
            b_title = (b.get('book_name') or '').strip()
            if b_title == title:
                qid = str(b.get('book_id', '')).replace('_qimao', '')
                return {
                    'qimao_id': qid,
                    'title': b_title,
                    'author': (b.get('author') or '').strip(),
                    'status': b.get('status', ''),
                    'word_count': b.get('word_number', ''),
                    'match': 'title_only',
                    'expected_author': author,
                }
    except Exception as e:
        return {'error': str(e)}
    return None

with open('/tmp/qidian_diff.json', 'r', encoding='utf-8') as f:
    diff_books = json.load(f)

print(f'待搜索: {len(diff_books)} 本', flush=True)

found = []
not_found = []
errors = []
lock = Lock()
done = [0]

def process(book):
    title = book['title']
    author = book['author']
    result = search_book(title, author)
    with lock:
        done[0] += 1
        if done[0] % 100 == 0:
            print(f'  进度: {done[0]}/{len(diff_books)}, 找到: {len(found)}', flush=True)
    if result and 'error' not in result:
        result['qidian_rankings'] = book.get('rankings', {})
        result['qidian_book_id'] = book.get('book_id', '')
        result['qidian_category'] = book.get('category', '')
        with lock:
            found.append(result)
    elif result and 'error' in result:
        with lock:
            errors.append({'title': title, 'author': author, 'error': result['error']})
    else:
        with lock:
            not_found.append({'title': title, 'author': author, 'qidian_book_id': book.get('book_id', '')})

with ThreadPoolExecutor(max_workers=10) as pool:
    futures = [pool.submit(process, b) for b in diff_books]
    for f in as_completed(futures):
        pass

print(f'\n===== 结果 =====')
print(f'  找到: {len(found)} 本')
print(f'  未找到: {len(not_found)} 本')
print(f'  错误: {len(errors)} 本')

exact = [b for b in found if b.get('match') == 'exact']
title_only = [b for b in found if b.get('match') == 'title_only']
print(f'  精确匹配(标题+作者): {len(exact)} 本')
print(f'  仅标题匹配: {len(title_only)} 本')

output = {
    'found': found,
    'not_found': not_found,
    'errors': errors,
    'stats': {
        'total_searched': len(diff_books),
        'found': len(found),
        'exact_match': len(exact),
        'title_only_match': len(title_only),
        'not_found': len(not_found),
        'errors': len(errors),
    }
}

out_path = '/Users/stark/Desktop/WXSW/qimao_search_results.json'
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(output, f, ensure_ascii=False, indent=2)

print(f'\n保存到: {out_path}')

found_sorted = sorted(found, key=lambda x: x.get('qidian_rankings', {}).get('人气排序', 9999))
print(f'\n七猫可下载 TOP 30 (按起点人气):')
for i, b in enumerate(found_sorted[:30]):
    ranks = ', '.join(f'{k}#{v}' for k, v in b.get('qidian_rankings', {}).items())
    mm = f' [仅标题,七猫作者:{b["author"]}]' if b.get('match') == 'title_only' else ''
    print(f'  {i+1}. {b["title"]} - {b.get("expected_author", b["author"])} (七猫ID:{b["qimao_id"]}){mm} ({ranks})')

print('\nDone!')
