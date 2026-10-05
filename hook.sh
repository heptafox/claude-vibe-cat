#!/bin/sh
# Claude Code hook: appends a trimmed copy of the event to ~/.vibecat/events.jsonl for vibecat.
# Drops big fields (file contents, edit text) and caps strings so the log stays small.
# `|| true`: a hook exiting 2 would block Claude's tool call, so never fail.
command -v jq >/dev/null || exit 0
umask 077  # the log holds prompts and shell commands; keep it readable by this user only
mkdir -p ~/.vibecat
# term: the terminal app's bundle id, inherited from whatever launched the shell; vibecat focuses it on click
jq -c --arg term "${__CFBundleIdentifier:-}" \
  '{event: .hook_event_name, session: .session_id, cwd, tool: .tool_name, message, prompt,
    kind: (.notification_type // .error_type), summary: (.last_assistant_message // ""), term: $term, agent: .agent_type,
    error: (.error // .error_message // .reason),
    input: (.tool_input // {} | del(.content, .old_string, .new_string, .edits, .new_source))}
   | walk(if type == "string" then .[0:300] else . end)' >> ~/.vibecat/events.jsonl 2>/dev/null || true
