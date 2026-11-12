#!/bin/sh
# Builds and checks vibecat, adds its hooks and status line to ~/.claude/settings.json next to what you already have, and starts
# the cat under launchd. `./install.sh --uninstall` undoes all of it and deletes the cat's data.
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "need jq: brew install jq"; exit 1; }
s=~/.claude/settings.json label=com.heptafox.vibecat plist=~/Library/LaunchAgents/com.heptafox.vibecat.plist
# The checkout the last install pointed at: if the repo moved, its hooks and status line point there and must go too.
old=$(cat ~/.vibecat/checkout 2>/dev/null || true); old=${old:-$PWD}
# Writes back through `cat >`, so a symlinked settings.json (a dotfiles repo) stays a symlink.
edit() { jq --arg a "$PWD" --arg b "$old" "$@" "$s" > "$s.new" && cat "$s.new" > "$s" && rm "$s.new"; }
# Drops every vibecat hook, from this checkout or the last one.
unhook='def ours($f): IN(($a, $b) + $f);
  .hooks = ((.hooks // {}) | map_values(map(select(all(.hooks[]?; (.command // "") | ours("/hook.sh") | not)))) | with_entries(select(.value | length > 0)))'

if [ "$1" = --uninstall ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"
  # The status line goes back to the one vibecat wrapped, or away if there was none.
  [ -f "$s" ] && edit --arg prev "$(cat ~/.vibecat/statusline-next 2>/dev/null)" "$unhook"'
    | if (.statusLine.command // "") | ours("/statusline.sh") then (if $prev == "" then del(.statusLine) else .statusLine.command = $prev end) else . end'
  rm -rf ~/.vibecat
  defaults delete vibecat 2>/dev/null || true
  echo "uninstalled. restart your Claude Code sessions so the hooks unload."
  exit 0
fi

./test.sh
swiftc -O Sources/*.swift -o vibecat
mkdir -p ~/.claude ~/.vibecat
[ -f "$s" ] || echo '{}' > "$s"
[ -f "$s.pre-vibecat" ] || cp "$s" "$s.pre-vibecat"  # settings as they were before vibecat's first install
cp "$s" "$s.bak"                                      # and before this one
# The event list changes between versions, so drop the old entries, then add one per event.
# The hook points at this checkout's hook.sh, so the repo can live anywhere. timeout 5: a stuck hook must never stall a tool call.
edit --arg h "$PWD/hook.sh" "$unhook"'
  | reduce ("PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionDenied","Notification","UserPromptSubmit","Stop","StopFailure","SessionEnd","PreCompact","PostCompact") as $ev
      (.; .hooks[$ev] += [{hooks: [{type: "command", command: $h, timeout: 5}]}])'
# Plan usage only reaches outside tools through the status line, and there is only one: wrap yours instead of replacing it.
# One that is already ours (this checkout or the last) is not saved, or statusline.sh would end up running itself.
prev=$(jq -r '.statusLine.command // ""' "$s")
case "$prev" in
  ""|"$PWD/statusline.sh"|"$old/statusline.sh") ;;
  *) printf '%s\n' "$prev" > ~/.vibecat/statusline-next; echo "status line: wrapped your existing one ($prev); statusline.sh still runs it" ;;
esac
edit --arg sl "$PWD/statusline.sh" '.statusLine = ((.statusLine // {type: "command"}) + {command: $sl})'
printf '%s\n' "$PWD" > ~/.vibecat/checkout
# launchd runs the cat: at login, now, and again after a crash (SuccessfulExit false: Quit from the menu stays quit until next login).
# bootout + bootstrap restarts a running cat on the new build.
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
