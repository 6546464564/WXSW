/**
 * 万象书屋 RN · legado 完整规则引擎
 * 对应 iOS: LegadoRuleEngine.swift
 * 对应 Android: AnalyzeRule + RuleAnalyzer
 *
 * 完整流程:
 *  1. RuleParser.split: 按 && || %% 切成 [SourceRule]
 *  2. 每个 SourceRule 推断 Mode (CSS/XPath/JSON/JS/Regex)
 *  3. expandTemplate: 把 {{...}} / @get / $1-$9 占位符解出来
 *  4. select: 在 result 上跑 selector → 新 result
 *  5. ##regex##replace: 后处理
 *  6. 链式 reduce
 *
 * 分流操作符:
 *  - || 短路 (prev 非空就停)
 *  - && 串联 (next 在 prev 结果上继续)
 *  - %% 交错合并 (按 index 拉链)
 *  - 前缀 - 倒置
 */

import axios from 'axios';
import {
  BookSource,
  LegadoContext,
  LegadoMode,
  LegadoSourceRule,
  SearchResult,
  BookInfo,
  Chapter,
} from './types';
import {splitTop, parseSingle} from './LegadoRuleParser';
import {queryCss, queryCssFirst} from './parsers/CssParser';
import {queryJsonPath, queryJsonPathFirst} from './parsers/JsonPathParser';
import {applyReplaceRules} from './parsers/RegexParser';
import {evaluateJs} from './JsRunner';

const MAX_RECURSION_DEPTH = 16;
const MAX_LIST_SIZE = 2000;
const MAX_SOURCE_LENGTH = 2_000_000; // 2MB

function clampSource(s: string): string {
  if (s.length > MAX_SOURCE_LENGTH) return s.slice(0, MAX_SOURCE_LENGTH);
  return s;
}

function stringify(val: any): string {
  if (val === null || val === undefined) return '';
  if (typeof val === 'string') return val;
  if (typeof val === 'object') {
    try {
      return JSON.stringify(val);
    } catch {
      return String(val);
    }
  }
  return String(val);
}

function toStringList(val: any): string[] {
  if (Array.isArray(val)) return val.map(stringify);
  const s = stringify(val);
  return s ? [s] : [];
}

function looksLikeJSON(s: string): boolean {
  const t = s.trimStart();
  return t.startsWith('{') || t.startsWith('[');
}

export class RuleEngine {
  private putStore: Record<string, Record<string, string>> = {};

  // MARK: - Put/Get Store

  putValue(value: string, key: string, sourceKey: string) {
    if (!this.putStore[sourceKey]) this.putStore[sourceKey] = {};
    this.putStore[sourceKey][key] = value;
  }

  getValue(key: string, sourceKey: string): string | undefined {
    return this.putStore[sourceKey]?.[key];
  }

  private getPutBag(ctx: LegadoContext): Record<string, string> {
    const key = ctx.bookSource?.bookSourceUrl || 'default';
    return this.putStore[key] || {};
  }

  private setPut(k: string, v: string, ctx: LegadoContext) {
    const key = ctx.bookSource?.bookSourceUrl || 'default';
    if (!this.putStore[key]) this.putStore[key] = {};
    this.putStore[key][k] = v;
  }

  resetPutStore(sourceKey?: string) {
    if (sourceKey) {
      delete this.putStore[sourceKey];
    } else {
      this.putStore = {};
    }
  }

  // MARK: - Public API

  /**
   * 取列表 (返多条结果)
   */
  async selectList(
    rule: string,
    source: string,
    ctx?: Partial<LegadoContext>,
  ): Promise<string[]> {
    const context = this.makeContext(source, ctx);
    return this.evalToList(rule, source, context, 0);
  }

  /**
   * 取单值
   */
  async selectString(
    rule: string,
    source: string,
    ctx?: Partial<LegadoContext>,
  ): Promise<string> {
    const context = this.makeContext(source, ctx);
    const list = await this.evalToList(rule, source, context, 0);
    return list[0] || '';
  }

  private makeContext(source: string, partial?: Partial<LegadoContext>): LegadoContext {
    return {
      baseUrl: partial?.baseUrl,
      source: source,
      key: partial?.key,
      page: partial?.page ?? 1,
      book: partial?.book ?? {},
      chapter: partial?.chapter ?? {},
      nextChapterUrl: partial?.nextChapterUrl,
      bookSource: partial?.bookSource,
    };
  }

  // MARK: - 核心三层: || → %% → &&

  /**
   * 顶层: || fallback (前面有非空结果就停)
   */
  private async evalToList(
    ruleStr: string,
    input: any,
    ctx: LegadoContext,
    depth: number,
  ): Promise<string[]> {
    if (depth > MAX_RECURSION_DEPTH) return [];

    const boundedInput =
      typeof input === 'string' ? clampSource(input) : input;
    const boundedCtx = {...ctx, source: clampSource(ctx.source)};

    // 检测开头 <js>...</js>\nrest 模式
    const jsBlock = this.stripLeadingJSBlock(ruleStr);
    if (jsBlock && jsBlock.rest) {
      const scope = {
        baseUrl: boundedCtx.baseUrl,
        src: boundedCtx.source,
        result: stringify(boundedInput),
        key: boundedCtx.key,
        page: boundedCtx.page,
        bookSource: boundedCtx.bookSource,
        book: boundedCtx.book,
        chapter: boundedCtx.chapter,
      };
      let newSource: string;
      try {
        const v = await evaluateJs(jsBlock.code, scope);
        newSource = stringify(v);
      } catch {
        newSource = stringify(boundedInput);
      }
      const newCtx = {...boundedCtx, source: newSource};
      return this.evalToList(jsBlock.rest, newSource, newCtx, depth + 1);
    }

    // || fallback
    const orBranches = splitTop(ruleStr, ['||'], false);
    for (const branch of orBranches) {
      const merged = await this.evalZipOrAnd(branch, boundedInput, boundedCtx);
      if (merged.length > 0 && !(merged.length === 1 && merged[0] === '')) {
        return merged;
      }
    }
    return [];
  }

  /**
   * 第二层: %% 拉链 + && 串联 + 前缀 - 倒置
   */
  private async evalZipOrAnd(
    ruleStr: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string[]> {
    let rs = ruleStr.trim();
    let invertList = false;
    if (rs.startsWith('-')) {
      invertList = true;
      rs = rs.slice(1).trim();
    }

    const zipSegs = splitTop(rs, ['%%'], false);
    let out: string[];

    if (zipSegs.length === 1) {
      out = await this.evalAnd(zipSegs[0], input, ctx);
    } else {
      const lists: string[][] = [];
      for (const seg of zipSegs) {
        lists.push(await this.evalAnd(seg, input, ctx));
      }
      out = this.zipLegadoLists(lists);
    }

    return invertList ? out.reverse() : out;
  }

  /**
   * Android zip 逻辑: 按 index 交错
   */
  private zipLegadoLists(lists: string[][]): string[] {
    if (!lists.length || !lists[0].length) return [];
    const result: string[] = [];
    const rowCount = lists[0].length;
    for (let i = 0; i < rowCount; i++) {
      for (const list of lists) {
        if (i < list.length) {
          result.push(list[i]);
        }
      }
    }
    return result;
  }

  /**
   * 第三层: && 串联 (每段在前一段结果上继续)
   */
  private async evalAnd(
    ruleStr: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string[]> {
    const andSegs = splitTop(ruleStr, ['&&']);
    if (andSegs.length === 1) {
      const sr = parseSingle(andSegs[0]);
      const r = await this.applyRule(sr, input, ctx, true);
      return toStringList(r).slice(0, MAX_LIST_SIZE);
    }

    let current: string[] = [stringify(input)];
    for (const seg of andSegs) {
      const sr = parseSingle(seg);
      const nextResults: string[] = [];
      for (const src of current) {
        const r = await this.applyRule(sr, src, ctx, true);
        const list = toStringList(r);
        nextResults.push(...list);
        if (nextResults.length >= MAX_LIST_SIZE) break;
      }
      current = nextResults.slice(0, MAX_LIST_SIZE);
      if (current.length === 0) break;
    }
    return current;
  }

  // MARK: - applyRule

  private async applyRule(
    rule: LegadoSourceRule,
    input: any,
    ctx: LegadoContext,
    listMode: boolean,
  ): Promise<any> {
    // 1. 展开模板
    const resolvedRule = await this.expandTemplate(rule.rule, input, ctx);
    const mode = rule.mode;
    const srcStr = clampSource(stringify(input));

    // 2. 主体 select
    let midResult: string[];

    switch (mode) {
      case LegadoMode.Raw:
        midResult = [resolvedRule];
        break;

      case LegadoMode.JS: {
        const r = await this.runJS(resolvedRule, input, ctx);
        midResult = toStringList(r);
        break;
      }

      case LegadoMode.CSS: {
        if (listMode) {
          midResult = queryCss(srcStr, resolvedRule);
        } else {
          const v = queryCssFirst(srcStr, resolvedRule);
          midResult = v ? [v] : [];
        }
        // CSS fallback to JSON (legado 兼容)
        if (midResult.length === 0 && looksLikeJSON(srcStr) && !resolvedRule.startsWith('@')) {
          let jpathRule: string;
          if (resolvedRule.startsWith('$')) {
            jpathRule = resolvedRule;
          } else if (resolvedRule.startsWith('[')) {
            jpathRule = '$' + resolvedRule;
          } else {
            jpathRule = '$.' + resolvedRule;
          }
          if (listMode) {
            midResult = queryJsonPath(srcStr, jpathRule).map(stringify);
          } else {
            const v = queryJsonPathFirst(srcStr, jpathRule);
            midResult = v ? [stringify(v)] : [];
          }
        }
        break;
      }

      case LegadoMode.XPath: {
        // RN 没有原生 XPath，对 HTML 用 cheerio 模拟基础 XPath
        // 复杂 XPath 规则回退到 CSS
        midResult = this.evalXPath(srcStr, resolvedRule, listMode);
        break;
      }

      case LegadoMode.JSON: {
        if (listMode) {
          midResult = queryJsonPath(srcStr, resolvedRule).map(stringify);
        } else {
          const v = queryJsonPathFirst(srcStr, resolvedRule);
          midResult = v !== undefined && v !== '' ? [stringify(v)] : [];
        }
        break;
      }

      case LegadoMode.Regex: {
        if (rule.isAllInOneRegex) {
          midResult = this.regexAllInOne(resolvedRule, srcStr);
        } else {
          midResult = [resolvedRule];
        }
        break;
      }

      default:
        midResult = [];
    }

    // 3. ##regex##replace 后处理
    if (rule.replaceRegex) {
      midResult = midResult.map(v => this.applyReplace(v, rule));
    }

    // 4. 返回
    if (!listMode) return midResult[0] || '';
    return midResult;
  }

  // MARK: - JS 执行

  private async runJS(script: string, result: any, ctx: LegadoContext): Promise<any> {
    const scope = {
      baseUrl: ctx.baseUrl,
      src: ctx.source,
      result,
      key: ctx.key,
      page: ctx.page,
      bookSource: ctx.bookSource,
      book: ctx.book,
      chapter: ctx.chapter,
      nextChapterUrl: ctx.nextChapterUrl,
    };
    return evaluateJs(script, scope);
  }

  // MARK: - 模板展开

  private async expandTemplate(
    template: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string> {
    let s = template;

    // 0. <X,Y> 页码选择器
    s = this.expandPagePicker(s, ctx.page);

    // 1. 简单变量
    if (ctx.key) {
      const enc = encodeURIComponent(ctx.key);
      s = s.replace(/\{\{key\}\}/g, enc);
      s = s.replace(/\{\{searchKey\}\}/g, enc);
    }
    s = s.replace(/\{\{page\}\}/g, String(ctx.page));

    // book.xxx
    for (const [k, v] of Object.entries(ctx.book)) {
      s = s.replace(new RegExp(`\\{\\{book\\.${k}\\}\\}`, 'g'), v);
      s = s.replace(new RegExp(`\\{\\{\\$\\.book\\.${k}\\}\\}`, 'g'), v);
    }

    // 2. <js>...</js> 内联 JS
    s = await this.replaceInlineJS(s, input, ctx);

    // 3. {{...}} 占位符
    s = await this.replaceMustache(s, input, ctx);

    // 4. @get:key
    if (s.includes('@get:')) {
      const bag = this.getPutBag(ctx);
      s = s.replace(/@get:\{?(\w+)\}?/g, (_match, key) => {
        return ctx.book[key] || bag[key] || '';
      });
    }

    // 5. @put:{key:rule}
    if (s.includes('@put:')) {
      s = await this.applyPutDirectives(s, input, ctx);
    }

    return s;
  }

  /**
   * <X,Y> — 第1页取X，第2页起取Y
   */
  private expandPagePicker(s: string, page: number): string {
    if (!s.includes('<') || !s.includes('>') || !s.includes(',')) return s;
    return s.replace(/<([^<>,\n\r]*),([^<>\n\r]*)>/g, (_m, x, y) => {
      return page <= 1 ? x : y;
    });
  }

  /**
   * 替换 <js>...</js> 内联 JS
   */
  private async replaceInlineJS(
    s: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string> {
    if (!s.includes('<js>')) return s;
    let result = s;
    let safety = 0;
    while (result.includes('<js>') && safety++ < 10) {
      const openIdx = result.indexOf('<js>');
      const closeIdx = result.indexOf('</js>', openIdx + 4);
      if (closeIdx < 0) break;
      const script = result.slice(openIdx + 4, closeIdx);
      const v = await this.runJS(script, input, ctx);
      result =
        result.slice(0, openIdx) + stringify(v) + result.slice(closeIdx + 5);
    }
    return result;
  }

  /**
   * 替换 {{...}} 占位符
   */
  private async replaceMustache(
    s: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string> {
    if (!s.includes('{{')) return s;

    let result = s;
    let safety = 0;
    while (result.includes('{{') && safety++ < 20) {
      const openIdx = result.indexOf('{{');
      const closeIdx = result.indexOf('}}', openIdx + 2);
      if (closeIdx < 0) break;
      const inner = result.slice(openIdx + 2, closeIdx);

      let value: string;
      // 判断内部规则类型
      if (inner.startsWith('$.') || inner.startsWith('$[')) {
        // JSONPath
        value = stringify(queryJsonPathFirst(stringify(input), inner));
      } else if (inner.startsWith('//') || inner.includes('/@')) {
        // XPath
        const results = this.evalXPath(stringify(input), inner, false);
        value = results[0] || '';
      } else if (inner.includes('(') && inner.includes(')')) {
        // JS 表达式 (e.g. java.put('key',key))
        try {
          const v = await this.runJS(inner, input, ctx);
          value = stringify(v);
        } catch {
          value = '';
        }
      } else {
        // 默认 CSS 或纯值
        value = queryCssFirst(stringify(input), inner);
        if (!value && looksLikeJSON(stringify(input))) {
          value = stringify(queryJsonPathFirst(stringify(input), '$.' + inner));
        }
      }

      result = result.slice(0, openIdx) + value + result.slice(closeIdx + 2);
    }
    return result;
  }

  /**
   * @put:{key:rule} 处理
   */
  private async applyPutDirectives(
    s: string,
    input: any,
    ctx: LegadoContext,
  ): Promise<string> {
    let out = s;
    let safety = 0;
    while (out.includes('@put:{') && safety++ < 10) {
      const openIdx = out.indexOf('@put:{');
      if (openIdx < 0) break;

      // 找配对的 }
      let depth = 1;
      let idx = openIdx + 6;
      let closeIdx = -1;
      while (idx < out.length) {
        if (out[idx] === '{') depth++;
        else if (out[idx] === '}') {
          depth--;
          if (depth === 0) {
            closeIdx = idx;
            break;
          }
        }
        idx++;
      }
      if (closeIdx < 0) break;

      const inner = out.slice(openIdx + 6, closeIdx);
      // 解析 key:rule 对
      const colonIdx = inner.indexOf(':');
      if (colonIdx > 0) {
        const key = inner.slice(0, colonIdx).trim();
        let ruleStr = inner.slice(colonIdx + 1).trim();
        // 去引号
        if (
          (ruleStr.startsWith('"') && ruleStr.endsWith('"')) ||
          (ruleStr.startsWith("'") && ruleStr.endsWith("'"))
        ) {
          ruleStr = ruleStr.slice(1, -1);
        }
        if (key && ruleStr) {
          const v = await this.selectString(ruleStr, stringify(input), {
            ...ctx,
          });
          this.setPut(key, v, ctx);
        }
      }

      // 删除 @put:{...}
      out = out.slice(0, openIdx) + out.slice(closeIdx + 1);
    }
    return out;
  }

  // MARK: - XPath 模拟

  private evalXPath(html: string, rule: string, listMode: boolean): string[] {
    // RN 没有原生 XPath DOM 支持
    // 基础 XPath 转 CSS 实现 (覆盖常见 legado 用法)
    const cssRule = this.xpathToCSS(rule);
    if (cssRule) {
      if (listMode) {
        return queryCss(html, cssRule);
      }
      const v = queryCssFirst(html, cssRule);
      return v ? [v] : [];
    }
    return [];
  }

  /**
   * 基础 XPath → CSS 转换 (覆盖 legado 常见模式)
   */
  private xpathToCSS(xpath: string): string | null {
    let r = xpath.trim();
    // //tag → tag
    r = r.replace(/^\/\//, '');
    // /text() → @text
    r = r.replace(/\/text\(\)$/, '@text');
    // /@attr → @attr
    r = r.replace(/\/@(\w+)$/, '@$1');
    // tag[@attr='val'] → tag[attr="val"]
    r = r.replace(/\[@(\w+)='([^']+)'\]/g, '[$1="$2"]');
    r = r.replace(/\[@(\w+)="([^"]+)"\]/g, '[$1="$2"]');
    // / → >  (child)
    r = r.replace(/\//g, ' > ');
    // 清理
    r = r.replace(/\s+/g, ' ').trim();
    return r || null;
  }

  // MARK: - Regex

  private regexAllInOne(pattern: string, source: string): string[] {
    try {
      const regex = new RegExp(pattern, 'g');
      const results: string[] = [];
      let match: RegExpExecArray | null;
      while ((match = regex.exec(source)) !== null) {
        // 生成 {"$0":full, "$1":group1, ...} JSON
        const obj: Record<string, string> = {'$0': match[0]};
        for (let i = 1; i < match.length; i++) {
          obj[`$${i}`] = match[i] || '';
        }
        results.push(JSON.stringify(obj));
      }
      return results;
    } catch {
      return [];
    }
  }

  private applyReplace(value: string, rule: LegadoSourceRule): string {
    if (!rule.replaceRegex) return value;
    try {
      const flags = rule.replaceFirst ? '' : 'g';
      const regex = new RegExp(rule.replaceRegex, flags);
      return value.replace(regex, rule.replacement);
    } catch {
      return value;
    }
  }

  // MARK: - Helpers

  private stripLeadingJSBlock(
    ruleStr: string,
  ): {code: string; rest: string} | null {
    const trimmed = ruleStr.trim();
    if (!trimmed.startsWith('<js>')) return null;
    const closeIdx = trimmed.indexOf('</js>');
    if (closeIdx < 0) return null;
    const code = trimmed.slice(4, closeIdx).trim();
    const rest = trimmed.slice(closeIdx + 5).trim();
    if (!rest) return null;
    return {code, rest};
  }

  // MARK: - HTTP

  private async fetchHtml(url: string, source: BookSource): Promise<string> {
    const headers: Record<string, string> = {};
    if (source.header) {
      try {
        let h = source.header.trim();
        if (h.startsWith('@js:')) {
          const jsCode = h.slice(4);
          const ctx: Partial<LegadoContext> = {
            baseUrl: source.bookSourceUrl,
            bookSource: source,
            book: {},
            chapter: {},
          };
          const v = await this.runJS(jsCode, '', this.makeContext('', ctx));
          if (typeof v === 'string') {
            h = v;
          } else if (v && typeof v === 'object') {
            Object.assign(headers, v);
            h = '';
          }
        }
        if (h && h.startsWith('{')) {
          Object.assign(headers, JSON.parse(h));
        }
      } catch {}
    }
    for (const [k, v] of Object.entries(headers)) {
      headers[k] = v
        .replace(/\{\{baseUrl\}\}/g, source.bookSourceUrl)
        .replace(/\{\{origin\}\}/g, source.bookSourceUrl);
    }
    const res = await axios.get(url, {headers, timeout: 10000});
    return typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
  }

  private resolveUrl(path: string, baseUrl: string): string {
    if (!path) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (path.startsWith('//')) return 'https:' + path;
    if (path.startsWith('/')) {
      try {
        const u = new URL(baseUrl);
        return u.origin + path;
      } catch {
        return path;
      }
    }
    return baseUrl.replace(/\/[^/]*$/, '/') + path;
  }

  // MARK: - 高层 API (搜索/书详/目录/正文)

  /**
   * 渲染 URL 模板
   */
  async renderURL(
    template: string,
    ctx: Partial<LegadoContext>,
  ): Promise<string> {
    const fullCtx = this.makeContext('', ctx);
    const trimmed = template.trim();
    if (trimmed.startsWith('@js:')) {
      const jsCode = trimmed.slice(4);
      const v = await this.runJS(jsCode, '', fullCtx);
      return stringify(v);
    }
    return this.expandTemplate(template, '', fullCtx);
  }

  async search(source: BookSource, keyword: string): Promise<SearchResult[]> {
    if (!source.searchUrl || !source.ruleSearch) return [];

    const ctx: Partial<LegadoContext> = {
      baseUrl: source.bookSourceUrl,
      key: keyword,
      page: 1,
      bookSource: source,
      book: {},
      chapter: {},
    };

    // 渲染搜索 URL
    const searchUrl = await this.renderURL(source.searchUrl, ctx);
    const resolvedUrl = this.resolveUrl(searchUrl, source.bookSourceUrl);

    const html = await this.fetchHtml(resolvedUrl, source);
    const rules = source.ruleSearch;

    const fullCtx: LegadoContext = {
      baseUrl: resolvedUrl,
      source: html,
      key: keyword,
      page: 1,
      bookSource: source,
      book: {},
      chapter: {},
    };

    // 获取书列表
    if (!rules.bookList) return [];
    const bookList = await this.selectList(rules.bookList, html, fullCtx);

    const results: SearchResult[] = [];
    for (const item of bookList.slice(0, 20)) {
      const itemCtx = {...fullCtx, source: item};
      const name = rules.name
        ? await this.selectString(rules.name, item, itemCtx)
        : '';
      const author = rules.author
        ? await this.selectString(rules.author, item, itemCtx)
        : '';
      const bookUrl = rules.bookUrl
        ? this.resolveUrl(
            await this.selectString(rules.bookUrl, item, itemCtx),
            resolvedUrl,
          )
        : '';
      const coverUrl = rules.coverUrl
        ? this.resolveUrl(
            await this.selectString(rules.coverUrl, item, itemCtx),
            resolvedUrl,
          )
        : undefined;
      const intro = rules.intro
        ? await this.selectString(rules.intro, item, itemCtx)
        : undefined;
      const kind = rules.kind
        ? await this.selectString(rules.kind, item, itemCtx)
        : undefined;

      if (name || bookUrl) {
        const lastChapter = rules.lastChapter
          ? await this.selectString(rules.lastChapter, item, itemCtx)
          : undefined;
        const wordCount = rules.wordCount
          ? await this.selectString(rules.wordCount, item, itemCtx)
          : undefined;
        results.push({
          name,
          author,
          intro,
          kind,
          coverUrl,
          bookUrl,
          lastChapter,
          wordCount,
          sourceUrl: source.bookSourceUrl,
          sourceName: source.bookSourceName,
          distinctOriginCount: 1,
          mergedSourceURLs: [],
          mergedSourceNames: [],
        });
      }
    }
    return results;
  }

  async getBookInfo(source: BookSource, bookUrl: string): Promise<BookInfo> {
    const html = await this.fetchHtml(bookUrl, source);
    const rules = source.ruleBookInfo;
    if (!rules) return {name: '', author: ''};

    const ctx: LegadoContext = {
      baseUrl: bookUrl,
      source: html,
      page: 1,
      bookSource: source,
      book: {},
      chapter: {},
    };

    // 执行 init 规则 (预处理)
    if (rules.init) {
      await this.selectString(rules.init, html, ctx);
    }

    const name = rules.name
      ? await this.selectString(rules.name, html, ctx)
      : '';
    const author = rules.author
      ? await this.selectString(rules.author, html, ctx)
      : '';
    const intro = rules.intro
      ? await this.selectString(rules.intro, html, ctx)
      : undefined;
    const coverUrl = rules.coverUrl
      ? this.resolveUrl(
          await this.selectString(rules.coverUrl, html, ctx),
          bookUrl,
        )
      : undefined;
    const tocUrl = rules.tocUrl
      ? this.resolveUrl(
          await this.selectString(rules.tocUrl, html, ctx),
          bookUrl,
        )
      : undefined;
    const kind = rules.kind
      ? await this.selectString(rules.kind, html, ctx)
      : undefined;
    const lastChapter = rules.lastChapter
      ? await this.selectString(rules.lastChapter, html, ctx)
      : undefined;

    // 写入 book context
    ctx.book = {name, author};
    if (intro) ctx.book.intro = intro;
    if (kind) ctx.book.kind = kind;

    return {name, author, intro, kind, coverUrl, tocUrl, lastChapter};
  }

  async getToc(
    source: BookSource,
    tocUrl: string,
    bookCtx?: Record<string, string>,
  ): Promise<Chapter[]> {
    const html = await this.fetchHtml(tocUrl, source);
    const rules = source.ruleToc;
    if (!rules) return [];

    const ctx: LegadoContext = {
      baseUrl: tocUrl,
      source: html,
      page: 1,
      bookSource: source,
      book: bookCtx || {},
      chapter: {},
    };

    // preUpdateJs
    if (rules.preUpdateJs) {
      await this.runJS(rules.preUpdateJs, html, ctx);
    }

    if (!rules.chapterList) return [];
    const chapterList = await this.selectList(rules.chapterList, html, ctx);

    const chapters: Chapter[] = [];
    for (let i = 0; i < chapterList.length; i++) {
      const item = chapterList[i];
      const itemCtx = {...ctx, source: item};
      const title = rules.chapterName
        ? await this.selectString(rules.chapterName, item, itemCtx)
        : `第${i + 1}章`;
      const url = rules.chapterUrl
        ? this.resolveUrl(
            await this.selectString(rules.chapterUrl, item, itemCtx),
            tocUrl,
          )
        : '';

      if (title || url) {
        chapters.push({
          title,
          url,
          index: i,
          isVolume: rules.isVolume
            ? (await this.selectString(rules.isVolume, item, itemCtx)) === 'true'
            : false,
        });
      }
    }

    // nextTocUrl (分页目录)
    if (rules.nextTocUrl) {
      const nextUrl = await this.selectString(rules.nextTocUrl, html, ctx);
      if (nextUrl && nextUrl !== tocUrl) {
        const nextChapters = await this.getToc(source, this.resolveUrl(nextUrl, tocUrl), bookCtx);
        for (const ch of nextChapters) {
          ch.index = chapters.length + ch.index;
          chapters.push(ch);
        }
      }
    }

    return chapters;
  }

  async getContent(
    source: BookSource,
    chapterUrl: string,
    bookCtx?: Record<string, string>,
    chapterCtx?: Record<string, string>,
  ): Promise<string> {
    const html = await this.fetchHtml(chapterUrl, source);
    const rules = source.ruleContent;
    if (!rules) return html;

    const ctx: LegadoContext = {
      baseUrl: chapterUrl,
      source: html,
      page: 1,
      bookSource: source,
      book: bookCtx || {},
      chapter: chapterCtx || {},
    };

    let content = rules.content
      ? await this.selectString(rules.content, html, ctx)
      : html;

    // replaceRegex
    if (rules.replaceRegex) {
      content = applyReplaceRules(content, rules.replaceRegex);
    }

    // 清理 HTML
    content = content
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<p[^>]*>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/\n{3,}/g, '\n\n')
      .trim();

    // nextContentUrl (正文分页)
    if (rules.nextContentUrl) {
      const nextUrl = await this.selectString(rules.nextContentUrl, html, ctx);
      if (nextUrl && nextUrl !== chapterUrl) {
        const nextContent = await this.getContent(
          source,
          this.resolveUrl(nextUrl, chapterUrl),
          bookCtx,
          chapterCtx,
        );
        if (nextContent) {
          content += '\n' + nextContent;
        }
      }
    }

    return content;
  }
}

export const ruleEngine = new RuleEngine();
