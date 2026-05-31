import subprocess
import re
import json
import time

def fetch_page(page_num):
    """Use Safari via AppleScript to fetch a Qidian finish page."""
    if page_num == 1:
        url = "https://www.qidian.com/finish/orderId12-/"
    else:
        url = f"https://www.qidian.com/finish/orderId12-page{page_num}/"
    
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
        print(f"Error on page {page_num}: {result.stderr}")
        return None
    return result.stdout

def extract_books(html):
    """Extract book info from HTML source."""
    books = []
    li_blocks = re.findall(r'<li data-rid="(\d+)">(.*?)</li>', html, re.DOTALL)
    for rid, block in li_blocks:
        bid_m = re.search(r'data-bid="(\d+)"', block)
        title_m = re.search(r'<h2><a[^>]*>(.*?)</a></h2>', block, re.DOTALL)
        author_m = re.search(r'class="name"[^>]*>(.*?)</a>', block)
        cat_m = re.search(r'class="name".*?<em>\|</em><a[^>]*>(.*?)</a>', block, re.DOTALL)
        if bid_m and title_m and author_m:
            books.append({
                "rank": int(rid),
                "book_id": bid_m.group(1),
                "title": title_m.group(1).strip(),
                "author": author_m.group(1).strip(),
                "category": cat_m.group(1).strip() if cat_m else ""
            })
    return books

all_books = []

for page in range(1, 51):
    print(f"Fetching page {page}/50...", flush=True)
    html = fetch_page(page)
    
    if html is None:
        print(f"  Failed to fetch page {page}, retrying...")
        time.sleep(3)
        html = fetch_page(page)
    
    if html:
        books = extract_books(html)
        print(f"  Found {len(books)} books", flush=True)
        for b in books:
            b["page"] = page
            all_books.append(b)
    else:
        print(f"  Page {page} failed after retry", flush=True)
    
    time.sleep(1)

with open("/Users/stark/Desktop/WXSW/qidian_finish_books.json", "w", encoding="utf-8") as f:
    json.dump(all_books, f, ensure_ascii=False, indent=2)

with open("/Users/stark/Desktop/WXSW/qidian_finish_1000.txt", "w", encoding="utf-8") as f:
    for b in all_books:
        author = b.get('author', '未知')
        category = b.get('category', '')
        line = f"{b['title']} - {author}"
        if category:
            line += f" [{category}]"
        if b.get('book_id'):
            line += f" (ID:{b['book_id']})"
        f.write(line + "\n")

print(f"\nTotal books extracted: {len(all_books)}")
print("Saved to qidian_finish_books.json + qidian_finish_1000.txt")
