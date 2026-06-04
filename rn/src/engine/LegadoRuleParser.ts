/**
 * 万象书屋 RN · legado 规则字符串切分
 * 对应 iOS: LegadoRuleParser.swift
 * 对应 Android: RuleAnalyzer.splitRule + AnalyzeRule.splitSourceRule
 *
 * 关键: `&&` `||` `%%` 在 [...] 和 (...) 平衡组里要忽略
 */

import {LegadoMode, LegadoSourceRule} from './types';

/**
 * 顶层入口: 一段 ruleStr → [LegadoSourceRule]
 */
export function splitRules(ruleStr: string): LegadoSourceRule[] {
  if (!ruleStr) return [];
  const chunks = splitTop(ruleStr, ['&&', '||']);
  return chunks.map(parseSingle);
}

/**
 * 解析单段规则 (mode 推断 + ## 切分)
 */
export function parseSingle(s: string): LegadoSourceRule {
  let raw = s.trim();

  // @@ 强制默认 CSS
  if (raw.startsWith('@@')) {
    raw = raw.slice(2);
  }

  // 显式前缀
  let mode: LegadoMode = LegadoMode.CSS;
  let isAllInOneRegex = false;
  const lower = raw.toLowerCase();

  if (lower.startsWith('@css:')) {
    mode = LegadoMode.CSS;
    raw = raw.slice(5);
  } else if (lower.startsWith('@xpath:')) {
    mode = LegadoMode.XPath;
    raw = raw.slice(7);
  } else if (lower.startsWith('@json:')) {
    mode = LegadoMode.JSON;
    raw = raw.slice(6);
  } else if (lower.startsWith('@js:')) {
    mode = LegadoMode.JS;
    raw = raw.slice(4);
  } else if (lower.startsWith('@regex:')) {
    mode = LegadoMode.Regex;
    raw = raw.slice(7);
  } else if (raw.startsWith(':')) {
    // AllInOne regex (用于列表场景)
    mode = LegadoMode.Regex;
    raw = raw.slice(1);
    isAllInOneRegex = true;
  } else if (raw.startsWith('$.') || raw.startsWith('$[')) {
    mode = LegadoMode.JSON;
  } else if (raw.startsWith('//')) {
    mode = LegadoMode.XPath;
  } else if (raw.startsWith('/')) {
    // 单 / 含 XPath 特征的判为 XPath
    if (raw.includes('[@') || raw.includes('/text(') || raw.includes('/@')) {
      mode = LegadoMode.XPath;
    }
  }

  // 占位符检测
  const hasPlaceholder =
    raw.includes('{{') || raw.includes('@get:') || raw.includes('<js>');

  // 切 ##regex##replace[##]
  let rule = raw;
  let replaceRegex = '';
  let replacement = '';
  let replaceFirst = false;

  if (rule.includes('##')) {
    const parts = splitChainSafe(rule, '##');
    rule = parts[0];
    if (parts.length >= 2) replaceRegex = parts[1];
    if (parts.length >= 3) replacement = parts[2];
    if (parts.length >= 4) replaceFirst = true;
  }

  // 占位符模式升级
  if (hasPlaceholder && mode === LegadoMode.CSS) {
    if (rule.startsWith('{{') && rule.endsWith('}}')) {
      mode = LegadoMode.Regex;
    } else if (rule.startsWith('<js>')) {
      // 整段 <js>...</js> → JS 模式
      const trimmed = rule.trim();
      const endIdx = trimmed.indexOf('</js>');
      if (
        trimmed.startsWith('<js>') &&
        endIdx > 0 &&
        trimmed.slice(endIdx + 5).trim() === ''
      ) {
        mode = LegadoMode.JS;
        rule = trimmed.slice(4, endIdx);
      } else {
        mode = LegadoMode.Regex;
      }
    } else if (rule.startsWith('http') || rule.startsWith('/')) {
      mode = LegadoMode.Regex;
    } else {
      mode = LegadoMode.Regex;
    }
  }

  return {
    mode,
    rule: rule.trim(),
    replaceRegex,
    replacement,
    replaceFirst,
    isAllInOneRegex,
    hasPlaceholder,
  };
}

/**
 * 平衡组感知的分割
 * 字符串按 separators 切分，但 [...] (...) <js>...</js> 引号内不切
 *
 * implicitJsChainSplit: 段中间出现的 @js: 是否当隐式 && 切
 */
export function splitTop(
  s: string,
  separators: string[],
  implicitJsChainSplit: boolean = true,
): string[] {
  const out: string[] = [];
  let depthSquare = 0;
  let depthRound = 0;
  let depthAngle = 0;
  let inSingleQ = false;
  let inDoubleQ = false;
  let inJsPrefix = false;

  const chars = s;
  let sliceStart = 0;
  let i = 0;

  while (i < chars.length) {
    const c = chars[i];

    // 引号
    if (!inDoubleQ && c === "'") {
      inSingleQ = !inSingleQ;
      i++;
      continue;
    }
    if (!inSingleQ && c === '"') {
      inDoubleQ = !inDoubleQ;
      i++;
      continue;
    }
    if (inSingleQ || inDoubleQ) {
      i++;
      continue;
    }

    // 嵌套追踪
    if (c === '[') depthSquare++;
    else if (c === ']') depthSquare = Math.max(0, depthSquare - 1);
    else if (c === '(') depthRound++;
    else if (c === ')') depthRound = Math.max(0, depthRound - 1);
    else if (c === '<') {
      const rest = chars.slice(i);
      if (rest.startsWith('</js>')) {
        depthAngle = Math.max(0, depthAngle - 1);
        i += 5;
        continue;
      } else if (rest.startsWith('<js>')) {
        depthAngle++;
        i += 4;
        continue;
      }
    } else if (c === '@') {
      const rest = chars.slice(i);
      if (rest.startsWith('@js:')) {
        if (
          implicitJsChainSplit &&
          depthSquare === 0 &&
          depthRound === 0 &&
          depthAngle === 0 &&
          !inJsPrefix
        ) {
          const pre = chars.slice(sliceStart, i);
          const trimmed = pre.trim();
          if (trimmed.length > 0) {
            out.push(pre);
            sliceStart = i;
            inJsPrefix = true;
            i += 4;
            continue;
          }
        }
        inJsPrefix = true;
        i += 4;
        continue;
      }
    }

    // 尝试分割（仅在顶层且非 @js: 段内）
    let matchedSep = false;
    if (
      depthSquare === 0 &&
      depthRound === 0 &&
      depthAngle === 0 &&
      !inJsPrefix
    ) {
      for (const sep of separators) {
        if (chars.slice(i, i + sep.length) === sep) {
          out.push(chars.slice(sliceStart, i));
          sliceStart = i + sep.length;
          i += sep.length;
          matchedSep = true;
          break;
        }
      }
    }
    if (!matchedSep) i++;
  }

  // 最后一段
  const last = chars.slice(sliceStart);
  if (last.length > 0 || out.length > 0) {
    out.push(last);
  }

  return out;
}

/**
 * 安全切 ##: 不切 [...] (...) 内的 ##
 */
export function splitChainSafe(s: string, separator: string): string[] {
  return splitTop(s, [separator]);
}
