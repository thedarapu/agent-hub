# agent-hub

Start, watch and steer coding agents (Claude Code, Codex, Amp, Shell, SSH) running on the Mac, from the iPhone, over Tailscale. Spec: [HANDOFF.md](HANDOFF.md).

```
daemon/    agent-hubd — Node 22.18+ TypeScript (runs .ts directly, no build step)
ios/       SwiftUI iPhone app (XcodeGen project, SwiftTerm)
macbar/    SwiftUI menu-bar app (thin localhost client)
protocol/  wire protocol: schema.json + route table
mockups/   design source
```

## Setup

1. **Prerequisites:** `brew install node tmux xcodegen` and install **Tailscale** on the Mac and the iPhone, signed in to the same tailnet. Until Tailscale is up, the daemon listens on 127.0.0.1 only and the pairing QR has no host.
2. **Daemon:**
   ```sh
   cd daemon && npm install
   ./scripts/install-launchagent.sh      # starts at login; logs: ~/Library/Logs/agent-hub/
   # or run in the foreground: npm start
   ```
   Config and state live in `~/Library/Application Support/agent-hub/`. `config.json` holds the base folder (default `~/workspace`), port (7420), token, SSH hosts, and the Tailscale-only setting.
3. **`hub` on the Mac (optional):** `ln -s "$PWD/daemon/bin/hub.ts" ~/.local/bin/hub`, and add `alias claude='hub claude'` to `~/.zshrc`. After that, `claude` (or `hub codex`, `hub amp`, `hub shell`, plus any flags) in a folder under the base folder starts the agent as an agent-hub session and attaches this terminal to it. The phone drives the same process, so nothing collides. Detach with Ctrl-b d. Use `hub ls` to list sessions and `hub attach <id>` to reattach, including to sessions started from the phone. When the agent exits, the session closes. Some cases run the real agent directly: folders outside the base folder, `-p`/`--print`, `--version`/`--help`, Claude subcommands (`mcp`, `update`, …), non-TTY use, an agent-hub session that is already running, or a daemon that is down. `HUB=0 claude` or `command claude` skips hub. Claude started this way shows on the phone as a live terminal; the structured transcript and phone approvals for it are planned next.
4. **Menu-bar app:** `cd macbar && xcodegen && open AgentHubBar.xcodeproj`, then Run. Choose **Pair iPhone…** to show the QR code.
4. **iPhone:** `cd ios && xcodegen && open AgentHub.xcodeproj`. Under Signing & Capabilities, choose your Personal Team. Run on the phone, trust the SwiftTerm build plugin when Xcode asks, and scan the QR code. Free provisioning expires after 7 days, so re-run from Xcode when it does.

Command-line simulator build: `ios/build.sh`.

## Tests

```sh
cd daemon
npm test                                    # unit tests
npm run typecheck
# end-to-end against a running daemon:
node scripts/smoke.ts http://127.0.0.1:7420 <token> <project> terminal
node scripts/smoke.ts http://127.0.0.1:7420 <token> <project> claude
```

## Status against the milestones

- **M1** works end to end. Shell sessions stream; composer and key input arrive; sessions survive app reconnects and daemon restarts; `tmux attach -t <id>` works on the Mac. Codex and Amp get their flags unchanged (verified with odd quoting).
- **M2** works end to end. Claude runs in structured mode with streamed text, collapsed tool summaries and inline approvals. Allow and Deny work. Always allow writes `.claude/settings.local.json`. Status shows `waiting` during an approval. `--resume` works after a daemon restart.
- **M3** works end to end. HTML outputs appear within about 1 s and render with relative assets. Overwriting a file creates v2, served through `/vfiles`. There is a Compare view. Feedback goes to the originating session. Simulator screenshots are taken after `xcodebuild` / `simctl install|launch`, and on request.
- **Resume terminal sessions:** Claude Code sessions started with `claude` on the Mac can be continued from the phone (Home → *Resume a session from the Mac…*, with Claude Code and a folder chosen). The daemon reads `~/.claude/projects/<folder>/<id>.jsonl` and copies the history into the transcript. The next prompt then runs `claude --resume <id>`. If a CLI still has the session open, as recorded in `~/.claude/sessions/<pid>.json`, the daemon adds `--fork-session`. Replies then go to a copy, and the terminal's conversation is unchanged. Endpoints: `GET /claude-sessions?project=<rel>` and `POST /claude-sessions {folder, claudeSessionId}`. Verified with Claude Code 2.1.322: closed sessions continue under the same id, and open ones fork.
- **M4:** the folder picker, rename/pin/stop/delete, presets, drawer search, menu bar, keep-awake, activity log and dark mode are built.

## Deviations from the handoff (with reasons)

- **Claude approvals use the stdio control protocol** (`--permission-prompt-tool stdio`). The CLI sends `can_use_tool` requests on stdout and the daemon answers on stdin. Verified with Claude Code 2.1.319. This avoids a separate MCP server, and there are no hook timeouts to worry about.
- **Claude sessions are not inside tmux.** The control protocol needs the daemon to own stdin and stdout. Persistence comes from `--resume <session_id>`: after a daemon restart, the next message resumes the conversation. A turn in flight during the restart is lost. At the Mac, use `claude --resume <id>`, which is shown in the session menu.
- **`.gitignore`:** instead of editing each project's `.gitignore`, the daemon writes `.agent-hub/.gitignore` containing `*`. Git then ignores the folder without touching project files. This resolves open item §9.3.
- **Keep-awake** uses `caffeinate -ims`, not `-dimsu`. The system stays awake but the display can sleep.
- **"Tailscale only" off** adds the Mac's LAN IPv4 addresses. It never binds to `0.0.0.0`.
- **SQLite:** uses the built-in `node:sqlite`, so `better-sqlite3` isn't a dependency.

## Not done yet / known gaps

- **Amp `agent.end` plugin:** not written yet; the plugin API needs verifying. Amp's status comes from the generic terminal heuristics: output activity, plus prompt and menu detection on the screen.
- **Code-change diffs** are snapshotted per turn with `git diff HEAD` for the touched files. Edits made outside the agent in that window also show up.
- **Mac window screenshots** capture the whole screen (`screencapture -x`), not one window. They need the Screen Recording permission for `node`.
- The **attach button** offers screenshots and outputs; file upload from the phone isn't implemented.
- Pairing and the connection were verified on a physical iPhone over Tailscale on 2026-11-10. The rest was verified against localhost and the iOS Simulator.
- **Resuming Codex and Amp sessions** from a terminal isn't implemented. Only Claude sessions can be resumed.
