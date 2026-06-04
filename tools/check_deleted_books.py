import subprocess
import re
import json
import time
import sys

sys.stdout.reconfigure(line_buffering=True)

with open('/tmp/deleted_check.json', 'r') as f:
    books = json.load(f)

print(f'检查 {len(books)} 本已删除的书...')
print()

results = []
for i, b in enumerate(books):
    url = f'https://www.qidian.com/book/{b["book_id"]}/'
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
        html = result.stdout
        ch = re.findall(r'章节字数：\d+">([^<]+)<', html)
        non_text = len([c for c in ch if not c.strip().startswith('第')])
        text_only = len(ch) - non_text
    except:
        ch = []
        non_text = 0
        text_only = 0

    pct_text = round(b['qimao'] / text_only * 100, 1) if text_only > 0 else 0
    status = '✓' if pct_text >= 90 else '✗'

    print(f'[{i+1}/{len(books)}] {status} {b["title"]}: '
          f'起点总={len(ch)} 非正文={non_text} 正文={text_only} '
          f'七猫={b["qimao"]} 正文率={pct_text}%')

    results.append({
        'title': b['title'],
        'qidian_total': len(ch),
        'non_text': non_text,
        'text_only': text_only,
        'qimao': b['qimao'],
        'pct_total': round(b['qimao'] / b['qidian'] * 100, 1) if b['qidian'] > 0 else 0,
        'pct_text': pct_text,
    })
    time.sleep(1)

print()
print('=== 汇总 ===')
really_missing = [r for r in results if r['pct_text'] < 90]
maybe_ok = [r for r in results if r['pct_text'] >= 90]
print(f'正文完整率>=90%（不该删）: {len(maybe_ok)}')
for r in maybe_ok:
    print(f'  {r["title"]}: {r["pct_text"]}% (七猫{r["qimao"]}/正文{r["text_only"]})')
print(f'正文完整率<90%（确实缺失）: {len(really_missing)}')
for r in really_missing:
    print(f'  {r["title"]}: {r["pct_text"]}% (七猫{r["qimao"]}/正文{r["text_only"]})')

with open('/tmp/deleted_check_results.json', 'w') as f:
    json.dump(results, f, ensure_ascii=False, indent=2)

print('\nDone!')
