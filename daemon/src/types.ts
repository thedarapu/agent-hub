// Wire + storage types. Source of truth for shapes is protocol/schema.json;
// keep the two in sync.

export type AgentKind = "claude" | "codex" | "amp" | "shell" | "ssh";
export type SessionMode = "structured" | "terminal";
export type SessionStatus =
  | "starting"
  | "running"
  | "waiting"
  | "idle"
  | "done"
  | "error"
  | "stopped";

export interface Session {
  id: string;
  name: string;
  folder: string;
  agent: AgentKind;
  mode: SessionMode;
  flags: string[];
  sshHost?: string;
  agentSessionId?: string;
  status: SessionStatus;
  statusDetail?: string;
  pinned: boolean;
  createdAt: string;
  updatedAt: string;
  lastActivityAt: string;
}

/** Normalized transcript event for structured sessions. */
export type TranscriptEvent =
  | { seq: number; ts: string; kind: "user"; text: string }
  | { seq: number; ts: string; kind: "assistant"; text: string }
  | { seq: number; ts: string; kind: "thinking"; text: string }
  | {
      seq: number;
      ts: string;
      kind: "tool_use";
      toolUseId: string;
      tool: string;
      summary: string;
      input: unknown;
    }
  | {
      seq: number;
      ts: string;
      kind: "tool_result";
      toolUseId: string;
      isError: boolean;
      text: string;
    }
  | {
      seq: number;
      ts: string;
      kind: "approval";
      requestId: string;
      tool: string;
      summary: string;
      input: unknown;
      decision?: ApprovalDecision | "expired";
    }
  | { seq: number; ts: string; kind: "output"; outputId: string; output?: Output }
  | {
      seq: number;
      ts: string;
      kind: "result";
      isError: boolean;
      text?: string;
      durationMs?: number;
      costUsd?: number;
    }
  | { seq: number; ts: string; kind: "system"; text: string };

export type ApprovalDecision = "allow" | "always" | "deny";

export type OutputKind = "page" | "image" | "markdown" | "changes";

export interface Output {
  id: string;
  folder: string;
  sessionId: string;
  kind: OutputKind;
  /** Path relative to the project folder. For "changes", a label. */
  relpath: string;
  source: "tool" | "watcher" | "simulator" | "mac";
  /** Display title: HTML <title>, "Simulator", "N files changed", … */
  title?: string;
  /** Session that produced the latest version. */
  latestSessionId?: string;
  /** For "changes": list of changed files (relative) and line counts. */
  files?: string[];
  additions?: number;
  deletions?: number;
  createdAt: string;
  updatedAt: string;
  versionCount: number;
}

export interface OutputVersion {
  id: string;
  outputId: string;
  n: number;
  sessionId: string;
  createdAt: string;
  sha1: string;
  size: number;
  /** Stored copy, relative to the project folder. */
  storedPath: string;
}

export interface Preset {
  id: string;
  folder: string;
  agent: AgentKind;
  flags: string[];
  label: string;
}

export interface ActivityEntry {
  id: number;
  ts: string;
  origin: string;
  action: string;
  sessionId?: string;
  detail?: string;
}
