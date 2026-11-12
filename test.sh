#!/bin/sh
# Self-check: a debug build of the self-test (a failed check names its line), then sample events through hook.sh and statusline.sh
# in a scratch HOME, checking the field names Model reads. Prints "ok".
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
swiftc -Onone Sources/*.swift -o "$tmp/vibecat"
"$tmp/vibecat" --test >/dev/null

long=$(printf '%400s' | tr ' ' x)
for e in \
  '{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/proj","tool_name":"Write","tool_input":{"file_path":"/x/a","content":"big"}}' \
  '{"hook_event_name":"Notification","session_id":"s","cwd":"/x/proj","message":"Allow?","notification_type":"permission_prompt"}' \
  '{"hook_event_name":"Stop","session_id":"s","cwd":"/x/proj","last_assistant_message":"Done."}' \
  '{"hook_event_name":"PostToolUseFailure","session_id":"s","cwd":"/x/proj","tool_name":"Bash","error":"exit 1","agent_type":"Explore"}' \
  "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s\",\"cwd\":\"/x/proj\",\"prompt\":\"$long\"}"
do printf '%s' "$e" | HOME=$tmp __CFBundleIdentifier=com.test.term ./hook.sh; done
jq -se '.[0] | .event == "PreToolUse" and .session == "s" and .cwd == "/x/proj" and .tool == "Write" and .term == "com.test.term"
          and .input.file_path == "/x/a" and (.input | has("content") | not)' "$tmp/.vibecat/events.jsonl" >/dev/null
jq -se '.[1].kind == "permission_prompt" and .[1].message == "Allow?" and .[2].summary == "Done."
          and .[3].error == "exit 1" and .[3].agent == "Explore" and (.[4].prompt | length) == 300' "$tmp/.vibecat/events.jsonl" >/dev/null
[ "$(stat -f %Lp "$tmp/.vibecat/events.jsonl")" = 600 ]

echo 'echo wrapped' > "$tmp/.vibecat/statusline-next"
out=$(printf '%s' '{"session_id":"s","session_name":"fix","workspace":{"current_dir":"/x/proj"},"model":{"display_name":"Opus"},
  "effort":{"level":"high"},"context_window":{"used_percentage":62,"total_input_tokens":100,"total_output_tokens":24,"context_window_size":200000},
  "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":2000000000},"seven_day":{"used_percentage":10,"resets_at":2000000000}},
  "cost":{"total_lines_added":3,"total_lines_removed":1,"total_cost_usd":0.5}}' | HOME=$tmp ./statusline.sh)
[ "$out" = wrapped ]  # the previous status line still runs, on the same input
printf '%s' '{"session_id":"t","cwd":"/x/other","context_window":{"used_percentage":5}}' | HOME=$tmp ./statusline.sh >/dev/null
jq -e '.five_hour.used_percentage == 40 and .five_hour.resets_at == 2000000000 and .seven_day.used_percentage == 10
       and (.chats.s | .cwd == "/x/proj" and .pct == 62 and .tokens == 124 and .size == 200000 and .name == "fix" and .model == "Opus"
            and .effort == "high" and .added == 3 and .removed == 1 and .usd == 0.5 and (.pid | type) == "number" and (.at | type) == "number")
       and .chats.t.cwd == "/x/other"' "$tmp/.vibecat/usage.json" >/dev/null  # no rate_limits in the second: the last values stay
echo ok
