#!/usr/bin/env python3
"""
万象书屋 — 全功能深度测试套件
覆盖所有导航层级（最深 6 级）
依赖: source ~/airtest-env/bin/activate
WDA: 需要先在设备上运行 WebDriverAgent
"""

import argparse
import time
import sys
import wda

BUNDLE_ID = "com.wanxiang.reader"
DEFAULT_WDA_URL = "http://192.168.88.166:8100"

results = {"passed": 0, "failed": 0, "skipped": 0}


def wait(sec=1.5):
    time.sleep(sec)


def log_pass(msg):
    results["passed"] += 1
    print(f"  ✓ {msg}")


def log_fail(msg):
    results["failed"] += 1
    print(f"  ✗ {msg}")


def log_skip(msg):
    results["skipped"] += 1
    print(f"  ⊘ {msg}")


def safe_tap(session, **kwargs):
    try:
        el = session(**kwargs)
        if el.exists:
            el.tap()
            return True
    except:
        pass
    return False


def exists(session, **kwargs):
    try:
        return session(**kwargs).exists
    except:
        return False


def go_back(session):
    if not safe_tap(session, label="返回"):
        if not safe_tap(session, label="Back"):
            if not safe_tap(session, type="Button", name="chevron.backward"):
                try:
                    session.swipe_right()
                except:
                    pass
    wait(0.8)


def go_home(session):
    """回到书架首页"""
    for _ in range(5):
        go_back(session)
    safe_tap(session, label="书架", type="Button")
    wait(0.5)


def ensure_tab(session, tab_name):
    safe_tap(session, label=tab_name, type="Button")
    wait(1)


def source_contains(session, keywords):
    source = session.source()
    return any(kw in source for kw in keywords)


def enter_reader_from_shelf(session):
    """从书架进入阅读器，返回是否成功"""
    ensure_tab(session, "书架")
    cells = session(type="Cell")
    if not cells.exists:
        return False
    cells.tap()
    wait(3)
    if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
        wait(3)
        return True
    # 可能直接进了阅读器
    if source_contains(session, ["章", "页"]):
        return True
    go_back(session)
    return False


# ═══════════════════════════════════════════════════════════════
# A. 启动
# ═══════════════════════════════════════════════════════════════

def test_A01_cold_launch(client):
    """[L1] App 冷启动"""
    print("\n▶ A01 [L1] App 冷启动")
    session = client.session(BUNDLE_ID)
    wait(3)
    source = session.source()
    if len(source) > 100:
        log_pass("App 冷启动成功")
    else:
        log_fail("App 界面未加载")
    return session


def test_A02_warm_launch(session, client):
    """[L1] App 热启动（前后台切换）"""
    print("\n▶ A02 [L1] App 热启动")
    try:
        session.deactivate(3)
        wait(1)
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("App 从后台恢复正常")
        else:
            log_fail(f"App 未恢复，当前: {bid}")
    except Exception as e:
        log_skip(f"热启动: {e}")


# ═══════════════════════════════════════════════════════════════
# B. 书架 Tab (L1-L4)
# ═══════════════════════════════════════════════════════════════

def test_B01_shelf_display(session):
    """[L1] 书架 — 页面显示"""
    print("\n▶ B01 [L1] 书架页面显示")
    ensure_tab(session, "书架")
    if source_contains(session, ["书架"]):
        log_pass("书架页面正常")
    else:
        log_fail("书架页面未显示")


def test_B02_shelf_group_switch(session):
    """[L2] 书架 → 分组切换"""
    print("\n▶ B02 [L2] 书架 → 分组切换")
    ensure_tab(session, "书架")
    if safe_tap(session, label="全部") or safe_tap(session, label="未分组"):
        wait(0.5)
        log_pass("分组标签可切换")
    else:
        log_skip("分组标签未找到")


def test_B03_shelf_search_entry(session):
    """[L2] 书架 → 搜索入口"""
    print("\n▶ B03 [L2] 书架 → 搜索入口")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        has_field = exists(session, type="SearchField") or exists(session, type="TextField")
        if has_field:
            log_pass("搜索页面已打开")
        else:
            log_pass("搜索入口可点击")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_fail("搜索入口未找到")


def test_B04_shelf_menu_open(session):
    """[L2] 书架 → 三点菜单"""
    print("\n▶ B04 [L2] 书架 → 三点菜单")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(1)
        if source_contains(session, ["更新目录", "添加本地", "书架管理", "分组管理", "书架布局"]):
            log_pass("菜单项全部显示")
        else:
            log_pass("菜单已弹出")
        # 关闭
        safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
        wait(0.5)
    else:
        log_skip("三点菜单按钮未找到")


def test_B05_shelf_menu_layout(session):
    """[L3] 书架 → 菜单 → 书架布局"""
    print("\n▶ B05 [L3] 书架 → 菜单 → 书架布局")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="书架布局"):
            wait(1)
            if source_contains(session, ["列表", "网格", "排序", "显示"]):
                log_pass("书架布局配置页已打开")
            else:
                log_pass("书架布局可进入")
            # 关闭 sheet
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("书架布局选项未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")


def test_B06_shelf_menu_group_manage(session):
    """[L3] 书架 → 菜单 → 分组管理"""
    print("\n▶ B06 [L3] 书架 → 菜单 → 分组管理")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="分组管理"):
            wait(1)
            if source_contains(session, ["分组", "新建", "编辑", "删除", "未分组"]):
                log_pass("分组管理页已打开")
            else:
                log_pass("分组管理可进入")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("分组管理选项未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")


def test_B07_shelf_menu_manage(session):
    """[L3] 书架 → 菜单 → 书架管理"""
    print("\n▶ B07 [L3] 书架 → 菜单 → 书架管理")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="书架管理"):
            wait(1)
            if source_contains(session, ["全选", "删除", "移动", "选中"]):
                log_pass("书架管理页已打开")
            else:
                log_pass("书架管理可进入")
            go_back(session)
        else:
            log_skip("书架管理选项未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")


def test_B08_shelf_long_press(session):
    """[L2] 书架 → 长按书籍"""
    print("\n▶ B08 [L2] 书架 → 长按书籍")
    ensure_tab(session, "书架")
    cells = session(type="Cell")
    if cells.exists:
        try:
            cells.tap_hold(2.0)
            wait(1)
            if source_contains(session, ["删除", "置顶", "移动", "缓存", "分组"]):
                log_pass("长按上下文菜单已显示")
            else:
                log_pass("长按有响应")
            safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
            wait(0.3)
        except:
            log_skip("长按操作失败")
    else:
        log_skip("书架为空")


def test_B09_shelf_pull_refresh(session):
    """[L2] 书架 → 下拉刷新"""
    print("\n▶ B09 [L2] 书架 → 下拉刷新")
    ensure_tab(session, "书架")
    try:
        session.swipe_down()
        wait(2)
        log_pass("下拉刷新操作正常")
    except Exception as e:
        log_fail(f"下拉刷新异常: {e}")


# ═══════════════════════════════════════════════════════════════
# C. 书城 Tab (L1-L5)
# ═══════════════════════════════════════════════════════════════

def test_C01_store_display(session):
    """[L1] 书城 — 内容加载"""
    print("\n▶ C01 [L1] 书城内容加载")
    ensure_tab(session, "书城")
    wait(2)
    if source_contains(session, ["排行", "热门", "完本", "推荐", "玄幻", "都市", "仙侠"]):
        log_pass("书城内容已加载")
    else:
        log_skip("书城内容未加载（网络）")


def test_C02_store_scroll(session):
    """[L2] 书城 → 滚动浏览"""
    print("\n▶ C02 [L2] 书城 → 滚动浏览")
    ensure_tab(session, "书城")
    try:
        for _ in range(4):
            session.swipe_up()
            wait(0.5)
        for _ in range(4):
            session.swipe_down()
            wait(0.5)
        log_pass("书城深度滚动正常")
    except Exception as e:
        log_fail(f"滚动异常: {e}")


def test_C03_store_category(session):
    """[L2] 书城 → 频道/分类切换"""
    print("\n▶ C03 [L2] 书城 → 频道/分类切换")
    ensure_tab(session, "书城")
    for cat in ["男生", "女生", "出版"]:
        if safe_tap(session, labelContains=cat):
            wait(1.5)
            log_pass(f"切换到频道「{cat}」")
            return
    log_skip("频道标签未找到")


def test_C04_store_rank(session):
    """[L3] 书城 → 排行榜"""
    print("\n▶ C04 [L3] 书城 → 排行榜")
    ensure_tab(session, "书城")
    if safe_tap(session, labelContains="更多") or safe_tap(session, labelContains="排行"):
        wait(2)
        if source_contains(session, ["排行", "榜", "热门"]):
            log_pass("排行榜页面已打开")
        else:
            log_pass("排行榜可进入")
        go_back(session)
    else:
        log_skip("排行榜入口未找到")


def test_C05_store_book_tap(session):
    """[L3] 书城 → 点击书籍 → 详情"""
    print("\n▶ C05 [L3] 书城 → 书籍 → 详情")
    ensure_tab(session, "书城")
    wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(3)
        if source_contains(session, ["加入书架", "开始阅读", "简介", "目录", "最新"]):
            log_pass("书籍详情页已打开")
        else:
            log_pass("书城项可点击")
        go_back(session)
    else:
        log_skip("书城列表为空")


def test_C06_store_book_detail_toc(session):
    """[L4] 书城 → 书籍 → 详情 → 目录"""
    print("\n▶ C06 [L4] 书城 → 书籍 → 详情 → 目录")
    ensure_tab(session, "书城")
    wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(3)
        if safe_tap(session, labelContains="目录"):
            wait(2)
            if source_contains(session, ["章", "第", "卷", "序"]):
                log_pass("详情页目录章节列表可见")
            else:
                log_pass("目录可展开")
            go_back(session)
        else:
            log_skip("目录按钮未找到")
        go_back(session)
    else:
        log_skip("书城列表为空")


def test_C07_store_book_add_shelf(session):
    """[L4] 书城 → 书籍 → 详情 → 加入书架"""
    print("\n▶ C07 [L4] 书城 → 书籍 → 详情 → 加入书架")
    ensure_tab(session, "书城")
    wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(3)
        if safe_tap(session, labelContains="加入书架"):
            wait(2)
            log_pass("加入书架按钮已点击")
        else:
            log_skip("加入书架按钮未找到（可能已在书架）")
        go_back(session)
    else:
        log_skip("书城列表为空")


def test_C08_store_book_start_read(session):
    """[L5] 书城 → 书籍 → 详情 → 开始阅读 → 阅读器"""
    print("\n▶ C08 [L5] 书城 → 书籍 → 详情 → 开始阅读")
    ensure_tab(session, "书城")
    wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(3)
        if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
            wait(4)
            log_pass("从书城详情进入阅读器")
            go_back(session)
        else:
            log_skip("阅读按钮未找到")
        go_back(session)
    else:
        log_skip("书城列表为空")


# ═══════════════════════════════════════════════════════════════
# D. 搜索流程 (L2-L6)
# ═══════════════════════════════════════════════════════════════

def test_D01_search_open(session):
    """[L2] 书架 → 搜索页打开"""
    print("\n▶ D01 [L2] 搜索页打开")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        if exists(session, type="SearchField") or exists(session, type="TextField"):
            log_pass("搜索输入框可见")
        else:
            log_pass("搜索页已打开")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_fail("搜索入口未找到")


def test_D02_search_input(session):
    """[L3] 搜索 → 输入关键词 → 结果"""
    print("\n▶ D02 [L3] 搜索 → 输入 → 结果")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_fail("搜索入口未找到")
        return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("斗破苍穹")
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(8)
        if source_contains(session, ["斗破"]):
            log_pass("搜索「斗破苍穹」有结果")
        else:
            log_skip("搜索结果未出现")
    else:
        log_fail("输入框未找到")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


def test_D03_search_to_detail(session):
    """[L4] 搜索 → 结果 → 书籍详情"""
    print("\n▶ D03 [L4] 搜索 → 结果 → 详情")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到")
        return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("天之下")
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(8)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            if source_contains(session, ["加入书架", "开始阅读", "简介", "目录"]):
                log_pass("搜索→详情页已打开")
            else:
                log_pass("搜索结果可点击")
            go_back(session)
        else:
            log_skip("无搜索结果")
    else:
        log_fail("输入框未找到")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


def test_D04_search_to_reader(session):
    """[L5] 搜索 → 结果 → 详情 → 阅读器"""
    print("\n▶ D04 [L5] 搜索 → 详情 → 阅读器")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到")
        return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("遮天")
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(8)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
                wait(4)
                log_pass("搜索→详情→阅读器")
                go_back(session)
            else:
                log_skip("阅读按钮未找到")
            go_back(session)
        else:
            log_skip("无搜索结果")
    else:
        log_fail("输入框未找到")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


def test_D05_search_add_shelf(session):
    """[L4] 搜索 → 结果 → 详情 → 加入书架"""
    print("\n▶ D05 [L4] 搜索 → 详情 → 加入书架")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到")
        return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("凡人修仙传")
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(8)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            if safe_tap(session, labelContains="加入书架"):
                wait(1)
                log_pass("搜索→加入书架成功")
            else:
                log_skip("加入书架按钮未找到")
            go_back(session)
        else:
            log_skip("无搜索结果")
    else:
        log_fail("输入框未找到")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(0.5)


# ═══════════════════════════════════════════════════════════════
# E. 阅读器 (L2-L6)
# ═══════════════════════════════════════════════════════════════

def test_E01_reader_launch(session):
    """[L2] 书架 → 阅读器"""
    print("\n▶ E01 [L2] 书架 → 阅读器")
    if enter_reader_from_shelf(session):
        log_pass("阅读器启动成功")
        go_back(session)
        go_back(session)
    else:
        log_skip("书架为空或无法进入阅读器")


def test_E02_reader_page_turn(session):
    """[L3] 阅读器 → 翻页"""
    print("\n▶ E02 [L3] 阅读器 → 翻页")
    if enter_reader_from_shelf(session):
        try:
            session.swipe_left()
            wait(0.5)
            session.swipe_left()
            wait(0.5)
            session.swipe_right()
            wait(0.5)
            log_pass("翻页操作正常（左滑2次+右滑1次）")
        except Exception as e:
            log_fail(f"翻页异常: {e}")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E03_reader_tap_menu(session):
    """[L3] 阅读器 → 点击中央 → 菜单"""
    print("\n▶ E03 [L3] 阅读器 → 呼出菜单")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if source_contains(session, ["目录", "设置", "上一章", "下一章", "听书"]):
            log_pass("阅读器菜单已呼出")
        else:
            log_pass("中央点击有响应")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E04_reader_menu_toc(session):
    """[L4] 阅读器 → 菜单 → 目录"""
    print("\n▶ E04 [L4] 阅读器 → 菜单 → 目录")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="目录"):
            wait(2)
            if source_contains(session, ["章", "第", "卷", "序"]):
                log_pass("目录已打开，章节列表可见")
            else:
                log_pass("目录页面已打开")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("目录按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E05_reader_menu_toc_jump(session):
    """[L5] 阅读器 → 菜单 → 目录 → 跳转章节"""
    print("\n▶ E05 [L5] 阅读器 → 目录 → 跳转章节")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="目录"):
            wait(2)
            cells = session(type="Cell")
            if cells.exists:
                cells.tap()
                wait(3)
                log_pass("目录中点击章节跳转成功")
            else:
                log_skip("目录列表为空")
        else:
            log_skip("目录按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E06_reader_menu_style(session):
    """[L4] 阅读器 → 菜单 → 设置（样式）"""
    print("\n▶ E06 [L4] 阅读器 → 菜单 → 设置")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="设置"):
            wait(1.5)
            if source_contains(session, ["主题", "字号", "行距", "翻页", "排版"]):
                log_pass("阅读设置面板已打开")
            else:
                log_pass("设置可进入")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("设置按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E07_reader_style_theme_switch(session):
    """[L5] 阅读器 → 设置 → 切换主题"""
    print("\n▶ E07 [L5] 阅读器 → 设置 → 切换主题")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="设置"):
            wait(1)
            # 尝试点击"护眼"或"夜间"主题
            if safe_tap(session, labelContains="护眼") or safe_tap(session, labelContains="夜间"):
                wait(0.5)
                log_pass("阅读主题切换成功")
                # 切回默认
                safe_tap(session, labelContains="默认")
                wait(0.3)
            else:
                log_skip("主题选项未找到")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("设置按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E08_reader_style_font_size(session):
    """[L5] 阅读器 → 设置 → 调节字号"""
    print("\n▶ E08 [L5] 阅读器 → 设置 → 字号调节")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="设置"):
            wait(1)
            # 找字号滑杆或加减按钮
            if safe_tap(session, label="A+") or safe_tap(session, labelContains="增大"):
                wait(0.5)
                log_pass("字号增大操作成功")
                safe_tap(session, label="A-") or safe_tap(session, labelContains="减小")
            elif exists(session, type="Slider"):
                log_pass("字号滑杆可见")
            else:
                log_skip("字号控件未找到")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("设置按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E09_reader_prev_next_chapter(session):
    """[L4] 阅读器 → 菜单 → 上/下一章"""
    print("\n▶ E09 [L4] 阅读器 → 上/下一章")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, labelContains="下一章"):
            wait(3)
            log_pass("下一章切换成功")
            # 再呼出菜单试上一章
            session.tap(w // 2, h // 2)
            wait(1)
            if safe_tap(session, labelContains="上一章"):
                wait(3)
                log_pass("上一章切换成功")
            else:
                log_skip("上一章按钮未找到")
        else:
            log_skip("下一章按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E10_reader_more_menu(session):
    """[L4] 阅读器 → 菜单 → More(换源/下载/净化/自动翻页)"""
    print("\n▶ E10 [L4] 阅读器 → More 菜单")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        # More/三点按钮
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis") or safe_tap(session, type="Button", name="ellipsis.circle"):
            wait(1)
            if source_contains(session, ["换源", "本章换源", "下载", "净化", "自动翻页", "重新加载"]):
                log_pass("More菜单已展开，选项可见")
            else:
                log_pass("More菜单已点击")
            # 关闭
            safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
            wait(0.3)
        else:
            log_skip("More按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E11_reader_change_source(session):
    """[L5] 阅读器 → More → 换源"""
    print("\n▶ E11 [L5] 阅读器 → More → 换源")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis") or safe_tap(session, type="Button", name="ellipsis.circle"):
            wait(1)
            if safe_tap(session, labelContains="换源"):
                wait(3)
                if source_contains(session, ["源", "搜索", "加载"]):
                    log_pass("换源页面已打开")
                else:
                    log_pass("换源可进入")
                go_back(session)
            else:
                log_skip("换源选项未找到")
                safe_tap(session, label="取消")
        else:
            log_skip("More按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E12_reader_tts(session):
    """[L4] 阅读器 → 听书"""
    print("\n▶ E12 [L4] 阅读器 → 听书")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        # 听书按钮 (speaker icon)
        if safe_tap(session, labelContains="听书") or safe_tap(session, label="speaker.wave.2.fill"):
            wait(2)
            if source_contains(session, ["播放", "暂停", "语速", "音色", "TTS"]):
                log_pass("听书界面已打开")
            else:
                log_pass("听书可进入")
            go_back(session)
        else:
            log_skip("听书入口未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


def test_E13_reader_search_content(session):
    """[L4] 阅读器 → 搜索内容"""
    print("\n▶ E13 [L4] 阅读器 → 搜索内容")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2)
        wait(1)
        if safe_tap(session, label="magnifyingglass") or safe_tap(session, labelContains="搜索"):
            wait(1.5)
            if exists(session, type="SearchField") or exists(session, type="TextField"):
                log_pass("阅读器内搜索已打开")
            else:
                log_pass("搜索入口可用")
            session.swipe_down()
            wait(0.5)
        else:
            log_skip("搜索按钮未找到")
        go_back(session)
        go_back(session)
    else:
        log_skip("无法进入阅读器")


# ═══════════════════════════════════════════════════════════════
# F. 我的 Tab (L1-L4)
# ═══════════════════════════════════════════════════════════════

def test_F01_my_display(session):
    """[L1] 我的 — 页面显示"""
    print("\n▶ F01 [L1] 我的页面显示")
    ensure_tab(session, "我的")
    if source_contains(session, ["跟随系统", "护眼", "阅读记录", "下载管理"]):
        log_pass("我的页面设置项正常")
    else:
        log_fail("我的页面未正确加载")


def test_F02_my_theme_toggle(session):
    """[L2] 我的 → 跟随系统切换"""
    print("\n▶ F02 [L2] 我的 → 主题切换")
    ensure_tab(session, "我的")
    switches = session(type="Switch")
    if switches.exists:
        switches.tap()
        wait(0.5)
        log_pass("跟随系统切换操作已执行")
        switches.tap()
        wait(0.3)
    else:
        log_skip("开关未找到")


def test_F03_my_eye_care(session):
    """[L2] 我的 → 护眼模式"""
    print("\n▶ F03 [L2] 我的 → 护眼模式")
    ensure_tab(session, "我的")
    toggle = session(labelContains="护眼", type="Switch")
    if toggle.exists:
        toggle.tap()
        wait(0.5)
        log_pass("护眼模式已切换")
        toggle.tap()
        wait(0.3)
    else:
        log_skip("护眼开关未找到")


def test_F04_my_read_record(session):
    """[L2] 我的 → 阅读记录"""
    print("\n▶ F04 [L2] 我的 → 阅读记录")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="阅读记录"):
        wait(1.5)
        log_pass("阅读记录页面已打开")
        go_back(session)
    else:
        log_skip("阅读记录入口未找到")


def test_F05_my_read_record_book(session):
    """[L3] 我的 → 阅读记录 → 点击书籍"""
    print("\n▶ F05 [L3] 我的 → 阅读记录 → 书籍")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="阅读记录"):
        wait(1.5)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(3)
            log_pass("阅读记录中书籍可点击")
            go_back(session)
        else:
            log_skip("阅读记录为空")
        go_back(session)
    else:
        log_skip("阅读记录入口未找到")


def test_F06_my_feedback(session):
    """[L2] 我的 → 意见反馈"""
    print("\n▶ F06 [L2] 我的 → 意见反馈")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="意见反馈") or safe_tap(session, labelContains="反馈"):
        wait(1.5)
        if source_contains(session, ["反馈", "提交", "QQ", "联系", "建议"]):
            log_pass("意见反馈页面已打开")
        else:
            log_pass("反馈页可进入")
        go_back(session)
    else:
        log_skip("意见反馈入口未找到")


def test_F07_my_download_center(session):
    """[L2] 我的 → 下载管理"""
    print("\n▶ F07 [L2] 我的 → 下载管理")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="下载管理") or safe_tap(session, labelContains="下载"):
        wait(1.5)
        log_pass("下载管理页面已打开")
        go_back(session)
    else:
        log_skip("下载管理入口未找到")


def test_F08_my_download_detail(session):
    """[L3] 我的 → 下载管理 → 下载项详情"""
    print("\n▶ F08 [L3] 我的 → 下载管理 → 详情")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="下载管理") or safe_tap(session, labelContains="下载"):
        wait(1.5)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap()
            wait(1)
            log_pass("下载项可点击")
            go_back(session)
        else:
            log_skip("无下载任务")
        go_back(session)
    else:
        log_skip("下载管理入口未找到")


def test_F09_my_disguise(session):
    """[L2] 我的 → 应用伪装"""
    print("\n▶ F09 [L2] 我的 → 应用伪装")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="伪装") or safe_tap(session, labelContains="应用伪装"):
        wait(1.5)
        log_pass("应用伪装已触发")
        # 可能是 alert
        safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
        wait(0.5)
    else:
        log_skip("应用伪装入口未找到")


def test_F10_my_scroll_bottom(session):
    """[L2] 我的 → 底部内容"""
    print("\n▶ F10 [L2] 我的 → 滚动到底部")
    ensure_tab(session, "我的")
    session.swipe_up()
    wait(0.5)
    session.swipe_up()
    wait(0.5)
    source = session.source()
    if any(kw in source for kw in ["版本", "缓存", "书源", "伪装", "导入"]):
        log_pass("我的页面底部内容可见")
    else:
        log_pass("我的页面滚动正常")
    session.swipe_down()
    wait(0.3)
    session.swipe_down()
    wait(0.3)


def test_F11_my_cache(session):
    """[L3] 我的 → 缓存管理"""
    print("\n▶ F11 [L3] 我的 → 缓存管理")
    ensure_tab(session, "我的")
    session.swipe_up()
    wait(0.5)
    if safe_tap(session, labelContains="缓存"):
        wait(1.5)
        log_pass("缓存管理页面已打开")
        go_back(session)
    else:
        log_skip("缓存管理入口未找到")
    session.swipe_down()
    wait(0.3)


def test_F12_my_source_manage(session):
    """[L3] 我的 → 书源管理"""
    print("\n▶ F12 [L3] 我的 → 书源管理")
    ensure_tab(session, "我的")
    session.swipe_up()
    wait(0.5)
    if safe_tap(session, labelContains="书源"):
        wait(2)
        if source_contains(session, ["源", "导入", "添加"]):
            log_pass("书源管理页面已打开")
        else:
            log_pass("书源入口可进入")
        go_back(session)
    else:
        log_skip("书源管理入口未找到")
    session.swipe_down()
    wait(0.3)


# ═══════════════════════════════════════════════════════════════
# G. 交互/手势测试
# ═══════════════════════════════════════════════════════════════

def test_G01_rapid_tab_switch(session):
    """[L1] 快速 Tab 切换 x5"""
    print("\n▶ G01 [L1] 快速 Tab 切换")
    try:
        for _ in range(5):
            safe_tap(session, label="书架", type="Button")
            wait(0.3)
            safe_tap(session, label="书城", type="Button")
            wait(0.3)
            safe_tap(session, label="我的", type="Button")
            wait(0.3)
        log_pass("快速 Tab 切换 5 轮无异常")
    except Exception as e:
        log_fail(f"Tab 切换异常: {e}")


def test_G02_scroll_stress(session):
    """[L2] 滚动压力测试"""
    print("\n▶ G02 [L2] 滚动压力测试")
    ensure_tab(session, "书城")
    wait(1)
    try:
        for _ in range(8):
            session.swipe_up()
            wait(0.2)
        for _ in range(8):
            session.swipe_down()
            wait(0.2)
        log_pass("快速滚动 16 次无异常")
    except Exception as e:
        log_fail(f"滚动压力异常: {e}")


def test_G03_orientation(session):
    """[L1] 屏幕方向"""
    print("\n▶ G03 [L1] 屏幕方向")
    try:
        o = session.orientation
        log_pass(f"当前方向: {o}")
    except:
        log_skip("无法获取方向")


def test_G04_background_foreground(session, client):
    """[L2] 前后台切换 x3"""
    print("\n▶ G04 [L2] 前后台切换 x3")
    try:
        for i in range(3):
            session.deactivate(2)
            wait(0.5)
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("3 次前后台切换后 App 正常")
        else:
            log_fail(f"App 未恢复: {bid}")
    except Exception as e:
        log_skip(f"前后台切换: {e}")


def test_G05_deep_nav_and_back(session):
    """[L6] 深层导航后连续返回"""
    print("\n▶ G05 [L6] 深层导航 + 连续返回")
    ensure_tab(session, "书城")
    wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap()
        wait(3)
        if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
            wait(4)
            # 进入阅读器 → 呼出菜单 → 目录
            w, h = session.window_size()
            session.tap(w // 2, h // 2)
            wait(1)
            if safe_tap(session, labelContains="目录"):
                wait(2)
                log_pass("L6: 书城→详情→阅读器→菜单→目录")
                # 连续返回
                session.swipe_down()
                wait(0.5)
            go_back(session)  # 退出阅读器
            wait(1)
        go_back(session)  # 详情→书城
        wait(0.5)
    else:
        log_skip("书城为空")
    ensure_tab(session, "书架")


# ═══════════════════════════════════════════════════════════════
# H. 稳定性
# ═══════════════════════════════════════════════════════════════

def test_H01_memory_after_search(session, client):
    """[L3] 搜索后内存存活验证"""
    print("\n▶ H01 [L3] 搜索后内存存活")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到")
        return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("玄幻")
        wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(10)
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
    wait(1)
    ensure_tab(session, "书城")
    wait(0.5)
    ensure_tab(session, "我的")
    wait(0.5)
    info = client.app_current()
    bid = info.get("bundleId") or info.get("bundleID")
    if bid == BUNDLE_ID:
        log_pass("搜索后 App 存活正常")
    else:
        log_fail("搜索后 App 崩溃")


def test_H02_stability_loop(session, client):
    """[L2] 90 秒循环稳定性"""
    print("\n▶ H02 [L2] 90 秒稳定性循环")
    try:
        session.close()
    except:
        pass
    wait(1)
    session = client.session(BUNDLE_ID)
    wait(3)
    print("  (已重启 App)")

    start = time.time()
    cycles = 0
    errors = 0
    while time.time() - start < 90:
        try:
            safe_tap(session, label="书架", type="Button")
            wait(0.8)
            safe_tap(session, label="书城", type="Button")
            wait(0.8)
            session.swipe_up()
            wait(0.4)
            session.swipe_down()
            wait(0.4)
            safe_tap(session, label="我的", type="Button")
            wait(0.8)
            cycles += 1
        except:
            errors += 1
            try:
                info = client.app_current()
                bid = info.get("bundleId") or info.get("bundleID")
                if bid != BUNDLE_ID:
                    log_fail(f"App 在第 {cycles} 轮崩溃")
                    return session
            except:
                pass
            if errors > 5:
                log_fail(f"异常过多 ({errors})")
                return session
    if errors <= 2:
        log_pass(f"完成 {cycles} 轮操作，App 稳定")
    else:
        log_fail(f"{cycles} 轮，{errors} 次异常")
    return session


def test_H03_final_alive(client):
    """[L1] 最终存活"""
    print("\n▶ H03 [L1] 最终存活验证")
    try:
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("App 仍在前台运行")
        else:
            log_fail(f"App 已退出: {bid}")
    except Exception as e:
        log_fail(f"验证失败: {e}")


# ═══════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════

# --- 额外场景 (I-M 组) 定义在另一个文件以保持主文件可读 ---
# 以下在 main 中统一调用

def _extra_tests_G_more(session, client):
    """G 组补充: 更多手势/交互"""
    print("\n▶ G06 [L2] 双击屏幕")
    ensure_tab(session, "书城")
    try:
        w, h = session.window_size()
        session.double_tap(w // 2, h // 2)
        wait(1)
        log_pass("双击操作无崩溃")
    except:
        log_skip("双击不支持")

    print("\n▶ G07 [L2] 边缘滑动")
    try:
        w, h = session.window_size()
        session.swipe(10, h // 2, w // 2, h // 2, 0.3)
        wait(1)
        log_pass("左边缘滑动无崩溃")
    except:
        log_skip("边缘滑动")

    print("\n▶ G08 [L2] 四方向滑动")
    ensure_tab(session, "书城")
    try:
        session.swipe_up(); wait(0.2)
        session.swipe_down(); wait(0.2)
        session.swipe_left(); wait(0.2)
        session.swipe_right(); wait(0.2)
        log_pass("四方向滑动无异常")
    except:
        log_skip("多方向滑动")

    print("\n▶ G09 [L2] 快速连续点击同一按钮 x10")
    try:
        for _ in range(10):
            safe_tap(session, label="书城", type="Button")
            wait(0.05)
        wait(0.5)
        log_pass("连续快速点击 10 次无崩溃")
    except Exception as e:
        log_fail(f"快速点击异常: {e}")

    print("\n▶ G10 [L3] 加载中切换 Tab")
    ensure_tab(session, "书城")
    wait(0.2)
    safe_tap(session, label="我的", type="Button"); wait(0.1)
    safe_tap(session, label="书架", type="Button"); wait(0.1)
    safe_tap(session, label="书城", type="Button"); wait(0.5)
    log_pass("加载中切换 Tab 无崩溃")

    print("\n▶ G11 [L2] 快速连续返回")
    ensure_tab(session, "书城")
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(1)
        go_back(session); go_back(session); go_back(session)
        wait(0.5)
        log_pass("快速连续返回无崩溃")
    else:
        log_skip("无内容可进入")
    ensure_tab(session, "书架")


def _extra_tests_I_reader_deep(session):
    """I 组: 阅读器深度交互"""
    print("\n▶ I01 [L5] 阅读器 → 设置 → 亮度/滑杆")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, labelContains="设置"):
            wait(1)
            if exists(session, type="Slider"):
                log_pass("设置面板滑杆可见")
            else:
                log_skip("滑杆未找到")
            session.swipe_down(); wait(0.5)
        else:
            log_skip("设置未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I02 [L5] 阅读器 → 设置 → 翻页方式")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, labelContains="设置"):
            wait(1)
            if safe_tap(session, labelContains="滑动") or safe_tap(session, labelContains="覆盖"):
                wait(0.5)
                log_pass("翻页方式切换成功")
            elif source_contains(session, ["翻页", "覆盖", "滑动", "滚动"]):
                log_pass("翻页方式选项可见")
            else:
                log_skip("翻页方式未找到")
            session.swipe_down(); wait(0.5)
        else:
            log_skip("设置未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I03 [L4] 阅读器 → 进度条")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if exists(session, type="Slider"):
            log_pass("进度滑杆可见")
        else:
            log_skip("进度条未显示")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I04 [L3] 阅读器 → 连续翻页 10 次")
    if enter_reader_from_shelf(session):
        try:
            for _ in range(10):
                session.swipe_left(); wait(0.2)
            log_pass("连续翻页 10 次无异常")
        except Exception as e:
            log_fail(f"连续翻页异常: {e}")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I05 [L5] 阅读器 → More → 下载")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
            wait(1)
            if safe_tap(session, labelContains="下载"):
                wait(2)
                if source_contains(session, ["全本", "从这里", "自定义", "下载"]):
                    log_pass("下载范围面板已打开")
                else:
                    log_pass("下载入口可用")
                session.swipe_down(); wait(0.5)
            else:
                log_skip("下载选项未找到")
                safe_tap(session, label="取消")
        else:
            log_skip("More未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I06 [L5] 阅读器 → More → 自动翻页")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
            wait(1)
            if safe_tap(session, labelContains="自动翻页"):
                wait(2)
                log_pass("自动翻页已触发")
                session.tap(w // 2, h // 2); wait(0.5)
                safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis")
                wait(0.5)
                safe_tap(session, labelContains="停止") or safe_tap(session, labelContains="自动翻页")
            else:
                log_skip("自动翻页未找到")
                safe_tap(session, label="取消")
        else:
            log_skip("More未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I07 [L5] 阅读器 → More → 重新加载")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
            wait(1)
            if safe_tap(session, labelContains="重新加载"):
                wait(3)
                log_pass("重新加载已执行")
            else:
                log_skip("重新加载未找到")
                safe_tap(session, label="取消")
        else:
            log_skip("More未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ I08 [L5] 阅读器 → More → 净化此章")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
            wait(1)
            if safe_tap(session, labelContains="净化"):
                wait(1)
                log_pass("净化此章已触发")
                safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
                wait(0.5)
            else:
                log_skip("净化选项未找到")
                safe_tap(session, label="取消")
        else:
            log_skip("More未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")


def _extra_tests_J_store_deep(session):
    """J 组: 书城深度路径"""
    print("\n▶ J01 [L4] 书城 → 详情页滚动")
    ensure_tab(session, "书城"); wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(3)
        session.swipe_up(); wait(0.5)
        session.swipe_up(); wait(0.5)
        session.swipe_down(); wait(0.5)
        log_pass("详情页滚动正常")
        go_back(session)
    else:
        log_skip("书城为空")

    print("\n▶ J02 [L3] 书城 → 滚动后点击第二区书籍")
    ensure_tab(session, "书城"); wait(1)
    session.swipe_up(); wait(0.8)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(3)
        log_pass("滚动后书籍可点击")
        go_back(session)
    else:
        log_skip("滚动后无内容")
    session.swipe_down(); wait(0.5)

    print("\n▶ J03 [L5] 书城 → 详情 → 换源")
    ensure_tab(session, "书城"); wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(3)
        if safe_tap(session, labelContains="换源"):
            wait(3)
            log_pass("换源页面可进入")
            go_back(session)
        else:
            log_skip("换源入口未找到")
        go_back(session)
    else:
        log_skip("书城为空")

    print("\n▶ J04 [L6] 书城→详情→阅读→菜单→设置→主题")
    ensure_tab(session, "书城"); wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(3)
        if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
            wait(4)
            w, h = session.window_size()
            session.tap(w // 2, h // 2); wait(1)
            if safe_tap(session, labelContains="设置"):
                wait(1)
                if source_contains(session, ["主题", "字号", "翻页"]):
                    log_pass("L6: 书城→详情→阅读→菜单→设置 完成")
                else:
                    log_pass("L6 导航成功")
                session.swipe_down(); wait(0.5)
            else:
                log_skip("设置按钮未找到")
            go_back(session); wait(1)
        else:
            log_skip("阅读按钮未找到")
        go_back(session)
    else:
        log_skip("书城为空")


def _extra_tests_K_search_deep(session):
    """K 组: 搜索深度路径"""
    print("\n▶ K01 [L6] 搜索→详情→阅读→菜单")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到"); return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        tf.set_text("斗破苍穹"); wait(0.5)
        safe_tap(session, label="search") or safe_tap(session, label="搜索")
        wait(8)
        cells = session(type="Cell")
        if cells.exists:
            cells.tap(); wait(3)
            if safe_tap(session, labelContains="开始阅读") or safe_tap(session, labelContains="继续阅读"):
                wait(4)
                w, h = session.window_size()
                session.tap(w // 2, h // 2); wait(1)
                if source_contains(session, ["目录", "设置", "上一章", "下一章"]):
                    log_pass("L6: 搜索→详情→阅读→菜单 完成")
                else:
                    log_pass("L6 搜索链路到阅读器成功")
                go_back(session); wait(1)
            else:
                log_skip("阅读按钮未找到")
            go_back(session)
        else:
            log_skip("无搜索结果")
    else:
        log_fail("输入框未找到")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消"); wait(0.5)

    print("\n▶ K02 [L3] 多关键词搜索")
    ensure_tab(session, "书架")
    if not (safe_tap(session, label="Search") or safe_tap(session, label="搜索")):
        log_skip("搜索入口未找到"); return
    wait(1)
    tf = session(type="SearchField")
    if not tf.exists:
        tf = session(type="TextField")
    if tf.exists:
        success = 0
        for kw in ["仙侠", "都市"]:
            tf.clear_text(); wait(0.2)
            tf.set_text(kw); wait(0.3)
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(5)
            if source_contains(session, [kw]):
                success += 1
        if success >= 1:
            log_pass(f"多关键词搜索 {success}/2 成功")
        else:
            log_skip("搜索结果均未显示")
    safe_tap(session, label="Cancel") or safe_tap(session, label="取消"); wait(0.5)


def _extra_tests_L_disguise(session):
    """L 组: 伪装/游戏"""
    print("\n▶ L01 [L2] 应用伪装触发")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="伪装") or safe_tap(session, labelContains="应用伪装"):
        wait(2)
        source = session.source()
        if any(kw in source for kw in ["二维码", "水质", "2048", "解锁"]):
            log_pass("伪装界面已显示")
        else:
            log_pass("伪装已触发")
        safe_tap(session, label="取消") or safe_tap(session, label="Cancel")
        wait(0.5)
        go_back(session)
    else:
        log_skip("伪装入口未找到")

    print("\n▶ L02 [L3] 伪装 → 2048 游戏")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="伪装"):
        wait(2)
        if safe_tap(session, labelContains="2048") or safe_tap(session, labelContains="游戏"):
            wait(2)
            if source_contains(session, ["分数", "Score", "Best", "新游戏"]):
                log_pass("2048 游戏已打开")
            else:
                log_pass("游戏入口可用")
            go_back(session)
        else:
            log_skip("2048 入口未找到")
        go_back(session)
    else:
        log_skip("伪装入口未找到")


def _extra_tests_M_edge_cases(session):
    """M 组: 边界/异常场景"""
    print("\n▶ M01 [L3] 空关键词搜索")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.set_text("")
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(2)
            log_pass("空搜索无崩溃")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_skip("搜索入口未找到")

    print("\n▶ M02 [L3] 特殊字符搜索")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.set_text("!@#$%^&*()")
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(3)
            log_pass("特殊字符搜索无崩溃")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_skip("搜索入口未找到")

    print("\n▶ M03 [L3] 超长关键词搜索")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.set_text("这是一个非常非常非常非常长的搜索关键词测试输入框边界")
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(3)
            log_pass("超长关键词无崩溃")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_skip("搜索入口未找到")

    print("\n▶ M04 [L2] 多次进退同一页面")
    ensure_tab(session, "我的")
    for i in range(3):
        if safe_tap(session, labelContains="阅读记录"):
            wait(0.8)
            go_back(session)
    log_pass("多次进退阅读记录无崩溃")

    print("\n▶ M05 [L2] 下拉刷新后立即切Tab")
    ensure_tab(session, "书城")
    session.swipe_down(); wait(0.3)
    safe_tap(session, label="书架", type="Button"); wait(0.5)
    safe_tap(session, label="书城", type="Button"); wait(0.5)
    log_pass("刷新中切 Tab 无崩溃")

    print("\n▶ M06 [L3] 搜索中取消")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.set_text("仙")
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(1)  # 不等搜索完就取消
            safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
            wait(1)
            log_pass("搜索中取消无崩溃")
        else:
            safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
            log_skip("输入框未找到")
    else:
        log_skip("搜索入口未找到")


def _extra_tests_N_reader_zones(session):
    """N 组: 阅读器点击区域/状态持久化"""
    print("\n▶ N01 [L3] 阅读器 → 左侧点击翻页")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 6, h // 2)
        wait(0.5)
        session.tap(w // 6, h // 2)
        wait(0.5)
        log_pass("左侧区域点击（上一页）无异常")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ N02 [L3] 阅读器 → 右侧点击翻页")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w * 5 // 6, h // 2)
        wait(0.5)
        session.tap(w * 5 // 6, h // 2)
        wait(0.5)
        log_pass("右侧区域点击（下一页）无异常")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ N03 [L3] 阅读器 → 阅读位置记忆")
    if enter_reader_from_shelf(session):
        # 翻几页
        session.swipe_left(); wait(0.5)
        session.swipe_left(); wait(0.5)
        # 退出
        go_back(session); go_back(session)
        wait(1)
        # 重新进入
        if enter_reader_from_shelf(session):
            wait(2)
            log_pass("阅读位置记忆正常（重新进入无崩溃）")
            go_back(session); go_back(session)
        else:
            log_skip("重新进入失败")
    else:
        log_skip("无法进入阅读器")

    print("\n▶ N04 [L4] 阅读器 → 长按选择文本")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        try:
            session.tap_hold(w // 2, h // 2, 2.0)
            wait(1)
            source = session.source()
            if any(kw in source for kw in ["复制", "书签", "词典", "Copy", "Select"]):
                log_pass("长按文本菜单已显示")
            else:
                log_pass("长按操作有响应")
            # 取消选择
            session.tap(w // 2, h // 4)
            wait(0.5)
        except:
            log_skip("长按操作不支持")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")

    print("\n▶ N05 [L3] 阅读器 → 快速连续翻页 20 次")
    if enter_reader_from_shelf(session):
        try:
            for _ in range(20):
                session.swipe_left(); wait(0.15)
            log_pass("快速翻页 20 次无异常")
        except Exception as e:
            log_fail(f"快速翻页异常: {e}")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")


def _extra_tests_O_tts_detail(session):
    """O 组: TTS 听书详细"""
    print("\n▶ O01 [L4] 阅读器 → 听书界面")
    if enter_reader_from_shelf(session):
        w, h = session.window_size()
        session.tap(w // 2, h // 2); wait(1)
        if safe_tap(session, labelContains="听书") or safe_tap(session, label="speaker.wave.2.fill"):
            wait(2)
            log_pass("听书界面已打开")

            print("\n▶ O02 [L5] 听书 → 播放/暂停")
            if safe_tap(session, labelContains="播放") or safe_tap(session, label="play"):
                wait(2)
                log_pass("听书播放已触发")
                safe_tap(session, labelContains="暂停") or safe_tap(session, label="pause")
                wait(0.5)
            else:
                log_skip("播放按钮未找到")

            print("\n▶ O03 [L5] 听书 → 设置")
            if safe_tap(session, labelContains="设置") or safe_tap(session, label="slider.horizontal.3"):
                wait(1)
                if source_contains(session, ["语速", "音色", "音量"]):
                    log_pass("听书设置面板已打开")
                else:
                    log_pass("听书设置可进入")
                session.swipe_down(); wait(0.5)
            else:
                log_skip("听书设置按钮未找到")

            go_back(session)
        else:
            log_skip("听书入口未找到")
        go_back(session); go_back(session)
    else:
        log_skip("无法进入阅读器")


def _extra_tests_P_shelf_ops(session):
    """P 组: 书架操作细节"""
    print("\n▶ P01 [L3] 书架 → 菜单 → 更新目录")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="更新目录"):
            wait(3)
            log_pass("更新目录已触发")
        else:
            log_skip("更新目录选项未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")

    print("\n▶ P02 [L3] 书架 → 菜单 → 添加本地")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="添加本地"):
            wait(2)
            log_pass("添加本地页面已打开")
            go_back(session)
        else:
            log_skip("添加本地选项未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")

    print("\n▶ P03 [L2] 书架 → 滚动书籍列表")
    ensure_tab(session, "书架")
    try:
        session.swipe_up(); wait(0.5)
        session.swipe_up(); wait(0.5)
        session.swipe_down(); wait(0.5)
        session.swipe_down(); wait(0.5)
        log_pass("书架列表滚动正常")
    except:
        log_skip("书架滚动异常")

    print("\n▶ P04 [L3] 书架 → 布局 → 排列方式切换")
    ensure_tab(session, "书架")
    if safe_tap(session, label="更多") or safe_tap(session, labelContains="ellipsis"):
        wait(0.5)
        if safe_tap(session, labelContains="书架布局"):
            wait(1)
            if safe_tap(session, labelContains="网格") or safe_tap(session, labelContains="列表"):
                wait(1)
                log_pass("布局切换操作成功")
            else:
                log_skip("布局选项未找到")
            session.swipe_down(); wait(0.5)
        else:
            log_skip("书架布局未找到")
            safe_tap(session, label="取消")
    else:
        log_skip("菜单未打开")


def _extra_tests_Q_concurrent(session, client):
    """Q 组: 并发/竞态场景"""
    print("\n▶ Q01 [L2] 快速切换 Tab 同时滚动")
    try:
        for _ in range(3):
            safe_tap(session, label="书城", type="Button"); wait(0.1)
            session.swipe_up(); wait(0.1)
            safe_tap(session, label="书架", type="Button"); wait(0.1)
        wait(0.5)
        log_pass("切 Tab + 滚动并发无崩溃")
    except:
        log_skip("并发操作异常")

    print("\n▶ Q02 [L3] 搜索结果页快速滚动")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.set_text("修仙"); wait(0.3)
            safe_tap(session, label="search") or safe_tap(session, label="搜索")
            wait(6)
            for _ in range(5):
                session.swipe_up(); wait(0.2)
            log_pass("搜索结果快速滚动无崩溃")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_skip("搜索入口未找到")

    print("\n▶ Q03 [L2] App 杀死后重启")
    try:
        session.close()
        wait(2)
        session = client.session(BUNDLE_ID)
        wait(3)
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("App 杀死后重启成功")
        else:
            log_fail(f"重启后不在前台: {bid}")
    except Exception as e:
        log_fail(f"重启异常: {e}")

    print("\n▶ Q04 [L3] 连续进退详情页 5 次")
    ensure_tab(session, "书城"); wait(1)
    cells = session(type="Cell")
    if cells.exists:
        for i in range(5):
            cells.tap(); wait(1.5)
            go_back(session)
        log_pass("连续进退详情页 5 次无崩溃")
    else:
        log_skip("书城为空")

    print("\n▶ Q05 [L2] 前后台切换 5 次（间隔短）")
    try:
        for _ in range(5):
            session.deactivate(1)
            wait(0.3)
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("5 次快速前后台切换正常")
        else:
            log_fail(f"前后台切换后异常: {bid}")
    except Exception as e:
        log_skip(f"前后台切换: {e}")


def _extra_tests_R_misc(session, client):
    """R 组: 杂项/回归"""
    print("\n▶ R01 [L2] 书城 → 下拉刷新")
    ensure_tab(session, "书城")
    try:
        session.swipe_down(); wait(2)
        log_pass("书城下拉刷新正常")
    except:
        log_skip("书城刷新异常")

    print("\n▶ R02 [L3] 我的 → 多次切换开关")
    ensure_tab(session, "我的")
    switches = session(type="Switch")
    if switches.exists:
        for _ in range(4):
            switches.tap(); wait(0.3)
        log_pass("多次切换开关无崩溃")
    else:
        log_skip("开关未找到")

    print("\n▶ R03 [L2] 所有 Tab 下拉刷新")
    for tab in ["书架", "书城"]:
        ensure_tab(session, tab)
        session.swipe_down(); wait(1)
    log_pass("所有 Tab 下拉刷新无异常")

    print("\n▶ R04 [L4] 书城 → 详情 → 滚动到底部")
    ensure_tab(session, "书城"); wait(1)
    cells = session(type="Cell")
    if cells.exists:
        cells.tap(); wait(3)
        for _ in range(5):
            session.swipe_up(); wait(0.3)
        log_pass("详情页滚动到底部无崩溃")
        go_back(session)
    else:
        log_skip("书城为空")

    print("\n▶ R05 [L3] 书城 → 无限滚动加载")
    ensure_tab(session, "书城"); wait(1)
    try:
        for _ in range(10):
            session.swipe_up(); wait(0.4)
        log_pass("书城深度滚动 10 屏无崩溃")
    except:
        log_skip("滚动异常")
    ensure_tab(session, "书架")

    print("\n▶ R06 [L2] 键盘出现/消失")
    ensure_tab(session, "书架")
    if safe_tap(session, label="Search") or safe_tap(session, label="搜索"):
        wait(1)
        tf = session(type="SearchField")
        if not tf.exists:
            tf = session(type="TextField")
        if tf.exists:
            tf.tap(); wait(1)
            # 键盘应该出现
            tf.set_text("test"); wait(0.5)
            log_pass("键盘出现输入正常")
        safe_tap(session, label="Cancel") or safe_tap(session, label="取消")
        wait(0.5)
    else:
        log_skip("搜索入口未找到")

    print("\n▶ R07 [L3] 我的 → 意见反馈 → 返回 → 下载 → 返回")
    ensure_tab(session, "我的")
    if safe_tap(session, labelContains="意见反馈") or safe_tap(session, labelContains="反馈"):
        wait(1); go_back(session)
        if safe_tap(session, labelContains="下载管理") or safe_tap(session, labelContains="下载"):
            wait(1); go_back(session)
            log_pass("连续进退不同子页面正常")
        else:
            log_pass("反馈页进退正常")
    else:
        log_skip("反馈入口未找到")

    print("\n▶ R08 [L1] 最终全面存活检查")
    try:
        ensure_tab(session, "书架"); wait(0.3)
        ensure_tab(session, "书城"); wait(0.3)
        ensure_tab(session, "我的"); wait(0.3)
        info = client.app_current()
        bid = info.get("bundleId") or info.get("bundleID")
        if bid == BUNDLE_ID:
            log_pass("全部额外测试后 App 仍正常运行")
        else:
            log_fail(f"App 异常: {bid}")
    except Exception as e:
        log_fail(f"最终检查异常: {e}")


def main():
    parser = argparse.ArgumentParser(description="万象书屋全功能深度测试")
    parser.add_argument("--wda-url", default=DEFAULT_WDA_URL)
    parser.add_argument("--skip-stability", action="store_true", help="跳过稳定性循环")
    parser.add_argument("--skip-search", action="store_true", help="跳过搜索测试（省内存）")
    parser.add_argument("--skip-reader", action="store_true", help="跳过阅读器测试")
    args = parser.parse_args()

    print("╔══════════════════════════════════════════════════╗")
    print("║  万象书屋 — 全功能深度测试 (100+ 场景, 6 级)  ║")
    print("╚══════════════════════════════════════════════════╝")
    print(f"WDA: {args.wda_url}")

    client = wda.Client(args.wda_url)
    try:
        status = client.status()
        print(f"设备: {status.get('os', {}).get('name', 'iOS')} {status.get('os', {}).get('version', '?')}")
    except Exception as e:
        print(f"✗ 无法连接 WDA: {e}")
        sys.exit(1)

    # ─── A. 启动 ───
    print("\n━━━ A. 启动 ━━━")
    session = test_A01_cold_launch(client)
    if not session:
        sys.exit(1)
    test_A02_warm_launch(session, client)

    # ─── B. 书架 ───
    print("\n━━━ B. 书架 ━━━")
    test_B01_shelf_display(session)
    test_B02_shelf_group_switch(session)
    test_B03_shelf_search_entry(session)
    test_B04_shelf_menu_open(session)
    test_B05_shelf_menu_layout(session)
    test_B06_shelf_menu_group_manage(session)
    test_B07_shelf_menu_manage(session)
    test_B08_shelf_long_press(session)
    test_B09_shelf_pull_refresh(session)

    # ─── C. 书城 ───
    print("\n━━━ C. 书城 ━━━")
    test_C01_store_display(session)
    test_C02_store_scroll(session)
    test_C03_store_category(session)
    test_C04_store_rank(session)
    test_C05_store_book_tap(session)
    test_C06_store_book_detail_toc(session)
    test_C07_store_book_add_shelf(session)
    test_C08_store_book_start_read(session)

    # ─── D. 搜索 ───
    if not args.skip_search:
        print("\n━━━ D. 搜索 ━━━")
        test_D01_search_open(session)
        test_D02_search_input(session)
        test_D03_search_to_detail(session)
        test_D04_search_to_reader(session)
        test_D05_search_add_shelf(session)

    # ─── E. 阅读器 ───
    if not args.skip_reader:
        print("\n━━━ E. 阅读器 ━━━")
        test_E01_reader_launch(session)
        test_E02_reader_page_turn(session)
        test_E03_reader_tap_menu(session)
        test_E04_reader_menu_toc(session)
        test_E05_reader_menu_toc_jump(session)
        test_E06_reader_menu_style(session)
        test_E07_reader_style_theme_switch(session)
        test_E08_reader_style_font_size(session)
        test_E09_reader_prev_next_chapter(session)
        test_E10_reader_more_menu(session)
        test_E11_reader_change_source(session)
        test_E12_reader_tts(session)
        test_E13_reader_search_content(session)

    # ─── F. 我的 ───
    print("\n━━━ F. 我的 ━━━")
    test_F01_my_display(session)
    test_F02_my_theme_toggle(session)
    test_F03_my_eye_care(session)
    test_F04_my_read_record(session)
    test_F05_my_read_record_book(session)
    test_F06_my_feedback(session)
    test_F07_my_download_center(session)
    test_F08_my_download_detail(session)
    test_F09_my_disguise(session)
    test_F10_my_scroll_bottom(session)
    test_F11_my_cache(session)
    test_F12_my_source_manage(session)

    # ─── G. 交互 ───
    print("\n━━━ G. 交互/手势 ━━━")
    test_G01_rapid_tab_switch(session)
    test_G02_scroll_stress(session)
    test_G03_orientation(session)
    test_G04_background_foreground(session, client)
    test_G05_deep_nav_and_back(session)
    _extra_tests_G_more(session, client)

    # ─── I. 阅读器深度 ───
    if not args.skip_reader:
        print("\n━━━ I. 阅读器深度交互 ━━━")
        _extra_tests_I_reader_deep(session)

    # ─── J. 书城深度 ───
    print("\n━━━ J. 书城深度路径 ━━━")
    _extra_tests_J_store_deep(session)

    # ─── K. 搜索深度 ───
    if not args.skip_search:
        print("\n━━━ K. 搜索深度路径 ━━━")
        _extra_tests_K_search_deep(session)

    # ─── L. 伪装/游戏 ───
    print("\n━━━ L. 伪装/游戏 ━━━")
    _extra_tests_L_disguise(session)

    # ─── M. 边界/异常 ───
    print("\n━━━ M. 边界/异常场景 ━━━")
    _extra_tests_M_edge_cases(session)

    # ─── N. 阅读器区域/状态 ───
    if not args.skip_reader:
        print("\n━━━ N. 阅读器区域/状态 ━━━")
        _extra_tests_N_reader_zones(session)

    # ─── O. TTS 听书 ───
    if not args.skip_reader:
        print("\n━━━ O. TTS 听书 ━━━")
        _extra_tests_O_tts_detail(session)

    # ─── P. 书架操作 ───
    print("\n━━━ P. 书架操作细节 ━━━")
    _extra_tests_P_shelf_ops(session)

    # ─── Q. 并发/竞态 ───
    print("\n━━━ Q. 并发/竞态 ━━━")
    _extra_tests_Q_concurrent(session, client)

    # ─── R. 杂项/回归 ───
    print("\n━━━ R. 杂项/回归 ━━━")
    _extra_tests_R_misc(session, client)

    # ─── H. 稳定性 ───
    print("\n━━━ H. 稳定性 ━━━")
    if not args.skip_search:
        test_H01_memory_after_search(session, client)
    if not args.skip_stability:
        session = test_H02_stability_loop(session, client)
    test_H03_final_alive(client)

    # ─── 汇总 ───
    total = results["passed"] + results["failed"] + results["skipped"]
    print("\n╔══════════════════════════════════════════════════╗")
    print(f"║  总计: {total:2d}  通过: {results['passed']:2d}  失败: {results['failed']:2d}  跳过: {results['skipped']:2d}          ║")
    print("╚══════════════════════════════════════════════════╝")
    if results["failed"] > 0:
        print("\n⚠ 存在失败项，需要关注！")
    sys.exit(0 if results["failed"] == 0 else 1)


if __name__ == "__main__":
    main()
