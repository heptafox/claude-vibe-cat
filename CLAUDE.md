# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VibeCat is a macOS desktop cat (single-file SwiftUI/AppKit app) that reacts to Claude Code hook events. No Xcode project, no package manager, no dependencies beyond the Swift toolchain and `jq`.

## Commands

```sh
swiftc -O vibecat.swift -o vibecat      # build
./vibecat --test                        # self-check; prints "ok" or traps on a failed precondition
./vibecat                               # run (floating panel, no Dock icon)
./install.sh                            # build + test + merge hooks into ~/.claude/settings.json (backs up to .bak)
```

- The self-test is the only test suite and it is one function (`selfTest()`); there is no per-test runner. Add cases there.
- Debug builds (`-Onone`) report the failing line and message from a `precondition`; `-O` builds just trap with exit 133.
- Set `VIBECAT_EVENTS=/some/file.jsonl` to run a second instance against a scratch log without touching the real one. Note that `./vibecat` truncates its events file on launch.
- Drive the app by hand by appending JSON lines to `~/.vibecat/events.jsonl` (see the event shape below), then screenshot. Restart the process with `pkill -x vibecat` after rebuilding.

## Architecture

Two pieces connected by a log file:

1. **`hook.sh`** is registered as the Claude Code hook for seven events (PreToolUse, PostToolUse, PostToolUseFailure, Notification, UserPromptSubmit, Stop, SessionEnd). It reads the hook JSON on stdin and appends one trimmed line to `~/.vibecat/events.jsonl`. It strips large fields, caps strings at 300 chars, drops PostToolUse events that are not failures, and on Stop extracts the last assistant text from the transcript. It must never exit non-zero (exit 2 would block Claude's tool call), hence the `|| true` and early `exit 0`.
2. **`vibecat.swift`** polls that file every 0.25s from `Model.tick()`, parses new complete lines, and turns them into a `Mood` plus a `Bubble`.

Event line fields: `event, session, cwd, tool, message, prompt, kind` (notification type), `summary` (Stop only), `term` (`$TERM_PROGRAM`), `error`, `input`. The field names are a contract between `hook.sh` and `Model.handle()`; change both together.

### Inside vibecat.swift

- `describe(tool:)` maps a tool call to bubble text; `moodFor(tool:)` maps it to a face (read / edit / work). Add new tools in both.
- `Model` holds all state. Key pieces: `sessions` (per-session start time and step count, drives the "Done · 4s · 3 steps" title and the effort level), `pending` (sessions waiting on the user), `quiet` (minimised).
- **Pending asks are per session.** A Notification adds to `pending`; any non-Notification event from the same session removes it. `tick()` re-shows the highest-priority pending bubble (permission asks outrank idle waits) whenever nothing newer is showing. Do not clear the bubble on events from other sessions.
- **Minimised mode** (`quiet`): events still update `last` and `pending` but nothing is shown or played; the cat shrinks to an icon with a "!" badge if a permission ask is pending. Clicking the cat wakes it. Persisted in `UserDefaults` along with `mute` and window `origin`.
- **Drawing**: `drawCat` paints the whole cat in a `Canvas` on a 100x100 grid. Everything that varies is in the `Look` struct (mood, blink, effort, last-event time, badge). Mood-specific motion lives in the first `switch mood`, eyes and mouth further down. The `TimelineView` is paused for static moods, so idle, sleeping and minimised cost no CPU.
- **Closing and hiding.** `close()` is the user-initiated hide (x button or 0.5s hover). It adds the session to `muted` so an acknowledged ask is not re-shown by `tick()`; a new Notification from that session un-mutes it. Permission asks are exempt from hover-hide. Plain `dismiss()` is the auto-hide path and does not mute.
- **Face-only mode** (`faceOnly`, persisted): all state, moods and timers run as normal; only the view skips drawing the bubble (`showsText`). "Last" sets `peeking` to show one bubble on demand.
- The window is a non-activating `NSPanel` so clicking the cat never steals focus.

## Gotchas

- `install.sh` replaces any existing hooks on those seven events in `~/.claude/settings.json`; it does not append to them.
- Hook changes only apply to Claude Code sessions started after install.
- The `vibecat` binary is a build artifact (gitignored). Build it per machine.
- Requires macOS 14+ (uses `.spring(duration:bounce:)` and Swift switch expressions).
- Shortcuts with known ceilings are marked with `ponytail:` comments (e.g. app-level terminal focus only, effort is a steps-and-time heuristic, naive log rotation can lose an event). Grep for them before "fixing" something that is deliberate.
