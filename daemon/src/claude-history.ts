// Claude Code sessions started outside agent-hub (e.g. `claude` in a terminal).
// Claude stores each one at ~/.claude/projects/<folder-key>/<session-id>.jsonl
// and registers running CLIs in ~/.claude/sessions/<pid>.json.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { summarizeTool, type NewEvent } from "./adapters/claude.ts";

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

/** Convert a session file into agent-hub transcript events (main thread only). */
export function readHistory(file: string, cwd: string, maxEvents = 2000): HistoryEvent[] {
  const out: HistoryEvent[] = [];
  const clip = (t: string) => (t.length > 4000 ? t.slice(0, 4000) + "\n…" : t);
  for (const m of lines(file)) {
    if (m.isSidechain) continue;
    const ts = typeof m.timestamp === "string" ? m.timestamp : new Date().toISOString();
    if (m.type === "user") {
      const p = userPrompt(m);
      if (p) {
        out.push({ kind: "user", text: p, ts });
        continue;
      }
      const c = m.message?.content;
      if (!Array.isArray(c) || m.isMeta) continue;
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
    }
  }
  // Long sessions: keep the most recent part.
  return out.length > maxEvents ? out.slice(-maxEvents) : out;
}
