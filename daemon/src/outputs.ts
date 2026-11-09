import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Store } from "./db.ts";
import type { Output, OutputKind, OutputVersion, Session } from "./types.ts";
import { bus } from "./bus.ts";

const pexec = promisify(execFile);

const IGNORED_DIRS = new Set([
  ".git", "node_modules", ".agent-hub", "DerivedData", "build", ".build", "Pods",
  "dist", ".next", ".venv", "venv", "__pycache__", ".gradle", "xcuserdata",
  ".swiftpm", ".idea", ".vscode", "target", ".cache", ".turbo", ".claude",
]);
const PAGE = new Set([".html", ".htm"]);
const IMAGE = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]);
const MARKDOWN = new Set([".md", ".markdown"]);
const BINARY_SKIP = new Set([
  ".zip", ".gz", ".tar", ".dmg", ".ipa", ".app", ".o", ".a", ".dylib", ".so",
  ".sqlite", ".db", ".wal", ".shm", ".lock", ".log", ".mp4", ".mov", ".mp3",
  ".wav", ".pdf", ".ttf", ".otf", ".woff", ".woff2", ".ico", ".DS_Store",
]);

export function classify(rel: string): OutputKind | "code" | null {
  const parts = rel.split(path.sep);
  if (parts.some((p) => IGNORED_DIRS.has(p))) return null;
  const base = parts[parts.length - 1];
  if (base.startsWith(".") && base !== ".gitignore") return null;
  if (base.endsWith("~") || base.endsWith(".swp") || base.includes(".tmp")) return null;
  const ext = path.extname(base).toLowerCase();
  if (PAGE.has(ext)) return "page";
  if (IMAGE.has(ext)) return "image";
  if (MARKDOWN.has(ext)) return "markdown";
  if (BINARY_SKIP.has(ext)) return null;
  return "code";
}

function shortId(prefix: string): string {
  return prefix + crypto.randomBytes(5).toString("hex");
}

function stamp(d = new Date()): string {
  return d.toISOString().replace(/[:.]/g, "-");
}

export function htmlTitle(buf: Buffer): string | undefined {
  const m = buf.subarray(0, 64 * 1024).toString("utf8").match(/<title[^>]*>([^<]{1,120})<\/title>/i);
  return m?.[1].trim() || undefined;
}

/** Ensure <project>/.agent-hub exists and is git-ignored without touching the project's .gitignore. */
export function ensureHubDir(folder: string): string {
  const dir = path.join(folder, ".agent-hub");
  fs.mkdirSync(dir, { recursive: true });
  const gi = path.join(dir, ".gitignore");
  if (!fs.existsSync(gi)) fs.writeFileSync(gi, "# Created by agent-hub: ignore this whole folder.\n*\n");
  return dir;
}

interface Changeset {
  files: Set<string>;
  timer?: NodeJS.Timeout;
}

export interface OutputsHooks {
  /** Called when an output is created or gets a new version. */
  added(o: Output, session: Session): void;
}

export class OutputsTracker {
  private store: Store;
  private watchers = new Map<string, fs.FSWatcher>();
  private pending = new Map<string, { timer: NodeJS.Timeout; sessionId: string; source: Output["source"] }>();
  private claims = new Map<string, { sessionId: string; at: number }>();
  private changesets = new Map<string, Changeset>();
  private getSession: (id: string) => Session | undefined;
  private activeIn: (folder: string) => Session | undefined;
  hooks: OutputsHooks = { added() {} };

  constructor(opts: {
    store: Store;
    getSession: (id: string) => Session | undefined;
    activeIn: (folder: string) => Session | undefined;
  }) {
    this.store = opts.store;
    this.getSession = opts.getSession;
    this.activeIn = opts.activeIn;
  }

  /** Start watching a project folder (idempotent). */
  watch(folder: string): void {
    if (this.watchers.has(folder)) return;
    try {
      const w = fs.watch(folder, { recursive: true }, (_ev, filename) => {
        if (!filename) return;
        this.onFsEvent(folder, filename.toString());
      });
      w.on("error", () => {
        this.watchers.delete(folder);
      });
      this.watchers.set(folder, w);
    } catch (e) {
      console.error("watch failed", folder, e);
    }
  }

  unwatch(folder: string): void {
    this.watchers.get(folder)?.close();
    this.watchers.delete(folder);
  }

  /** Structured adapters report file writes directly (source of truth). */
  toolTouched(session: Session, abs: string): void {
    const rel = path.relative(session.folder, abs);
    if (rel.startsWith("..") || path.isAbsolute(rel)) return;
    this.claims.set(abs, { sessionId: session.id, at: Date.now() });
    this.schedule(session.folder, rel, session.id, "tool");
  }

  private onFsEvent(folder: string, rel: string): void {
    if (!classify(rel)) return;
    const abs = path.join(folder, rel);
    const claim = this.claims.get(abs);
    let sessionId: string | undefined;
    if (claim && Date.now() - claim.at < 15_000) sessionId = claim.sessionId;
    else sessionId = this.activeIn(folder)?.id;
    if (!sessionId) return;
    const prev = this.pending.get(abs);
    const source = prev?.source === "tool" ? "tool" : "watcher";
    this.schedule(folder, rel, sessionId, source);
  }

  private schedule(folder: string, rel: string, sessionId: string, source: Output["source"]): void {
    const abs = path.join(folder, rel);
    const prev = this.pending.get(abs);
    if (prev) clearTimeout(prev.timer);
    const timer = setTimeout(() => {
      this.pending.delete(abs);
      this.record(folder, rel, sessionId, source).catch((e) => console.error("record output", e));
    }, 400);
    this.pending.set(abs, { timer, sessionId, source: prev?.source === "tool" ? "tool" : source });
  }

  private async record(folder: string, rel: string, sessionId: string, source: Output["source"]): Promise<void> {
    const kind = classify(rel);
    const session = this.getSession(sessionId);
    if (!kind || kind === "changes" || !session) return;
    const abs = path.join(folder, rel);
    if (kind === "code") {
      if (!fs.existsSync(abs) || fs.statSync(abs).isFile()) this.addToChangeset(session, rel);
      return;
    }
    let st: fs.Stats;
    try {
      st = fs.statSync(abs);
    } catch {
      return; // deleted
    }
    if (!st.isFile() || st.size > 25 * 1024 * 1024) return;
    const buf = fs.readFileSync(abs);
    await this.addVersion(session, rel, kind, buf, source);
  }

  /** Create or update an output with a new version of `buf`. Dedupes identical content. */
  async addVersion(
    session: Session,
    rel: string,
    kind: Exclude<OutputKind, "changes">,
    buf: Buffer,
    source: Output["source"],
    title?: string,
  ): Promise<Output | undefined> {
    const folder = session.folder;
    const sha1 = crypto.createHash("sha1").update(buf).digest("hex");
    const now = new Date();
    let out = this.store.findOutput(folder, rel);
    const versions = out ? this.store.versions(out.id) : [];
    if (versions.length && versions[versions.length - 1].sha1 === sha1) return undefined;

    const hub = ensureHubDir(folder);
    const ext = path.extname(rel) || ".bin";
    const storedRel = path.join(".agent-hub", "versions", rel, `${stamp(now)}${ext}`);
    fs.mkdirSync(path.dirname(path.join(folder, storedRel)), { recursive: true });
    fs.writeFileSync(path.join(folder, storedRel), buf);
    void hub;

    const nowIso = now.toISOString();
    if (!out) {
      out = {
        id: shortId("o-"),
        folder,
        sessionId: session.id,
        kind,
        relpath: rel,
        source,
        title: title ?? (kind === "page" ? htmlTitle(buf) : undefined),
        createdAt: nowIso,
        updatedAt: nowIso,
        versionCount: 0,
      };
    }
    const v: OutputVersion = {
      id: shortId("v-"),
      outputId: out.id,
      n: versions.length + 1,
      sessionId: session.id,
      createdAt: nowIso,
      sha1,
      size: buf.length,
      storedPath: storedRel,
    };
    this.store.putVersion(v);
    out.versionCount = v.n;
    out.updatedAt = nowIso;
    out.latestSessionId = session.id;
    if (kind === "page") out.title = htmlTitle(buf) ?? out.title;
    this.store.putOutput(out);
    bus.publish({ type: "output.added", output: out, version: v });
    this.hooks.added(out, session);
    return out;
  }

  // ---- Code changes, grouped per turn ----

  private addToChangeset(session: Session, rel: string): void {
    let cs = this.changesets.get(session.id);
    if (!cs) {
      cs = { files: new Set() };
      this.changesets.set(session.id, cs);
    }
    cs.files.add(rel);
    // Terminal sessions have no turn boundary: flush after a quiet spell.
    if (session.mode === "terminal") {
      if (cs.timer) clearTimeout(cs.timer);
      cs.timer = setTimeout(() => void this.flushChanges(session.id), 20_000);
    }
  }

  /** Called at the end of a structured turn (or by the quiet timer). */
  async flushChanges(sessionId: string): Promise<Output | undefined> {
    const cs = this.changesets.get(sessionId);
    this.changesets.delete(sessionId);
    const session = this.getSession(sessionId);
    if (!cs || !cs.files.size || !session) return;
    if (cs.timer) clearTimeout(cs.timer);
    const files = [...cs.files].sort();
    const { diff, additions, deletions } = await gitDiff(session.folder, files);
    const now = new Date().toISOString();
    const id = shortId("o-");
    const hub = ensureHubDir(session.folder);
    const diffRel = path.join(".agent-hub", "changes", `${id}.diff`);
    fs.mkdirSync(path.join(hub, "changes"), { recursive: true });
    fs.writeFileSync(path.join(session.folder, diffRel), diff);
    const out: Output = {
      id,
      folder: session.folder,
      sessionId,
      latestSessionId: sessionId,
      kind: "changes",
      relpath: diffRel,
      source: "watcher",
      files,
      additions,
      deletions,
      title: `${files.length} file${files.length === 1 ? "" : "s"} changed`,
      createdAt: now,
      updatedAt: now,
      versionCount: 1,
    };
    this.store.putOutput(out);
    bus.publish({ type: "output.added", output: out });
    this.hooks.added(out, session);
    return out;
  }

  // ---- Screenshots ----

  async captureSimulator(session: Session): Promise<Output | undefined> {
    const tmp = path.join(ensureHubDir(session.folder), "screenshots");
    fs.mkdirSync(tmp, { recursive: true });
    const file = path.join(tmp, `simulator-${stamp()}.png`);
    try {
      await pexec("xcrun", ["simctl", "io", "booted", "screenshot", file], { timeout: 20_000 });
    } catch (e: any) {
      throw new Error("No booted Simulator (" + String(e.stderr ?? e.message).trim().split("\n")[0] + ")");
    }
    const buf = fs.readFileSync(file);
    fs.unlinkSync(file);
    // One output ("Simulator") per session; each capture is a version.
    return this.addVersion(session, `.agent-hub/screenshots/simulator-${session.id}.png`, "image", buf, "simulator", "Simulator");
  }

  async captureMac(session: Session): Promise<Output | undefined> {
    const dir = path.join(ensureHubDir(session.folder), "screenshots");
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `mac-${stamp()}.png`);
    await pexec("screencapture", ["-x", "-o", file], { timeout: 20_000 });
    const buf = fs.readFileSync(file);
    fs.unlinkSync(file);
    return this.addVersion(session, `.agent-hub/screenshots/mac-${session.id}.png`, "image", buf, "mac", "Mac screen");
  }

  async simulatorBooted(): Promise<boolean> {
    try {
      const { stdout } = await pexec("xcrun", ["simctl", "list", "devices", "booted"], { timeout: 10_000 });
      return /\(Booted\)/.test(stdout);
    } catch {
      return false;
    }
  }
}

export async function gitDiff(
  folder: string,
  files: string[],
): Promise<{ diff: string; additions: number; deletions: number }> {
  let diff = "";
  try {
    const { stdout } = await pexec("git", ["-C", folder, "diff", "--no-color", "HEAD", "--", ...files], {
      maxBuffer: 32 * 1024 * 1024,
    });
    diff = stdout;
    // Untracked files don't show in `git diff HEAD`.
    const { stdout: untracked } = await pexec("git", ["-C", folder, "ls-files", "--others", "--exclude-standard", "--", ...files]);
    for (const f of untracked.split("\n").filter(Boolean)) {
      try {
        await pexec("git", ["-C", folder, "diff", "--no-color", "--no-index", "/dev/null", f], { maxBuffer: 8 * 1024 * 1024 });
      } catch (e: any) {
        // --no-index exits 1 when files differ; stdout holds the diff.
        diff += e.stdout ?? "";
      }
    }
  } catch {
    diff = "(not a git repository — no diff available)\n" + files.map((f) => `  ${f}`).join("\n");
  }
  let additions = 0;
  let deletions = 0;
  for (const line of diff.split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }
  return { diff, additions, deletions };
}
