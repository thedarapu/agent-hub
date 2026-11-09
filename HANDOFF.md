# agent-hub — build handoff

You are building **agent-hub**: an iOS app plus a Mac daemon that lets Bharath start, watch, and steer coding agents (Claude Code, Codex, Amp, plus plain shell and SSH) running on his Mac, from his iPhone, over Tailscale. Read this whole file before writing code. Where this file says **VERIFY**, check the current docs or `--help` output before relying on the detail — agent CLIs change often.

Mockups: `mockups/*.dc.html` (bundled with this file). They are HTML-like source; read them for layout, copy, and tokens. They will not render on their own.

---

## 1. Context and constraints

- **Mac:** MacBook Pro, Apple M1, 16 GB RAM. macOS, Apple Silicon only.
- **Projects:** one folder per project under `~/workspace/` (e.g. `~/workspace/binge`, `~/workspace/podcast-app`). Each project is usually worked by one agent.
- **Agents installed and signed in on the Mac:** `claude` (Claude Code, subscription login), `codex`, `amp`. Also `tmux`, `git`, Xcode.
- **Network:** Tailscale on Mac and iPhone. The daemon must listen on the Tailscale interface only.
- **No paid Apple Developer account (yet).** The iOS app is free-provisioned (7-day signing). Consequences: **no APNs push, no Live Activities** in v1. Do not design anything that requires them. Push arrives in a later phase once he buys the account.
- **Owner preference:** clean, calm, beautiful UI. The interaction model mirrors the Claude iOS app (drawer of conversations, picker at top, composer at bottom, artifacts as cards) generalized to every agent. Do not use Anthropic logos or branding.

## 2. Scope

### v1 (build this)
1. Mac daemon: launch any supported agent in any folder under `~/workspace`, keep it alive in tmux, stream it to the phone, accept input.
2. Claude Code sessions in **structured mode**: chat-style transcript, tool-use summaries, inline approve/deny.
3. Codex, Amp, Shell, SSH sessions in **terminal mode**: live terminal inside the same chat frame, plus a special-keys row.
4. **Outputs:** everything an agent produced (HTML/design pages rendered live, images, Simulator screenshots, code diffs), scoped per project with a per-session filter, with **file versions**.
5. Session management: auto-name from the first message, rename, pin, stop, delete. Folder picker. Agent picker with pass-through flags.
6. Mac menu-bar app: status, keep-awake, Tailscale-only toggle, session list, activity log.

### Explicitly out of scope for v1
- Push notifications, Live Activities, Apple Watch (need paid account — phase 2).
- Build/install/re-sign screens (removed by owner; the agent can run `xcodebuild`/`devicectl` itself when asked).
- Git worktrees, multi-Mac, multi-user.
- Structured adapters for Codex and Amp (phase 2; see §5.4).

## 3. Architecture

```
iPhone (SwiftUI app)
   │  WebSocket + HTTPS-less HTTP over Tailscale (100.x.y.z:7420), bearer token
   ▼
agent-hubd (Mac daemon, launchd user agent)
   ├── Session manager ── tmux (one tmux session per agent session, name = stable id)
   ├── Adapters
   │     ├── claude-structured  (claude -p stream-json, long-lived process)
   │     └── terminal           (PTY attached to tmux: codex, amp, $SHELL, ssh)
   ├── Approvals broker (permission requests ⇄ phone)
   ├── Outputs tracker (file events + tool events → outputs + versions)
   ├── Static file server (serves project files for previews)
   └── State store (SQLite)
   ▲
Mac menu-bar app (SwiftUI) ── talks to daemon over localhost
```

**Recommended stack** (change only with a reason):
- Daemon: **TypeScript on Node 22+**. Libraries: `node-pty` (PTY), `ws` (WebSocket), `better-sqlite3` (state), `chokidar` or native FSEvents bindings (file watching). Run as a `launchd` LaunchAgent so it starts at login.
- iOS app: **SwiftUI**, iOS 17+. **SwiftTerm** for terminal rendering, **WKWebView** for page previews.
- Menu-bar app: SwiftUI `MenuBarExtra`. It is a thin client of the daemon; the daemon must run without it.

Repo layout (monorepo at `~/workspace/agent-hub`):
```
daemon/        TypeScript daemon
ios/           Xcode project for the iOS app
macbar/        Xcode project for the menu-bar app
protocol/      shared JSON schema for the wire protocol (source of truth)
mockups/       the .dc.html files from this handoff
```

## 4. Session model

```ts
type AgentKind = "claude" | "codex" | "amp" | "shell" | "ssh";
type SessionMode = "structured" | "terminal";

interface Session {
  id: string;            // stable, e.g. "s-7f3a"; also the tmux session name
  name: string;          // display name; auto from first prompt, user-renamable
  folder: string;        // absolute path, must be inside ~/workspace (or a configured base)
  agent: AgentKind;
  mode: SessionMode;     // claude → structured; others → terminal (v1)
  flags: string[];       // passed through verbatim to the agent CLI
  sshHost?: string;      // for agent "ssh"
  agentSessionId?: string; // e.g. Claude session_id, for resume
  status: "starting" | "running" | "waiting" | "idle" | "done" | "error" | "stopped";
  pinned: boolean;
  createdAt: string; updatedAt: string;
}
```

Rules:
- **Folder is fixed** once a session starts. Changing folders means a new session.
- **Rename changes `name` only.** Never rename the tmux session.
- **Flags are pass-through.** Do not parse or validate agent flags beyond splitting on shell-word boundaries. Save per-project presets (e.g. "binge: claude --model opus --permission-mode plan").
- `status = "waiting"` means the agent needs the user (approval or input). This drives the "Needs you" section.

## 5. Daemon

### 5.1 Security (non-negotiable)
- Bind only to the Tailscale IP (detect via `tailscale ip -4`) and `127.0.0.1` for the menu-bar app. Never `0.0.0.0`.
- Pairing: the menu-bar app shows a QR code containing `{host, port, token}`. The phone stores the token in Keychain. Every HTTP/WS request requires `Authorization: Bearer <token>`.
- Path allowlist: every folder and file path must resolve (after `realpath`) inside the base folder (`~/workspace` by default). Reject `..` escapes and symlinks pointing outside.
- Append-only activity log of every action started from the phone (session start/stop, prompt sent, approval decision).

### 5.2 Process model
- Every session runs inside tmux: `tmux new-session -d -s <id> -c <folder> <command>`. This gives persistence across daemon restarts, phone disconnects, and Mac sleep, and lets Bharath run `tmux attach -t <id>` at the Mac.
- On daemon start, reconcile: list tmux sessions, re-attach to those it owns (prefix or tag), mark missing ones `stopped`.

### 5.3 Claude Code — structured adapter
Run Claude Code non-interactively with streaming JSON in both directions, as a long-lived process inside the session's tmux window:

```
claude -p --input-format stream-json --output-format stream-json --verbose [user flags]
```
- Feed user messages as JSON lines on stdin; parse events from stdout. The stream starts with a `system/init` event (capture `session_id`) and each turn ends with a `result` event. **VERIFY** the exact input message shape for `--input-format stream-json` in the CLI reference.
- Resume with `--resume <session_id>`.
- **Auth:** do **not** pass `--bare`. Bare mode skips the subscription login and requires `ANTHROPIC_API_KEY`; Bharath uses a subscription. The docs say `--bare` may become the default for `-p` in a future release — detect this (startup auth failure in the `result` event) and surface a clear error.
- **Approvals:** in `-p` mode a call that needs approval is denied unless something approves it. Use one of:
  - **Preferred:** `--permission-prompt-tool <mcp tool>`. The daemon runs a small MCP server exposing a permission tool; when Claude calls it, the daemon sets the session to `waiting`, pushes an `approval.request` to the phone, and blocks until the phone answers (allow / always allow / deny). **VERIFY** the expected input/output schema of the permission prompt tool.
  - **Alternative:** a `PermissionRequest` hook (configured via `--settings`) that calls the daemon and waits; it returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}`. **VERIFY** hook timeout limits before choosing this, since a phone answer can take minutes.
  - "Always allow for this project" → write a `permissions.allow` rule into the project's `.claude/settings.local.json`.
- Map stream events to the transcript: user messages, assistant text, tool calls collapsed into a summary line ("Read 2 files, edited 2 files"), outputs as cards, approvals inline.

### 5.4 Terminal adapter (Codex, Amp, Shell, SSH)
- Commands: `codex [flags]`, `amp [flags]`, `$SHELL -l`, `ssh <host>`. Run in tmux; attach a `node-pty` to `tmux attach -t <id>` and stream bytes to the phone; write keystrokes back.
- Status heuristics for "waiting": idle output for N seconds plus a prompt-like last line. Keep this simple and conservative.
- **Amp hook for completion:** a plugin in `~/.config/amp/plugins/` with an `agent.end` handler that POSTs to the daemon. Amp no longer asks before running tools by default (since May 2026), so there are few approvals to surface.
- **Phase 2 (do not build now, but don't block it):**
  - Amp structured: `amp -x --stream-json --stream-json-input`, resume with `amp threads continue T-… -x --stream-json`. Amp documents its stream as Claude Code–compatible except thinking blocks, so the Claude parser should be reusable. Unattended execute mode needs `AMP_API_KEY`.
  - Codex structured: `codex exec --json` (events: `thread.started`, `turn.started`, `item.*`, `turn.completed`, …), resume with `codex exec resume <id>`. **VERIFY** Codex approval handling in exec mode and its `notify` config.

### 5.5 Outputs and versions
An **output** is a file an agent produced or changed that is worth viewing: `.html/.htm`, images (`.png .jpg .jpeg .gif .webp .svg`), Markdown, plus code changes grouped per turn.
- **Detection:** for structured sessions, use tool events (file write/edit) as the source of truth. For terminal sessions, watch the project folder and diff against `git status` at session start.
- **Simulator screenshots:** after a build the agent ran (or on request), capture with `xcrun simctl io booted screenshot <path>`; for the Mac app window use `screencapture -l <windowid>`. Store as outputs of that session.
- **Versions:** agents overwrite files in place, so on every write copy the file to `<project>/.agent-hub/versions/<relpath>/<timestamp>.<ext>` and record it. Add `.agent-hub/` to the project's `.gitignore` (ask once per project; don't silently edit). Without this, history starts empty.
- **Serving:** serve files read-only from the project root at `/files/<sessionId>/<relpath>` so relative CSS/JS/images in HTML mockups resolve. Same auth and path allowlist.
- **Noise control:** default view shows pages and images; code changes collapse into one "N files changed" card per turn.

### 5.6 Wire protocol (sketch — formalize in `protocol/`)
HTTP:
```
GET  /health
GET  /folders?path=<rel>            list subfolders + git branch/language hints
POST /folders                        create folder in base
GET  /presets / PUT /presets
GET  /sessions                       list (pinned first, waiting next)
POST /sessions                       {folder, agent, flags, sshHost?, firstPrompt?}
PATCH /sessions/:id                  {name?, pinned?}
POST /sessions/:id/stop
DELETE /sessions/:id
GET  /sessions/:id/transcript        structured sessions
GET  /outputs?project=<folder>&session=<id?>
GET  /outputs/:id/versions
GET  /files/:sessionId/<relpath>
GET  /mac                            status: awake, tailscale ip, agent CLIs found
```
WebSocket `/ws` (JSON messages, `type` field):
- server → phone: `session.updated`, `transcript.event`, `terminal.data` (base64), `approval.request`, `output.added`, `mac.updated`
- phone → server: `prompt.send`, `terminal.input` (base64), `terminal.resize`, `approval.respond {requestId, decision: allow|always|deny}`, `subscribe {sessionId}`

### 5.7 Mac utilities
- Keep-awake toggle: spawn/kill `caffeinate -dimsu` (or `-s` on power).
- Agent detection: `which claude codex amp tmux` plus `--version`.
- Persist state in SQLite at `~/Library/Application Support/agent-hub/`.

## 6. iOS app

### 6.1 Screens (see mockups)
| Mockup | Screen | Behavior |
|---|---|---|
| `Main.dc.html` | Home / new session | Hamburger (drawer), agent picker at top center, serif greeting naming the project, quick actions (continue last session, review uncommitted changes, build and run in Simulator), composer with attach, **folder chip**, dictation. Sending the first message creates the session. |
| `Drawer.dc.html` | Sessions drawer | Search, New session, Projects, **Needs you** (status=waiting, amber), Recent (agent dot + name + `project · agent · status`), Mac status at bottom. |
| `NewSession.dc.html` | Agent picker sheet | Claude Code / Codex / Amp / Shell / SSH. Selected agent shows option pills (model, mode) and a pass-through flags field. |
| `Folders.dc.html` | Folder picker sheet | Breadcrumb from `~/workspace`, search, recent projects (language · branch · session count), drill into subfolders, "New folder in workspace", "Use <folder>". |
| `Session.dc.html` | Claude session (structured) | Header title (tap → session menu), agent dot + `project · agent`, Outputs icon. User bubbles; collapsible tool summary; assistant text in serif; output cards; inline approval card (Allow / Always allow / Deny). Composer. |
| `Terminal.dc.html` | Codex/Amp/Shell/SSH session | Same frame; dark terminal pane (SwiftTerm); key row: Enter, Esc, ↑, ⌃C, Tab; composer sends text + Enter. |
| `SessionMenu.dc.html` | Rename / session menu | Editable name + Save; folder and agent (read-only); Pin, Stop agent, Delete session. |
| `Visuals.dc.html` | Outputs | Scope toggle **This session / All of <project>**; grouped by file with version chips (v1 v2 v3); image and Simulator tiles; code-change card. |
| `Viewer.dc.html` | Output viewer | Full screen; Preview / Code toggle; version strip with dates + Compare; composer "Ask <agent> to change this" which sends feedback to the originating session with the file referenced. |

Navigation: drawer-based, no tab bar.

### 6.2 Design tokens
- Background `#F7F5F0`; surface `#FFFFFF`; sunken `#EFEBE3` / `#EAE6DD`; hairline `#E3DED4`; scrim `#CFCAC0`.
- Text `#1F1E1B`; secondary `#6B6860` (keep ≥4.5:1 contrast).
- Needs-you text `#A35F00`, background `#F3E6CF`. Success `#3E7D4F`. Destructive `#B3261E`.
- Agent colors: Claude `#C96442`, Codex `#2F6FDB`, Amp `#7B5BD6`, Shell/SSH `#5E5B54`. Filled dot = running; ring = idle/done.
- Type: mockups use Inter / Source Serif 4 / JetBrains Mono. On iOS use system equivalents: SF Pro (body), **New York** (greeting, assistant text, screen titles), SF Mono (code/terminal).
- Radii: composer 26, cards 18–24, sheets 28 (top corners), pills full. Touch targets ≥44pt. Support Dynamic Type and dark mode (derive a dark palette from these tokens).

### 6.3 iOS specifics
- Connection: store daemon host/port/token from QR pairing in Keychain. Reconnect with backoff; show "Mac offline" state in the drawer footer.
- Free provisioning: no push, no background refresh guarantees. Reconnect and resync on foreground.
- Previews: `WKWebView` loading `/files/...` with the bearer token injected (custom URL scheme handler or cookie).

## 7. Milestones and acceptance criteria

**M1 — Daemon core + terminal sessions**
- Pair phone via QR; start a Shell session in `~/workspace/binge` from the phone; type `ls`, see output; kill the app, reopen, session still there; `tmux attach -t <id>` on Mac shows the same session.
- Start Codex and Amp sessions with custom flags; flags reach the CLI unchanged.

**M2 — Claude structured mode + approvals**
- Start a Claude session from the phone, send a prompt, see streamed assistant text and collapsed tool summary.
- A command needing approval shows the inline card; Allow runs it, Deny blocks it, Always allow writes a project rule.
- Session shows in Needs you while waiting; resume after daemon restart works.

**M3 — Outputs**
- Agent writes an HTML mockup → appears in Outputs within 2s and renders with its relative assets.
- Overwriting it creates v2; viewer shows both and Compare works.
- Simulator screenshot captured after a build appears as an output.
- Viewer feedback box sends a message to the originating session referencing the file.

**M4 — Polish**
- Folder picker, rename/pin/stop/delete, presets, drawer search, Mac menu-bar app, keep-awake, activity log, dark mode.

## 8. Phase 2 (after Apple Developer account)
APNs push on `waiting`/`done` (daemon → APNs directly), Live Activities for running sessions, structured adapters for Amp and Codex.

## 9. Open items to confirm with Bharath before/while building
- Exact base folder (assumed `~/workspace`).
- SSH hosts to offer (assumed `homeserver`).
- Whether adding `.agent-hub/` to each project's `.gitignore` is OK.

## 10. References
- Claude Code headless / stream-json: https://code.claude.com/docs/en/headless
- Claude Code hooks (PermissionRequest, Stop, Notification): https://code.claude.com/docs/en/hooks
- Claude Code CLI reference: https://code.claude.com/docs/en/cli-reference
- Amp streaming JSON: https://ampcode.com/docs/cli/streaming-json
- Amp plugin API: https://ampcode.com/manual/plugin-api
- Amp permissions: https://ampcode.com/permissions
- Codex exec JSONL reference (third-party): https://codex.danielvaughan.com/2026/04/08/codex-exec-jsonl-reference/
