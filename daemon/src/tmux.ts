import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";

const pexec = promisify(execFile);

export const TMUX = (() => {
  for (const p of ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]) {
    try {
      execFileSync(p, ["-V"]);
      return p;
    } catch {}
  }
  return "tmux";
})();

/** Tag stored as a tmux user option so we can recognise our sessions. */
const TAG = "@agenthub";

async function tmux(...args: string[]): Promise<string> {
  const { stdout } = await pexec(TMUX, args, { maxBuffer: 16 * 1024 * 1024 });
  return stdout;
}

export async function newSession(opts: {
  id: string;
  cwd: string;
  command: string;
  env: Record<string, string>;
  cols?: number;
  rows?: number;
}): Promise<void> {
  const envArgs = Object.entries(opts.env).flatMap(([k, v]) => ["-e", `${k}=${v}`]);
  // One invocation so the options apply before a fast-failing command exits.
  // remain-on-exit keeps the final screen (e.g. an "unknown flag" error) visible.
  await tmux(
    "new-session", "-d", "-s", opts.id, "-c", opts.cwd,
    "-x", String(opts.cols ?? 80), "-y", String(opts.rows ?? 24),
    ...envArgs, opts.command,
    ";", "set-option", "-t", opts.id, "remain-on-exit", "on",
    ";", "set-option", "-t", opts.id, TAG, "1",
    // The app has its own chrome; size to whichever client was active last.
    ";", "set-option", "-t", opts.id, "status", "off",
    ";", "set-option", "-t", opts.id, "window-size", "latest",
    ";", "set-option", "-t", opts.id, "history-limit", "20000",
  );
}

export interface TmuxSessionInfo {
  name: string;
  activity: number; // epoch seconds of last window activity
  ours: boolean;
  dead: boolean;
}

export async function listSessions(): Promise<TmuxSessionInfo[]> {
  try {
    const out = await tmux(
      "list-panes",
      "-a",
      "-F",
      `#{session_name}\t#{window_activity}\t#{${TAG}}\t#{pane_dead}`,
    );
    const seen = new Map<string, TmuxSessionInfo>();
    for (const line of out.trim().split("\n")) {
      if (!line) continue;
      const [name, act, tag, dead] = line.split("\t");
      if (!seen.has(name))
        seen.set(name, { name, activity: Number(act), ours: tag === "1", dead: dead === "1" });
    }
    return [...seen.values()];
  } catch (e: any) {
    // "no server running" is the normal empty case.
    if (String(e.stderr ?? e.message).match(/no server|No such file|error connecting/i)) return [];
    throw e;
  }
}

export async function hasSession(id: string): Promise<boolean> {
  try {
    await tmux("has-session", "-t", `=${id}`);
    return true;
  } catch {
    return false;
  }
}

export async function killSession(id: string): Promise<void> {
  try {
    await tmux("kill-session", "-t", `=${id}`);
  } catch {}
}

/** Send literal text (no key-name interpretation). */
export async function sendLiteral(id: string, text: string): Promise<void> {
  await tmux("send-keys", "-t", `=${id}:`, "-l", "--", text);
}

export async function sendKeys(id: string, ...keys: string[]): Promise<void> {
  await tmux("send-keys", "-t", `=${id}:`, ...keys);
}

/** Plain-text screen contents of the active pane. */
export async function capturePane(id: string, lines = 0): Promise<string> {
  const args = ["capture-pane", "-p", "-t", `=${id}:`];
  if (lines) args.push("-S", String(-lines));
  return tmux(...args);
}
