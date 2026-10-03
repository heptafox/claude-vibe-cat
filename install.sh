#!/bin/sh
# Builds vibecat and merges its hooks into ~/.claude/settings.json (backup kept beside it).
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "need jq: brew install jq"; exit 1; }
swiftc -O vibecat.swift -o vibecat && ./vibecat --test
s=~/.claude/settings.json
[ -f "$s" ] || echo '{}' > "$s"
cp "$s" "$s.bak"
# hooks point at this checkout's hook.sh, so the repo can live anywhere
jq --arg h "$PWD/hook.sh" '.hooks = (.hooks // {}) + (["PreToolUse","PostToolUse","PostToolUseFailure","Notification","UserPromptSubmit","Stop","SessionEnd"]
  | map({key: ., value: [{hooks: [{type: "command", command: $h}]}]}) | from_entries)' "$s" > "$s.new" && mv "$s.new" "$s"
echo "installed. run ./vibecat (or add it to Login Items)"
