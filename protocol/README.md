# agent-hub protocol

`schema.json` is the source of truth for object shapes and WebSocket messages
(`server:*` = daemon → phone, `phone:*` = phone → daemon). Keep
`daemon/src/types.ts` and `ios/AgentHub/Model/Models.swift` in sync with it.

Transport: plain HTTP + WebSocket on the Tailscale IP (and 127.0.0.1), port 7420.
Every request except `GET /health` needs `Authorization: Bearer <token>`.

## HTTP

| Route | Notes |
|---|---|
| `GET /health` | unauthenticated liveness |
| `GET /mac` · `PATCH /mac {keepAwake?, tailscaleOnly?, sshHosts?}` | status, agent CLIs found |
| `GET /pairing` | `{host, port, token, name}` — localhost only (menu-bar QR) |
| `GET /activity?limit=` | append-only activity log |
| `GET /folders?path=<rel>` · `POST /folders {path}` | subfolders with git branch / language hints |
| `GET /presets` · `PUT /presets [Preset]` | per-project agent + flags presets |
| `GET /sessions` | pinned first, then waiting, then most recent |
| `POST /sessions {folder, agent, flags, sshHost?, firstPrompt?, name?, cols?, rows?}` | `flags` string (shell-split) or array |
| `GET /sessions/:id` | session + `pendingApprovals` |
| `PATCH /sessions/:id {name?, pinned?}` | rename never touches tmux |
| `POST /sessions/:id/stop` · `DELETE /sessions/:id` | |
| `POST /sessions/:id/prompt {text}` · `POST /sessions/:id/interrupt` | HTTP fallbacks for the WS messages |
| `POST /sessions/:id/screenshot {target: simulator\|mac}` | stored as an output |
| `GET /sessions/:id/transcript?after=<seq>` | structured sessions |
| `GET /outputs?project=<rel>&session=<id?>` | |
| `GET /outputs/:id` · `/outputs/:id/versions` · `/outputs/:id/diff` | |
| `GET /files/:sessionId/<relpath>` | read-only project files (relative assets resolve) |
| `GET /vfiles/:sessionId/:versionId/<relpath>` | a stored version served at its original path |
| `POST /hooks {sessionId, event}` | localhost only (agent integrations) |

## WebSocket `/ws`

On connect the daemon sends `hello` with sessions, Mac status and pending approvals.
Clients `subscribe` to a session to receive its `transcript.*` / `terminal.data`
messages; everything else is broadcast.
