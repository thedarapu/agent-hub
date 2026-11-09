/** Split a flags string on shell-word boundaries (quotes, backslashes). No expansion. */
export function shellSplit(input: string): string[] {
  const out: string[] = [];
  let cur = "";
  let has = false;
  let q: '"' | "'" | null = null;
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (q === "'") {
      if (c === "'") q = null;
      else cur += c;
    } else if (q === '"') {
      if (c === '"') q = null;
      else if (c === "\\" && i + 1 < input.length && '"\\$`'.includes(input[i + 1])) cur += input[++i];
      else cur += c;
    } else if (c === "'" || c === '"') {
      q = c;
      has = true;
    } else if (c === "\\" && i + 1 < input.length) {
      cur += input[++i];
      has = true;
    } else if (/\s/.test(c)) {
      if (has || cur) out.push(cur);
      cur = "";
      has = false;
    } else {
      cur += c;
    }
  }
  if (q) throw new Error("unterminated quote in flags");
  if (has || cur) out.push(cur);
  return out;
}

export function shellQuote(s: string): string {
  if (s !== "" && /^[A-Za-z0-9_\-+=.,/:@%^]+$/.test(s)) return s;
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

export function shellJoin(argv: string[]): string {
  return argv.map(shellQuote).join(" ");
}
