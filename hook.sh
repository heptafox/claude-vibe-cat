#!/bin/sh
# Claude Code hook: appends a trimmed copy of the event to ~/.vibecat/events.jsonl for vibecat.
# Drops big fields (file contents, edit text) and caps strings so the log stays small.
# On Stop, pulls Claude's last reply out of the transcript so the cat can show what it concluded.
# `|| true`: a hook exiting 2 would block Claude's tool call, so never fail.
command -v jq >/dev/null || exit 0
mkdir -p ~/.vibecat
in=$(cat)
ev=$(printf %s "$in" | jq -r '.hook_event_name')
summary=""
case "$ev" in
  PostToolUse)  # only failures are interesting; a clean PostToolUse would just double the log
    [ "$(printf %s "$in" | jq -r '.tool_response | if type == "object" then .is_error // false else false end')" = true ] || exit 0 ;;
  Stop)
    tp=$(printf %s "$in" | jq -r '.transcript_path // empty')
    # ponytail: last 40 lines is enough for the final reply; a huge final message just gets its tail
    [ -f "$tp" ] && summary=$(tail -n 40 "$tp" | jq -rs '[.[] | select(.type == "assistant")
        | (.message.content | if type == "string" then [{type: "text", text: .}] else . end)[]?
        | select(.type == "text") | .text] | last // ""' 2>/dev/null) ;;
esac
printf %s "$in" | jq -c --arg summary "$summary" --arg term "${TERM_PROGRAM:-}" \
  '{event: .hook_event_name, session: .session_id, cwd, tool: .tool_name, message, prompt,
    kind: .notification_type, summary: $summary, term: $term,
    error: (.error // (.tool_response | if type == "object" then .error else null end)),
    input: (.tool_input // {} | del(.content, .old_string, .new_string, .edits, .new_source))}
   | walk(if type == "string" then .[0:300] else . end)' >> ~/.vibecat/events.jsonl 2>/dev/null || true
