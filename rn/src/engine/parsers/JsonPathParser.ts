/**
 * Simple JSONPath parser for book source rules.
 * Supports: $.store.book[0].title, $..author, $[*].name
 */
export function queryJsonPath(json: any, path: string): any[] {
  if (!json || !path) return [];

  try {
    const data = typeof json === 'string' ? JSON.parse(json) : json;
    const tokens = tokenize(path);
    return resolve(data, tokens);
  } catch {
    return [];
  }
}

export function queryJsonPathFirst(json: any, path: string): any {
  const results = queryJsonPath(json, path);
  return results[0] ?? '';
}

function tokenize(path: string): string[] {
  // Remove leading $. or $
  let p = path.startsWith('$.') ? path.slice(2) : path.startsWith('$') ? path.slice(1) : path;
  // Split by . but respect brackets
  const tokens: string[] = [];
  let current = '';
  for (let i = 0; i < p.length; i++) {
    const ch = p[i];
    if (ch === '.' && current) {
      tokens.push(current);
      current = '';
    } else if (ch === '[') {
      if (current) tokens.push(current);
      current = '';
      const end = p.indexOf(']', i);
      if (end > i) {
        tokens.push(p.substring(i, end + 1));
        i = end;
      }
    } else if (ch !== '.') {
      current += ch;
    }
  }
  if (current) tokens.push(current);
  return tokens;
}

function resolve(data: any, tokens: string[]): any[] {
  if (!tokens.length) {
    return Array.isArray(data) ? data : [data];
  }

  const [token, ...rest] = tokens;

  // Recursive descent: ..key
  if (token === '') {
    // handle $..key (double dot produces empty token)
    return resolveRecursive(data, rest);
  }

  // Array index: [0], [*]
  const bracketMatch = token.match(/^\[(.+)\]$/);
  if (bracketMatch) {
    const inner = bracketMatch[1];
    if (inner === '*') {
      if (Array.isArray(data)) {
        return data.flatMap(item => resolve(item, rest));
      }
      return [];
    }
    const idx = parseInt(inner, 10);
    if (!isNaN(idx) && Array.isArray(data)) {
      return resolve(data[idx], rest);
    }
    return [];
  }

  // Object key
  if (data && typeof data === 'object') {
    if (Array.isArray(data)) {
      return data.flatMap(item => resolve(item?.[token], rest));
    }
    if (data[token] !== undefined) {
      return resolve(data[token], rest);
    }
  }

  return [];
}

function resolveRecursive(data: any, tokens: string[]): any[] {
  const results: any[] = [];
  if (!data || typeof data !== 'object') return results;

  results.push(...resolve(data, tokens));

  if (Array.isArray(data)) {
    for (const item of data) {
      results.push(...resolveRecursive(item, tokens));
    }
  } else {
    for (const val of Object.values(data)) {
      results.push(...resolveRecursive(val, tokens));
    }
  }

  return results;
}
