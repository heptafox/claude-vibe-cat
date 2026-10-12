import Cocoa
import SwiftUI

// MARK: - Self-check

@MainActor func selfTest() {
    func check(_ b: Bubble?, _ want: String) {
        let got = b.map { "\($0.title)|\($0.detail)|\($0.code)" } ?? "nil"
        precondition(got == want, "want \(want), got \(got)")
    }
    check(describe(tool: "Read", ["file_path": "/a/b/cat.swift"]), "Reading|cat.swift|")
    check(describe(tool: "Bash", ["command": "ls -la\necho hi", "description": "List files"]), "Running|List files|ls -la")
    check(describe(tool: "TodoWrite", ["todos": [["content": "A", "status": "completed"],
                                                 ["content": "B", "activeForm": "Doing B", "status": "in_progress"]]]), "Plan 1/2|Doing B|")
    check(describe(tool: "mcp__claude_ai_Slack__send_message", [:]), "Using Slack|send_message|")
    let m = Model()
    m.quiet = false
    m.handle(["event": "UserPromptSubmit", "session": "s", "cwd": "/x/proj", "prompt": "hi"])
    m.handle(["event": "PreToolUse", "session": "s", "cwd": "/x/proj", "tool": "Read", "input": ["file_path": "/f.txt"]])
    check(m.bubble, "Reading|f.txt|")
    precondition(m.mood == .read)
    m.handle(["event": "PreToolUse", "session": "s", "cwd": "/x/proj", "tool": "Edit", "input": ["file_path": "/f.txt"]])
    precondition(m.mood == .edit)
    m.handle(["event": "PostToolUse", "session": "s", "cwd": "/x/proj", "tool": "Edit"])  // an event we don't handle: nothing changes
    precondition(m.mood == .edit)
    m.handle(["event": "PostToolUseFailure", "session": "s", "cwd": "/x/proj", "tool": "Bash", "error": "exit 1\nmore"])
    check(m.bubble, "Oops|Bash didn't go well|exit 1")
    precondition(m.mood == .oops && m.look.effort > 0.2)
    m.handle(["event": "Stop", "session": "s", "cwd": "/x/proj", "summary": "Fixed the **bug**.\nTests pass."])
    check(m.bubble, "Done · 0s · 2 steps|Fixed the bug. Tests pass.|")
    precondition(m.mood == .done && m.bubble?.project == "proj" && m.sessions.isEmpty && m.look.effort == 0)
    precondition(plain("## Done\n- Fixed `a`\n- Tests **pass**\n\n1. next") == "Done Fixed a Tests pass next")
    // A permission ask survives another session's chatter and clears only when its own session moves on.
    m.handle(["event": "Notification", "session": "a", "cwd": "/a", "message": "Allow Bash?", "kind": "permission_prompt"])
    m.handle(["event": "PreToolUse", "session": "b", "cwd": "/b", "tool": "Read", "input": ["file_path": "/f.txt"]])
    check(m.bubble, "Reading|f.txt|")
    m.hideAt = .distantPast; m.tick(live: false)
    check(m.bubble, "Needs you|Allow Bash?|")
    precondition(m.mood == .ask)
    m.handle(["event": "Notification", "session": "b", "cwd": "/b", "message": "Claude is waiting for your input"])
    check(m.bubble, "Needs you|Allow Bash?|")  // b's idle wait queues behind a's ask instead of covering it
    precondition(m.mood == .ask && m.pending.count == 2)
    m.handle(["event": "PreToolUse", "session": "a", "cwd": "/a", "tool": "Read", "input": ["file_path": "/g.txt"]])
    precondition(m.pending["a"] == nil && m.pending["b"] != nil)
    // Minimised: events are remembered but not shown; a waiting permission shows as a badge.
    m.quiet = true; m.tick(live: false)
    m.handle(["event": "Notification", "session": "c", "cwd": "/c", "message": "Allow Write?", "kind": "permission_prompt"])
    m.tick(live: false)
    precondition(m.bubble == nil && m.mood == .quiet && m.look.badge)
    m.quiet = false; m.tick(live: false)
    check(m.bubble, "Needs you|1 more waiting… Allow Write?|")  // b's idle wait is queued behind it
    // A PermissionRequest only remembers the specifics; the Notification that follows shows them.
    let p = Model()
    p.quiet = false
    p.handle(["event": "PermissionRequest", "session": "p", "cwd": "/p", "tool": "Bash", "input": ["command": "rm -rf build", "description": "Clean"]])
    precondition(p.bubble == nil && p.pending.isEmpty)
    p.handle(["event": "Notification", "session": "p", "cwd": "/p", "message": "Claude needs your permission to use Bash", "kind": "permission_prompt"])
    check(p.bubble, "Needs you · Running|Clean|rm -rf build")
    precondition(p.mood == .ask && p.bubble?.session == "p" && p.askDetail.isEmpty)
    // Other notification kinds are news, not requests: no pending, no nagging.
    p.handle(["event": "PreToolUse", "session": "p", "cwd": "/p", "tool": "Bash", "input": ["command": "rm -rf build"]])
    p.handle(["event": "Notification", "session": "p", "cwd": "/p", "message": "Signed in", "kind": "auth_success"])
    check(p.bubble, "Heads up|Signed in|")
    precondition(p.pending.isEmpty)
    // An API failure nags like an ask, survives the idle notice that follows, needs a click rather than a hover, and clears when the user types again.
    p.handle(["event": "StopFailure", "session": "p", "cwd": "/p", "kind": "rate_limit", "error": "429 Too many requests\ndetails"])
    check(p.bubble, "Claude stopped|rate limit|429 Too many requests")
    precondition(p.mood == .oops && p.pending["p"]?.mood == .oops && p.sessions.isEmpty)
    p.handle(["event": "Notification", "session": "p", "cwd": "/p", "message": "Claude is waiting for your input", "kind": "idle_prompt"])
    check(p.bubble, "Claude stopped|rate limit|429 Too many requests")
    p.hovering(true)
    precondition(p.hoverTask == nil)
    p.hideAt = .distantPast; p.tick(live: false)
    check(p.bubble, "Claude stopped|rate limit|429 Too many requests")
    p.close(); p.tick(live: false)
    precondition(p.bubble == nil && p.muted.contains("p"))
    p.handle(["event": "UserPromptSubmit", "session": "p", "cwd": "/p", "prompt": "retry"])
    precondition(p.pending.isEmpty && p.muted.isEmpty)
    // Closing an ask keeps it closed until that session sends a fresh notification.
    let n = Model()
    n.quiet = false; n.faceOnly = false
    n.handle(["event": "Notification", "session": "d", "cwd": "/d", "message": "Allow X?", "kind": "permission_prompt"])
    n.close(); n.tick(live: false)
    precondition(n.bubble == nil && n.muted.contains("d"))
    n.handle(["event": "Notification", "session": "d", "cwd": "/d", "message": "Allow Y?", "kind": "permission_prompt"])
    check(n.bubble, "Needs you|Allow Y?|")
    // A helper's tool calls show as such and don't count as steps; a denied call is news, not an ask.
    let h = Model()
    h.quiet = false; h.faceOnly = false
    h.handle(["event": "UserPromptSubmit", "session": "h", "cwd": "/h", "prompt": "go"])
    h.handle(["event": "PreToolUse", "session": "h", "cwd": "/h", "tool": "Read", "input": ["file_path": "/f.txt"], "agent": "Explore"])
    check(h.bubble, "Helper · Reading|f.txt|")
    precondition(h.mood == .read && h.sessions["h"]?.steps == 0)
    h.handle(["event": "PermissionDenied", "session": "h", "cwd": "/h", "tool": "Bash", "input": ["command": "rm -rf /", "description": "Wipe"], "error": "blocked by policy\nmore"])
    check(h.bubble, "Blocked · Running|Wipe|blocked by policy")
    precondition(h.mood == .oops && h.pending.isEmpty)
    // A finished background agent waits for you; a quota auto-resume clears the stopped nag; a failed resume nags instead.
    h.handle(["event": "Notification", "session": "h", "cwd": "/h", "message": "Agent done", "kind": "agent_completed"])
    check(h.bubble, "Helper finished|Agent done|")
    precondition(h.pending["h"]?.mood == .wait)
    h.handle(["event": "StopFailure", "session": "h", "cwd": "/h", "kind": "rate_limit", "error": "429"])
    precondition(h.pending["h"]?.mood == .oops)
    h.handle(["event": "Notification", "session": "h", "cwd": "/h", "message": "Resumed", "kind": "quota_auto_resume_fired"])
    check(h.bubble, "Back on it|Resumed|")
    precondition(h.mood == .think && h.pending.isEmpty)
    h.handle(["event": "Notification", "session": "h", "cwd": "/h", "message": "Gave up", "kind": "quota_auto_resume_stale"])
    check(h.bubble, "Didn't resume|Gave up|")
    precondition(h.pending["h"]?.mood == .oops)
    // Chat metadata from the status line: name, model and effort for the menu, lines changed in the Done title.
    h.noteUsage(["chats": ["h": ["cwd": "/x/proj", "pct": 12, "at": Date().timeIntervalSince1970, "name": "fix bug", "model": "Opus",
                                 "effort": "xhigh", "added": 3, "removed": 1, "usd": 0.42]]])
    precondition(h.chats["h"]?.name == "fix bug" && h.chats["h"]?.setup == "Opus · xhigh" && h.chats["h"]?.usd == 0.42)
    precondition(Chat(project: "p", pct: 0, tokens: 0, size: 0, at: .now, model: "Haiku").setup == "Haiku")  // no effort setting
    h.handle(["event": "UserPromptSubmit", "session": "h", "cwd": "/h", "prompt": "go"])
    h.handle(["event": "Stop", "session": "h", "cwd": "/h", "summary": "ok"])
    check(h.bubble, "Done · 0s · +3 −1|ok|")
    precondition(!n.muted.contains("d"))
    // Face-only: the mood still changes, but no text is shown unless asked for with "Last".
    n.faceOnly = true
    n.handle(["event": "PreToolUse", "session": "e", "cwd": "/e", "tool": "Read", "input": ["file_path": "/f.txt"]])
    precondition(n.mood == .read && !n.showsText)
    n.recall()
    precondition(n.showsText)
    n.dismiss()
    precondition(!n.showsText)
    // Usage: one nudge at 80% and one at 95% per window; a new window starts over; expired windows are dropped.
    let u = Model()
    u.quiet = false; u.faceOnly = false
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func snap(_ pct: Double, _ resets: Double) -> [String: Any] {
        ["five_hour": ["used_percentage": pct, "resets_at": resets], "seven_day": ["used_percentage": 40, "resets_at": 1_000_000 + 86400 * 3]]
    }
    u.noteUsage(snap(50, 1_003_600), now: t0)
    precondition(u.bubble == nil && u.usage["five_hour"]?.pct == 50 && u.usage["seven_day"]?.pct == 40)
    u.noteUsage(snap(82, 1_003_600), now: t0)
    check(u.bubble, "Session 82% used|Resets in 1h|")
    u.dismiss()
    u.noteUsage(snap(85, 1_003_600), now: t0)
    precondition(u.bubble == nil)
    u.noteUsage(snap(96, 1_003_600), now: t0)
    check(u.bubble, "Session 96% used|Resets in 1h|")
    u.dismiss()
    u.noteUsage(snap(81, 1_021_600), now: t0)
    check(u.bubble, "Session 81% used|Resets in 6h|")
    u.noteUsage(snap(81, 999_000), now: t0)
    precondition(u.usage["five_hour"] == nil && u.usage["seven_day"] != nil)
    // Both limits crossing in one snapshot share a bubble; the weekly reset is in days; a working cat keeps its face.
    u.mood = .work
    u.noteUsage(["five_hour": ["used_percentage": 96, "resets_at": 1_050_000], "seven_day": ["used_percentage": 85, "resets_at": 1_000_000 + 86400 * 3]], now: t0)
    check(u.bubble, "Session 96% · Week 85% used|Resets in 13h 53m|")
    precondition(u.mood == .work)
    u.noteUsage(["seven_day": ["used_percentage": 96, "resets_at": 1_000_000 + 86400 * 3]], now: t0)
    check(u.bubble, "Week 96% used|Resets in 3d|")
    // Context rows: newest chats first, at most two, none older than an hour, ended, from an exited process, or replaced in theirs.
    let t = Date().timeIntervalSince1970, me = getpid()
    u.noteUsage(["chats": ["a": ["cwd": "/x/alpha", "pct": 62, "tokens": 124_000, "size": 200_000, "at": t - 60],
                           "b": ["cwd": "/x/beta", "pct": 10, "tokens": 20_000, "size": 200_000, "at": t - 10, "pid": me],
                           "e": ["cwd": "/x/exited", "pct": 1, "at": t - 1, "pid": 99_999_999],
                           "f": ["cwd": "/x/cleared", "pct": 1, "at": t - 30, "pid": me],
                           "c": ["cwd": "/x/gamma", "pct": 90, "tokens": 900_000, "size": 1_000_000, "at": t - 5000],
                           "d": ["cwd": "/x/delta", "pct": 5, "tokens": 1, "size": 1, "at": t]]])
    u.handle(["event": "SessionEnd", "session": "d", "cwd": "/x/delta"])
    precondition(u.recentChats.map(\.project) == ["beta", "alpha"] && u.recentChats[1].tokens == 124_000)
    u.handle(["event": "UserPromptSubmit", "session": "d", "cwd": "/x/delta", "prompt": "back"])  // resumed: same id, row returns
    precondition(!u.ended.contains("d"))
    // Today's row counts every chat seen today, ended or not.
    let d = Model()
    d.noteUsage(["chats": ["x": ["cwd": "/x", "pct": 1, "at": t, "added": 3, "removed": 1, "usd": 0.5], "y": ["cwd": "/y", "pct": 1, "at": t, "added": 2, "usd": 1.0]]])
    precondition(d.today == (2, 5, 1, 1.5))
    // Forecast: average pace since the window opened, shown only when it beats the reset.
    precondition(runsOut(Limit(pct: 60, resets: t0.addingTimeInterval(3 * 86400)), window: 7 * 86400, now: t0) != nil)  // 15%/day, dry in 2.7d
    precondition(runsOut(Limit(pct: 89, resets: t0.addingTimeInterval(3600)), window: 7 * 86400, now: t0) == nil)       // resets first
    precondition(runsOut(Limit(pct: 40, resets: t0.addingTimeInterval(86400)), window: 7 * 86400, now: t0) == nil)      // under half: no forecast
    // A long tool call comes back with its clock after the bubble times out, and lapses once it ends.
    let r = Model()
    r.quiet = false; r.faceOnly = false
    r.handle(["event": "PreToolUse", "session": "r", "cwd": "/r", "tool": "Bash", "input": ["command": "npm test", "description": "Run tests"]])
    r.running["r"]?.since = Date().addingTimeInterval(-125); r.hideAt = .distantPast; r.tick(live: false)
    check(r.bubble, "Running · 2m 5s|Run tests|npm test")
    precondition(r.mood == .work)
    r.handle(["event": "PostToolUse", "session": "r", "cwd": "/r", "tool": "Bash"])
    r.hideAt = .distantPast; r.tick(live: false)
    precondition(r.bubble == nil && r.running.isEmpty)
    // The idle wait keeps Claude's last summary.
    r.handle(["event": "Stop", "session": "r", "cwd": "/r", "summary": "Tests **pass**."])
    r.handle(["event": "Notification", "session": "r", "cwd": "/r", "message": "Claude is waiting for your input", "kind": "idle_prompt"])
    check(r.bubble, "Ready when you are|Tests pass.|")
    // Questions and plans say what they are.
    check(describe(tool: "ExitPlanMode", ["plan": "# Fix the bug\n1. Edit"]), "Plan ready|Fix the bug Edit|")
    r.handle(["event": "PermissionRequest", "session": "r", "cwd": "/r", "tool": "AskUserQuestion", "input": ["questions": [["question": "Ship it?"], ["question": "Now?"]]]])
    r.handle(["event": "Notification", "session": "r", "cwd": "/r", "message": "Claude needs your permission", "kind": "permission_prompt"])
    check(r.bubble, "Needs you · 2 questions|Ship it?|")
    // Compaction shows while it runs.
    r.handle(["event": "PreCompact", "session": "r", "cwd": "/r"])
    check(r.bubble, "Tidying up memory|Compacting the chat to free up context|")
    precondition(r.mood == .think && r.pending.isEmpty)
    r.running["r"]?.since = Date().addingTimeInterval(-30.2); r.hideAt = .distantPast; r.tick(live: false)
    check(r.bubble, "Tidying up memory · 30s|Compacting the chat to free up context|")
    r.handle(["event": "PostCompact", "session": "r", "cwd": "/r"])
    precondition(r.bubble == nil)
    print("ok")
}
