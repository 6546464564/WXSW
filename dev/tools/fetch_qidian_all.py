import subprocess
import re
import json
import time
import sys

SORT_ORDERS = {
    "人气排序": "",
    "总收藏": "orderId11",
    "总字数": "orderId3",
    "月票": "orderId12",
}

MAX_PAGES = 50

def fetch_page(url):
    script = f'''
    tell application "Safari"
        set URL of document 1 to "{url}"
        delay 8
        set pageSource to source of document 1
        return pageSource
    end tell
    '''
    result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        return None
    return result.stdout

def extract_books(html):
    books = []
    li_blocks = re.findall(r'<li data-rid="(\d+)">(.*?)</li>', html, re.DOTALL)
    for rid, block in li_blocks:
        bid_m = re.search(r'data-bid="(\d+)"', block)
        title_m = re.search(r'<h2><a[^>]*>(.*?)</a></h2>', block, re.DOTALL)
        author_m = re.search(r'class="name"[^>]*>(.*?)</a>', block)
        cat_m = re.search(r'<em>\|</em><a[^>]*href="//www\.qidian\.com/\w+/"[^>]*>(.*?)</a>', block)
        sub_cat_m = re.search(r'go-sub-type[^>]*>(.*?)</a>', block)
        status_m = re.search(r'<span>(连载|完本)</span>', block)
        if bid_m and title_m:
            books.append({
                "rank": int(rid),
                "book_id": bid_m.group(1),
                "title": title_m.group(1).strip(),
                "author": author_m.group(1).strip() if author_m else "",
                "category": cat_m.group(1).strip() if cat_m else "",
                "sub_category": sub_cat_m.group(1).strip() if sub_cat_m else "",
                "status": status_m.group(1) if status_m else "",
            })
    return books

results = {}
for sort_name, sort_id in SORT_ORDERS.items():
    print(f"\n=== {sort_name} ===", flush=True)
    sort_books = []

    for page in range(1, MAX_PAGES + 1):
        if sort_id:
            url = f"https://www.qidian.com/all/{sort_id}/" if page == 1 else f"https://www.qidian.com/all/{sort_id}-page{page}/"
        else:
            url = "https://www.qidian.com/all/" if page == 1 else f"https://www.qidian.com/all/page{page}/"

        print(f"  [{sort_name}] page {page}/{MAX_PAGES}...", end=" ", flush=True)

        html = fetch_page(url)
        if not html:
            print("FAIL, retry...", flush=True)
            time.sleep(3)
            html = fetch_page(url)

        if html:
            books = extract_books(html)
            print(f"{len(books)} books", flush=True)
            for b in books:
                b["page"] = page
                b["global_rank"] = (page - 1) * 20 + b["rank"]
            sort_books.extend(books)
        else:
            print("FAILED", flush=True)

        time.sleep(1)

    results[sort_name] = sort_books
    print(f"  Total: {len(sort_books)} books for {sort_name}")

output = {
    "fetched_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    "sort_orders": results,
    "stats": {name: len(books) for name, books in results.items()},
}

out_path = "/Users/stark/Desktop/WXSW/qidian_all_rankings.json"
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(output, f, ensure_ascii=False, indent=2)

all_ids = set()
for books in results.values():
    for b in books:
        all_ids.add(b["book_id"])

print(f"\nDone! Total unique books: {len(all_ids)}")
print(f"Saved to {out_path}")

for name, books in results.items():
    print(f"\n{name} Top 10:")
    for b in books[:10]:
        print(f"  #{b['global_rank']} {b['title']} - {b['author']} [{b['category']}] {b['status']}")
