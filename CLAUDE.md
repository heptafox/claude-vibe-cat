# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VibeCat is a macOS desktop cat (single-file SwiftUI/AppKit app) that reacts to Claude Code hook events. No Xcode project, no package manager, no dependencies beyond the Swift toolchain and `jq`.

## Commands

```sh
swiftc -O vibecat.swift -o vibecat      # build
./vibecat --test                        # self-check; prints "ok" or traps on a failed precondition
./vibecat                               # run by hand (floating panel, no Dock icon); normally launchd runs it, see install.sh
./install.sh                            # build + test + merge hooks and wrap statusLine in ~/.claude/settings.json (backs up to .bak) + (re)start the cat via launchd
```

- The self-test is the only test suite and it is one function (`selfTest()`); there is no per-test runner. Add cases there.
- Debug builds (`-Onone`) report the failing line and message from a `precondition`; `-O` builds just trap with exit 133.
- Set `VIBECAT_EVENTS=/some/file.jsonl` to run a second instance against a scratch log without touching the real one. Note that `./vibecat` truncates its events file on launch.
- Drive the app by hand by appending JSON lines to `~/.vibecat/events.jsonl` (see the event shape below), then screenshot. After rebuilding, `./install.sh` or `pkill -x vibecat` restarts it: launchd relaunches the cat on any non-zero exit (`KeepAlive.SuccessfulExit false`), so a kill is a restart and a menu Quit (exit 0) sticks.

## Architecture

Two pieces connected by a log file, plus a usage snapshot:

1. **`hook.sh`** is registered as the Claude Code hook for twelve events (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, UserPromptSubmit, Stop, StopFailure, SessionEnd, PreCompact, PostCompact). It is a single `jq` pass that reads the hook JSON on stdin and appends one trimmed line to `~/.vibecat/events.jsonl` (mode 600). It strips large fields and caps strings at 300 chars. It must never exit non-zero (exit 2 would block Claude's tool call), hence the `|| true` and early `exit 0`.
2. **`vibecat.swift`** polls that file every 0.25s from `Model.tick()`, parses new complete lines, and turns them into a `Mood` plus a `Bubble`.

Event line fields: `event, session, cwd, tool, message, prompt, kind` (notification type, or error type on StopFailure), `summary` (Stop only, from `last_assistant_message`), `term` (the terminal app's bundle id, from `$__CFBundleIdentifier`), `agent` (`agent_type`, set only when the hook fired inside a subagent), `error` (also the denial `reason` on PermissionDenied), `input`. The field names are a contract between `hook.sh` and `Model.handle()`; change both together.

3. **`statusline.sh`** is installed as the Claude Code `statusLine`, the only place plan usage is exposed. It rewrites `~/.vibecat/usage.json` as `{five_hour, seven_day, chats}`. `five_hour` and `seven_day` come from `rate_limits`, each with `used_percentage` and `resets_at` in epoch seconds; they are Pro/Max only, and the last known values are kept when they're absent. `chats` maps each `session_id` to `{cwd, pct, tokens, size, at, name, model, effort, added, removed, usd}` (`name` is `session_name`, `effort` is `effort.level` and absent for models without the setting, `added`/`removed`/`usd` come from `cost`), merged with the previous file and pruned after a day. `tokens` is what's in the context window now; Claude Code exposes no cumulative per-session total. The file is written atomically. It then pipes the same stdin to the user's previous status line, whose command `install.sh` saved in `~/.vibecat/statusline-next`. `Model.readUsage()` stats the file each tick. `noteUsage()` fills `usage` and `chats`, and nudges once per limit window at 80% and 95%, tracked in `warned`. Context never nudges; it shows only in the menu. `MenuView` shows `usage`, then `recentChats`: the last hour, newest two, minus sessions in `ended` (filled from SessionEnd). A chat row is labelled by `name`, falling back to the folder, which sits in the tooltip. Model and effort (`Chat.setup`) sit in a `chip` over the rows: once on the Context caption, and again above a row only when it differs from the row above. With no plan limits (API billing) the row shows `usd` instead of tokens. The Stop title appends `+added −removed` from the session's chat. A "Today" row sums `today`: every chat whose `at` is today, ended or not, with cost only on API billing. A limit row swaps its reset time for "⚠ <time>" when `runsOut()` (the average pace since the window opened, from the window length in `limitNames`, 50% and up) says it runs dry before resetting. The panel is 300pt tall so the menu fits all four meters, a second model chip and the Today row.

### Inside vibecat.swift

- `describe(tool:)` maps a tool call to bubble text; `moodFor(tool:)` maps it to a face (read / edit / work). Add new tools in both.
- `Model` holds all state. Key pieces: `sessions` (per-session start time and step count, drives the "Done · 4s · 3 steps" title and the effort level), `pending` (sessions waiting on the user), `quiet` (minimised).
- **Pending asks are per session.** A Notification (ask or idle wait) or a StopFailure adds to `pending` through `pend()`; any non-Notification event from the same session removes it. Only four notification kinds count as asks (`permission_prompt`, the two elicitation dialogs, `agent_needs_input`); `idle_prompt` and `agent_completed` are waits (a finished background agent is worth coming back for); `quota_auto_resume_fired` clears the session's pending stop failure and shows "Back on it"; the other `quota_auto_resume_*` kinds pend as `.oops`; everything else is a short "Heads up". PermissionDenied (auto mode refused a tool) is a plain `.oops` bubble, not pending. Events carrying `agent` (fired inside a subagent) get a "Helper · " title prefix and don't count as steps. PermissionRequest shows nothing itself: it stashes the described tool in `askDetail`, and the `permission_prompt` Notification that follows shows it. `tick()` re-shows the highest-priority pending bubble (asks and stop failures outrank idle waits) whenever nothing newer is showing, with "N more waiting" on its detail line. `pend()` only shows a new pending bubble if it is now the highest-priority one, so a later idle wait never covers an earlier ask. The idle bubble shows the session's last Stop summary, kept in `said`. AskUserQuestion and ExitPlanMode go through the same PermissionRequest path, so they show as "Needs you · Question" with the question and "Needs you · Plan ready". A pending bubble carries its `session`, which is how close, hover and tap know they are acting on a waiting session. Do not clear the bubble on events from other sessions.
- **Long tool calls.** Every PreToolUse (and PreCompact, as "Tidying up memory") is kept in `running` until any later event from that session, usually PostToolUse, which is registered only for this. When the bubble times out and nothing else is up, `tick()` re-shows the newest one with its elapsed time, refreshing `hideAt` 2s ahead so it lapses by itself once the call ends. Pending bubbles outrank it, closing any bubble clears it, and entries expire after 11 minutes (foreground Bash caps at 10).
- **Minimised mode** (`quiet`): events still update `last` and `pending` but nothing is shown or played; the cat shrinks to an icon with a "!" badge if an ask or a stopped session is pending. Clicking the cat wakes it. Persisted in `UserDefaults` along with `mute` and window `origin`.
- **Drawing**: `drawCat` paints the whole cat in a `Canvas` on a 100x100 grid. Everything that varies is in the `Look` struct (mood, blink, effort, last-event time, badge). Mood-specific motion lives in the first `switch mood`, eyes and mouth further down. The `TimelineView` is paused for static moods, so idle, sleeping and minimised cost no CPU.
- **Closing and hiding.** `close()` is the user-initiated hide (x button or 0.5s hover). It adds the session to `muted` so an acknowledged ask is not re-shown by `tick()`; a new Notification from that session un-mutes it. Asks and stop failures are exempt from hover-hide. Plain `dismiss()` is the auto-hide path and does not mute.
- **Face-only mode** (`faceOnly`, persisted): all state, moods and timers run as normal; only the view skips drawing the bubble (`showsText`). "Last" sets `peeking` to show one bubble on demand.
- The window is a non-activating `NSPanel` so clicking the cat never steals focus.

## Gotchas

- `install.sh` removes earlier vibecat entries from `~/.claude/settings.json` and appends its own, leaving other hooks alone. Re-run it after pulling, since the event list changes between versions.
- Hook changes only apply to Claude Code sessions started after install.
- `install.sh` writes `~/Library/LaunchAgents/com.heptafox.vibecat.plist` pointing at this checkout's binary and bootstraps it. Moving the checkout means re-running it. The agent runs the binary with no env, so `VIBECAT_EVENTS` test instances are always started by hand.
- The `vibecat` binary is a build artifact (gitignored). Build it per machine.
- Requires macOS 14+ (uses `.spring(duration:bounce:)` and Swift switch expressions).
- Shortcuts with known ceilings are marked with `ponytail:` comments (e.g. app-level terminal focus only, effort is a steps-and-time heuristic, naive log rotation can lose an event). Grep for them before "fixing" something that is deliberate.
