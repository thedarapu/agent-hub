import * as pty from "node-pty";
import { TMUX } from "../tmux.ts";
import { bus } from "../bus.ts";

/**
 * Bridges a tmux session to phone clients through a PTY running
 * `tmux attach`. The tmux session outlives this bridge; the bridge only
 * exists while someone is watching.
 */
export class TerminalBridge {
  private term: pty.IPty | null = null;
  private subscribers = new Set<string>();
  private detachTimer: NodeJS.Timeout | null = null;
  private cols = 80;
  private rows = 24;
  readonly id: string;
  onOutput: () => void = () => {};

  constructor(id: string) {
    this.id = id;
  }

  subscribe(clientId: string, cols?: number, rows?: number): void {
    if (cols && rows) {
      this.cols = cols;
      this.rows = rows;
    }
    this.subscribers.add(clientId);
    if (this.detachTimer) clearTimeout(this.detachTimer);
    this.detachTimer = null;
    // Re-attach so tmux repaints the full screen for the new viewer.
    this.attach();
  }

  unsubscribe(clientId: string): void {
    this.subscribers.delete(clientId);
    if (this.subscribers.size === 0 && !this.detachTimer) {
      this.detachTimer = setTimeout(() => this.detach(), 30_000);
    }
  }

  write(data: Buffer): void {
    this.term?.write(data.toString("utf8"));
  }

  resize(cols: number, rows: number): void {
    if (!(cols > 0 && rows > 0)) return;
    this.cols = Math.min(cols, 500);
    this.rows = Math.min(rows, 300);
    try {
      this.term?.resize(this.cols, this.rows);
    } catch {}
  }

  private attach(): void {
    this.detach();
    const term = pty.spawn(TMUX, ["attach-session", "-t", `=${this.id}`], {
      name: "xterm-256color",
      cols: this.cols,
      rows: this.rows,
      env: { ...process.env, TERM: "xterm-256color", LANG: process.env.LANG ?? "en_US.UTF-8" } as Record<string, string>,
      encoding: null,
    });
    this.term = term;
    term.onData((d: string | Buffer) => {
      const buf = typeof d === "string" ? Buffer.from(d, "utf8") : d;
      bus.publish(
        { type: "terminal.data", sessionId: this.id, data: buf.toString("base64") },
        true,
      );
      this.onOutput();
    });
    term.onExit(() => {
      if (this.term === term) this.term = null;
    });
  }

  detach(): void {
    if (this.term) {
      const t = this.term;
      this.term = null;
      try {
        t.kill();
      } catch {}
    }
  }
}
