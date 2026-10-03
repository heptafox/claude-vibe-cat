# VibeCat

A tiny desktop cat that tells you what [Claude Code](https://claude.com/claude-code) is doing, so you can look away from the terminal and still know when it needs you.

- **Reads the room.** Curious while reading files, focused while editing, busy while running commands, and it gets sweaty the longer a task grinds on.
- **Says what's happening.** A speech bubble shows the current step, and when Claude finishes it shows what Claude concluded.
- **Gets your attention.** A permission request makes the cat bounce and chirp, and keeps nagging until you answer. Click the bubble to jump to your terminal.
- **Handles failures.** A failed tool call gives it an "oops" face with the error.
- **Multi-session aware.** Several Claude Code windows at once are fine; one session's chatter never hides another's request.
- **Stays out of the way.** Bubbles disappear on their own, close with the x, and hide when you hover over them. A permission request is the one exception to hover-hide, so you can still click it.
- **Faces only, if you prefer.** Click the cat and choose **Face only** to drop the speech bubbles and keep just the reactions and sounds. **Last** shows the latest message on demand.
- **Minimise.** Click the cat, choose **Minimise**, and it shrinks to a small icon. Click it to wake it. It never steals focus, and it drags anywhere.

## Requirements

- macOS 14 or newer
- Xcode command line tools: `xcode-select --install`
- `jq`: `brew install jq`

## Install

```sh
git clone <this repo> vibe-cat
cd vibe-cat
./install.sh     # builds, self-tests, and adds the hooks to ~/.claude/settings.json
./vibecat        # start the cat
```

Then restart any open Claude Code sessions, because hooks load at session start. To launch at login, add the built `vibecat` to System Settings, General, Login Items.

`install.sh` backs up your settings to `~/.claude/settings.json.bak` and **replaces** any existing hooks on the seven events it uses (PreToolUse, PostToolUse, PostToolUseFailure, Notification, UserPromptSubmit, Stop, SessionEnd). The hooks point at this folder's `hook.sh`, so keep the folder where it is, or re-run the installer after moving it.

## How it works

`hook.sh` is a Claude Code hook. It appends a trimmed one-line JSON copy of each event to `~/.vibecat/events.jsonl`, dropping file contents and capping long strings. `vibecat.swift` watches that file and turns events into a mood and a bubble. Everything stays on your machine, and nothing is sent anywhere.

## Development

```sh
swiftc -O vibecat.swift -o vibecat   # build
./vibecat --test                     # self-check, prints "ok"
```

The whole app is one Swift file with no dependencies. To try a mood without Claude, append an event to the log:

```sh
echo '{"event":"Notification","session":"x","cwd":"/demo","message":"Allow Bash?","kind":"permission_prompt"}' >> ~/.vibecat/events.jsonl
```

Set `VIBECAT_EVENTS=/path/to/file.jsonl` to run a test instance against a scratch log. See `CLAUDE.md` for architecture notes.

## Known limits

- Clicking a "Needs you" bubble focuses the terminal app, not the specific tab. Supported: iTerm, Terminal, VS Code, Warp, Ghostty, Hyper.
- "Effort" is estimated from step count and elapsed time, not from understanding the task.

## License

[MIT](LICENSE)
