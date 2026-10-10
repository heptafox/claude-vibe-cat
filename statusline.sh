#!/bin/sh
# Claude Code status line: saves plan usage (5-hour and weekly limits) and each chat's context window, name, model, effort, lines changed and cost
# to ~/.vibecat/usage.json
# for vibecat, then runs the status line you had before (install.sh kept its command in ~/.vibecat/statusline-next).
# rate_limits only exists for Pro/Max, after a session's first response; when absent, the last known values stay.
umask 077
mkdir -p ~/.vibecat
in=$(cat)
if command -v jq >/dev/null; then
  f=~/.vibecat/usage.json t=~/.vibecat/usage.json.$$
  [ -s "$f" ] || echo '{}' > "$f"
  # ponytail: concurrent sessions can race this read-modify-write and drop one update; the next status line refresh restores it
  printf '%s' "$in" | jq -c --slurpfile old "$f" --argjson now "$(date +%s)" '($old[0] // {}) as $o | .context_window as $c
    | {five_hour: (.rate_limits.five_hour // $o.five_hour), seven_day: (.rate_limits.seven_day // $o.seven_day),
       chats: ((($o.chats // {}) | with_entries(select(.value.at > $now - 86400)))
         + (if .session_id and $c.used_percentage then {(.session_id): {cwd: (.workspace.current_dir // .cwd), pct: $c.used_percentage,
              tokens: (($c.total_input_tokens // 0) + ($c.total_output_tokens // 0)), size: $c.context_window_size, at: $now,
              name: .session_name, model: .model.display_name, effort: .effort.level,
              added: .cost.total_lines_added, removed: .cost.total_lines_removed, usd: .cost.total_cost_usd}} else {} end))}' \
    > "$t" 2>/dev/null && mv "$t" "$f" || rm -f "$t"
fi
next=~/.vibecat/statusline-next
[ -s "$next" ] && printf '%s' "$in" | sh -c "$(cat "$next")"
exit 0
