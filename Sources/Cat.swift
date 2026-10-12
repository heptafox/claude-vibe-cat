import Cocoa
import SwiftUI

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
    // How hard it's going, 0…1: faster typing, knitted brows, drooping ears, sweat, heavy lids. Resting, waiting and asking faces stay clean.
    let worn = [.idle, .sleep, .quiet, .wait, .ask].contains(mood) ? 0 : l.effort, pace = 1 + worn * 0.5
    var hop = 0.0, bob = 0.0, tilt = 0.0, wag = 0.0, tap = 0.0, ear = worn * 10, scan = 0.0
    switch mood {
    case .work: bob = sin(t * 7 * pace) * 1.2; wag = sin(t * 3) * 14; tap = sin(t * 7 * pace)  // busy typing, frantic when worn
    case .edit: bob = sin(t * 5 * pace) * 0.8; wag = sin(t * 2) * 8; tap = sin(t * 5 * pace)   // heads-down
    case .read: scan = sin(t * 2.2) * 3; wag = sin(t * 1.4) * 10; ear = -12                    // scanning, one ear cocked
    case .think: tilt = sin(t * 1.3) * 5; wag = sin(t * 1.5) * 8                               // head tilt
    case .ask: hop = -abs(sin(t * 5)) * 6; wag = sin(t * 6) * 18                               // bouncing for attention
    case .wait: wag = sin(t * 1.2) * 6                                                         // patient
    case .done: hop = -abs(sin(t * 3.5)) * 3; wag = sin(t * 2) * 10; tilt = l.asking ? 8 + sin(t * 1.3) * 3 : 0  // happy hops; "well?" when it asked something
    case .oops: ear = 22; wag = sin(t * 1) * 4                                                 // ears back
    case .sleep, .quiet: ear = 18                                                              // ears droop
    default: break
    }
    let since = Date().timeIntervalSince(l.eventAt)
    let twitch = since < 0.35 ? sin(since / 0.35 * .pi * 2) * 9 : 0
    let brow = mood == .oops ? 1 : min(1, max(0, worn - 0.2) / 0.5)  // 0 none … 1 fully furrowed

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
            let lid = max(mood == .edit ? 5.5 : 0, max(0, worn - 0.75) * 22)  // narrowed when focused; lids sag when worn out
            if lid > 0 { h.fill(Path(CGRect(x: c.x - 5, y: c.y - 6, width: 10, height: lid)), with: .color(fur)) }
        }
        if brow > 0 {  // furrowed brows slope in toward the nose, steeper and darker the harder it's going
            line(h, seg(P(c.x - 5 * inward, 29 - 2 * brow), P(c.x + 3 * inward, 29 + 1.5 * brow)), 2.2, ink.opacity(0.35 + 0.65 * brow))
        }
    }
    paint(h, shape(P(46.5, 46), P(53.5, 46), P(50, 50)), blush, 1.2)
    if l.speaking {  // mouth opens and closes while the voice talks, whatever the mood
        let open = 1.5 + abs(sin(t * 9)) * 4.5
        h.fill(oval(50 - 3, 51, 6, open), with: .color(ink))
    } else if mood == .ask {
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
    if worn > 0.6 || mood == .oops {  // sweat drop sliding down the temple
        let dy = (t * 0.7).truncatingRemainder(dividingBy: 1) * 4
        paint(h, oval(80, 28 + dy, 5, 7), sweat, 1.2)
    }

    let mark = Font.system(size: 16, weight: .heavy, design: .rounded)
    switch mood {
    case .think:  // thought dots appear one by one
        let n = Int(t * 2) % 4
        for k in 0..<min(n, 3) { g.fill(oval(80 + CGFloat(k) * 6, 12 - CGFloat(k) * 3, 4.5, 4.5), with: .color(ink.opacity(0.5))) }
    case .ask: g.draw(Text("!").font(mark).foregroundColor(blush), at: P(88, 12 + abs(sin(t * 5)) * 3))
    case .done where worn <= 0.6: g.draw(Text("♥").font(mark).foregroundColor(blush), at: P(86, 14 - abs(sin(t * 3.5)) * 2))  // a rough finish gets the sweat drop instead
    case .sleep:
        g.draw(Text("z").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(ink.opacity(0.55)), at: P(82, 19))
        g.draw(Text("Z").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(ink.opacity(0.55)), at: P(91, 9))
    case .quiet where l.badge: g.draw(Text("!").font(mark).foregroundColor(blush), at: P(88, 12))
    default: break
    }
}
