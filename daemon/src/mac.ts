import os from "node:os";
import { execFile, spawn, type ChildProcess } from "node:child_process";
import { promisify } from "node:util";

const pexec = promisify(execFile);

/** Tailscale IPv4 (100.64.0.0/10), via the CLI or by scanning interfaces. */
export async function tailscaleIPv4(): Promise<string | undefined> {
  for (const bin of ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) {
    try {
      const { stdout } = await pexec(bin, ["ip", "-4"], { timeout: 5000 });
      const ip = stdout.trim().split("\n")[0];
      if (isCGNAT(ip)) return ip;
    } catch {}
  }
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs ?? []) if (a.family === "IPv4" && isCGNAT(a.address)) return a.address;
  }
  return undefined;
}

function isCGNAT(ip: string): boolean {
  const m = ip.match(/^100\.(\d+)\.\d+\.\d+$/);
  return !!m && Number(m[1]) >= 64 && Number(m[1]) <= 127;
}

export function lanIPv4s(): string[] {
  const out: string[] = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    if (!/^en\d/.test(name)) continue;
    for (const a of addrs ?? []) if (a.family === "IPv4" && !a.internal && !isCGNAT(a.address)) out.push(a.address);
  }
  return out;
}

export interface AgentInfo {
  name: string;
  path?: string;
  version?: string;
}

export async function detectAgents(): Promise<AgentInfo[]> {
  const names = ["claude", "codex", "amp", "tmux", "git", "xcrun"];
  return Promise.all(
    names.map(async (name) => {
      try {
        const { stdout: p } = await pexec("/usr/bin/which", [name]);
        const path = p.trim();
        let version: string | undefined;
        try {
          const flag = name === "tmux" ? "-V" : "--version";
          const { stdout } = await pexec(path, [flag], { timeout: 8000 });
          version = stdout.trim().split("\n")[0];
        } catch {}
        return { name, path, version };
      } catch {
        return { name };
      }
    }),
  );
}

export class KeepAwake {
  private proc: ChildProcess | null = null;
  get on(): boolean {
    return this.proc !== null;
  }
  set(on: boolean): void {
    if (on && !this.proc) {
      // -i: no idle sleep, -m: no disk sleep, -s: no system sleep on AC.
      // Display may sleep (no -d); agents keep running.
      const p = spawn("caffeinate", ["-ims"], { stdio: "ignore" });
      p.on("exit", () => {
        if (this.proc === p) this.proc = null;
      });
      this.proc = p;
    } else if (!on && this.proc) {
      this.proc.kill();
      this.proc = null;
    }
  }
}
