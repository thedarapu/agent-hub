import { spawn, type ChildProcess } from "node:child_process";
import readline from "node:readline";
import path from "node:path";
import os from "node:os";
import { shellJoin } from "../shell.ts";

/** Distributive Omit so each union member keeps its own fields. */
type DistOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
export type NewEvent = DistOmit<import("../types.ts").TranscriptEvent, "seq" | "ts">;

export interface ApprovalRequest {
  controlId: string;
  tool: string;
  summary: string;
  input: Record<string, unknown>;
  suggestions: unknown[];
  toolUseId?: string;
}

export interface ClaudeCallbacks {
  event(e: NewEvent): void;
  delta(text: string): void;
  status(s: "running" | "idle" | "error", detail?: string): void;
  sessionId(id: string): void;
  approval(req: ApprovalRequest): void;
  approvalCancelled(controlId: string): void;
  fileTouched(absPath: string, tool: string): void;
  bashCommand(cmd: string): void;
  turnEnd(): void;
  exited(code: number | null, stderrTail: string): void;
}

const FILE_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit"]);

export function summarizeTool(name: string, input: any, cwd: string): string {
  const rel = (p?: string) => (p ? path.relative(cwd, p) || path.basename(p) : "");
  const clip = (s: string, n = 80) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
  switch (name) {
    case "Read":
      return `Read ${rel(input?.file_path)}`;
    case "Write":
      return `Wrote ${rel(input?.file_path)}`;
    case "Edit":
    case "MultiEdit":
      return `Edited ${rel(input?.file_path)}`;
    case "NotebookEdit":
      return `Edited ${rel(input?.notebook_path)}`;
    case "Bash":
      return `Ran ${clip(String(input?.command ?? "").split("\n")[0])}`;
    case "Grep":
      return `Searched for ${clip(String(input?.pattern ?? ""), 50)}`;
    case "Glob":
      return `Listed ${clip(String(input?.pattern ?? ""), 50)}`;
    case "WebFetch":
      return `Fetched ${clip(String(input?.url ?? ""), 60)}`;
    case "WebSearch":
      return `Searched the web for ${clip(String(input?.query ?? ""), 50)}`;
    case "Task":
    case "Agent":
      return `Ran agent: ${clip(String(input?.description ?? ""), 60)}`;
    case "TodoWrite":
      return "Updated todos";
    default:
      return name;
  }
}

/** Imperative phrasing for an approval card: "Run npm test", "Write hello.html". */
export function approvalSummary(tool: string, input: any, description: string | undefined, cwd: string): string {
  const past = summarizeTool(tool, input, cwd);
  const map: Record<string, string> = { Ran: "Run", Wrote: "Write", Edited: "Edit", Read: "Read", Fetched: "Fetch" };
  const [verb, ...rest] = past.split(" ");
  if (map[verb] && rest.length) return `${map[verb]} ${rest.join(" ")}`;
  return description || past;
}

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content))
    return content
      .map((c: any) => (c?.type === "text" ? c.text : c?.type ? `[${c.type}]` : ""))
      .join("\n");
  return "";
}

/**
 * One long-lived `claude -p` process speaking stream-json both ways, with
 * permission prompts answered over the stdio control protocol.
 */
export class ClaudeProcess {
  private proc: ChildProcess | null = null;
  private cb: ClaudeCallbacks;
  private cwd: string;
  private flags: string[];
  private resumeId?: string;
  private stderrTail = "";
  private reqCounter = 0;
  private toolNames = new Map<string, string>();
  private pendingBash = new Map<string, string>();
  private pendingFiles = new Map<string, { path: string; tool: string }>();
  busy = false;

  constructor(opts: { cwd: string; flags: string[]; resumeId?: string; cb: ClaudeCallbacks }) {
    this.cwd = opts.cwd;
    this.flags = opts.flags;
    this.resumeId = opts.resumeId;
    this.cb = opts.cb;
  }

  get alive(): boolean {
    return this.proc !== null && this.proc.exitCode === null;
  }

  setResumeId(id: string) {
    this.resumeId = id;
  }

  start(): void {
    if (this.alive) return;
    const args = [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--permission-prompt-tool",
      "stdio",
    ];
    if (this.resumeId) args.push("--resume", this.resumeId);
    args.push(...this.flags);
    // Login shell so the agent sees the same environment as Bharath's terminal.
    const shell = process.env.SHELL || "/bin/zsh";
    const cmd = "exec claude " + shellJoin(args);
    this.stderrTail = "";
    const proc = spawn(shell, ["-l", "-c", cmd], {
      cwd: this.cwd,
      env: { ...process.env, HOME: os.homedir() },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc = proc;
    proc.stdin!.on("error", () => {});
    readline.createInterface({ input: proc.stdout! }).on("line", (l) => this.onLine(l));
    proc.stderr!.on("data", (d: Buffer) => {
      this.stderrTail = (this.stderrTail + d.toString()).slice(-4000);
    });
    proc.on("exit", (code) => {
      if (this.proc === proc) this.proc = null;
      this.busy = false;
      this.cb.exited(code, this.stderrTail);
    });
    this.send({ type: "control_request", request_id: this.nextReq(), request: { subtype: "initialize" } });
  }

  private nextReq(): string {
    return `ah-${++this.reqCounter}`;
  }

  private send(obj: unknown): void {
    this.proc?.stdin?.write(JSON.stringify(obj) + "\n");
  }

  sendPrompt(text: string): void {
    this.start();
    this.busy = true;
    this.cb.status("running");
    this.send({ type: "user", message: { role: "user", content: text } });
  }

  respondApproval(
    controlId: string,
    decision: "allow" | "always" | "deny",
    input: Record<string, unknown>,
    suggestions: unknown[],
    tool: string,
  ): void {
    let response: Record<string, unknown>;
    if (decision === "deny") {
      response = { behavior: "deny", message: "Denied from agent-hub on the phone." };
    } else {
      response = { behavior: "allow", updatedInput: input };
      if (decision === "always") {
        // Persist as a project rule in .claude/settings.local.json. Prefer the
        // CLI's own suggested rule; fall back to a tool-wide rule.
        const rules = (suggestions as any[]).filter(
          (s) => s?.type === "addRules" && s?.behavior === "allow",
        );
        response.updatedPermissions = (rules.length
          ? rules
          : [{ type: "addRules", rules: [{ toolName: tool }], behavior: "allow" }]
        ).map((r) => ({ ...r, destination: "localSettings" }));
      }
    }
    this.send({
      type: "control_response",
      response: { subtype: "success", request_id: controlId, response },
    });
  }

  interrupt(): void {
    if (!this.alive) return;
    this.send({ type: "control_request", request_id: this.nextReq(), request: { subtype: "interrupt" } });
  }

  kill(): void {
    const p = this.proc;
    if (!p) return;
    p.stdin?.end();
    p.kill("SIGTERM");
    setTimeout(() => {
      if (p.exitCode === null) p.kill("SIGKILL");
    }, 3000);
  }

  private onLine(line: string): void {
    let m: any;
    try {
      m = JSON.parse(line);
    } catch {
      return;
    }
    switch (m.type) {
      case "system":
        if (m.subtype === "init" && m.session_id) {
          this.resumeId = m.session_id;
          this.cb.sessionId(m.session_id);
        }
        break;
      case "stream_event": {
        const ev = m.event;
        if (m.parent_tool_use_id) break; // sub-agent chatter
        if (ev?.type === "content_block_delta" && ev.delta?.type === "text_delta") {
          this.cb.delta(ev.delta.text);
        }
        break;
      }
      case "assistant": {
        if (m.parent_tool_use_id) break;
        for (const c of m.message?.content ?? []) {
          if (c.type === "text" && c.text) this.cb.event({ kind: "assistant", text: c.text });
          else if (c.type === "thinking" && c.thinking) this.cb.event({ kind: "thinking", text: c.thinking });
          else if (c.type === "tool_use") {
            this.toolNames.set(c.id, c.name);
            this.cb.event({
              kind: "tool_use",
              toolUseId: c.id,
              tool: c.name,
              summary: summarizeTool(c.name, c.input, this.cwd),
              input: c.input,
            });
            if (c.name === "Bash" && c.input?.command) this.pendingBash.set(c.id, c.input.command);
            const fp = c.input?.file_path ?? c.input?.notebook_path;
            if (FILE_TOOLS.has(c.name) && fp)
              this.pendingFiles.set(c.id, { path: path.resolve(this.cwd, fp), tool: c.name });
          }
        }
        break;
      }
      case "user": {
        if (m.parent_tool_use_id) break;
        const content = m.message?.content;
        if (!Array.isArray(content)) break;
        for (const c of content) {
          if (c.type !== "tool_result") continue;
          const text = toolResultText(c.content);
          this.cb.event({
            kind: "tool_result",
            toolUseId: c.tool_use_id,
            isError: !!c.is_error,
            text: text.length > 4000 ? text.slice(0, 4000) + "\n…" : text,
          });
          const touched = this.pendingFiles.get(c.tool_use_id);
          if (touched) {
            this.pendingFiles.delete(c.tool_use_id);
            if (!c.is_error) this.cb.fileTouched(touched.path, touched.tool);
          }
          const cmd = this.pendingBash.get(c.tool_use_id);
          if (cmd) {
            this.pendingBash.delete(c.tool_use_id);
            if (!c.is_error) this.cb.bashCommand(cmd);
          }
        }
        break;
      }
      case "result": {
        this.busy = false;
        const isError = !!m.is_error || m.subtype !== "success";
        const text = typeof m.result === "string" ? m.result : undefined;
        this.cb.event({
          kind: "result",
          isError,
          text: isError ? text ?? m.subtype : undefined,
          durationMs: m.duration_ms,
          costUsd: m.total_cost_usd,
        });
        if (isError && text && /log ?in|api key|authenticat|ANTHROPIC_API_KEY|\/login/i.test(text)) {
          this.cb.status(
            "error",
            "Claude Code is not signed in for headless use. Run `claude` on the Mac and sign in. (If the CLI now defaults -p to --bare, the daemon must pass an explicit non-bare flag.)",
          );
        } else {
          this.cb.status("idle");
        }
        this.cb.turnEnd();
        break;
      }
      case "control_request": {
        const r = m.request;
        if (r?.subtype === "can_use_tool") {
          this.cb.approval({
            controlId: m.request_id,
            tool: r.tool_name,
            summary: approvalSummary(r.tool_name, r.input ?? {}, r.description, this.cwd),
            input: r.input ?? {},
            suggestions: r.permission_suggestions ?? [],
            toolUseId: r.tool_use_id,
          });
        } else {
          // Unknown host request: reply with an error so the CLI does not hang.
          this.send({
            type: "control_response",
            response: { subtype: "error", request_id: m.request_id, error: `unsupported: ${r?.subtype}` },
          });
        }
        break;
      }
      case "control_cancel_request":
        if (m.request_id) this.cb.approvalCancelled(m.request_id);
        break;
    }
  }
}
