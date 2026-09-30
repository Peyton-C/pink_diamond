import SwiftUI

/// Song time ↔ seconds from now on the playback clock, for one song around the playhead. Transitions play a song
/// faster or slower, so the two drift apart inside them.
struct SongClock {
    private let songTimes: [Double]   // ascending
    private let times: [Double]       // seconds from now, ascending

    init(now: Double, sides: [TransitionSide], span: Double) {
        func rate(_ s: Double) -> Double { max(sides.first { s >= $0.start && s <= $0.end }?.rate(at: s) ?? 1, 0.01) }
        let step = 0.02
        var fs = [now], ft = [0.0]
        while ft.last! < span {
            let s = fs.last!
            fs.append(s + step); ft.append(ft.last! + step / rate(s + step / 2))
        }
        var bs: [Double] = [], bt: [Double] = []
        var s = now, t = 0.0
        while t > -span {
            t -= step / rate(s - step / 2); s -= step
            bs.append(s); bt.append(t)
        }
        songTimes = bs.reversed() + fs
        times = bt.reversed() + ft
    }

    func songTime(at t: Double) -> Double { Self.interpolate(t, times, songTimes) }
    func time(at s: Double) -> Double { Self.interpolate(s, songTimes, times) }

    /// Linear interpolation in a table; beyond it, one second per second (no transition is that far out).
    private static func interpolate(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] + (x - xs[0]) }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] + (x - xs[xs.count - 1]) }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if xs[mid] <= x { lo = mid } else { hi = mid } }
        return ys[lo] + (x - xs[lo]) / max(xs[hi] - xs[lo], 1e-9) * (ys[hi] - ys[lo])
    }
}

/// One song on one deck, around the playhead.
struct LiveDeck {
    let song: Song?
    let analysis: SongAnalysis?
    let entering: TransitionSide?
    let leaving: TransitionSide?
    let clock: SongClock

    var sides: [TransitionSide] { [entering, leaving].compactMap { $0 } }
    /// Song times where the song is heard: from its entering transition (or its start) to the end of its leaving one.
    var audible: ClosedRange<Double> { (entering?.start ?? 0)...max(entering?.start ?? 0, leaving?.end ?? analysis?.duration ?? 0) }
}

/// The playing playlist as two decks scrolling past a fixed playhead. Songs alternate between the decks, odd
/// playlist positions on A (top) and even on B (bottom), so a song stays on its deck from the moment it's cued until it
/// has played out, and the next one is cued on the other.
struct LiveDeckView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    static let span = 10.0   // seconds either side of the playhead
    static let labelWidth = 110.0

    var body: some View {
        if let queue = player.queue, let position = player.position {
            content(queue, position)
        } else {
            Color.clear
        }
    }

    private func plan(_ ids: [UUID], _ i: Int) -> TransitionPlan? {
        guard i >= 0, i + 1 < ids.count, case .ready(let p) = library.plan(from: ids[i], to: ids[i + 1]) else { return nil }
        return p
    }

    private func content(_ queue: MixPlayer.Queue, _ p: MixRenderer.Position) -> some View {
        let ids = queue.ids, d = p.deck
        let current = plan(ids, d)
        // The queue's first song is rendered without its entering transition (playback started inside it).
        let outEntering = d > 0 ? plan(ids, d - 1)?.incoming : nil
        let outgoing = LiveDeck(song: library.song(ids[d]), analysis: library.analyses[ids[d]], entering: outEntering,
                                leaving: current?.outgoing,
                                clock: SongClock(now: p.deckOut, sides: [outEntering, current?.outgoing].compactMap { $0 }, span: Self.span))
        var incoming: LiveDeck?
        if d + 1 < ids.count {
            let leaving = plan(ids, d + 1)?.outgoing
            // Before it starts, the incoming song is where it will be when the outgoing one reaches the handoff.
            let cue = current.map { outgoing.clock.time(at: $0.outgoing.start) }
                ?? outgoing.clock.time(at: outgoing.analysis?.duration ?? 0)
            let now = p.deckIn ?? ((current?.incoming.start ?? 0) - cue)
            incoming = LiveDeck(song: library.song(ids[d + 1]), analysis: library.analyses[ids[d + 1]], entering: current?.incoming,
                                leaving: leaving,
                                clock: SongClock(now: now, sides: [current?.incoming, leaving].compactMap { $0 }, span: Self.span))
        }
        let outOnA = (queue.startIndex + d) % 2 == 0
        let a = outOnA ? outgoing : incoming
        let b = outOnA ? incoming : outgoing
        return VStack(alignment: .leading, spacing: 10) {
            header(outgoing, incoming, current)
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    LiveRuler().frame(height: 18)
                    LiveLanes(deck: a, color: Theme.outgoing)
                    LiveDeckLane(deck: a, color: Theme.outgoing, name: "A").frame(height: 92)
                    LiveDeckLane(deck: b, color: Theme.incoming, name: "B").frame(height: 92)
                    LiveLanes(deck: b, color: Theme.incoming)
                }
            }
        }
        .padding(14)
        .background(Theme.panel)
    }

    private func header(_ outgoing: LiveDeck, _ incoming: LiveDeck?, _ plan: TransitionPlan?) -> some View {
        HStack(spacing: 10) {
            Text(outgoing.song?.title ?? "?")
            if let incoming {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(incoming.song?.title ?? "?")
            }
            if let plan {
                StyleChip(plan: plan)
                let start = outgoing.clock.time(at: plan.outgoing.start)
                Text(start > 0 ? "in \(Theme.time(start).dropLast(2))" : "mixing").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 15, weight: .bold))
        .lineLimit(1)
    }
}

private func liveX(_ t: Double, _ width: Double) -> Double {
    (t + LiveDeckView.span) / (2 * LiveDeckView.span) * width
}

struct LiveRuler: View {
    var body: some View {
        Canvas { ctx, size in
            for t in stride(from: -LiveDeckView.span, through: LiveDeckView.span, by: 2) {
                ctx.draw(Text(t == 0 ? "now" : String(format: "%+.0fs", t)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: liveX(t, size.width), y: size.height / 2))
            }
        }
        .padding(.leading, LiveDeckView.labelWidth)
    }
}

struct LiveDeckLane: View {
    let deck: LiveDeck?
    let color: Color
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Text(name).font(.system(size: 11, weight: .heavy)).foregroundStyle(.black.opacity(0.8))
                    .frame(width: 18, height: 18).background(color, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck?.song?.title ?? "—").font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(2)
                    if let analysis = deck?.analysis {
                        HStack(spacing: 5) { Text("\(analysis.bpm) BPM").font(.system(size: 10)).foregroundStyle(.secondary); KeyBadge(key: analysis.key) }
                    }
                }
            }
            .frame(width: LiveDeckView.labelWidth - 6, alignment: .leading).padding(.trailing, 6)
            Canvas { ctx, size in draw(&ctx, size) }
                .background(Theme.lane, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let width = Double(size.width), mid = size.height / 2
        let x = { (t: Double) in liveX(t, width) }
        defer { ctx.fill(Path(CGRect(x: width / 2 - 1, y: 0, width: 2, height: size.height)), with: .color(.white)) }
        guard let deck, let analysis = deck.analysis else { return }
        let clock = deck.clock
        // Transition windows.
        for side in deck.sides {
            let x0 = x(clock.time(at: side.start)), x1 = x(clock.time(at: side.end))
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(Theme.accent.opacity(0.07)))
        }
        // Waveform columns, coloured by band, height × the transition's output volume, dimmed where it isn't heard.
        let wf = analysis.waveform
        for col in stride(from: 0.0, to: width, by: 1) {
            let s = clock.songTime(at: col / width * 2 * LiveDeckView.span - LiveDeckView.span)
            let i = Int(s / wf.secondsPerPoint)
            guard s >= 0, i < wf.peak.count else { continue }
            let side = deck.sides.first { s >= $0.start && s <= $0.end }
            let gain = side?.automations["out_gain"]?.value(at: s) ?? 1
            let dim = deck.audible.contains(s) ? 1.0 : 0.25
            let h = Double(wf.peak[i]) * gain * (mid - 2)
            let c = Color(red: Double(wf.low[i]) * 1.6 + 0.15, green: Double(wf.mid[i]) * 1.3 + 0.15, blue: Double(wf.high[i]) * 1.6 + 0.2)
            ctx.fill(Path(CGRect(x: col, y: mid - h, width: 1, height: max(1, 2 * h))), with: .color(c.opacity(0.85 * dim)))
        }
        // Beat grid, bars, sections.
        let visible = clock.songTime(at: -LiveDeckView.span)...clock.songTime(at: LiveDeckView.span)
        let bars = Set(analysis.bars.map { Int(($0 * 100).rounded()) })
        for b in analysis.beats where visible.contains(b) {
            let isBar = bars.contains(Int((b * 100).rounded()))
            ctx.fill(Path(CGRect(x: x(clock.time(at: b)), y: isBar ? 0 : size.height - 8, width: isBar ? 1 : 0.5, height: isBar ? size.height : 8)),
                     with: .color(.white.opacity(isBar ? 0.22 : 0.18)))
        }
        for sec in analysis.sections where visible.contains(sec) {
            ctx.draw(Text("◆").font(.system(size: 9)).foregroundColor(Theme.accent), at: CGPoint(x: x(clock.time(at: sec)), y: 7))
        }
        for side in deck.sides {
            for s in [side.start, side.end] {
                ctx.fill(Path(CGRect(x: x(clock.time(at: s)), y: 0, width: 1, height: size.height)), with: .color(Theme.accent.opacity(0.6)))
            }
        }
    }
}

/// A deck's effect lanes, for the transitions on screen only, so they scroll in and out with them.
struct LiveLanes: View {
    let deck: LiveDeck?
    let color: Color

    private struct Lane: Identifiable {
        let id: String
        let automation: Automation
        let side: TransitionSide
    }

    private var lanes: [Lane] {
        guard let deck else { return [] }
        return deck.sides.enumerated().flatMap { n, side -> [Lane] in
            let t0 = deck.clock.time(at: side.start), t1 = deck.clock.time(at: side.end)
            guard t1 > -LiveDeckView.span, t0 < LiveDeckView.span else { return [] }
            return side.automations.values.filter { $0.moves && $0.id != "bypa" }
                .sorted { EffectLanes.order($0.id) < EffectLanes.order($1.id) }
                .map { Lane(id: "\(n).\($0.id)", automation: $0, side: side) }
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(lanes) { lane in
                HStack(spacing: 0) {
                    Text(EffectCatalog.name(lane.automation.id)).font(.system(size: 10)).foregroundStyle(color.opacity(0.9))
                        .frame(width: LiveDeckView.labelWidth - 6, alignment: .leading).padding(.trailing, 6).lineLimit(1)
                    Canvas { ctx, size in draw(lane, &ctx, size) }
                        .background(Theme.lane.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 20)
            }
        }
    }

    private func draw(_ lane: Lane, _ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let clock = deck?.clock else { return }
        let width = Double(size.width), h = Double(size.height)
        let toggle = EffectCatalog.isToggle(lane.automation.id)
        var path = Path(), fill = Path(), started = false
        let x0 = max(0, liveX(clock.time(at: lane.side.start), width)), x1 = min(width, liveX(clock.time(at: lane.side.end), width))
        for col in stride(from: x0, through: x1, by: 1) {
            let s = clock.songTime(at: col / width * 2 * LiveDeckView.span - LiveDeckView.span)
            guard let v = lane.automation.value(at: s) else { continue }
            let n = EffectCatalog.normalize(lane.automation, v)
            if toggle {
                if n > 0.5 { fill.addRect(CGRect(x: col, y: 3, width: 1, height: h - 6)) }
            } else {
                let y = h - 2 - n * (h - 4)
                if started { path.addLine(to: CGPoint(x: col, y: y)) } else { path.move(to: CGPoint(x: col, y: y)); started = true }
            }
        }
        if toggle { ctx.fill(fill, with: .color(color.opacity(0.55))) } else { ctx.stroke(path, with: .color(color), lineWidth: 1.5) }
        ctx.fill(Path(CGRect(x: width / 2 - 0.75, y: 0, width: 1.5, height: h)), with: .color(.white.opacity(0.8)))
    }
}
