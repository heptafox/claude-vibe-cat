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
  | reduce ("PreToolUse","PostToolUseFailure","PermissionRequest","Notification","UserPromptSubmit","Stop","StopFailure","SessionEnd") as $ev
      (.; .hooks[$ev] += [{hooks: [{type: "command", command: $h, timeout: 5}]}])' "$s" > "$s.new" && mv "$s.new" "$s"
echo "installed. run ./vibecat (or add it to Login Items)"
