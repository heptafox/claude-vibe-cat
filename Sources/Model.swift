import Cocoa
import SwiftUI

// MARK: - State

/// One plan limit window from the status line's `rate_limits`.
struct Limit: Equatable { var pct: Double, resets: Date }
let limitNames = [("five_hour", "Session", 5 * 3600.0, "5h"), ("seven_day", "Week", 7 * 86400.0, "7d")]  // key, menu name, window length, collar tag
/// When a limit runs dry at its average pace since the window opened, if that comes before it resets. Menu only.
/// ponytail: straight-line average, blind to bursts; a recent-rate forecast needs snapshots kept over time
func runsOut(_ l: Limit, window: TimeInterval, now: Date = Date()) -> Date? {
    let elapsed = window - l.resets.timeIntervalSince(now)
    guard l.pct >= 50, l.pct < 100, elapsed > 0 else { return nil }
    let out = now.addingTimeInterval((100 - l.pct) / l.pct * elapsed)
    return out < l.resets ? out : nil
}
/// One chat, from the status line. `tokens` is what's in the context now, not a running total. `name`, `model` and `effort`
/// may be empty (no effort on models without the setting); `usd` is Claude Code's list-price estimate, only meaningful on API billing.
struct Chat: Hashable {
    var project: String, pct: Double, tokens: Int, size: Int, at: Date
    var name = "", model = "", effort = "", added = 0, removed = 0, usd = 0.0
    var pid: Int32 = 0  // the Claude process the status line ran under; 0 = unknown (older statusline.sh)
    var setup: String { [model, effort].filter { !$0.isEmpty }.joined(separator: " · ") }  // "Opus 5.5 · xhigh"
}

typealias Pend = (mood: Mood, bubble: Bubble, since: Date, term: String)

/// Where a session's effort starts, from the chat's configured effort level: an xhigh session looks determined from its first step.
let effortFloor = ["medium": 0.1, "high": 0.2, "xhigh": 0.35, "max": 0.5]
/// A Stop summary that reads as a struggle, so the done face keeps its sweat.
/// ponytail: a word list, no sentiment model; "error" is left out since "fixed the error" is good news
func rough(_ summary: String) -> Bool {
    summary.range(of: #"\b(couldn|can|didn|wasn)[’']t\b|\b(cannot|unable|failed|failing|stuck|blocked|gave up|not possible)\b"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
}

enum Mood {
    case idle, sleep, quiet, think, read, edit, work, ask, wait, done, oops
    var animated: Bool { self != .idle && self != .sleep && self != .quiet }
    var tint: Color {
        switch self {
        case .think: .purple
        case .read: .teal
        case .edit: .indigo
        case .work: .blue
        case .ask: .pink
        case .done: .green
        case .oops: .red
        default: .orange
        }
    }
}

/// Everything the drawing needs, in one bag.
struct Look {
    var mood = Mood.idle, blink = false
    var speaking = false  // Voice is mid-phrase: the mouth moves and the timeline keeps running
    var effort = 0.0      // 0 fresh … 1 grinding: brows knit from 0.2, ears droop and typing speeds up, sweat from 0.6, heavy lids from 0.75
    var asking = false    // the last Stop summary ended in a question: the done face tilts its head
    var eventAt = Date.distantPast  // ears twitch right after an event
    var badge = false     // minimised with an ask or a stopped session waiting: small "!" so you still notice
    var heat = 0.0        // the fullest live chat's context, 0 at 50% … 1 at 100%: the fur reddens, in every mood
    var splash = Date.distantPast, splashFrom = 0.0  // when the context last dropped and from what heat: drops rain, the tint fades, steam rises
    var collar: [String] = []  // tags of the plan limits at 80% or more ("5h", "7d"): a red collar with one tag each, off once the window resets
}

@MainActor final class Model: ObservableObject {
    @Published var look = Look()
    @Published var bubble: Bubble?
    @Published var menu = false
    @Published var quiet = defaults.bool(forKey: "quiet")
    @Published var faceOnly = defaults.bool(forKey: "faceOnly")  // reactions without speech bubbles
    @Published var peeking = false                                // "Last" in face-only mode shows one bubble on request
    var showsText: Bool { !faceOnly || peeking }
    var muted: Set<String> = []  // sessions whose current ask/wait bubble the user closed; a fresh notification un-mutes
    var hoverTask: DispatchWorkItem?
    var mood: Mood { get { look.mood } set { look.mood = newValue } }
    var last: (Mood, Bubble)?
    /// Sessions waiting on the user. Shown whenever nothing newer is up, cleared only when *that* session moves on.
    var pending: [String: Pend] = [:]
    var hideAt = Date.distantFuture
    /// Asks and stop failures outrank idle waits; otherwise oldest first. Closed (muted) ones stay quiet.
    var firstPending: (key: String, value: Pend)? {
        pending.filter { !muted.contains($0.key) }
            .min { ($0.value.mood == .wait ? 1 : 0, $0.value.since.timeIntervalSince1970) < ($1.value.mood == .wait ? 1 : 0, $1.value.since.timeIntervalSince1970) }
    }
    var askDetail: [String: Bubble] = [:]  // what PermissionRequest said a session is about to ask for; the Notification that follows shows it
    var said: [String: String] = [:]       // each session's last Stop summary, so "Ready when you are" still says what Claude concluded
    /// Each session's latest tool call, until any later event from that session says it ended. tick() keeps a long one on screen.
    var running: [String: (mood: Mood, bubble: Bubble, since: Date)] = [:]
    var runShown: Bubble?                  // the "still running" bubble tick() last put up, so it can refresh its clock
    var lastEvent = Date()
    var sessions: [String: (start: Date, steps: Int, seen: Date)] = [:]
    var offset: UInt64 = 0
    @Published var usage: [String: Limit] = [:] {  // five_hour / seven_day; empty for API-key users
        didSet {  // the collar follows every path usage changes on: a climb, a new window, a window that passed its reset
            let c = limitNames.compactMap { k, _, _, tag in (usage[k]?.pct ?? 0) >= 80 ? tag : nil }
            if look.collar != c { look.collar = c }
        }
    }
    var warned: [String: Int] = [:]               // "<window><resets_at>" -> highest threshold already nudged, so a new window starts over
    var voice: Process?                           // the `say` child mid-phrase; AVSpeechSynthesizer clipped the end of every phrase on macOS, NSSpeechSynthesizer is deprecated
    @Published var chats: [String: Chat] = [:]    // session -> context window
    var ended: Set<String> = []                   // SessionEnd seen; usage.json keeps them for a day
    /// The menu's context rows: the two most recent live chats from the last hour. Live: no SessionEnd seen, its Claude process
    /// still running (`ended` is lost on restart and a closed tab may never send SessionEnd), and the newest chat in that process
    /// (/clear and /resume swap the session id under the same one).
    /// ponytail: a recycled pid can keep a dead chat alive for the rest of its hour
    var liveChats: [Chat] {
        let live = chats.filter { !ended.contains($0.key) && $0.value.at.timeIntervalSinceNow > -3600 }.values
            .filter { $0.pid == 0 || kill($0.pid, 0) == 0 }
        return live.filter { c in c.pid == 0 || !live.contains { $0.pid == c.pid && $0.at > c.at } }.sorted { $0.at > $1.at }
    }
    var recentChats: [Chat] { Array(liveChats.prefix(2)) }
    /// The menu's "Today" row: chats the status line saw today, their lines changed, and their cost.
    /// ponytail: a chat that spans midnight counts in full; splitting it by day needs a snapshot at midnight
    var today: (chats: Int, added: Int, removed: Int, usd: Double) {
        let start = Calendar.current.startOfDay(for: Date())
        return chats.values.filter { $0.at >= start }.reduce((0, 0, 0, 0.0)) { ($0.0 + 1, $0.1 + $1.added, $0.2 + $1.removed, $0.3 + $1.usd) }
    }
    var usageStamp = Date.distantPast             // usage.json mtime last read
    weak var window: NSWindow?

    /// `secs == nil` keeps the bubble up until the next event or a click.
    func say(_ m: Mood, _ b: Bubble, for secs: TimeInterval?) {
        last = (m, b)
        hideAt = secs.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if quiet { return }  // minimised: remember it, don't show it
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { mood = m; bubble = b; menu = false }
    }

    func dismiss() { withAnimation(.easeOut(duration: 0.2)) { bubble = nil; menu = false; peeking = false } }

    /// The user closed the bubble (x or hover). A waiting session is acknowledged, so it won't pop back up.
    func close() {
        if let k = bubble?.session, !k.isEmpty { muted.insert(k) }
        running.removeAll()  // seen it: don't bring the tool call back as "still running"
        dismiss()
    }

    /// Hovering a bubble hides it after a short dwell. Asks and stop failures are exempt: you need to click them.
    func hovering(_ inside: Bool) {
        hoverTask?.cancel(); hoverTask = nil
        guard inside, let b = bubble, b.session.isEmpty || mood == .wait else { return }
        let w = DispatchWorkItem { self.close() }
        hoverTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func toggleFaceOnly() {
        defaults.set(!faceOnly, forKey: "faceOnly")
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { faceOnly.toggle(); peeking = false; menu = false }
    }

    func chirp(_ name: String) {
        if !quiet, !defaults.bool(forKey: "mute") { NSSound(named: name)?.play() }
    }

    /// Spoken only with Voice on; Mute and minimised silence it like the chirps. A phrase already playing wins.
    func speak(_ s: String) {
        guard !quiet, !defaults.bool(forKey: "mute"), defaults.bool(forKey: "voice"), voice?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")  // the System voice from Spoken Content settings, at its own rate: a picked voice and a slower, softer delivery sounded worse
        p.arguments = [s]
        guard (try? p.run()) != nil else { return }
        voice = p
        look.speaking = true  // tick() clears it when `say` exits
    }

    /// "Needs you · Running" in proj → "Claude needs you in proj." A whole sentence with a full stop, so the voice closes it
    /// instead of trailing off. ponytail: headline and folder only; the detail (code, summaries) sounds awful spoken
    func phrase(_ b: Bubble) -> String {
        let head = b.title.components(separatedBy: " · ")[0]
        return (head == "Needs you" ? "Claude needs you" : head) + (b.project.isEmpty ? "." : " in \(b.project).")
    }

    func recall() {
        if let (m, b) = last { say(m, b, for: 10) }
        else { say(.idle, Bubble(icon: "pawprint.fill", title: "Meow!", detail: "Nothing from Claude yet"), for: 4) }
        peeking = true
    }

    func catTapped() {
        if quiet { setQuiet(false); recall(); return }
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { bubble = nil; menu.toggle() }
        if menu { hideAt = Date().addingTimeInterval(6) }
    }

    func setQuiet(_ q: Bool) {
        defaults.set(q, forKey: "quiet")
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) { quiet = q; bubble = nil; menu = false; if q { mood = .quiet } }
    }

    /// Bubble tap: a waiting session's bubble jumps to its terminal, anything else just closes.
    func bubbleTapped() {
        guard let b = bubble, let p = pending[b.session] else { return dismiss() }
        // ponytail: app-level focus only (term is the terminal's bundle id); per-tab focus needs AppleScript per terminal
        NSRunningApplication.runningApplications(withBundleIdentifier: p.term).first?.activate()
    }

    /// A session is waiting on the user. tick() keeps re-showing it until that session moves on; a fresh call un-mutes a closed one.
    func pend(_ sid: String, _ m: Mood, _ b: Bubble, _ term: String, sound: String? = nil) {
        var b = b
        b.session = sid
        pending[sid] = (m, b, Date(), term)
        muted.remove(sid)
        if let s = sound { chirp(s); speak(phrase(b)) }  // a sound marks the asks worth looking up for, so those are the ones spoken
        // A lower-priority wait must not cover an ask that's already up; tick() counts it in that bubble's "+1 more" instead.
        if firstPending?.key == sid { say(m, b, for: nil) } else { last = (m, b) }
    }

    func handle(_ e: [String: Any]) {
        let now = Date(), sid = str(e["session"]), project = fileName(e["cwd"]), event = str(e["event"]), term = str(e["term"])
        let helper = str(e["agent"]).isEmpty ? "" : "Helper · "  // hooks fire inside subagents too, with agent_type set
        lastEvent = now
        if event != "PostToolUse" { look.eventAt = now }  // ears twitch once per tool call, not twice
        sessions[sid]?.seen = now
        running[sid] = nil  // whatever this session was running has ended (or is now waiting on you)
        if event != "SessionEnd" { ended.remove(sid) }  // a resumed chat keeps its session id
        if event != "Notification" { pending[sid] = nil; muted.remove(sid); askDetail[sid] = nil }  // the session moved on, so the user answered
        look.asking = false
        let floor = effortFloor[chats[sid]?.effort ?? ""] ?? 0
        switch event {
        case "UserPromptSubmit":
            sessions[sid] = (now, 0, now)
            said[sid] = nil
            look.effort = floor
            let prompt = str(e["prompt"]).replacingOccurrences(of: "\n", with: " ")
            say(.think, Bubble(icon: "sparkles", title: "On it…", detail: prompt, project: project), for: 10)
        case "PreToolUse":
            if helper.isEmpty {  // ponytail: helpers' calls still drive the mood and bubble, just not the step count
                sessions[sid, default: (now, 0, now)].steps += 1
                let s = sessions[sid]!
                // ponytail: effort = configured level, steps and wall time; no notion of what the task actually is
                look.effort = min(1, floor + Double(s.steps) / 30 + now.timeIntervalSince(s.start) / 600)
            }
            let tool = str(e["tool"])
            var b = describe(tool: tool, e["input"] as? [String: Any] ?? [:])
            b.title = helper + b.title; b.project = project
            running[sid] = (moodFor(tool: tool), b, now)
            say(moodFor(tool: tool), b, for: 10)
        case "PostToolUseFailure":
            let err = str(e["error"])
            guard !err.isEmpty else { return }
            look.effort = min(1, look.effort + 0.25)  // failures wear the cat down
            say(.oops, Bubble(icon: "exclamationmark.triangle.fill", title: helper + "Oops", detail: "\(str(e["tool"])) didn't go well",
                              code: firstLine(err), project: project), for: 8)
        case "PermissionDenied":  // auto mode refused a tool call; Claude carries on, so this is news rather than an ask
            var b = describe(tool: str(e["tool"]), e["input"] as? [String: Any] ?? [:])
            b.icon = "hand.raised.slash.fill"; b.title = "Blocked · " + b.title; b.project = project
            let why = firstLine(str(e["error"]))
            if !why.isEmpty { b.code = why }
            say(.oops, b, for: 8)
        case "PermissionRequest":  // fires just before the permission dialog; the Notification that follows is the cue to show it
            var b = describe(tool: str(e["tool"]), e["input"] as? [String: Any] ?? [:])
            b.icon = "hand.raised.fill"; b.title = "Needs you · " + b.title; b.project = project
            askDetail[sid] = b
        case "Notification":
            let msg = str(e["message"]), kind = str(e["kind"])
            if kind == "idle_prompt" || msg.lowercased().contains("waiting for your input") {
                if pending[sid]?.mood == .oops { return }  // a stopped session is still stopped; "ready" would hide the error
                pend(sid, .wait, Bubble(icon: "cup.and.saucer.fill", title: "Ready when you are", detail: said[sid] ?? "", project: project), term)
            } else if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(kind) {
                let b = (kind == "permission_prompt" ? askDetail.removeValue(forKey: sid) : nil)
                    ?? Bubble(icon: "hand.raised.fill", title: "Needs you", detail: msg, project: project)
                pend(sid, .ask, b, term, sound: "Pop")
            } else if kind == "agent_completed" {  // a background agent finished: worth coming back for
                pend(sid, .wait, Bubble(icon: "person.2.fill", title: "Helper finished", detail: msg, project: project), term, sound: "Glass")
            } else if kind == "quota_auto_resume_fired" {  // the session resumed itself after a rate limit; drop the "stopped" nag
                pending[sid] = nil; muted.remove(sid)
                chirp("Glass")
                say(.think, Bubble(icon: "arrow.clockwise", title: "Back on it", detail: msg, project: project), for: 10)
            } else if kind.hasPrefix("quota_auto_resume_") {  // stale or disabled: still stuck
                pend(sid, .oops, Bubble(icon: "exclamationmark.triangle.fill", title: "Didn't resume", detail: msg, project: project), term, sound: "Basso")
            } else {  // auth_success, elicitation results: news, not a request
                say(.idle, Bubble(icon: "info.circle", title: "Heads up", detail: msg, project: project), for: 6)
            }
        case "StopFailure":  // API error (rate limit, overloaded, billing…): the session is dead until you act, so it nags like an ask
            sessions[sid] = nil
            look.effort = 0
            pend(sid, .oops, Bubble(icon: "exclamationmark.triangle.fill", title: "Claude stopped",
                                    detail: str(e["kind"]).replacingOccurrences(of: "_", with: " "), code: firstLine(str(e["error"])), project: project),
                 term, sound: "Basso")
        case "Stop":
            var title = "All done!"
            if let s = sessions.removeValue(forKey: sid) {
                title = "Done · " + (durations.string(from: now.timeIntervalSince(s.start)) ?? "")
                if s.steps > 0 { title += " · \(s.steps) step\(s.steps == 1 ? "" : "s")" }
                // ponytail: the status line refreshes on its own clock, so this is its last count, which may trail this Stop by a tick
                if let c = chats[sid], c.added + c.removed > 0 { title += " · +\(c.added) −\(c.removed)" }
            }
            let summary = plain(str(e["summary"]))
            look.effort = rough(summary) ? max(look.effort, 0.7) : 0  // a struggle ends with a "phew": sweat stays on the done face
            look.asking = summary.hasSuffix("?")
            said[sid] = summary
            chirp("Glass")
            speak("Claude has done the job" + (project.isEmpty ? "." : " in \(project)."))
            say(.done, Bubble(icon: "checkmark.circle.fill", title: title, detail: summary, project: project), for: 30)
        case "SessionEnd":
            sessions[sid] = nil
            said[sid] = nil
            ended.insert(sid)
        case "PreCompact":  // /compact, or automatic when the context fills; held like a long tool call until PostCompact
            let b = Bubble(icon: "archivebox.fill", title: "Tidying up memory", detail: "Compacting the chat to free up context", project: project)
            running[sid] = (.think, b, now)
            say(.think, b, for: 10)
        case "PostCompact":
            if bubble?.icon == "archivebox.fill" { dismiss() }  // the title may carry a clock by now
        default: break
        }
    }

    /// A status line snapshot: `{five_hour: {used_percentage, resets_at}, seven_day: {...}, chats: {...}}`.
    /// Nudges once at 80% and once at 95% per limit window; context never nudges, the terminal already does.
    func noteUsage(_ j: [String: Any], now: Date = Date()) {
        var u: [String: Limit] = [:], nudge: [String] = [], resetsIn = ""
        for (key, name, _, _) in limitNames {
            guard let w = j[key] as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let at = (w["resets_at"] as? NSNumber)?.doubleValue, at > now.timeIntervalSince1970 else { continue }  // expired: stale
            u[key] = Limit(pct: pct, resets: Date(timeIntervalSince1970: at))
            let tag = key + String(Int(at)), hit = [95, 80].first { pct >= Double($0) } ?? 0
            if hit > warned[tag, default: 0] {
                warned[tag] = hit
                nudge.append("\(name) \(Int(pct))%")
                if resetsIn.isEmpty { resetsIn = "Resets in " + (durations.string(from: at - now.timeIntervalSince1970) ?? "") }
            }
        }
        if !nudge.isEmpty {  // both at once (typically at launch) share one bubble; a working cat keeps its face
            speak(nudge.map { let p = $0.split(separator: " "); return "Your \(p[0].lowercased()) limit is at \(p[1])." }.joined(separator: " "))  // "Your session limit is at 80%."
            say([.think, .read, .edit, .work].contains(mood) ? mood : .idle,
                Bubble(icon: "gauge.with.dots.needle.67percent", title: nudge.joined(separator: " · ") + " used", detail: resetsIn), for: 10)
        }
        if u != usage { usage = u }
        var c: [String: Chat] = [:]
        for (sid, v) in j["chats"] as? [String: [String: Any]] ?? [:] {
            guard let pct = (v["pct"] as? NSNumber)?.doubleValue, let at = (v["at"] as? NSNumber)?.doubleValue else { continue }
            c[sid] = Chat(project: fileName(v["cwd"]), pct: pct, tokens: (v["tokens"] as? NSNumber)?.intValue ?? 0,
                          size: (v["size"] as? NSNumber)?.intValue ?? 0, at: Date(timeIntervalSince1970: at),
                          name: str(v["name"]), model: str(v["model"]), effort: str(v["effort"]), added: (v["added"] as? NSNumber)?.intValue ?? 0,
                          removed: (v["removed"] as? NSNumber)?.intValue ?? 0, usd: (v["usd"] as? NSNumber)?.doubleValue ?? 0,
                          pid: (v["pid"] as? NSNumber)?.int32Value ?? 0)
        }
        // Context never gets a bubble (the terminal shows it), but Voice calls out each climb past half: the last snapshot was
        // below, this one is at or above. Nothing at launch, and a /compact drops it back so it can speak again.
        for (sid, n) in c where n.pct >= 50 {
            if let o = chats[sid], o.pct < 50 { speak("The \(n.name.isEmpty ? n.project : n.name) chat is \(Int(n.pct))% full.") }
        }
        if c != chats { chats = c }
        // The fullest live chat heats the cat from 50% up. A drop of a third or more between snapshots is a /clear or /compact
        // (or the tab closing), not drift: the cat gets a splash and says so. ponytail: follows the status line's clock, a turn behind the terminal
        let live = liveChats, heat = min(1, max(0, ((live.map(\.pct).max() ?? 0) - 50) / 50))
        if look.heat - heat >= 0.3 {
            look.splash = now; look.splashFrom = look.heat
            let project = live.first?.project ?? ""  // the newest live chat is the one just cleared
            speak("Fresh start" + (project.isEmpty ? "." : " in \(project)."))
            say([.think, .read, .edit, .work].contains(mood) ? mood : .idle,
                Bubble(icon: "drop.fill", title: "Fresh start", detail: "The context is cleared", project: project), for: 10)
        }
        if look.heat != heat { look.heat = heat }
    }

    func readUsage() {
        guard let at = (try? FileManager.default.attributesOfItem(atPath: usagePath))?[.modificationDate] as? Date, at != usageStamp,
              let d = FileManager.default.contents(atPath: usagePath) else {
            let live = usage.filter { $0.value.resets > Date() }  // a window passed with no fresh snapshot yet
            if live != usage { usage = live }
            return
        }
        usageStamp = at
        noteUsage((try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
    }

    func poll() {
        guard let h = FileHandle(forReadingAtPath: eventsPath) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }  // file was truncated
        guard size > offset, (try? h.seek(toOffset: offset)) != nil, let data = try? h.readToEnd(),
              let nl = data.lastIndex(of: 10) else { return }  // only consume complete lines
        offset += UInt64(nl - data.startIndex + 1)
        for line in data[..<nl].split(separator: 10) {
            if let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(e) }
        }
        // ponytail: naive rotation, an event appended between our read and this truncate is lost
        if offset > 1_000_000 { try? Data().write(to: URL(fileURLWithPath: eventsPath)); offset = 0 }
    }

    func tick(live: Bool = true) {
        if look.speaking, voice?.isRunning != true { look.speaking = false }
        if live { poll(); readUsage() }  // readUsage is one stat unless the status line wrote a new snapshot
        let now = Date()
        // ponytail: a closed session never sends another event, so idle pleas expire; asks and stop failures never do
        pending = pending.filter { $0.value.mood != .wait || now.timeIntervalSince($0.value.since) < 600 }
        muted = muted.filter { pending[$0] != nil }
        let needsYou = pending.values.contains { $0.mood != .wait }
        if quiet {
            if bubble != nil || menu { bubble = nil; menu = false }
            if look.badge != needsYou { look.badge = needsYou }
            if mood != .quiet { mood = .quiet }
            return
        }
        if look.badge { look.badge = false }
        if menu, now > hideAt { dismiss() }
        if bubble != nil, now > hideAt { dismiss() }
        if let f = firstPending {
            let p = f.value
            var want = p.bubble
            let wait = now.timeIntervalSince(p.since)
            let more = pending.keys.filter { $0 != f.key && !muted.contains($0) }.count  // other sessions queued behind this one
            var notes: [String] = []  // on the detail line: a long title would truncate them
            if p.mood != .wait, wait >= 60 { notes.append("Waiting \(durations.string(from: wait) ?? "")") }
            if more > 0 { notes.append("\(more) more waiting") }
            if !notes.isEmpty { want.detail = notes.joined(separator: " · ") + "… " + want.detail }
            if bubble == nil || (mood == p.mood && bubble != want) { bubble = want; mood = p.mood; hideAt = .distantFuture }
        }
        // A tool call still going after its bubble timed out (a build, a test run) comes back with its clock.
        // ponytail: foreground Bash stops at 10 min, so an entry past 11 is a call whose end we never heard (interrupt, crash)
        running = running.filter { now.timeIntervalSince($0.value.since) < 660 }
        if bubble == nil || bubble == runShown, let r = running.values.max(by: { $0.since < $1.since }), now.timeIntervalSince(r.since) >= 10 {
            var want = r.bubble
            want.title += " · " + (durations.string(from: now.timeIntervalSince(r.since)) ?? "")
            if bubble != want { bubble = want; mood = r.mood }
            runShown = want
            hideAt = now.addingTimeInterval(2)  // lapses by itself once the call ends
        }
        if bubble == nil {
            // Claude can go quiet mid-task (long thinking); stay busy unless the session is silent for 2 min.
            let busy = sessions.values.contains { now.timeIntervalSince($0.seen) < 120 }
            let m: Mood = busy ? (mood == .think ? .think : .work) : now.timeIntervalSince(lastEvent) > 300 ? .sleep : .idle
            if m != mood { mood = m }
            if !busy, look.effort > 0 { look.effort = 0 }  // the "phew" wears off once the done bubble is gone
        }
        if mood.animated, mood != .ask, !look.blink, Int.random(in: 0..<14) == 0 {  // no blinking mid-plea, it reads as yawning
            look.blink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.look.blink = false }
        }
    }
}
