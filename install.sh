#!/bin/sh
# Builds vibecat and adds its hook to ~/.claude/settings.json next to any hooks you already have (backup kept beside it).
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "need jq: brew install jq"; exit 1; }
swiftc -O vibecat.swift -o vibecat && ./vibecat --test
s=~/.claude/settings.json
[ -f "$s" ] || echo '{}' > "$s"
cp "$s" "$s.bak"
# Drop earlier vibecat entries (the event list changes between versions), then add one per event.
# The hook points at this checkout's hook.sh, so the repo can live anywhere. timeout 5: a stuck hook must never stall a tool call.
jq --arg h "$PWD/hook.sh" '.hooks = ((.hooks // {}) | map_values(map(select(all(.hooks[]?; .command != $h)))) | with_entries(select(.value | length > 0)))
  | reduce ("PreToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied","Notification","UserPromptSubmit","Stop","StopFailure","SessionEnd") as $ev
      (.; .hooks[$ev] += [{hooks: [{type: "command", command: $h, timeout: 5}]}])' "$s" > "$s.new" && mv "$s.new" "$s"
# Plan usage only reaches outside tools through the status line, and there is only one: wrap yours instead of replacing it.
sl="$PWD/statusline.sh"
mkdir -p ~/.vibecat
prev=$(jq -r '.statusLine.command // ""' "$s")
[ -n "$prev" ] && [ "$prev" != "$sl" ] && printf '%s\n' "$prev" > ~/.vibecat/statusline-next
jq --arg sl "$sl" '.statusLine = ((.statusLine // {type: "command"}) + {command: $sl})' "$s" > "$s.new" && mv "$s.new" "$s"
[ -n "$prev" ] && [ "$prev" != "$sl" ] && echo "status line: wrapped your existing one ($prev); statusline.sh still runs it"
# launchd runs the cat: at login, now, and again after a crash (SuccessfulExit false: Quit from the menu stays quit until next login).
# bootout + bootstrap restarts a running cat on the new build.
label=com.heptafox.vibecat plist=~/Library/LaunchAgents/com.heptafox.vibecat.plist
mkdir -p ~/Library/LaunchAgents
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$PWD/vibecat</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true  # nothing loaded on a first install
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed. the cat is running and starts at login. restart your Claude Code sessions so the hooks load."
