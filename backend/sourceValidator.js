// 万象书屋: 书源准确性校验
// 两层校验:
//   Layer 1 (shape) 同步: 必填字段 / 类型 / URL 合法性 / header / 模板占位符
//   Layer 2 (reach) 异步: 主域是否可达, 可选 searchUrl 渲染后能否拉到非空响应
// 不引入新依赖, 用 Node.js 22 自带的 global fetch.

const dns = require('dns').promises;

const VALID_TYPES = new Set([0, 1, 2, 3]); // text / audio / image / file

/**
 * 万象书屋: SSRF 防护. 拒绝 fetch 私网/本地/云元数据地址.
 * 这样即使 admin 添加恶意书源指向 http://169.254.169.254 (AWS metadata)
 * 或 http://localhost:6379 (Redis), validator 不会去请求, 防止借后端探内网.
 *
 * 注: 仅看 hostname 字面量是不够的 — 攻击者注册 evil.example.com A→127.0.0.1
 * 仍能绕过. 真正的检查在 isPrivateAddrAfterDns().
 */
function isPrivateHost(hostname) {
  if (!hostname) return true;
  const h = hostname.toLowerCase();
  if (h === 'localhost' || h === '0.0.0.0') return true;
  // IPv6 loopback / link-local / unique-local
  if (h === '::1' || h === '[::1]') return true;
  if (h.startsWith('fe80:') || h.startsWith('[fe80')) return true;
  if (h.startsWith('fc') || h.startsWith('fd')) return true; // fc00::/7 unique local
  // IPv4: 127.x, 10.x, 172.16-31.x, 192.168.x, 169.254.x (link local / AWS metadata)
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (m) {
    const [a, b] = [+m[1], +m[2]];
    if (a === 127 || a === 10) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 0) return true;
  }
  return false;
}

/** 判断已解析的 IP 地址是否私网 / 元数据地址 */
function isPrivateIp(ip) {
  if (!ip) return true;
  const lower = ip.toLowerCase();
  // IPv6 loopback / link-local / unique-local / mapped
  if (lower === '::1' || lower === '::') return true;
  if (lower.startsWith('fe80:')) return true;
  if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
  // ::ffff:127.0.0.1 (IPv4-mapped) → 转回检查
  const mapped = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPrivateIp(mapped[1]);
  const m = ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (m) {
    const [a, b] = [+m[1], +m[2]];
    if (a === 127 || a === 10) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64.0.0/10
    if (a === 0) return true;
    if (a >= 224) return true; // multicast / reserved
  }
  return false;
}

/**
 * 解析 hostname 并校验所有 A/AAAA 记录是否都不指向私网.
 * 返回 { ok: true } 或 { ok: false, reason }.
 * dns.lookup 走系统解析器, 与 fetch 走的解析器一致, 不会有"校验通过但 fetch 解到别的地址"的 race.
 */
async function isPrivateAddrAfterDns(hostname) {
  if (isPrivateHost(hostname)) return { ok: false, reason: 'private hostname literal' };
  try {
    // all=true 拿全部 A + AAAA 记录, 任何一条命中私网即拒绝
    const addrs = await dns.lookup(hostname, { all: true });
    for (const a of addrs) {
      if (isPrivateIp(a.address)) {
        return { ok: false, reason: `dns -> private ip ${a.address}` };
      }
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: 'dns: ' + (e.code || e.message) };
  }
}

/** 同步形状校验, 返回 {issues: [...]} */
function validateShape(src) {
  const issues = [];
  const push = (severity, field, msg) => issues.push({ severity, field, msg });

  if (!src || typeof src !== 'object' || Array.isArray(src)) {
    push('error', '_root', '必须是 JSON 对象');
    return { issues };
  }

  // 1. 必填核心字段
  if (typeof src.bookSourceUrl !== 'string' || !src.bookSourceUrl.trim()) {
    push('error', 'bookSourceUrl', '必填, 且为非空字符串');
  } else if (!/^https?:\/\//i.test(src.bookSourceUrl)) {
    push('error', 'bookSourceUrl', '必须以 http:// 或 https:// 开头');
  } else {
    try {
      // eslint-disable-next-line no-new
      new URL(src.bookSourceUrl);
    } catch {
      push('error', 'bookSourceUrl', '不是合法的 URL');
    }
  }

  if (typeof src.bookSourceName !== 'string' || !src.bookSourceName.trim()) {
    push('error', 'bookSourceName', '必填, 且为非空字符串');
  }

  if (src.bookSourceType !== undefined && !VALID_TYPES.has(Number(src.bookSourceType))) {
    push('warn', 'bookSourceType', '应为 0(文本) / 1(音频) / 2(图片) / 3(文件), 当前为 ' + src.bookSourceType);
  }

  // 2. header 字段必须是合法 JSON 字符串
  if (src.header) {
    if (typeof src.header !== 'string') {
      push('warn', 'header', '应为 JSON 字符串');
    } else {
      try {
        const parsed = JSON.parse(src.header);
        if (!parsed || typeof parsed !== 'object') {
          push('warn', 'header', 'JSON 解析后不是对象');
        }
      } catch (e) {
        push('warn', 'header', 'JSON 解析失败: ' + e.message);
      }
    }
  }

  // 3. searchUrl: 含 {{key}} 模板才算可搜
  if (src.searchUrl) {
    if (typeof src.searchUrl !== 'string') {
      push('warn', 'searchUrl', '应为字符串');
    } else if (!/\{\{key\}\}|\{\{page\}\}/.test(src.searchUrl)) {
      push('warn', 'searchUrl', '没有 {{key}} 占位符, 该源无法被搜索');
    }
  } else {
    push('info', 'searchUrl', '未配置, 该源不参与全网搜索 (仅作为发现/书架源使用)');
  }

  // 4. ruleSearch: 必须有 bookList + (name 或 bookUrl)
  if (src.ruleSearch) {
    if (typeof src.ruleSearch !== 'object') {
      push('warn', 'ruleSearch', '应为对象');
    } else {
      if (!src.ruleSearch.bookList) {
        push('warn', 'ruleSearch.bookList', '空, 搜索结果无法定位列表节点');
      }
      if (!src.ruleSearch.name && !src.ruleSearch.bookUrl) {
        push('warn', 'ruleSearch', 'name / bookUrl 都为空, 搜索结果不可点击');
      }
    }
  } else if (src.searchUrl) {
    push('warn', 'ruleSearch', '配置了 searchUrl 但没有 ruleSearch, 搜索结果无法解析');
  }

  // 5. ruleToc / ruleContent: 文本类书源没这两个就读不了
  if (Number(src.bookSourceType || 0) === 0) {
    if (!src.ruleToc || !src.ruleToc.chapterList) {
      push('warn', 'ruleToc.chapterList', '空, 无法解析目录');
    }
    if (!src.ruleContent || !src.ruleContent.content) {
      push('warn', 'ruleContent.content', '空, 无法解析正文');
    }
  }

  // 6. 万象书屋: 书源 JS 静态扫描.
  //    所有字符串字段递归扫描, 命中危险模式则记 warn (不直接 error,
  //    因为 legado 书源经常含 eval / Function 来反爬, 一刀切会误杀;
  //    管理员看到 warn 后可人工判断是否要禁用该源).
  scanJsContent(src, '', push);

  return { issues };
}

// 万象书屋: JS 静态扫描器
// 扫描书源 JSON 所有字符串字段, 识别可疑模式. 命中只记 warn 不阻止保存.
// 真正高危的 (远程 fetch http URL / 动态加载远程模块) 会标 error.
const DANGEROUS_JS_PATTERNS = [
  // 高危: 动态加载远程代码
  { sev: 'error', re: /\bimport\s*\(\s*['"]https?:\/\//i,
    msg: '动态 import 远程模块 (热更新/远程代码注入风险)' },
  { sev: 'error', re: /\bfetch\s*\(\s*['"]https?:\/\/(?!example\.|localhost|127\.)/i,
    msg: 'JS 内向第三方 URL 发起 fetch (可能是数据外发或上报)' },
  { sev: 'error', re: /<script[\s>][^<]*src\s*=\s*['"]https?:\/\//i,
    msg: '内嵌 <script src=远程地址> 标签' },

  // 中危: 动态执行 (legado 书源常见, 不一定是恶意)
  { sev: 'warn', re: /\beval\s*\(/,
    msg: '使用 eval() (动态执行字符串)' },
  { sev: 'warn', re: /\bnew\s+Function\s*\(/,
    msg: '使用 new Function() (动态构造代码)' },
  { sev: 'warn', re: /\bFunction\s*\(\s*['"][^'"]{20,}['"]\s*\)/,
    msg: '使用 Function(longString) 形式动态执行' },

  // 中危: 浏览器存储 / cookie 写入
  { sev: 'warn', re: /document\.cookie\s*=[^=]/,
    msg: '写入 document.cookie' },
  { sev: 'warn', re: /\b(local|session)Storage\.setItem\s*\(/,
    msg: '写入浏览器 localStorage / sessionStorage' },

  // 提示: 网络通讯 API (本身合法但管理员应知情)
  { sev: 'info', re: /\bXMLHttpRequest\b/,
    msg: '使用 XMLHttpRequest (规则用于跨域抓取常见)' },
];

function scanJsContent(value, path, push) {
  if (value == null) return;
  if (typeof value === 'string') {
    if (value.length < 8) return;
    for (const p of DANGEROUS_JS_PATTERNS) {
      if (p.re.test(value)) {
        push(p.sev, 'js:' + (path || '_root'), 'JS 静态扫描: ' + p.msg);
        // 同一字段只报最严重一次, 防止 issues 列表爆炸
        return;
      }
    }
    return;
  }
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      scanJsContent(value[i], path ? path + '[' + i + ']' : '[' + i + ']', push);
    }
    return;
  }
  if (typeof value === 'object') {
    for (const k of Object.keys(value)) {
      // 跳过明显非 JS 字段 (URL / 名称 / 时间戳), 减小误报和扫描成本
      if (k === 'bookSourceUrl' || k === 'bookSourceName' ||
          k === 'lastUpdateTime' || k === 'customOrder' ||
          k === 'enabled' || k === 'enabledExplore' || k === 'enabledCookieJar' ||
          k === 'bookSourceType' || k === 'bookSourceComment' ||
          k === 'weight') continue;
      scanJsContent(value[k], path ? path + '.' + k : k, push);
    }
  }
}

/** 取 issues 中最严重的级别. error > warn > info > ok */
function severityOf(issues) {
  if (issues.some(i => i.severity === 'error')) return 'error';
  if (issues.some(i => i.severity === 'warn')) return 'warn';
  if (issues.some(i => i.severity === 'info')) return 'info';
  return 'ok';
}

/**
 * 拉取 url, 返回 {status, ok, ms, error?, bodyLen}.
 * - 5 秒硬超时
 * - 拒绝私网地址 (SSRF 防护)
 * - body 流式读, 超过 MAX_BODY 立即 abort, 不占内存
 * - 失败不抛
 */
const MAX_BODY = 256 * 1024; // 256KB 足够判断"搜索响应有没有内容"

async function probeUrl(url, { timeoutMs = 5000, method = 'GET', maxRedirects = 5 } = {}) {
  const t0 = Date.now();
  // 万象书屋: 自前 redirect:'follow' 由 fetch 内部处理, 只有第一跳 hostname 进过 SSRF 校验,
  // 30x Location 跳到私网照样被发出 → SSRF 攻击成立.
  // 改为 redirect:'manual', 自己一跳一跳跑, 每跳都过 isPrivateAddrAfterDns 检查.
  let currentUrl = url;
  for (let hop = 0; hop <= maxRedirects; hop++) {
    let parsed;
    try {
      parsed = new URL(currentUrl);
    } catch {
      return { status: 0, ok: false, ms: Date.now() - t0, error: 'invalid url' };
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return { status: 0, ok: false, ms: Date.now() - t0, error: 'blocked: non-http scheme' };
    }
    const ssrf = await isPrivateAddrAfterDns(parsed.hostname);
    if (!ssrf.ok) {
      return { status: 0, ok: false, ms: Date.now() - t0, error: 'blocked: ' + ssrf.reason };
    }

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    let resp;
    try {
      resp = await fetch(currentUrl, {
        method,
        redirect: 'manual',
        signal: ctrl.signal,
        headers: {
          'User-Agent':
            'Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      });
    } catch (err) {
      clearTimeout(timer);
      return {
        status: 0, ok: false, ms: Date.now() - t0,
        error: err.name === 'AbortError' ? 'timeout' : err.message,
      };
    }
    clearTimeout(timer);

    // 30x: 拿 Location, 解析成绝对 URL, 下一跳再校验 SSRF
    if (resp.status >= 300 && resp.status < 400) {
      const loc = resp.headers.get('location');
      if (!loc) {
        return { status: resp.status, ok: false, ms: Date.now() - t0, error: 'redirect without location' };
      }
      try {
        currentUrl = new URL(loc, currentUrl).toString();
      } catch {
        return { status: resp.status, ok: false, ms: Date.now() - t0, error: 'invalid redirect location' };
      }
      // 取消未读 body 释放连接
      try { resp.body?.cancel(); } catch {}
      continue;
    }

    // 终态响应: 流式读 body 限 MAX_BODY
    let bodyLen = 0;
    if (method === 'GET' && resp.body) {
      const reader = resp.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bodyLen += value.byteLength;
        if (bodyLen >= MAX_BODY) {
          try { reader.cancel(); } catch {}
          break;
        }
      }
    }
    return { status: resp.status, ok: resp.ok, ms: Date.now() - t0, bodyLen, finalUrl: currentUrl };
  }
  return { status: 0, ok: false, ms: Date.now() - t0, error: 'too many redirects' };
}

/** 把 searchUrl 模板渲染成可访问的绝对 URL. 失败返 null. */
function renderSearchUrl(src, key = '修真') {
  if (!src.searchUrl || !src.bookSourceUrl) return null;
  const rendered = src.searchUrl.replace(/\{\{\s*key\s*\}\}/g, encodeURIComponent(key));
  // legado searchUrl 可能含 ',{...}' 后置参数 (POST body 等), 先剥掉
  const onlyUrl = rendered.split(',')[0];
  try {
    return new URL(onlyUrl, src.bookSourceUrl).toString();
  } catch {
    return null;
  }
}

/**
 * 综合校验单条书源.
 * @param {object} src 解析好的源对象
 * @param {object} opts {checkReach=true, checkSearch=false, timeoutMs=5000}
 * @returns {Promise<{name, url, severity, issues, reach?, search?}>}
 */
async function validateOne(src, opts = {}) {
  const { checkReach = true, checkSearch = false, timeoutMs = 5000 } = opts;
  const shape = validateShape(src);
  const result = {
    url: src && src.bookSourceUrl,
    name: src && src.bookSourceName,
    issues: shape.issues,
  };

  // shape 有 error 直接返, 不做 reach (无意义)
  const hasError = shape.issues.some(i => i.severity === 'error');
  if (!hasError && checkReach) {
    result.reach = await probeUrl(src.bookSourceUrl, { timeoutMs, method: 'GET' });
    if (!result.reach.ok) {
      result.issues.push({
        severity: 'error',
        field: 'bookSourceUrl',
        msg: `主域不可达: status=${result.reach.status}${result.reach.error ? ' ' + result.reach.error : ''}`,
      });
    }
  }

  if (!hasError && checkSearch && src.searchUrl) {
    const searchUrl = renderSearchUrl(src);
    if (!searchUrl) {
      result.issues.push({ severity: 'warn', field: 'searchUrl', msg: '渲染失败 (URL 拼接错误)' });
    } else {
      result.search = await probeUrl(searchUrl, { timeoutMs, method: 'GET' });
      result.search.url = searchUrl;
      if (!result.search.ok) {
        result.issues.push({
          severity: 'warn',
          field: 'searchUrl',
          msg: `搜索接口不可达: status=${result.search.status}${result.search.error ? ' ' + result.search.error : ''}`,
        });
      } else if (result.search.bodyLen != null && result.search.bodyLen < 200) {
        // 200 字节以下的响应基本不可能含真实搜索结果
        result.issues.push({
          severity: 'warn',
          field: 'searchUrl',
          msg: `搜索响应过短 (${result.search.bodyLen}B), 可能被反爬拦截`,
        });
      }
    }
  }

  result.severity = severityOf(result.issues);
  return result;
}

/**
 * 批量校验, 简单并发池.
 * @param {Array<object>} sources
 * @param {object} opts {concurrency=8, ...同 validateOne}
 * @returns {Promise<{total, ok, warn, error, results}>}
 */
async function validateAll(sources, opts = {}) {
  const { concurrency = 8, ...vOpts } = opts;
  const results = new Array(sources.length);
  let cursor = 0;
  async function worker() {
    while (true) {
      const idx = cursor++;
      if (idx >= sources.length) break;
      results[idx] = await validateOne(sources[idx], vOpts);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, sources.length) }, worker));
  const ok = results.filter(r => r.severity === 'ok').length;
  const warn = results.filter(r => r.severity === 'warn' || r.severity === 'info').length;
  const error = results.filter(r => r.severity === 'error').length;
  return { total: results.length, ok, warn, error, results };
}

module.exports = {
  validateShape, validateOne, validateAll, severityOf, probeUrl, renderSearchUrl,
  // 导出 SSRF 工具函数, 单元测试可直接覆盖
  isPrivateHost, isPrivateIp, isPrivateAddrAfterDns,
};
