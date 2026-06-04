import * as cheerio from 'cheerio';

/**
 * Legado CSS selector rule parser.
 *
 * 支持两种格式:
 *  1. 标准 CSS: `.item img@src`, `#info h1@text`
 *  2. Legado 自定义: `class.item@tag.img@src`, `id.list@tag.ul@tag.li`
 *
 * Legado 格式会自动转换为标准 CSS 再由 cheerio 执行。
 */
export function queryCss(html: string, rule: string): string[] {
  if (!rule || !html) return [];
  const $ = cheerio.load(html);

  const parts = parseRule(rule);
  let elements: any[];
  if (parts.textMatch) {
    const scope = parts.selector ? $(parts.selector) : $('body');
    const all = scope.find(`*:contains("${parts.textMatch}")`).toArray();
    if (all.length > 0) {
      elements = all.filter(el => {
        const $el = $(el);
        return $el.find(`*:contains("${parts.textMatch}")`).length === 0;
      });
    } else {
      elements = scope.toArray().filter(el => {
        return $(el).text().includes(parts.textMatch!);
      });
    }
  } else if (parts.selector) {
    elements = $(parts.selector).toArray();
  } else {
    const body = $('body');
    elements = body.length
      ? body.children().toArray()
      : $.root().children().toArray();
  }

  if (parts.exclude) {
    const excludeSet = new Set($(parts.exclude).toArray());
    elements = elements.filter(el => !excludeSet.has(el));
  }

  return elements.map(el => {
    const $el = $(el);
    switch (parts.attr) {
      case 'text':
        return $el.text().trim();
      case 'textNodes':
        return $el
          .contents()
          .filter((_, node) => node.type === 'text')
          .text()
          .trim();
      case 'html':
      case 'innerHTML':
        return $el.html() || '';
      case 'outerHtml':
        return $.html(el) || '';
      default:
        if (parts.attr) {
          return $el.attr(parts.attr) || '';
        }
        return $.html(el) || '';
    }
  });
}

export function queryCssFirst(html: string, rule: string): string {
  const results = queryCss(html, rule);
  return results[0] || '';
}

interface ParsedRule {
  selector: string;
  attr?: string;
  exclude?: string;
  textMatch?: string;
}

function isLegadoSegment(s: string): boolean {
  return /^(class|tag|id|text)\./.test(s);
}

/**
 * 把 legado 自定义 CSS 段转为标准 CSS。
 *
 * class.item     → .item
 * class.item.2   → .item:eq(2)
 * tag.p          → p
 * tag.p.1        → p:eq(1)
 * id.list        → #list
 * text.下一页     → :contains("下一页")
 * 非 legado 段    → 原样返回
 */
function convertSegment(seg: string): string {
  const s = seg.trim();
  if (!s) return '';

  if (s.startsWith('class.')) {
    const rest = s.slice(6);
    const m = rest.match(/^(.+?)\.(\d+)$/);
    if (m) return `.${m[1]}:eq(${m[2]})`;
    return `.${rest}`;
  }
  if (s.startsWith('tag.')) {
    const rest = s.slice(4);
    const m = rest.match(/^(.+?)\.(\d+)$/);
    if (m) return `${m[1]}:eq(${m[2]})`;
    return rest;
  }
  if (s.startsWith('id.')) {
    return `#${s.slice(3)}`;
  }
  if (s.startsWith('text.')) {
    return `__TEXT_MATCH__${s.slice(5)}`;
  }
  return s;
}

function parseRule(rule: string): ParsedRule {
  let main = rule;
  let attr: string | undefined;
  let exclude: string | undefined;

  // 1. 排除: selector!excludeSelector
  const exIdx = main.indexOf('!');
  if (exIdx > 0) {
    exclude = main.substring(exIdx + 1);
    main = main.substring(0, exIdx);
  }

  // 2. 按 @ 拆分
  const atParts = main.split('@');

  // 3. 最后一段: 如果不是 legado 选择器段，视为属性
  if (atParts.length > 1) {
    const last = atParts[atParts.length - 1];
    if (!isLegadoSegment(last)) {
      attr = last;
      atParts.pop();
    }
  }

  // 4. 转换每段为标准 CSS，用空格拼接（后代选择器）
  const converted = atParts.map(convertSegment).filter(Boolean);

  // 检测 text.XXX 标记
  let textMatch: string | undefined;
  const selectorParts: string[] = [];
  for (const part of converted) {
    if (part.startsWith('__TEXT_MATCH__')) {
      textMatch = part.slice('__TEXT_MATCH__'.length);
    } else {
      selectorParts.push(part);
    }
  }
  const selector = selectorParts.join(' ').trim();

  // 5. 排除也转换
  let convertedExclude: string | undefined;
  if (exclude) {
    const exParsed = parseRule(exclude);
    convertedExclude = exParsed.selector;
  }

  return {selector, attr, exclude: convertedExclude, textMatch};
}
