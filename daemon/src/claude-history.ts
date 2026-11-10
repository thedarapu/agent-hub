// Claude Code sessions started outside agent-hub (e.g. `claude` in a terminal).
// Claude stores each one at ~/.claude/projects/<folder-key>/<session-id>.jsonl
// and registers running CLIs in ~/.claude/sessions/<pid>.json.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { summarizeTool, type NewEvent } from "./adapters/claude.ts";
import type { TerminalPrompt } from "./types.ts";

export interface ClaudeHistorySession {
  /** Claude's session id (file name without .jsonl). */
  id: string;
  folder: string;
  title: string;
  /** Most recent prompt, to recognise what the session was doing. */
  lastPrompt?: string;
  /** Prompts typed by the user (not tool results). */
  promptCount: number;
  lastActivityAt: string;
  sizeBytes: number;
  /** A running `claude` (not started by agent-hub) has this session open. */
  openInTerminal: boolean;
  /** Set when an agent-hub session already continues this one. */
  hubSessionId?: string;
}

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function claudeHome(): string {
  return process.env.AGENT_HUB_CLAUDE_HOME ?? path.join(os.homedir(), ".claude");
}

/** Claude's per-folder directory name: every non-alphanumeric char becomes "-". */
export function projectKey(folder: string): string {
  return folder.replace(/[^a-zA-Z0-9]/g, "-");
}

export function sessionFile(folder: string, id: string): string | undefined {
  if (!SESSION_ID.test(id)) return undefined;
  const f = path.join(claudeHome(), "projects", projectKey(folder), id + ".jsonl");
  return fs.existsSync(f) ? f : undefined;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e.code === "EPERM";
  }
}

/** Session ids held open by a running Claude CLI, with that CLI's pid. */
export function liveClaudeSessions(): Map<string, number> {
  const out = new Map<string, number>();
  const dir = path.join(claudeHome(), "sessions");
  let names: string[] = [];
  try {
    names = fs.readdirSync(dir).filter((n) => /^\d+\.json$/.test(n));
  } catch {
    return out;
  }
  for (const n of names) {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(dir, n), "utf8"));
      if (typeof j.sessionId === "string" && typeof j.pid === "number" && pidAlive(j.pid)) out.set(j.sessionId, j.pid);
    } catch {
      // being rewritten; skip
    }
  }
  return out;
}

/** Text the user typed, or undefined for meta/command/tool-result lines. */
function userPrompt(m: any): string | undefined {
  if (m.isMeta || m.isSidechain) return undefined;
  const c = m.message?.content;
  let text: string | undefined;
  if (typeof c === "string") text = c;
  else if (Array.isArray(c)) {
    if (c.some((x: any) => x?.type === "tool_result")) return undefined;
    text = c.filter((x: any) => x?.type === "text").map((x: any) => x.text).join("\n");
  }
  text = text?.trim();
  if (!text) return undefined;
  // Slash-command plumbing and interrupts, not prompts.
  if (/^<(command-|local-command|bash-|task-notification|system-reminder)/.test(text)) return undefined;
  if (/^\[Request interrupted/.test(text)) return undefined;
  return text;
}

function* lines(file: string): Generator<any> {
  const raw = fs.readFileSync(file, "utf8");
  for (const l of raw.split("\n")) {
    if (!l) continue;
    try {
      yield JSON.parse(l);
    } catch {
      // partial last line while Claude is writing
    }
  }
}

interface Summary {
  title: string;
  lastPrompt?: string;
  promptCount: number;
  mtimeMs: number;
  size: number;
}
const summaryCache = new Map<string, Summary>();

function summarize(file: string, st: fs.Stats): Summary {
  const hit = summaryCache.get(file);
  if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) return hit;
  let custom: string | undefined;
  let first: string | undefined;
  let last: string | undefined;
  let promptCount = 0;
  for (const m of lines(file)) {
    if (m.type === "custom-title" && m.customTitle) custom = String(m.customTitle);
    else if (m.type === "user") {
      const p = userPrompt(m);
      if (p) {
        promptCount++;
        first ??= p;
        last = p;
      }
    }
  }
  const title = custom ?? (first ? first.replace(/\s+/g, " ").slice(0, 120) : "Untitled session");
  const oneLine = (t?: string) => t?.replace(/\s+/g, " ").slice(0, 160);
  const s = { title, lastPrompt: last !== first || custom ? oneLine(last) : undefined, promptCount, mtimeMs: st.mtimeMs, size: st.size };
  summaryCache.set(file, s);
  return s;
}

/** Claude sessions for a folder, newest first. Sessions with no prompts are skipped. */
export function listClaudeSessions(
  folder: string,
  opts: { limit?: number; ownIds?: Set<string>; hubByAgentId?: Map<string, string> } = {},
): ClaudeHistorySession[] {
  const dir = path.join(claudeHome(), "projects", projectKey(folder));
  let files: { id: string; file: string; st: fs.Stats }[] = [];
  try {
    for (const n of fs.readdirSync(dir)) {
      if (!n.endsWith(".jsonl")) continue;
      const id = n.slice(0, -6);
      if (!SESSION_ID.test(id)) continue;
      const file = path.join(dir, n);
      files.push({ id, file, st: fs.statSync(file) });
    }
  } catch {
    return [];
  }
  files.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs);
  files = files.slice(0, opts.limit ?? 40);
  const live = liveClaudeSessions();
  const out: ClaudeHistorySession[] = [];
  for (const f of files) {
    const sum = summarize(f.file, f.st);
    if (!sum.promptCount) continue;
    out.push({
      id: f.id,
      folder,
      title: sum.title,
      lastPrompt: sum.lastPrompt,
      promptCount: sum.promptCount,
      lastActivityAt: f.st.mtime.toISOString(),
      sizeBytes: f.st.size,
      // A daemon-owned process also registers; that isn't "a terminal".
      openInTerminal: live.has(f.id) && !opts.ownIds?.has(f.id),
      hubSessionId: opts.hubByAgentId?.get(f.id),
    });
  }
  return out;
}

export type HistoryEvent = NewEvent & { ts: string };

const clip = (t: string) => (t.length > 4000 ? t.slice(0, 4000) + "\n…" : t);

/** Transcript events for one session-file record (main thread only). */
export function recordEvents(m: any, cwd: string): HistoryEvent[] {
  const out: HistoryEvent[] = [];
  if (!m || m.isSidechain) return out;
  const ts = typeof m.timestamp === "string" ? m.timestamp : new Date().toISOString();
  if (m.type === "user") {
    const p = userPrompt(m);
    if (p) return [{ kind: "user", text: p, ts }];
    const c = m.message?.content;
    if (!Array.isArray(c) || m.isMeta) return out;
    for (const x of c) {
      if (x?.type !== "tool_result") continue;
      const t = typeof x.content === "string"
        ? x.content
        : Array.isArray(x.content)
          ? x.content.map((y: any) => (y?.type === "text" ? y.text : `[${y?.type}]`)).join("\n")
          : "";
      out.push({ kind: "tool_result", toolUseId: x.tool_use_id, isError: !!x.is_error, text: clip(t), ts });
    }
  } else if (m.type === "assistant") {
    for (const x of m.message?.content ?? []) {
      if (x?.type === "text" && x.text) out.push({ kind: "assistant", text: x.text, ts });
      else if (x?.type === "thinking" && x.thinking) out.push({ kind: "thinking", text: x.thinking, ts });
      else if (x?.type === "tool_use")
        out.push({ kind: "tool_use", toolUseId: x.id, tool: x.name, summary: summarizeTool(x.name, x.input, cwd), input: x.input, ts });
    }
  } else if (m.type === "system" && m.subtype === "turn_duration") {
    out.push({ kind: "result", isError: false, durationMs: typeof m.durationMs === "number" ? m.durationMs : undefined, ts });
  }
  return out;
}

/** Convert a session file into agent-hub transcript events (main thread only). */
export function readHistory(file: string, cwd: string, maxEvents = 2000): HistoryEvent[] {
  const out: HistoryEvent[] = [];
  for (const m of lines(file)) out.push(...recordEvents(m, cwd));
  // Long sessions: keep the most recent part.
  return out.length > maxEvents ? out.slice(-maxEvents) : out;
}

/**
 * Follows a session file Claude is still writing. `offset` is where the next
 * read starts; it only advances past complete lines.
 */
export class JsonlTail {
  readonly file: string;
  private cwd: string;
  offset: number;
  /** Claude's own input queue (messages typed while it works), rebuilt from queue-operation records. */
  private queue: string[] = [];

  constructor(file: string, cwd: string, offset = 0) {
    this.file = file;
    this.cwd = cwd;
    this.offset = offset;
  }

  /**
   * New events since the last read, plus the latest titles seen: `customTitle`
   * from /rename, `aiTitle` from Claude's automatic naming.
   */
  read(maxEvents = 2000): { events: HistoryEvent[]; customTitle?: string; aiTitle?: string; queue?: string[] } {
    let size: number;
    try {
      size = fs.statSync(this.file).size;
    } catch {
      return { events: [] };
    }
    if (size < this.offset) this.offset = 0; // rewritten
    if (size === this.offset) return { events: [] };
    const fd = fs.openSync(this.file, "r");
    let buf: Buffer;
    try {
      buf = Buffer.alloc(size - this.offset);
      fs.readSync(fd, buf, 0, buf.length, this.offset);
    } finally {
      fs.closeSync(fd);
    }
    const end = buf.lastIndexOf(0x0a);
    if (end < 0) return { events: [] }; // only a partial line so far
    this.offset += end + 1;
    const events: HistoryEvent[] = [];
    let customTitle: string | undefined;
    let aiTitle: string | undefined;
    let queueChanged = false;
    for (const l of buf.subarray(0, end).toString("utf8").split("\n")) {
      if (!l) continue;
      let m: any;
      try {
        m = JSON.parse(l);
      } catch {
        continue;
      }
      if (m.type === "custom-title" && m.customTitle) customTitle = String(m.customTitle);
      else if (m.type === "ai-title" && m.aiTitle) aiTitle = String(m.aiTitle);
      else if (m.type === "queue-operation") {
        queueChanged = true;
        if (m.operation === "enqueue" && typeof m.content === "string") this.queue.push(m.content);
        else if (m.operation === "dequeue") this.queue.shift();
        else if (m.operation === "popAll") this.queue = [];
        else if (m.operation === "remove") {
          const i = this.queue.indexOf(m.content);
          if (i >= 0) this.queue.splice(i, 1);
        }
      }
      else events.push(...recordEvents(m, this.cwd));
    }
    // Background-task notifications queue up too; only show what a person typed.
    const queue = queueChanged ? this.queue.filter((q) => !q.trimStart().startsWith("<")) : undefined;
    return { events: events.length > maxEvents ? events.slice(-maxEvents) : events, customTitle, aiTitle, queue };
  }
}

export interface ClaudeRegistryEntry {
  pid: number;
  sessionId: string;
  /** "<tmux session>:@window.%pane" when the CLI runs inside tmux. */
  tmux?: string;
  status?: string;
}

/** Running Claude CLIs, from ~/.claude/sessions/<pid>.json. */
export function claudeRegistry(): ClaudeRegistryEntry[] {
  const out: ClaudeRegistryEntry[] = [];
  const dir = path.join(claudeHome(), "sessions");
  let names: string[] = [];
  try {
    names = fs.readdirSync(dir).filter((n) => /^\d+\.json$/.test(n));
  } catch {
    return out;
  }
  for (const n of names) {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(dir, n), "utf8"));
      if (typeof j.sessionId !== "string" || typeof j.pid !== "number" || !pidAlive(j.pid)) continue;
      out.push({ pid: j.pid, sessionId: j.sessionId, tmux: typeof j.tmux === "string" ? j.tmux : undefined, status: typeof j.status === "string" ? j.status : undefined });
    } catch {
      // being rewritten; skip
    }
  }
  return out;
}

const OPTION = /^(\s*)(❯\s*)?(\d)\.\s+(.*)$/;

/**
 * A numbered selection menu at the bottom of Claude's terminal UI (permission
 * prompts, plan approval, …). A menu has a ❯ cursor on one option; plain
 * numbered lists in replies don't.
 */
export function parseTerminalPrompt(screen: string): TerminalPrompt | undefined {
  const ls = screen.split("\n").map((l) => l.replace(/\s+$/, ""));
  let last = -1;
  for (let i = ls.length - 1; i >= 0 && i >= ls.length - 40; i--) {
    if (OPTION.test(ls[i])) {
      last = i;
      break;
    }
  }
  if (last < 0) return undefined;
  // Walk up: options, and wrapped continuation lines (indented deeper).
  const opts: { key: string; label: string; cursor: boolean; line: number }[] = [];
  let cont: string[] = [];
  let i = last;
  // Continuation lines of the last option sit below it.
  let tail: string[] = [];
  const lastIndent = (ls[last].match(OPTION)![1] + (ls[last].match(OPTION)![2] ?? "")).length;
  for (let j = last + 1; j < ls.length; j++) {
    const l = ls[j];
    if (!l.trim() || (l.length - l.trimStart().length) <= lastIndent) break;
    tail.push(l.trim());
  }
  for (; i >= 0; i--) {
    const m = ls[i].match(OPTION);
    if (m) {
      const label = [m[4].trim(), ...cont.reverse(), ...(opts.length ? [] : tail)].join(" ");
      opts.unshift({ key: m[3], label, cursor: !!m[2], line: i });
      cont = [];
      if (m[3] === "1") break;
    } else if (ls[i].trim() && ls[i].length - ls[i].trimStart().length > 2) {
      cont.push(ls[i].trim());
    } else {
      return undefined;
    }
  }
  if (i < 0 || !opts.some((o) => o.cursor)) return undefined;
  if (opts.some((o, n) => o.key !== String(n + 1))) return undefined;
  // Question: the nearest text line above option 1; context: up to a rule.
  let q = i - 1;
  while (q >= 0 && !ls[q].trim()) q--;
  if (q < 0) return undefined;
  // The dialog: from the solid rule above it down to the question.
  let top = q - 1;
  while (top >= 0 && !/^[─━]{8,}/.test(ls[top].trim())) top--;
  const box = ls.slice(top + 1, q).map((l) => l.trim());
  const dashed = box.flatMap((l, n) => (/^[╌┄]{8,}$/.test(l) ? [n] : []));
  let context: string[];
  if (dashed.length >= 2) {
    // Title line plus what sits between the dashed rules (the command).
    context = [box[0], ...box.slice(dashed[0] + 1, dashed[1])];
  } else {
    context = box.filter((l, n) => {
      if (!l || /^[╌┄]{8,}$/.test(l)) return false;
      // Drop "Tip: …" and its wrapped lines (which don't start a new sentence).
      for (let k = n; k >= 0 && box[k]; k--) {
        if (box[k].startsWith("Tip:")) return false;
        if (/^[A-Z]/.test(box[k])) return true;
      }
      return true;
    });
  }
  context = context.filter(Boolean).slice(0, 12);
  return { question: ls[q].trim(), context: context.join("\n"), options: opts.map(({ key, label }) => ({ key, label })) };
}
