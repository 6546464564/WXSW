/**
 * Regex-based content extraction for book source rules.
 * Format: pattern##replacement or just pattern (returns first group or full match)
 */
export function queryRegex(text: string, rule: string): string[] {
  if (!text || !rule) return [];

  try {
    const parts = rule.split('##');
    const pattern = parts[0];
    const replacement = parts[1];

    const regex = new RegExp(pattern, 'g');
    const results: string[] = [];

    let match: RegExpExecArray | null;
    while ((match = regex.exec(text)) !== null) {
      if (replacement !== undefined) {
        results.push(match[0].replace(new RegExp(pattern), replacement));
      } else {
        results.push(match[1] || match[0]);
      }
    }

    return results;
  } catch {
    return [];
  }
}

export function queryRegexFirst(text: string, rule: string): string {
  const results = queryRegex(text, rule);
  return results[0] || '';
}

/**
 * Apply replace rules to clean content.
 * Format: "pattern##replacement\npattern2##replacement2"
 */
export function applyReplaceRules(text: string, rules: string): string {
  if (!text || !rules) return text;

  let result = text;
  const lines = rules.split('\n').filter(Boolean);

  for (const line of lines) {
    try {
      const [pattern, replacement = ''] = line.split('##');
      result = result.replace(new RegExp(pattern, 'g'), replacement);
    } catch {
      // Skip invalid regex
    }
  }

  return result;
}
