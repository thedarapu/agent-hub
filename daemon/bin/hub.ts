#!/usr/bin/env -S node --no-warnings
// hub — start agents as agent-hub sessions from a Mac terminal, so the same
// process is drivable from the phone.
//
//   hub claude [flags…]     Claude Code (terminal UI) in the current folder
//   hub codex|amp [flags…]  same for Codex / Amp
//   hub shell               login shell
//   hub ls                  list agent-hub sessions
//   hub attach <id>         attach to a running session
//
// The session runs in tmux; this terminal attaches to it. Detach with
// Ctrl-b d: the agent keeps running and stays on the phone.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const AGENTS = ["claude", "codex", "amp", "shell"];
const dataDir = process.env.AGENT_HUB_DATA ?? path.join(os.homedir(), "Library", "Application Support", "agent-hub");

function die(msg: string, code = 1): never {
  process.stderr.write(`hub: ${msg}\n`);
  process.exit(code);
}

function config(onMissing?: () => never): { port: number; token: string; baseFolder: string } {
  try {
    const c = JSON.parse(fs.readFileSync(path.join(dataDir, "config.json"), "utf8"));
    return { port: c.port ?? 7420, token: c.token, baseFolder: c.baseFolder ?? path.join(os.homedir(), "workspace") };
  } catch {
    if (onMissing) onMissing();
    die("agent-hub isn't set up on this Mac (no config.json). Install the daemon first.");
  }
}

async function api(method: string, p: string, body?: unknown, onDown?: () => never): Promise<any> {
  const c = config();
  let res: Response;
  try {
    res = await fetch(`http://127.0.0.1:${c.port}${p}`, {
      method,
      headers: { authorization: `Bearer ${c.token}`, ...(body ? { "content-type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    if (onDown) onDown();
    die("the agent-hub daemon isn't running. Start it with daemon/scripts/install-launchagent.sh.");
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) die(data.error ?? `HTTP ${res.status}`);
  return data;
}

function tmuxBin(): string {
  for (const p of ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]) if (fs.existsSync(p)) return p;
  return "tmux";
}

function attach(id: string): never {
  // Inside tmux already: switch this client instead of nesting.
  const args = process.env.TMUX ? ["switch-client", "-t", id] : ["attach-session", "-t", id];
  const r = spawnSync(tmuxBin(), args, { stdio: "inherit" });
  process.exit(r.status ?? 1);
}

function ago(iso: string): string {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

const [cmd, ...rest] = process.argv.slice(2);

if (!cmd || cmd === "-h" || cmd === "--help" || cmd === "help") {
  process.stdout.write(
    [
      "usage: hub <claude|codex|amp|shell> [flags…]   start in this folder and attach",
      "       hub ls                                   list sessions",
      "       hub attach <id>                          attach to a running session",
      "",
      "Sessions show up in agent-hub on the phone. Detach with Ctrl-b d.",
      "",
    ].join("\n"),
  );
  process.exit(cmd ? 0 : 2);
}

if (cmd === "ls") {
  const list: any[] = await api("GET", "/sessions");
  const live = list.filter((s) => ["starting", "running", "waiting", "idle"].includes(s.status));
  if (!live.length) process.stdout.write("no running sessions\n");
  for (const s of live) {
    const where = s.mode === "terminal" ? "terminal" : "phone only";
    process.stdout.write(
      `${s.id.padEnd(8)} ${s.agent.padEnd(7)} ${s.status.padEnd(8)} ${ago(s.lastActivityAt).padStart(4)}  ${path.basename(s.folder)} · ${s.name}${s.mode === "terminal" ? "" : `  (${where})`}\n`,
    );
  }
  process.exit(0);
}

if (cmd === "attach") {
  const id = rest[0] ?? die("usage: hub attach <id>");
  const s = await api("GET", `/sessions/${encodeURIComponent(id)}`);
  if (s.mode !== "terminal") die(`${id} is a structured Claude session; it can only be driven from the phone.`);
  attach(id);
}

if (!AGENTS.includes(cmd)) die(`unknown command "${cmd}". Try: hub claude`);

/** Run the agent directly, as if hub weren't there (for `alias claude="hub claude"`). */
function direct(why?: string): never {
  if (why && process.env.HUB_QUIET !== "1") process.stderr.write(`hub: ${why}; running ${cmd} directly.\n`);
  const bin = cmd === "shell" ? process.env.SHELL || "/bin/zsh" : cmd;
  // Ctrl-C belongs to the child; hub just waits.
  process.on("SIGINT", () => {});
  const r = spawnSync(bin, rest, { stdio: "inherit" });
  if (r.error) die(`couldn't run ${bin}: ${r.error.message}`);
  process.exit(r.status ?? (r.signal ? 128 + (os.constants.signals[r.signal] ?? 0) : 1));
}

// Things that aren't an interactive session go straight to the agent.
const CLAUDE_SUBCOMMANDS = new Set([
  "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin",
  "plugins", "purge", "respawn", "rm", "setup-token", "stop", "kill", "ultrareview", "update", "upgrade",
  "config", "migrate-installer",
]);
const ONE_SHOT = new Set(["-p", "--print", "-v", "--version", "-h", "--help"]);
if (process.env.HUB === "0") direct();
if (process.env.AGENT_HUB_SESSION) direct(); // already inside a hub session
if (!process.stdin.isTTY || !process.stdout.isTTY) direct();
if (rest.some((a) => ONE_SHOT.has(a))) direct();
if (cmd === "claude" && rest[0] && CLAUDE_SUBCOMMANDS.has(rest[0])) direct();

const cwd = fs.realpathSync(process.cwd());
const base = fs.realpathSync(config(() => direct("agent-hub isn't set up on this Mac")).baseFolder);
const rel = path.relative(base, cwd);
if (rel.startsWith("..") || path.isAbsolute(rel)) direct(`not under ${base.replace(os.homedir(), "~")}, so not an agent-hub session`);

const s = await api("POST", "/sessions", {
  folder: cwd,
  agent: cmd,
  flags: rest,
  terminal: true,
  attached: true,
  cols: process.stdout.columns,
  rows: process.stdout.rows,
}, () => direct("the agent-hub daemon isn't running"));
process.stderr.write(`hub: ${s.id} · ${s.name} — on your phone too. Detach: Ctrl-b d · back: hub attach ${s.id}\n`);
attach(s.id);
