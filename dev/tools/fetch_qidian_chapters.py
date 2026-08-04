import subprocess
import re
import json
import time
import sys

sys.stdout.reconfigure(line_buffering=True)

with open('/tmp/qidian_book_ids.json', 'r') as f:
    books = json.load(f)

print(f'需要获取 {len(books)} 本书的章节数')

def fetch_chapter_count(book_id):
    url = f"https://www.qidian.com/book/{book_id}/"
    script = f'''
    tell application "Safari"
        set URL of document 1 to "{url}"
        delay 5
        set pageSource to source of document 1
        return pageSource
    end tell
    '''
    try:
        result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            return None
        html = result.stdout
        m = re.search(r'共(\d+)章', html)
        if m:
            return int(m.group(1))
        m = re.search(r'已更新(\d+)章', html)
        if m:
            return int(m.group(1))
        return None
    except Exception:
        return None

results = []
for i, book in enumerate(books):
    count = fetch_chapter_count(book['book_id'])
    book['qidian_chapters'] = count
    results.append(book)
    status = f"#{count}" if count else "FAIL"
    print(f'[{i+1}/{len(books)}] {book["title"]} - {status}')

    if (i + 1) % 50 == 0:
        with open('/tmp/qidian_chapters_partial.json', 'w') as f:
            json.dump(results, f, ensure_ascii=False, indent=2)

    time.sleep(1)

with open('/Users/stark/Desktop/WXSW/qidian_chapters_remaining.json', 'w') as f:
    json.dump(results, f, ensure_ascii=False, indent=2)

ok = sum(1 for r in results if r.get('qidian_chapters'))
print(f'\n完成: {ok}/{len(results)} 成功获取章节数')
print('Done!')
