import fs from "node:fs";
import path from "node:path";
import { safeResolve } from "./paths.ts";

export interface FolderInfo {
  name: string;
  /** Relative to the base folder. */
  path: string;
  isGit: boolean;
  branch?: string;
  language?: string;
  hasChildren: boolean;
  modifiedAt: string;
  sessionCount: number;
}

function gitBranch(dir: string): string | undefined {
  try {
    let head = path.join(dir, ".git");
    if (fs.statSync(head).isFile()) {
      // worktree / submodule: "gitdir: <path>"
      const m = fs.readFileSync(head, "utf8").match(/gitdir:\s*(.+)/);
      if (!m) return undefined;
      head = path.resolve(dir, m[1].trim());
    }
    const ref = fs.readFileSync(path.join(head, "HEAD"), "utf8").trim();
    const m = ref.match(/^ref: refs\/heads\/(.+)$/);
    return m ? m[1] : ref.slice(0, 7);
  } catch {
    return undefined;
  }
}

function language(dir: string, entries: string[]): string | undefined {
  const has = (n: string) => entries.includes(n);
  if (entries.some((e) => e.endsWith(".xcodeproj") || e.endsWith(".xcworkspace")) || has("Package.swift")) return "Swift";
  if (has("build.gradle") || has("build.gradle.kts") || has("settings.gradle.kts")) return "Kotlin";
  if (has("Cargo.toml")) return "Rust";
  if (has("go.mod")) return "Go";
  if (has("pyproject.toml") || has("requirements.txt") || has("setup.py")) return "Python";
  if (has("tsconfig.json")) return "TypeScript";
  if (has("package.json")) return "JavaScript";
  if (has("Gemfile")) return "Ruby";
  if (entries.some((e) => e.endsWith(".html"))) return "HTML";
  void dir;
  return undefined;
}

export function listFolders(base: string, rel: string, counts: Map<string, number>): { path: string; folders: FolderInfo[] } {
  const dir = safeResolve(base, rel || ".");
  const out: FolderInfo[] = [];
  for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
    if (d.name.startsWith(".")) continue;
    const abs = path.join(dir, d.name);
    let isDir = d.isDirectory();
    if (d.isSymbolicLink()) {
      try {
        safeResolve(base, abs);
        isDir = fs.statSync(abs).isDirectory();
      } catch {
        continue; // symlink pointing outside the base
      }
    }
    if (!isDir) continue;
    let entries: string[] = [];
    try {
      entries = fs.readdirSync(abs);
    } catch {
      continue;
    }
    const st = fs.statSync(abs);
    const isGit = entries.includes(".git");
    out.push({
      name: d.name,
      path: path.relative(base, abs),
      isGit,
      branch: isGit ? gitBranch(abs) : undefined,
      language: language(abs, entries),
      hasChildren: entries.some((e) => {
        if (e.startsWith(".") || e === "node_modules") return false;
        try {
          return fs.statSync(path.join(abs, e)).isDirectory();
        } catch {
          return false;
        }
      }),
      modifiedAt: st.mtime.toISOString(),
      sessionCount: counts.get(abs) ?? 0,
    });
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return { path: path.relative(base, dir), folders: out };
}

export function createFolder(base: string, rel: string): string {
  const name = path.basename(rel);
  if (!name || name.startsWith(".") || !/^[\w.\- ]+$/.test(name)) throw Object.assign(new Error("bad folder name"), { status: 400 });
  const abs = safeResolve(base, rel);
  if (fs.existsSync(abs)) throw Object.assign(new Error("already exists"), { status: 409 });
  fs.mkdirSync(abs, { recursive: true });
  return abs;
}
