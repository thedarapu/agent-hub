#!/bin/zsh
# Install agent-hubd as a per-user LaunchAgent (starts at login, restarts on crash).
#   ./scripts/install-launchagent.sh          install + start
#   ./scripts/install-launchagent.sh remove   stop + uninstall
set -euo pipefail
LABEL=com.bharath.agent-hubd
PLIST=~/Library/LaunchAgents/$LABEL.plist
DIR=$(cd "$(dirname "$0")/.." && pwd)
NODE=$(command -v node || echo /opt/homebrew/bin/node)
LOGS=~/Library/Logs/agent-hub

if [[ "${1:-}" == remove ]]; then
  launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $LABEL"; exit 0
fi

mkdir -p "$LOGS" ~/Library/LaunchAgents
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$DIR/src/main.ts</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SHELL</key><string>${SHELL:-/bin/zsh}</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/agent-hubd.log</string>
  <key>StandardErrorPath</key><string>$LOGS/agent-hubd.log</string>
</dict></plist>
PL
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "installed $LABEL → logs in $LOGS/agent-hubd.log"
