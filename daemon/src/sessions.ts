import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { Config } from "./config.ts";
import type { Store } from "./db.ts";
import type {
  AgentKind,
  ApprovalDecision,
  Output,
  Session,
  SessionStatus,
  TranscriptEvent,
} from "./types.ts";
import { bus } from "./bus.ts";
import * as tmux from "./tmux.ts";
import { TerminalBridge } from "./adapters/terminal.ts";
import { ClaudeProcess, type ApprovalRequest, type NewEvent } from "./adapters/claude.ts";
import { OutputsTracker } from "./outputs.ts";
import { safeResolve } from "./paths.ts";
import { shellJoin, shellSplit } from "./shell.ts";
import { listClaudeSessions, liveClaudeSessions, readHistory, sessionFile, type ClaudeHistorySession } from "./claude-history.ts";

const AGENTS: AgentKind[] = ["claude", "codex", "amp", "shell", "ssh"];
const LIVE: SessionStatus[] = ["starting", "running", "waiting", "idle"];

export class HttpError extends Error {
  status: number;
  constructor(status: number, msg: string) {
    super(msg);
    this.status = status;
  }
}

interface PendingApproval extends ApprovalRequest {
  requestId: string;
  sessionId: string;
  seq: number;
  createdAt: string;
}

const AGENT_LABEL: Record<AgentKind, string> = {
  claude: "Claude Code",
  codex: "Codex",
  amp: "Amp",
  shell: "Shell",
  ssh: "SSH",
};

/** Patterns on the last lines of a quiet terminal that mean "needs you". */
const WAITING_PATTERNS = [
  /\(y\/n\)|\[y\/n\]|\(yes\/no\)/i,
  /allow (this|command|once)|approve|do you want to|proceed\?|continue\?/i,
  /password[^\n]*:\s*$/i,
  /press enter to/i,
  // TUI selection menus (Codex, Amp): "› 1. Yes, proceed"
  /^\s*[›❯▶>]\s*\d+[.)]\s+\S/m,
];

function validSize(n: unknown, max: number): number | undefined {
  return typeof n === "number" && Number.isInteger(n) && n >= 10 && n <= max ? n : undefined;
}

export function autoName(text: string): string {
  const t = text.replace(/\s+/g, " ").trim();
  if (!t) return "";
  let s = t.length <= 48 ? t : t.slice(0, 48).replace(/\s+\S*$/, "") + "…";
  s = s.replace(/[.?!:;,]+$/, "");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export class SessionManager {
  private cfg: Config;
  private store: Store;
  private sessions = new Map<string, Session>();
  private bridges = new Map<string, TerminalBridge>();
  private claudes = new Map<string, ClaudeProcess>();
  private approvals = new Map<string, PendingApproval>();
  private seqs = new Map<string, number>();
  private shotTimers = new Map<string, NodeJS.Timeout>();
  private pollTimer?: NodeJS.Timeout;
  private lastCapture = new Map<string, number>();
  /** Last terminal size a phone reported; new sessions start at it so TUIs draw at the right width. */
  private lastTermSize = { cols: 80, rows: 24 };
  readonly outputs: OutputsTracker;

  constructor(cfg: Config, store: Store) {
    this.cfg = cfg;
    this.store = store;
    this.outputs = new OutputsTracker({
      store,
      getSession: (id) => this.sessions.get(id),
      activeIn: (folder) => this.activeIn(folder),
    });
    this.outputs.hooks.added = (o, s) => this.onOutputAdded(o, s);
  }

  // ---------- lifecycle ----------

  async init(): Promise<void> {
    for (const s of this.store.allSessions()) this.sessions.set(s.id, s);
    const live = new Map((await tmux.listSessions()).map((t) => [t.name, t]));
    for (const s of this.sessions.values()) {
      if (s.mode === "terminal") {
        const t = live.get(s.id);
        if (!t) {
          if (LIVE.includes(s.status)) this.setStatus(s, "stopped", "tmux session no longer exists");
        } else {
          this.outputs.watch(s.folder);
        }
      } else {
        // Structured processes don't survive a daemon restart; they resume on the next prompt.
        if (LIVE.includes(s.status) && s.status !== "idle") this.setStatus(s, "idle");
        this.expireApprovals(s.id);
        if (LIVE.includes(s.status)) this.outputs.watch(s.folder);
      }
    }
    this.pollTimer = setInterval(() => void this.pollTerminals(), 2000);
  }

  shutdown(): void {
    if (this.pollTimer) clearInterval(this.pollTimer);
    for (const b of this.bridges.values()) b.detach();
    for (const c of this.claudes.values()) c.kill();
  }

  // ---------- queries ----------

  list(): Session[] {
    return [...this.sessions.values()].sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
      const aw = a.status === "waiting";
      const bw = b.status === "waiting";
      if (aw !== bw) return aw ? -1 : 1;
      return b.lastActivityAt.localeCompare(a.lastActivityAt);
    });
  }

  get(id: string): Session {
    const s = this.sessions.get(id);
    if (!s) throw new HttpError(404, "no such session");
    return s;
  }

  find(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  sessionCountByFolder(): Map<string, number> {
    const m = new Map<string, number>();
    for (const s of this.sessions.values()) m.set(s.folder, (m.get(s.folder) ?? 0) + 1);
    return m;
  }

  pendingApprovals(sessionId?: string): PendingApproval[] {
    return [...this.approvals.values()].filter((a) => !sessionId || a.sessionId === sessionId);
  }

  private activeIn(folder: string): Session | undefined {
    let best: Session | undefined;
    for (const s of this.sessions.values()) {
      if (s.folder !== folder || !LIVE.includes(s.status)) continue;
      if (!best || s.lastActivityAt > best.lastActivityAt) best = s;
    }
    return best;
  }

  // ---------- Claude sessions started outside agent-hub ----------

  /** Claude sessions in a folder that agent-hub didn't start (or that it continues). */
  claudeHistory(folderRel: string): ClaudeHistorySession[] {
    const folder = safeResolve(this.cfg.baseFolder, folderRel);
    const own = new Set<string>();
    const hubByAgentId = new Map<string, string>();
    for (const s of this.sessions.values()) {
      if (s.agent !== "claude") continue;
      if (s.agentSessionId) own.add(s.agentSessionId);
      if (s.resumedFrom) hubByAgentId.set(s.resumedFrom, s.id);
    }
    return listClaudeSessions(folder, { ownIds: own, hubByAgentId }).filter((h) => !own.has(h.id) || hubByAgentId.has(h.id));
  }

  /**
   * Continue a Claude session started elsewhere. Its history is copied into
   * the transcript; the next prompt runs `claude --resume <id>`. If a CLI still
   * has it open, the session is forked so the two don't write over each other.
   */
  resumeClaude(params: { folder: string; claudeSessionId: string; name?: string }, origin: string): Session {
    const folder = safeResolve(this.cfg.baseFolder, String(params.folder ?? ""));
    const cid = String(params.claudeSessionId ?? "");
    for (const s of this.sessions.values())
      if (s.agent === "claude" && (s.resumedFrom === cid || s.agentSessionId === cid)) return s;
    const file = sessionFile(folder, cid);
    if (!file) throw new HttpError(404, "no such Claude session in that folder");
    const fork = liveClaudeSessions().has(cid);
    const title = listClaudeSessions(folder).find((h) => h.id === cid)?.title;

    const now = new Date().toISOString();
    const s: Session = {
      id: "",
      name: params.name?.trim() || autoName(title ?? "") || `Claude Code in ${path.basename(folder)}`,
      folder,
      agent: "claude",
      mode: "structured",
      flags: [],
      agentSessionId: cid,
      resumedFrom: cid,
      forkOnResume: fork || undefined,
      status: "idle",
      pinned: false,
      createdAt: now,
      updatedAt: now,
      lastActivityAt: now,
    };
    return this.finishResume(s, file, fork, origin);
  }

  private finishResume(s: Session, file: string, fork: boolean, origin: string): Session {
    s.id = "s-" + crypto.randomBytes(2).toString("hex");
    while (this.sessions.has(s.id)) s.id = "s-" + crypto.randomBytes(2).toString("hex");
    const history = readHistory(file, s.folder);
    let seq = 0;
    for (const e of history) this.store.putEvent(s.id, { ...e, seq: ++seq } as TranscriptEvent);
    this.seqs.set(s.id, seq);
    if (history.length) s.lastActivityAt = history[history.length - 1].ts;
    this.sessions.set(s.id, s);
    this.save(s);
    this.addEvent(s.id, {
      kind: "system",
      text: fork
        ? "Continued from a terminal session that is still open. Replies here go to a copy, so the terminal's conversation is unchanged."
        : "Continued from a terminal session.",
    });
    this.store.logActivity(origin, "session.resume", s.id, `${s.resumedFrom}${fork ? " (fork)" : ""} in ${s.folder}`);
    this.outputs.watch(s.folder);
    return s;
  }

  // ---------- create ----------

  async create(
    params: {
      folder: string;
      agent: AgentKind;
      flags?: string | string[];
      sshHost?: string;
      firstPrompt?: string;
      name?: string;
      cols?: number;
      rows?: number;
      /** Run Claude as its terminal UI in tmux (as `ah claude` does) instead of structured mode. */
      terminal?: boolean;
      /** A Mac terminal will attach (`ah`): close the session when the agent exits. */
      attached?: boolean;
    },
    origin: string,
  ): Promise<Session> {
    if (!AGENTS.includes(params.agent)) throw new HttpError(400, "unknown agent");
    const folder = safeResolve(this.cfg.baseFolder, params.folder);
    if (!fs.existsSync(folder) || !fs.statSync(folder).isDirectory()) throw new HttpError(400, "folder does not exist");
    let flags: string[];
    try {
      flags = Array.isArray(params.flags) ? params.flags.map(String) : shellSplit(params.flags ?? "");
    } catch (e: any) {
      throw new HttpError(400, e.message);
    }
    if (params.agent === "ssh") {
      if (!params.sshHost || !/^[A-Za-z0-9_.@:-]+$/.test(params.sshHost)) throw new HttpError(400, "sshHost required");
    }

    const id = await this.newId();
    const now = new Date().toISOString();
    const mode = params.agent === "claude" && !params.terminal ? "structured" : "terminal";
    const project = path.basename(folder);
    const s: Session = {
      id,
      name:
        params.name?.trim() ||
        autoName(params.firstPrompt ?? "") ||
        (params.agent === "ssh" ? `SSH to ${params.sshHost}` : `${AGENT_LABEL[params.agent]} in ${project}`),
      folder,
      agent: params.agent,
      mode,
      flags,
      sshHost: params.sshHost,
      status: "starting",
      pinned: false,
      createdAt: now,
      updatedAt: now,
      lastActivityAt: now,
    };
    this.sessions.set(id, s);
    this.save(s);
    this.store.logActivity(origin, "session.start", id, `${s.agent} in ${folder} ${shellJoin(flags)}`.trim());
    this.outputs.watch(folder);

    if (mode === "terminal") {
      await tmux.newSession({
        id,
        cwd: folder,
        command: this.terminalCommand(s),
        env: {
          PATH: process.env.PATH ?? "",
          AGENT_HUB_SESSION: id,
          AGENT_HUB_URL: `http://127.0.0.1:${this.cfg.port}`,
        },
        cols: validSize(params.cols, 500) ?? this.lastTermSize.cols,
        rows: validSize(params.rows, 300) ?? this.lastTermSize.rows,
        remainOnExit: !params.attached,
      });
      console.log(`${id}: ${s.agent} in ${folder} at ${validSize(params.cols, 500) ?? this.lastTermSize.cols}x${validSize(params.rows, 300) ?? this.lastTermSize.rows}`);
      this.setStatus(s, "running");
      if (params.firstPrompt?.trim()) void this.typeWhenReady(s, params.firstPrompt);
    } else {
      this.ensureClaude(s).start();
      this.setStatus(s, "idle");
      if (params.firstPrompt?.trim()) this.prompt(s.id, params.firstPrompt, origin);
    }
    return s;
  }

  private async newId(): Promise<string> {
    for (;;) {
      const id = "s-" + crypto.randomBytes(2).toString("hex");
      if (!this.sessions.has(id) && !(await tmux.hasSession(id))) return id;
    }
  }

  private terminalCommand(s: Session): string {
    const shell = process.env.SHELL || "/bin/zsh";
    switch (s.agent) {
      case "shell":
        return shellJoin([shell, "-l", ...s.flags]);
      case "ssh":
        return shellJoin(["ssh", ...s.flags, s.sshHost!]);
      default:
        // Login shell so the agent sees Bharath's usual environment.
        return shellJoin([shell, "-l", "-c", "exec " + shellJoin([s.agent, ...s.flags])]);
    }
  }

  /** Wait for the TUI to settle, then paste the first prompt and press Enter. */
  private async typeWhenReady(s: Session, text: string): Promise<void> {
    const start = Date.now();
    let last = -1;
    let stableSince = Date.now();
    while (Date.now() - start < 20_000) {
      await new Promise((r) => setTimeout(r, 500));
      const info = (await tmux.listSessions()).find((t) => t.name === s.id);
      if (!info) return;
      const screen = await tmux.capturePane(s.id).catch(() => "");
      const sig = screen.length;
      if (sig !== last) {
        last = sig;
        stableSince = Date.now();
      } else if (Date.now() - stableSince > 1500 && screen.trim()) break;
    }
    await this.pasteAndEnter(s.id, text);
  }

  private async pasteAndEnter(id: string, text: string): Promise<void> {
    if (text.includes("\n")) {
      // Bracketed paste so multi-line prompts don't submit line by line.
      await tmux.sendLiteral(id, "\x1b[200~" + text + "\x1b[201~");
    } else {
      await tmux.sendLiteral(id, text);
    }
    await new Promise((r) => setTimeout(r, 120));
    await tmux.sendKeys(id, "Enter");
  }

  // ---------- Claude structured ----------

  private ensureClaude(s: Session): ClaudeProcess {
    let c = this.claudes.get(s.id);
    if (c) return c;
    c = new ClaudeProcess({
      cwd: s.folder,
      flags: s.flags,
      resumeId: s.agentSessionId,
      fork: s.forkOnResume,
      cb: {
        event: (e) => this.addEvent(s.id, e),
        delta: (text) => bus.publish({ type: "transcript.delta", sessionId: s.id, text }, true),
        status: (st, detail) => {
          if (st === "idle" && this.pendingApprovals(s.id).length) return;
          this.setStatus(s, st, detail);
        },
        sessionId: (sid) => {
          if (s.agentSessionId !== sid) {
            s.agentSessionId = sid;
            s.forkOnResume = undefined;
            this.save(s);
          }
        },
        approval: (req) => this.onApproval(s, req),
        approvalCancelled: (controlId) => {
          for (const a of this.approvals.values())
            if (a.sessionId === s.id && a.controlId === controlId) this.resolveApprovalEvent(a, "expired");
        },
        fileTouched: (abs) => this.outputs.toolTouched(s, abs),
        bashCommand: (cmd) => this.maybeScreenshot(s, cmd),
        turnEnd: () => void this.outputs.flushChanges(s.id),
        exited: (code, stderr) => {
          this.expireApprovals(s.id);
          if (s.status === "stopped") return;
          if (code && code !== 0 && code !== 143) {
            const msg = stderr.trim().split("\n").slice(-3).join("\n") || `claude exited with code ${code}`;
            this.addEvent(s.id, { kind: "system", text: msg });
            this.setStatus(s, "error", msg);
          } else if (s.status !== "error") {
            this.setStatus(s, "idle");
          }
        },
      },
    });
    this.claudes.set(s.id, c);
    return c;
  }

  private nextSeq(sessionId: string): number {
    let n = this.seqs.get(sessionId);
    if (n === undefined) n = this.store.nextSeq(sessionId) - 1;
    n += 1;
    this.seqs.set(sessionId, n);
    return n;
  }

  private addEvent(sessionId: string, e: NewEvent): TranscriptEvent {
    const ev = { ...e, seq: this.nextSeq(sessionId), ts: new Date().toISOString() } as TranscriptEvent;
    this.store.putEvent(sessionId, ev);
    bus.publish({ type: "transcript.event", sessionId, event: ev }, true);
    const s = this.sessions.get(sessionId);
    if (s) this.touch(s);
    return ev;
  }

  private onApproval(s: Session, req: ApprovalRequest): void {
    const requestId = "a-" + crypto.randomBytes(4).toString("hex");
    const ev = this.addEvent(s.id, {
      kind: "approval",
      requestId,
      tool: req.tool,
      summary: req.summary,
      input: req.input,
    });
    const a: PendingApproval = { ...req, requestId, sessionId: s.id, seq: ev.seq, createdAt: ev.ts };
    this.approvals.set(requestId, a);
    this.setStatus(s, "waiting", `Approve: ${req.summary}`);
    bus.publish({
      type: "approval.request",
      sessionId: s.id,
      requestId,
      tool: req.tool,
      summary: req.summary,
      input: req.input,
      sessionName: s.name,
    });
  }

  respondApproval(requestId: string, decision: ApprovalDecision, origin: string): void {
    const a = this.approvals.get(requestId);
    if (!a) throw new HttpError(404, "approval not pending (it may have expired)");
    if (!["allow", "always", "deny"].includes(decision)) throw new HttpError(400, "bad decision");
    const s = this.get(a.sessionId);
    this.claudes.get(s.id)?.respondApproval(a.controlId, decision, a.input, a.suggestions, a.tool);
    this.resolveApprovalEvent(a, decision);
    this.store.logActivity(origin, "approval." + decision, s.id, a.summary);
    if (!this.pendingApprovals(s.id).length) {
      const c = this.claudes.get(s.id);
      this.setStatus(s, c?.busy ? "running" : "idle");
    }
  }

  private resolveApprovalEvent(a: PendingApproval, decision: ApprovalDecision | "expired"): void {
    this.approvals.delete(a.requestId);
    const ev: TranscriptEvent = {
      seq: a.seq,
      ts: a.createdAt,
      kind: "approval",
      requestId: a.requestId,
      tool: a.tool,
      summary: a.summary,
      input: a.input,
      decision,
    };
    this.store.putEvent(a.sessionId, ev);
    bus.publish({ type: "transcript.event", sessionId: a.sessionId, event: ev }, true);
    bus.publish({ type: "approval.resolved", sessionId: a.sessionId, requestId: a.requestId, decision });
  }

  private expireApprovals(sessionId: string): void {
    for (const a of [...this.approvals.values()]) if (a.sessionId === sessionId) this.resolveApprovalEvent(a, "expired");
    // Also mark stale approval events from before a restart.
    for (const e of this.store.transcript(sessionId)) {
      if (e.kind === "approval" && !e.decision) {
        const fixed = { ...e, decision: "expired" as const };
        this.store.putEvent(sessionId, fixed);
      }
    }
  }

  transcript(id: string, after = 0): TranscriptEvent[] {
    this.get(id);
    return this.store.transcript(id, after);
  }

  // ---------- input ----------

  prompt(id: string, text: string, origin: string): void {
    const s = this.get(id);
    if (!text.trim()) throw new HttpError(400, "empty prompt");
    this.store.logActivity(origin, "prompt.send", id, text.slice(0, 200));
    if (s.mode === "structured") {
      const isFirst = !this.store.transcript(id).some((e) => e.kind === "user");
      if (isFirst && s.name.endsWith(` in ${path.basename(s.folder)}`)) this.rename(s, autoName(text));
      this.addEvent(id, { kind: "user", text });
      const c = this.ensureClaude(s);
      if (!c.alive && s.agentSessionId) c.setResumeId(s.agentSessionId);
      c.sendPrompt(text);
    } else {
      if (!LIVE.includes(s.status)) throw new HttpError(409, "session has ended");
      if (s.name === `${AGENT_LABEL[s.agent]} in ${path.basename(s.folder)}`) this.rename(s, autoName(text));
      void this.pasteAndEnter(id, text);
      this.touch(s);
    }
  }

  interrupt(id: string, origin: string): void {
    const s = this.get(id);
    this.store.logActivity(origin, "session.interrupt", id);
    if (s.mode === "structured") this.claudes.get(id)?.interrupt();
    else void tmux.sendKeys(id, "C-c");
  }

  subscribeTerminal(id: string, clientId: string, cols?: number, rows?: number): void {
    const s = this.get(id);
    if (s.mode !== "terminal") return;
    if (validSize(cols, 500) && validSize(rows, 300)) this.lastTermSize = { cols: cols!, rows: rows! };
    let b = this.bridges.get(id);
    if (!b) {
      b = new TerminalBridge(id);
      this.bridges.set(id, b);
    }
    b.subscribe(clientId, cols, rows);
  }

  unsubscribeAll(clientId: string): void {
    for (const b of this.bridges.values()) b.unsubscribe(clientId);
  }

  unsubscribeTerminal(id: string, clientId: string): void {
    this.bridges.get(id)?.unsubscribe(clientId);
  }

  terminalInput(id: string, data: Buffer): void {
    const b = this.bridges.get(id);
    if (b) b.write(data);
    else void tmux.sendLiteral(id, data.toString("utf8"));
    const s = this.sessions.get(id);
    if (s) this.touch(s);
  }

  terminalResize(id: string, cols: number, rows: number): void {
    if (validSize(cols, 500) && validSize(rows, 300)) this.lastTermSize = { cols, rows };
    this.bridges.get(id)?.resize(cols, rows);
  }

  // ---------- management ----------

  patch(id: string, p: { name?: string; pinned?: boolean }, origin: string): Session {
    const s = this.get(id);
    if (typeof p.name === "string" && p.name.trim()) this.rename(s, p.name.trim().slice(0, 120));
    if (typeof p.pinned === "boolean") s.pinned = p.pinned;
    this.store.logActivity(origin, "session.update", id, JSON.stringify(p));
    this.save(s);
    return s;
  }

  private rename(s: Session, name: string): void {
    if (!name) return;
    s.name = name; // display only; the tmux session keeps its id
    this.save(s);
  }

  async stop(id: string, origin: string): Promise<Session> {
    const s = this.get(id);
    this.store.logActivity(origin, "session.stop", id);
    if (s.mode === "structured") {
      this.setStatus(s, "stopped");
      this.claudes.get(id)?.kill();
      this.claudes.delete(id);
      this.expireApprovals(id);
    } else {
      this.bridges.get(id)?.detach();
      this.bridges.delete(id);
      await tmux.killSession(id);
      this.setStatus(s, "stopped");
    }
    return s;
  }

  async delete(id: string, origin: string): Promise<void> {
    const s = this.get(id);
    if (s.status !== "stopped" && s.status !== "done" && s.status !== "error") await this.stop(id, origin);
    this.store.logActivity(origin, "session.delete", id, s.name);
    this.claudes.get(id)?.kill();
    this.claudes.delete(id);
    await tmux.killSession(id);
    this.sessions.delete(id);
    this.seqs.delete(id);
    this.store.deleteSession(id);
    bus.publish({ type: "session.deleted", sessionId: id });
  }

  async screenshot(id: string, target: "simulator" | "mac", origin: string): Promise<Output | undefined> {
    const s = this.get(id);
    this.store.logActivity(origin, "screenshot." + target, id);
    return target === "mac" ? this.outputs.captureMac(s) : this.outputs.captureSimulator(s);
  }

  /** Amp plugin / other hooks report completion. */
  hookEvent(id: string, event: string): void {
    const s = this.sessions.get(id);
    if (!s || !LIVE.includes(s.status)) return;
    if (event === "agent.end" || event === "done") this.setStatus(s, "idle", "Agent finished");
  }

  // ---------- internals ----------

  private maybeScreenshot(s: Session, cmd: string): void {
    if (!/xcodebuild\b|simctl\s+(install|launch)/.test(cmd)) return;
    clearTimeout(this.shotTimers.get(s.id));
    this.shotTimers.set(
      s.id,
      setTimeout(async () => {
        if (await this.outputs.simulatorBooted()) {
          try {
            await this.outputs.captureSimulator(s);
          } catch (e) {
            console.error("auto screenshot", e);
          }
        }
      }, 4000),
    );
  }

  private onOutputAdded(o: Output, s: Session): void {
    if (s.mode === "structured") this.addEvent(s.id, { kind: "output", outputId: o.id, output: o });
  }

  private touch(s: Session): void {
    s.lastActivityAt = new Date().toISOString();
    // Persist lazily; activity timestamps change constantly.
  }

  private setStatus(s: Session, status: SessionStatus, detail?: string): void {
    if (s.status === status && s.statusDetail === detail) return;
    s.status = status;
    s.statusDetail = detail;
    s.lastActivityAt = new Date().toISOString();
    this.save(s);
  }

  private save(s: Session): void {
    s.updatedAt = new Date().toISOString();
    this.store.putSession(s);
    bus.publish({ type: "session.updated", session: s });
  }

  private async pollTerminals(): Promise<void> {
    let live: Map<string, tmux.TmuxSessionInfo>;
    try {
      live = new Map((await tmux.listSessions()).map((t) => [t.name, t]));
    } catch {
      return;
    }
    const now = Date.now() / 1000;
    for (const s of this.sessions.values()) {
      if (s.mode !== "terminal" || !LIVE.includes(s.status)) continue;
      const t = live.get(s.id);
      if (!t) {
        this.setStatus(s, "done", "Process exited");
        continue;
      }
      if (t.dead) {
        this.setStatus(s, "done", "Process exited");
        continue;
      }
      const actIso = new Date(t.activity * 1000).toISOString();
      if (actIso > s.lastActivityAt) s.lastActivityAt = actIso;
      if (now - t.activity < this.cfg.terminalIdleSeconds) {
        if (s.status !== "running") this.setStatus(s, "running");
        continue;
      }
      // Quiet: look at the screen once per quiet spell.
      if (this.lastCapture.get(s.id) === t.activity && s.status !== "starting") continue;
      this.lastCapture.set(s.id, t.activity);
      const screen = await tmux.capturePane(s.id).catch(() => "");
      const tail = screen.trimEnd().split("\n").slice(-6).join("\n");
      const waiting = s.agent !== "shell" && WAITING_PATTERNS.some((re) => re.test(tail));
      this.setStatus(s, waiting ? "waiting" : "idle", waiting ? tail.split("\n").filter(Boolean).pop()?.trim().slice(0, 120) : undefined);
    }
  }
}
