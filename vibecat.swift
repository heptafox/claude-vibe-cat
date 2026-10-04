// VibeCat: a tiny desktop cat that tells you what Claude Code is doing.
// Build: swiftc -O vibecat.swift -o vibecat    Run: ./vibecat    Self-check: ./vibecat --test
// Reads events that hook.sh appends to ~/.vibecat/events.jsonl.
// Click the cat for its menu (last message, minimise, face-only, mute, quit). Minimised, it sits quietly; click to wake.
// Bubbles close with their x, or by hovering them. Click a "Needs you" bubble to jump to that terminal. Drag the cat to move it.
import Cocoa
import SwiftUI

let eventsPath = ProcessInfo.processInfo.environment["VIBECAT_EVENTS"] ?? NSHomeDirectory() + "/.vibecat/events.jsonl"  // override for testing
let defaults = UserDefaults.standard

// MARK: - Turning hook events into words

struct Bubble: Equatable {
    var icon: String, title: String, detail = "", code = "", project = ""
    var session = ""  // set when the bubble is a session waiting on you: click jumps to its terminal, close acknowledges it
}

func str(_ v: Any?) -> String { (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
func firstLine(_ v: Any?) -> String { str(v).components(separatedBy: .newlines)[0] }
func fileName(_ v: Any?) -> String { (str(v) as NSString).lastPathComponent }
/// Enough markdown stripping for a two-line bubble: headings, bullets, numbering, bold, backticks, newlines.
func plain(_ md: String) -> String {
    md.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s*|[-*•]\s+|\d+\.\s+)|\*\*|`+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

func describe(tool: String, _ i: [String: Any]) -> Bubble {
    switch tool {
    case "Read": return Bubble(icon: "doc.text", title: "Reading", detail: fileName(i["file_path"]))
    case "Write": return Bubble(icon: "doc.badge.plus", title: "Writing", detail: fileName(i["file_path"]))
    case "Edit", "MultiEdit": return Bubble(icon: "pencil", title: "Editing", detail: fileName(i["file_path"]))
    case "NotebookEdit": return Bubble(icon: "pencil", title: "Editing", detail: fileName(i["notebook_path"]))
    case "Bash": return Bubble(icon: "terminal", title: "Running", detail: str(i["description"]), code: firstLine(i["command"]))
    case "Grep": return Bubble(icon: "magnifyingglass", title: "Searching", detail: fileName(i["path"]), code: str(i["pattern"]))
    case "Glob": return Bubble(icon: "folder", title: "Looking for files", code: str(i["pattern"]))
    case "WebFetch": return Bubble(icon: "globe", title: "Reading the web", detail: URL(string: str(i["url"]))?.host ?? str(i["url"]))
    case "WebSearch": return Bubble(icon: "globe", title: "Searching the web", detail: str(i["query"]))
    case "Task", "Agent": return Bubble(icon: "person.2", title: "Sending a helper", detail: str(i["description"]))
    case "TodoWrite":
        let todos = i["todos"] as? [[String: Any]] ?? []
        let doing = todos.first { $0["status"] as? String == "in_progress" }
        let done = todos.filter { $0["status"] as? String == "completed" }.count
        return Bubble(icon: "checklist", title: "Plan \(done)/\(todos.count)", detail: str(doing?["activeForm"] ?? doing?["content"]))
    default:
        let parts = tool.components(separatedBy: "__")  // mcp__<server>__<tool>
        if parts.count == 3, parts[0] == "mcp" {
            let server = parts[1].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
            return Bubble(icon: "puzzlepiece.extension", title: "Using \(server)", detail: parts[2])
        }
        return Bubble(icon: "wrench.and.screwdriver", title: "Using \(tool)")
    }
}

/// Which face a tool gets: reading is curious, editing is focused, everything else is busy.
func moodFor(tool: String) -> Mood {
    switch tool {
    case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch": .read
    case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
    default: .work
    }
}

let durations: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute, .second]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f
}()

// MARK: - State

typealias Pend = (mood: Mood, bubble: Bubble, since: Date, term: String)

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
    var effort = 0.0      // 0 fresh … 1 grinding: adds furrowed brows and a sweat drop
    var eventAt = Date.distantPast  // ears twitch right after an event
    var badge = false     // minimised with an ask or a stopped session waiting: small "!" so you still notice
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
    var lastEvent = Date()
    var sessions: [String: (start: Date, steps: Int, seen: Date)] = [:]
    var offset: UInt64 = 0
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
        if let s = sound { chirp(s) }
        say(m, b, for: nil)
    }

    func handle(_ e: [String: Any]) {
        let now = Date(), sid = str(e["session"]), project = fileName(e["cwd"]), event = str(e["event"]), term = str(e["term"])
        lastEvent = now
        look.eventAt = now
        sessions[sid]?.seen = now
        if event != "Notification" { pending[sid] = nil; muted.remove(sid); askDetail[sid] = nil }  // the session moved on, so the user answered
        switch event {
        case "UserPromptSubmit":
            sessions[sid] = (now, 0, now)
            look.effort = 0
            let prompt = str(e["prompt"]).replacingOccurrences(of: "\n", with: " ")
            say(.think, Bubble(icon: "sparkles", title: "On it…", detail: prompt, project: project), for: 10)
        case "PreToolUse":
            sessions[sid, default: (now, 0, now)].steps += 1
            let s = sessions[sid]!
            // ponytail: effort = steps and wall time; no notion of what the task actually is
            look.effort = min(1, Double(s.steps) / 30 + now.timeIntervalSince(s.start) / 600)
            let tool = str(e["tool"])
            var b = describe(tool: tool, e["input"] as? [String: Any] ?? [:])
            b.project = project
            say(moodFor(tool: tool), b, for: 10)
        case "PostToolUseFailure":
            let err = str(e["error"])
            guard !err.isEmpty else { return }
            look.effort = min(1, look.effort + 0.25)  // failures wear the cat down
            say(.oops, Bubble(icon: "exclamationmark.triangle.fill", title: "Oops", detail: "\(str(e["tool"])) didn't go well",
                              code: firstLine(err), project: project), for: 8)
        case "PermissionRequest":  // fires just before the permission dialog; the Notification that follows is the cue to show it
            var b = describe(tool: str(e["tool"]), e["input"] as? [String: Any] ?? [:])
            b.icon = "hand.raised.fill"; b.title = "Needs you · " + b.title; b.project = project
            askDetail[sid] = b
        case "Notification":
            let msg = str(e["message"]), kind = str(e["kind"])
            if kind == "idle_prompt" || msg.lowercased().contains("waiting for your input") {
                if pending[sid]?.mood == .oops { return }  // a stopped session is still stopped; "ready" would hide the error
                pend(sid, .wait, Bubble(icon: "cup.and.saucer.fill", title: "Ready when you are", project: project), term)
            } else if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(kind) {
                let b = (kind == "permission_prompt" ? askDetail.removeValue(forKey: sid) : nil)
                    ?? Bubble(icon: "hand.raised.fill", title: "Needs you", detail: msg, project: project)
                pend(sid, .ask, b, term, sound: "Pop")
            } else {  // auth_success, agent_completed, elicitation results, quota auto-resume: news, not a request
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
            }
            look.effort = 0
            let summary = plain(str(e["summary"]))
            chirp("Glass")
            say(.done, Bubble(icon: "checkmark.circle.fill", title: title, detail: summary, project: project), for: 30)
        case "SessionEnd":
            sessions[sid] = nil
        default: break
        }
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
        if live { poll() }
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
        if let p = firstPending?.value {
            var want = p.bubble
            let wait = now.timeIntervalSince(p.since)
            if p.mood != .wait, wait >= 60 { want.detail = "Waiting \(durations.string(from: wait) ?? "")… " + want.detail }
            if bubble == nil || (mood == p.mood && bubble != want) { bubble = want; mood = p.mood; hideAt = .distantFuture }
        }
        if bubble == nil {
            // Claude can go quiet mid-task (long thinking); stay busy unless the session is silent for 2 min.
            let busy = sessions.values.contains { now.timeIntervalSince($0.seen) < 120 }
            let m: Mood = busy ? (mood == .think ? .think : .work) : now.timeIntervalSince(lastEvent) > 300 ? .sleep : .idle
            if m != mood { mood = m }
        }
        if mood.animated, mood != .ask, !look.blink, Int.random(in: 0..<14) == 0 {  // no blinking mid-plea, it reads as yawning
            look.blink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.look.blink = false }
        }
    }
}

// MARK: - The cat (drawn on a 100x100 grid)

let fur = Color(red: 0.98, green: 0.74, blue: 0.45), stripe = Color(red: 0.90, green: 0.55, blue: 0.27)
let ink = Color(red: 0.33, green: 0.21, blue: 0.15), cream = Color(red: 1, green: 0.94, blue: 0.86)
let blush = Color(red: 1, green: 0.6, blue: 0.66), sweat = Color(red: 0.55, green: 0.8, blue: 1)

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)) }
func shape(_ pts: CGPoint...) -> Path { var p = Path(); p.addLines(pts); p.closeSubpath(); return p }
func curve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addQuadCurve(to: b, control: c); return p }
func seg(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addLine(to: b); return p }
func paint(_ g: GraphicsContext, _ p: Path, _ c: Color, _ w: CGFloat = 2.5) {
    g.fill(p, with: .color(c))
    g.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w, lineJoin: .round))
}
func line(_ g: GraphicsContext, _ p: Path, _ w: CGFloat, _ c: Color = ink) {
    g.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
}
func rotated(_ g: GraphicsContext, about c: CGPoint, by deg: Double) -> GraphicsContext {
    var r = g
    r.translateBy(x: c.x, y: c.y); r.rotate(by: .degrees(deg)); r.translateBy(x: -c.x, y: -c.y)
    return r
}

func drawCat(_ ctx: GraphicsContext, _ size: CGSize, _ l: Look, t: Double) {
    let mood = l.mood, resting = mood == .sleep || mood == .quiet
    var g = ctx
    g.scaleBy(x: size.width / 100, y: size.height / 100)
    var hop = 0.0, bob = 0.0, tilt = 0.0, wag = 0.0, tap = 0.0, ear = 0.0, scan = 0.0
    switch mood {
    case .work: bob = sin(t * 7) * 1.2; wag = sin(t * 3) * 14; tap = sin(t * 7)  // busy typing
    case .edit: bob = sin(t * 5) * 0.8; wag = sin(t * 2) * 8; tap = sin(t * 5)   // heads-down
    case .read: scan = sin(t * 2.2) * 3; wag = sin(t * 1.4) * 10; ear = -12      // scanning, one ear cocked
    case .think: tilt = sin(t * 1.3) * 5; wag = sin(t * 1.5) * 8                 // head tilt
    case .ask: hop = -abs(sin(t * 5)) * 6; wag = sin(t * 6) * 18                 // bouncing for attention
    case .wait: wag = sin(t * 1.2) * 6                                           // patient
    case .done: hop = -abs(sin(t * 3.5)) * 3; wag = sin(t * 2) * 10              // happy hops
    case .oops: ear = 22; wag = sin(t * 1) * 4                                   // ears back
    case .sleep, .quiet: ear = 18                                                // ears droop
    default: break
    }
    let since = Date().timeIntervalSince(l.eventAt)
    let twitch = since < 0.35 ? sin(since / 0.35 * .pi * 2) * 9 : 0
    let strained = l.effort > 0.5 && (mood == .work || mood == .edit || mood == .read || mood == .think)

    g.fill(oval(31 - hop * 0.6, 93, 38 + hop * 1.2, 6), with: .color(.black.opacity(0.18)))  // ground shadow shrinks as it hops
    if resting {  // squash a little when curled up
        g.translateBy(x: 0, y: 98); g.scaleBy(x: 1, y: 0.93); g.translateBy(x: 0, y: -98)
    }
    g.translateBy(x: 0, y: hop)

    var tail = g
    tail.translateBy(x: 68, y: 88)
    tail.rotate(by: .degrees(wag))
    let tailPath = curve(P(0, 0), P(26, 2), P(22, -28))
    line(tail, tailPath, 13)
    line(tail, tailPath, 9, fur)
    line(tail, seg(P(17, -14), P(23, -17)), 2.6, stripe)
    line(tail, seg(P(20, -22), P(25, -23)), 2.6, stripe)

    paint(g, oval(26, 56, 48, 41), fur)
    g.fill(oval(39, 66, 22, 28), with: .color(cream))
    paint(g, oval(32, 89 - max(0, tap) * 3, 15, 9), fur, 2)   // paws tap alternately while working
    paint(g, oval(53, 89 - max(0, -tap) * 3, 15, 9), fur, 2)

    var h = g
    h.translateBy(x: 50, y: 44 + bob)
    h.rotate(by: .degrees(tilt))
    h.translateBy(x: -50, y: -44)
    // ears: left droops/twitches outward with -angle, right with +angle; read mode cocks only the right one
    let le = rotated(h, about: P(24, 30), by: -(mood == .read ? 0 : ear) - twitch)
    let re = rotated(h, about: P(76, 30), by: ear + twitch)
    paint(le, shape(P(20, 32), P(25, 5), P(45, 20)), fur)
    paint(re, shape(P(80, 32), P(75, 5), P(55, 20)), fur)
    le.fill(shape(P(26, 25), P(27.5, 11), P(39, 20)), with: .color(blush))
    re.fill(shape(P(74, 25), P(72.5, 11), P(61, 20)), with: .color(blush))
    paint(h, oval(15, 14, 70, 52), fur)
    for (a, b) in [(P(50, 15.5), P(50, 24)), (P(42, 17), P(43.5, 23)), (P(58, 17), P(56.5, 23))] {
        line(h, seg(a, b), 2.6, stripe)
    }
    h.fill(oval(37, 43, 26, 17), with: .color(cream))
    h.fill(oval(19, 45, 12, 7), with: .color(blush.opacity(0.6)))
    h.fill(oval(69, 45, 12, 7), with: .color(blush.opacity(0.6)))

    let look: CGPoint = switch mood {  // work: eyes on the bubble; think: up and away; wait: downcast
    case .work, .edit: P(-2, 1.5)
    case .read: P(scan, 0.5)
    case .think: P(2.5, -3.5)
    case .wait: P(-1, 2.5)
    default: .zero
    }
    for x in [CGFloat(35), 65] {
        let c = P(x + look.x, 37 + look.y), inward: CGFloat = x < 50 ? 1 : -1
        if mood == .done {
            line(h, curve(P(c.x - 5, c.y + 2), P(c.x, c.y - 6), P(c.x + 5, c.y + 2)), 2.4)  // ^ ^
        } else if l.blink || resting {
            line(h, curve(P(c.x - 5, c.y), P(c.x, c.y + 4), P(c.x + 5, c.y)), 2.4)
        } else if mood == .oops {
            h.fill(oval(c.x - 2.5, c.y - 2.5, 5, 5), with: .color(ink))  // tiny shocked dots
        } else {
            let k: CGFloat = mood == .ask ? 1.25 : 1
            h.fill(oval(c.x - 4 * k, c.y - 5 * k, 8 * k, 10 * k), with: .color(ink))
            h.fill(oval(c.x - 0.5, c.y - 4.5, 3.4, 3.4), with: .color(.white))
            if mood == .ask { h.fill(oval(c.x - 2.5, c.y + 1.5, 1.8, 1.8), with: .color(.white)) }
            if mood == .edit { h.fill(Path(CGRect(x: c.x - 5, y: c.y - 6, width: 10, height: 5.5)), with: .color(fur)) }  // narrowed, focused
        }
        if strained || mood == .oops {  // furrowed brows slope in toward the nose
            line(h, seg(P(c.x - 5 * inward, 27), P(c.x + 3 * inward, 30)), 2.2)
        }
    }
    paint(h, shape(P(46.5, 46), P(53.5, 46), P(50, 50)), blush, 1.2)
    if mood == .ask {
        h.fill(oval(47.5, 51, 5, 5.5), with: .color(ink))
    } else if mood == .oops {
        line(h, curve(P(45, 53), P(50, 50.5), P(55, 53)), 1.8)  // wobbly flat mouth
    } else {
        var m = curve(P(44, 51.5), P(47, 55.5), P(50, 51.5))
        m.addQuadCurve(to: P(56, 51.5), control: P(53, 55.5))
        m.addPath(seg(P(50, 50), P(50, 51.5)))
        line(h, m, 1.8)
        if mood == .edit { paint(h, oval(48.3, 53.5, 3.6, 3.2), blush, 1) }  // tongue tip: concentrating
    }
    for (a, b) in [(P(23, 49), P(8, 46)), (P(23, 52.5), P(8, 54.5)), (P(77, 49), P(92, 46)), (P(77, 52.5), P(92, 54.5))] {
        line(h, seg(a, b), 1.3, ink.opacity(0.75))
    }
    if strained || mood == .oops {  // sweat drop sliding down the temple
        let dy = (t * 0.7).truncatingRemainder(dividingBy: 1) * 4
        paint(h, oval(80, 28 + dy, 5, 7), sweat, 1.2)
    }

    let mark = Font.system(size: 16, weight: .heavy, design: .rounded)
    switch mood {
    case .think:  // thought dots appear one by one
        let n = Int(t * 2) % 4
        for k in 0..<min(n, 3) { g.fill(oval(80 + CGFloat(k) * 6, 12 - CGFloat(k) * 3, 4.5, 4.5), with: .color(ink.opacity(0.5))) }
    case .ask: g.draw(Text("!").font(mark).foregroundColor(blush), at: P(88, 12 + abs(sin(t * 5)) * 3))
    case .done: g.draw(Text("♥").font(mark).foregroundColor(blush), at: P(86, 14 - abs(sin(t * 3.5)) * 2))
    case .sleep:
        g.draw(Text("z").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(ink.opacity(0.55)), at: P(82, 19))
        g.draw(Text("Z").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(ink.opacity(0.55)), at: P(91, 9))
    case .quiet where l.badge: g.draw(Text("!").font(mark).foregroundColor(blush), at: P(88, 12))
    default: break
    }
}

// MARK: - Views

struct BubbleShape: Shape {  // rounded box with a little tail pointing right at the cat
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width - 8, height: r.height), cornerRadius: 14)
        p.move(to: P(r.maxX - 8, r.maxY - 28))
        p.addQuadCurve(to: P(r.maxX, r.maxY - 8), control: P(r.maxX - 3, r.maxY - 17))
        p.addLine(to: P(r.maxX - 8, r.maxY - 15))
        p.closeSubpath()
        return p
    }
}

struct Card<Content: View>: View {  // shared bubble chrome: solid background, tinted edge, soft shadow
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 11)
            .frame(width: 300, alignment: .leading)  // fixed width so it doesn't jump around between events
            .background(BubbleShape().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.3), radius: 10, y: 4))
            .overlay(BubbleShape().stroke(tint.opacity(0.45), lineWidth: 1))
    }
}

struct BubbleView: View {
    let b: Bubble, tint: Color, close: () -> Void
    var body: some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: b.icon).foregroundStyle(tint)
                    Text(b.title).fontWeight(.bold).lineLimit(1).layoutPriority(1)  // the title wins; the project chip shrinks first
                    Spacer(minLength: 8)
                    if !b.project.isEmpty {
                        Text(b.project).font(.system(size: 11, weight: .bold)).foregroundStyle(tint).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint.opacity(0.16), in: Capsule())
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.primary.opacity(0.65))
                            .frame(width: 20, height: 20).background(Color.primary.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
                }
                .font(.system(size: 14))
                if !b.detail.isEmpty {
                    Text(b.detail).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85)).lineLimit(2)
                }
                if !b.code.isEmpty {
                    Text(b.code).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.9)).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .combine)  // VoiceOver reads the whole bubble as one line
    }
}

struct MenuView: View {  // what you get when you click the cat
    @ObservedObject var m: Model
    var body: some View {
        Card(tint: .orange) {
            HStack(spacing: 4) {
                item("bubble.left.fill", "Last") { m.recall() }
                item("moon.zzz.fill", "Minimise") { m.setQuiet(true) }
                item(m.faceOnly ? "text.bubble.fill" : "face.smiling.fill", m.faceOnly ? "Show text" : "Face only") { m.toggleFaceOnly() }
                item(defaults.bool(forKey: "mute") ? "speaker.slash.fill" : "speaker.wave.2.fill",
                     defaults.bool(forKey: "mute") ? "Unmute" : "Mute") {
                    defaults.set(!defaults.bool(forKey: "mute"), forKey: "mute"); m.objectWillChange.send()
                }
                item("xmark.circle.fill", "Quit") { NSApp.terminate(nil) }
            }
        }
    }
    func item(_ icon: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 3) { Image(systemName: icon).font(.system(size: 15)); Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct Root: View {
    @ObservedObject var m: Model
    @State private var grab: CGPoint?
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            if m.menu {
                MenuView(m: m).padding(.bottom, 44)
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            } else if let b = m.bubble, m.showsText {
                BubbleView(b: b, tint: m.mood.tint, close: m.close)
                    .onHover { m.hovering($0) }
                    .padding(.bottom, 44)
                    .onTapGesture { m.bubbleTapped() }
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            }
            // Redraws only while the cat is moving; idle, asleep and minimised cost nothing.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !m.mood.animated && Date().timeIntervalSince(m.look.eventAt) > 0.5)) { tl in
                Canvas { g, size in drawCat(g, size, m.look, t: tl.date.timeIntervalSinceReferenceDate) }
            }
            .frame(width: 96, height: 96)
            .scaleEffect(m.quiet ? 0.4 : 1, anchor: .bottomTrailing)  // minimised: icon-sized, full 96pt hit area stays
            .opacity(m.quiet ? 0.85 : 1)
            .contentShape(Rectangle())
            .accessibilityLabel("VibeCat: " + String(describing: m.mood)).accessibilityAddTraits(.isButton)  // sound is the only other non-visual cue
            .onTapGesture { m.catTapped() }
            .gesture(DragGesture(minimumDistance: 3).onChanged { _ in
                guard let w = m.window else { return }
                let mouse = NSEvent.mouseLocation
                let o = grab ?? P(mouse.x - w.frame.minX, mouse.y - w.frame.minY)
                grab = o
                w.setFrameOrigin(P(mouse.x - o.x, mouse.y - o.y))
            }.onEnded { _ in
                grab = nil
                if let w = m.window { defaults.set(NSStringFromPoint(w.frame.origin), forKey: "origin") }
            })
            .contextMenu {
                Button("Hide bubble") { m.close() }
                Button(m.faceOnly ? "Show text" : "Face only") { m.toggleFaceOnly() }
                Button(m.quiet ? "Wake up" : "Minimise") { m.setQuiet(!m.quiet) }
                Button("Quit VibeCat") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 440, height: 190, alignment: .bottomTrailing)
    }
}

final class Host: NSHostingView<Root> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // react on the first click
}

// MARK: - Launch

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
    precondition(m.mood == .wait && m.pending.count == 2)
    m.handle(["event": "PreToolUse", "session": "a", "cwd": "/a", "tool": "Read", "input": ["file_path": "/g.txt"]])
    precondition(m.pending["a"] == nil && m.pending["b"] != nil)
    // Minimised: events are remembered but not shown; a waiting permission shows as a badge.
    m.quiet = true; m.tick(live: false)
    m.handle(["event": "Notification", "session": "c", "cwd": "/c", "message": "Allow Write?", "kind": "permission_prompt"])
    m.tick(live: false)
    precondition(m.bubble == nil && m.mood == .quiet && m.look.badge)
    m.quiet = false; m.tick(live: false)
    check(m.bubble, "Needs you|Allow Write?|")
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
    precondition(!n.muted.contains("d"))
    // Face-only: the mood still changes, but no text is shown unless asked for with "Last".
    n.faceOnly = true
    n.handle(["event": "PreToolUse", "session": "e", "cwd": "/e", "tool": "Read", "input": ["file_path": "/f.txt"]])
    precondition(n.mood == .read && !n.showsText)
    n.recall()
    precondition(n.showsText)
    n.dismiss()
    precondition(!n.showsText)
    print("ok")
}

// Top-level code isn't main-actor isolated here, but AppKit and the model need it.
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no dock icon
    // Fresh log, readable only by this user: it holds prompts and shell commands.
    try? FileManager.default.createDirectory(atPath: (eventsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o600])

    let model = Model()
    let screen = NSScreen.main!.visibleFrame
    var origin = P(screen.maxX - 450, screen.minY + 6)
    if let s = defaults.string(forKey: "origin"), NSScreen.screens.contains(where: { $0.frame.contains(NSPointFromString(s)) }) {
        origin = NSPointFromString(s)  // where you left it, if that monitor is still here
    }
    // Non-activating panel: clicking the cat never steals focus from what you're doing.
    let panel = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 440, height: 190)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.contentView = Host(rootView: Root(m: model))
    model.window = panel
    panel.orderFrontRegardless()

    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { model.tick() } }
    app.run()
}
