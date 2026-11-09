import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

export interface Config {
  /** Absolute, realpath'd base folder. Every session folder must be inside. */
  baseFolder: string;
  port: number;
  token: string;
  /** If true, listen on Tailscale + localhost only. If false, also on LAN IPv4s. */
  tailscaleOnly: boolean;
  sshHosts: string[];
  /** Seconds of quiet output before a terminal session counts as idle. */
  terminalIdleSeconds: number;
}

export const dataDir =
  process.env.AGENT_HUB_DATA ??
  path.join(os.homedir(), "Library", "Application Support", "agent-hub");

const configPath = path.join(dataDir, "config.json");

export function loadConfig(): Config {
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  let raw: Partial<Config> = {};
  if (fs.existsSync(configPath)) {
    raw = JSON.parse(fs.readFileSync(configPath, "utf8"));
  }
  const base = raw.baseFolder ?? path.join(os.homedir(), "workspace");
  const cfg: Config = {
    baseFolder: fs.existsSync(base) ? fs.realpathSync(base) : base,
    port: raw.port ?? Number(process.env.AGENT_HUB_PORT ?? 7420),
    token: raw.token ?? crypto.randomBytes(32).toString("base64url"),
    tailscaleOnly: raw.tailscaleOnly ?? true,
    sshHosts: raw.sshHosts ?? ["homeserver"],
    terminalIdleSeconds: raw.terminalIdleSeconds ?? 4,
  };
  saveConfig(cfg);
  return cfg;
}

export function saveConfig(cfg: Config): void {
  const tmp = configPath + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, configPath);
}

/** PATH that finds Homebrew and ~/.local/bin tools even under launchd. */
export function augmentedPath(): string {
  const extra = [
    path.join(os.homedir(), ".local", "bin"),
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/Applications/Tailscale.app/Contents/MacOS",
  ];
  const cur = (process.env.PATH ?? "").split(":").filter(Boolean);
  return [...new Set([...cur, ...extra])].join(":");
}

process.env.PATH = augmentedPath();
