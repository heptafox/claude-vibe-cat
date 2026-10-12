import Cocoa
import SwiftUI

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
            .fontDesign(.rounded)  // matches the cat; SF Rounded reads better than SF at these small sizes
            .padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 11)
            .frame(width: 320, alignment: .leading)  // fixed width so it doesn't jump around between events
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
                    ViewThatFits(in: .horizontal) {  // the title wins; a project chip that can't fit whole is dropped, not shrunk to "vib…"
                        HStack(spacing: 7) { title; Spacer(minLength: 8); if !b.project.isEmpty { chip(b.project, tint) } }
                        HStack(spacing: 7) { title; Spacer(minLength: 8) }
                    }
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.primary.opacity(0.65))
                            .frame(width: 20, height: 20).background(Color.primary.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
                }
                .font(.system(size: 14))
                if !b.detail.isEmpty {
                    Text(b.detail).font(.system(size: 13)).lineLimit(2)
                }
                if !b.code.isEmpty {
                    Text(b.code).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .combine)  // VoiceOver reads the whole bubble as one line
    }
    var title: some View { Text(b.title).fontWeight(.bold).lineLimit(1) }
}

/// Small tinted capsule: the project on a bubble, the model · effort over the menu's chat rows.
func chip(_ s: String, _ tint: Color) -> some View {
    Text(s).font(.system(size: 12, weight: .bold)).foregroundStyle(tint).lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
}

struct MenuView: View {  // what you get when you click the cat
    @ObservedObject var m: Model
    var body: some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                let limits = limitNames.compactMap { key, name, window in m.usage[key].map { (name, $0, window) } }, chats = m.recentChats
                if !limits.isEmpty {
                    caption("Plan usage")
                    ForEach(limits, id: \.0) { name, l, window in
                        if let out = runsOut(l, window: window) {
                            meter(name, l.pct, "⚠ " + clock(out)).help("At this pace it runs out around \(clock(out)), before it resets at \(clock(l.resets))")
                        } else {
                            meter(name, l.pct, "↻ " + clock(l.resets))
                        }
                    }
                }
                // Model · effort heads a row only when it differs from the row above, so one setup shows once on the Context line.
                // ponytail: the folder lives in the tooltip; a third column doesn't fit. Cost replaces tokens on API billing
                // (no plan limits), where it's real money; plan users would only see a misleading list price.
                ForEach(chats.indices, id: \.self) { i in
                    let c = chats[i], ctx = tokens(c.tokens) + " / " + tokens(c.size), paid = limits.isEmpty && c.usd > 0
                    if i == 0 || c.setup != chats[i - 1].setup {
                        HStack {
                            caption(i == 0 ? "Context" : "")
                            Spacer()
                            chip(c.setup, .orange).help("Model and effort level of the chat\(i == 0 && chats.dropFirst().allSatisfy { $0.setup == c.setup } ? "s" : " below")")
                        }
                    }
                    meter(c.name.isEmpty ? c.project : c.name, c.pct, paid ? String(format: "$%.2f", c.usd) : ctx)
                        .help([c.project, paid ? ctx : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                let t = m.today
                if t.chats > 0 {
                    HStack(spacing: 6) {
                        caption("Today")
                        Spacer()
                        Text("\(t.chats) chat\(t.chats == 1 ? "" : "s") · +\(t.added) −\(t.removed)" + (limits.isEmpty && t.usd > 0 ? String(format: " · $%.2f", t.usd) : ""))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
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
    }
    func tokens(_ n: Int) -> String { n.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))) }  // 124K, 1M: tokens are counted in K/M everywhere
    func caption(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
    }
    /// "3:10 PM" if within a day, else "Thu 3:10 PM".
    func clock(_ d: Date) -> String {
        (d.timeIntervalSinceNow < 86400 ? "" : d.formatted(.dateTime.weekday()) + " ") + d.formatted(date: .omitted, time: .shortened)
    }
    /// "Session [bar] 78%  ↻ 3:10 PM" or "vibe-cat [bar] 62%  124K / 200K".
    func meter(_ name: String, _ pct: Double, _ note: String) -> some View {
        HStack(spacing: 6) {
            Text(name).fontWeight(.semibold).truncationMode(.middle).frame(width: 88, alignment: .leading)
            Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6).overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(pct >= 80 ? Color.red : pct >= 50 ? .orange : .green).frame(width: g.size.width * min(pct, 100) / 100)
                }
            }
            Text("\(Int(pct))%").monospacedDigit().frame(width: 32, alignment: .trailing)
            Text(note).monospacedDigit().foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
        }
        .font(.system(size: 12)).lineLimit(1)
        .accessibilityElement(children: .combine)
    }
    func item(_ icon: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 3) { Image(systemName: icon).font(.system(size: 15)); Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
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
                    .onHover { if m.menu { m.hideAt = $0 ? .distantFuture : Date().addingTimeInterval(3) } }  // stays open while you read it; the guard keeps a closing menu from cutting short the bubble "Last" just showed
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
        .frame(width: 440, height: 320, alignment: .bottomTrailing)  // tall enough for the menu with all four meters and two model chips
    }
}

final class Host: NSHostingView<Root> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // react on the first click
}
