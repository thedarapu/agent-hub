import fs from "node:fs";
import path from "node:path";

export class PathError extends Error {
  status = 403;
}

function isInside(base: string, p: string): boolean {
  const rel = path.relative(base, p);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/**
 * Resolve `p` (absolute, or relative to `base`) and make sure the real path
 * stays inside `base`. Follows symlinks. For paths that do not exist yet,
 * resolves the nearest existing ancestor.
 */
export function safeResolve(base: string, p: string): string {
  if (p.includes("\0")) throw new PathError("bad path");
  const abs = path.resolve(base, p);
  if (!isInside(base, abs)) throw new PathError("path outside base folder");
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    tail.unshift(path.basename(existing));
    const parent = path.dirname(existing);
    if (parent === existing) break;
    existing = parent;
  }
  const real = path.join(fs.realpathSync(existing), ...tail);
  if (!isInside(base, real)) throw new PathError("path escapes base folder");
  return real;
}

/** Relative path inside a folder, or throws. Used for /files serving. */
export function safeRelative(folder: string, rel: string): string {
  const decoded = rel
    .split("/")
    .map((s) => decodeURIComponent(s))
    .join("/");
  return safeResolve(folder, decoded);
}
