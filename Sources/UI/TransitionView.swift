import AVFoundation
import SwiftUI

/// Maps a song's time onto the transition's timeline (seconds from the transition start) and back.
struct SideTimeline {
    let side: TransitionSide
    let isOutgoing: Bool
    let duration: Double           // transition length
    private let songTimes: [Double]
    private let times: [Double]

    init(side: TransitionSide, isOutgoing: Bool, duration: Double) {
        self.side = side; self.isOutgoing = isOutgoing; self.duration = duration
        var s = [side.start], t = [0.0]
        let step = 0.02
        var x = side.start
        while x < side.end {
            let dx = min(step, side.end - x)
            t.append(t.last! + dx / max(side.rate(at: x + dx / 2), 0.01))
            x += dx
            s.append(x)
        }
        songTimes = s; times = t
    }

    /// Song time playing at transition time `t`, or nil when this song is silent then.
    func songTime(at t: Double) -> Double? {
        if t < 0 { return side.start + t }          // before the transition (incoming: shown dimmed as a preview)
        if t > duration { return isOutgoing ? nil : side.end + (t - duration) }
        var lo = 0, hi = times.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if times[mid] <= t { lo = mid } else { hi = mid - 1 } }
        guard lo + 1 < times.count else { return songTimes.last }
        let f = (t - times[lo]) / max(times[lo + 1] - times[lo], 1e-9)
        return songTimes[lo] + f * (songTimes[lo + 1] - songTimes[lo])
    }

    /// Transition time at which song time `s` plays.
    func transitionTime(at s: Double) -> Double {
        if s < side.start { return s - side.start }
        if s > side.end { return duration + (s - side.end) }
        var lo = 0, hi = songTimes.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if songTimes[mid] <= s { lo = mid } else { hi = mid - 1 } }
        guard lo + 1 < songTimes.count else { return times.last ?? duration }
        let f = (s - songTimes[lo]) / max(songTimes[lo + 1] - songTimes[lo], 1e-9)
        return times[lo] + f * (times[lo + 1] - times[lo])
    }

    /// Whether the song is audible at `t` (the incoming song is silent before the transition).
    func audible(at t: Double) -> Bool { isOutgoing ? t <= duration : t >= 0 }
}

/// The deck view, which is also the mix editor: drag a song to move its side of the transition by bars, edit or add
/// effect automation, or pick another of the plans Apple's planner makes for the pair. Edits go to the library, so
/// playback and export use them too.
struct TransitionView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var mixPlayer: MixPlayer
    @Environment(\.undoManager) private var undo
    let ref: TransitionRef
    let plan: TransitionPlan
    @StateObject private var player = PreviewPlayer()
    @State private var dragStart: TransitionEdit?   // the edit before the drag under way, for undo
    @State private var showingStyles = false
    static let margin = 8.0

    private var from: Song? { library.song(ref.from) }
    private var to: Song? { library.song(ref.to) }
    private var edit: TransitionEdit { library.edit(from: ref.from, to: ref.to) }

    var body: some View {
        let out = SideTimeline(side: plan.outgoing, isOutgoing: true, duration: plan.duration)
        let inc = SideTimeline(side: plan.incoming, isOutgoing: false, duration: plan.duration)
        let playhead = player.playhead
        let base = basePlan
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                let range = -Self.margin...(plan.duration + Self.margin)
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        TimeRuler(range: range, duration: plan.duration, pivot: plan.pivot)
                            .frame(height: 18)
                        // Each song's effects sit on its outer side, the outgoing song's above it and the incoming
                        // song's below, so the two waveforms stay together in the middle.
                        EffectLanes(plan: plan, timeline: out, color: Theme.outgoing, range: range, playhead: playhead,
                                    pinned: pinned(base?.outgoing, edit.outgoing), presets: presets(plan.outgoing),
                                    onChange: { setLane(true, $0, $1, ended: $2) }, onAdd: { addPreset($0, outgoing: true) },
                                    onRemove: { removeLane($0, outgoing: true) }, onReset: resetLane(true, base?.outgoing))
                        DeckLane(title: from?.title ?? "outgoing", color: Theme.outgoing, timeline: out,
                                 analysis: library.analyses[ref.from], range: range, plan: plan, playhead: playhead,
                                 onDrag: { move(true, by: $0, ended: $1) })
                            .frame(height: 92)
                        DeckLane(title: to?.title ?? "incoming", color: Theme.incoming, timeline: inc,
                                 analysis: library.analyses[ref.to], range: range, plan: plan, playhead: playhead,
                                 onDrag: { move(false, by: $0, ended: $1) })
                            .frame(height: 92)
                        EffectLanes(plan: plan, timeline: inc, color: Theme.incoming, range: range, playhead: playhead,
                                    pinned: pinned(base?.incoming, edit.incoming), presets: presets(plan.incoming),
                                    onChange: { setLane(false, $0, $1, ended: $2) }, onAdd: { addPreset($0, outgoing: false) },
                                    onRemove: { removeLane($0, outgoing: false) }, onReset: resetLane(false, base?.incoming))
                    }
                    .frame(width: geo.size.width)
                }
            }
        }
        .padding(14)
        .background(Theme.panel)
        .onDisappear { player.stop() }
        .onChange(of: ref) { player.stop() }
        .onChange(of: edit) { player.stop() }   // the preview no longer matches
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(from?.title ?? "?").foregroundStyle(Theme.outgoing)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(to?.title ?? "?").foregroundStyle(Theme.incoming)
                }
                .font(.system(size: 15, weight: .bold))
                HStack(spacing: 10) {
                    StyleChip(plan: plan)
                    if edit.hasChanges { Text("edited").foregroundStyle(Theme.accent) }
                    Text(String(format: "%.1f s", plan.duration))
                    Text("out \(Theme.time(plan.outgoing.start)) → \(Theme.time(plan.outgoing.end))").foregroundStyle(Theme.outgoing)
                    Text("in \(Theme.time(plan.incoming.start)) → \(Theme.time(plan.incoming.end))").foregroundStyle(Theme.incoming)
                    let r0 = plan.outgoing.rate(at: plan.outgoing.end), r1 = plan.incoming.rate(at: plan.incoming.start)
                    if abs(r0 - 1) > 0.003 || abs(r1 - 1) > 0.003 {
                        Text(String(format: "tempo %.1f%% / %+.1f%%", (r0 - 1) * 100, (r1 - 1) * 100)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11)).monospacedDigit()
            }
            Spacer()
            Button { showingStyles = true } label: { Label("Styles", systemImage: "diamond") }
                .help("Other plans Apple's planner makes for these two songs")
                .popover(isPresented: $showingStyles, arrowEdge: .bottom) {
                    StylePicker(ref: ref, current: edit.variant) { variant in
                        showingStyles = false
                        apply(TransitionEdit(variant: variant), ended: true)
                    }
                }
            Button("Reset") { apply(TransitionEdit(), ended: true) }
                .help("Back to Apple's plan")
                .disabled(edit.isEmpty)
            Button {
                player.isPlaying ? player.stop() : preview()
            } label: {
                Label(player.isRendering ? "Rendering…" : player.isPlaying ? "Stop" : "Preview",
                      systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.isRendering)
        }
    }

    private func preview() {
        guard let a = library.playableURL(ref.from), let b = library.playableURL(ref.to),
              let aa = library.analyses[ref.from], let ab = library.analyses[ref.to] else { return }
        mixPlayer.pause()   // one thing plays at a time
        let items = [MixRenderer.Item(audio: a, beats: aa.beats, entering: nil, leaving: plan.outgoing),
                     MixRenderer.Item(audio: b, beats: ab.beats, entering: plan.incoming, leaving: nil)]
        player.renderAndPlay(items, startTime: plan.outgoing.start - Self.margin, tail: Self.margin, offset: -Self.margin)
    }

    // MARK: Editing

    private var basePlan: TransitionPlan? {
        if case .ready(let p) = library.basePlan(from: ref.from, to: ref.to, variant: edit.variant) { return p }
        return nil
    }

    /// Lanes that stay on screen even when flat: the plan's own moving ones and the effects the user added, so a lane
    /// doesn't vanish mid-drag when its points line up.
    private func pinned(_ base: TransitionSide?, _ lanes: [String: [TransitionEdit.Point]]) -> Set<String> {
        let own = (base?.automations.values.filter(\.moves).map(\.id) ?? []).filter { $0 != "bypa" }
        return Set(own).union(lanes.keys.filter { id in EffectPreset.all.contains { $0.id == id } })
    }

    private func presets(_ side: TransitionSide) -> [EffectPreset] {
        EffectPreset.all.filter { p in p.requires.allSatisfy { side.wiring[$0] != nil } && side.automations[p.id]?.moves != true }
    }

    /// Applies `new`. A drag applies every step and commits (saves, with one undo step) when it ends.
    private func apply(_ new: TransitionEdit, ended: Bool) {
        if ended {
            library.setEdit(new, from: ref.from, to: ref.to, undo: undo, previous: dragStart)
            dragStart = nil
        } else {
            if dragStart == nil { dragStart = edit }
            library.setEdit(new, from: ref.from, to: ref.to)
        }
    }

    /// Moves one side of the transition by a drag of `dt` seconds on the timeline, snapped to that song's bars (beats
    /// with ⌥), keeping whatever offset from the grid the planner chose.
    private func move(_ outgoing: Bool, by dt: Double, ended: Bool) {
        let before = dragStart ?? edit
        let side = outgoing ? plan.outgoing : plan.incoming
        let baseStart = side.start - edit.shift(outgoing)
        let length = side.end - side.start
        let analysis = library.analyses[outgoing ? ref.from : ref.to]
        let duration = analysis?.duration ?? .infinity
        let target = baseStart + before.shift(outgoing) - dt
        var start = target
        if let analysis {
            let bars = analysis.bars.isEmpty ? analysis.beats : analysis.bars
            let grid = NSEvent.modifierFlags.contains(.option) || bars.isEmpty ? analysis.beats : bars
            if let anchor = grid.min(by: { abs($0 - baseStart) < abs($1 - baseStart) }) {
                let offset = baseStart - anchor
                let valid = grid.map { $0 + offset }.filter { $0 >= 0 && $0 + length <= duration }
                start = valid.min(by: { abs($0 - target) < abs($1 - target) }) ?? baseStart
            }
        }
        start = min(max(start, 0), max(0, duration - length))
        var new = before
        new.setShift(outgoing, start - baseStart)
        apply(new, ended: ended)
    }

    private func setLane(_ outgoing: Bool, _ id: String, _ points: [TransitionEdit.Point], ended: Bool) {
        var new = dragStart ?? edit
        new.setLane(outgoing, id, points)
        apply(new, ended: ended)
    }

    private func addPreset(_ preset: EffectPreset, outgoing: Bool) {
        let side = outgoing ? plan.outgoing : plan.incoming
        let bpm = Double(library.analyses[outgoing ? ref.from : ref.to]?.bpm ?? 120)
        var new = edit
        for (id, points) in preset.lanes(length: side.end - side.start, outgoing: outgoing, bpm: bpm, side: side) {
            new.setLane(outgoing, id, points)
        }
        apply(new, ended: true)
    }

    /// Takes an effect out of the transition: one the user added disappears with its settings; one from the plan is
    /// held at its neutral value.
    private func removeLane(_ id: String, outgoing: Bool) {
        let base = outgoing ? basePlan?.outgoing : basePlan?.incoming
        let side = outgoing ? plan.outgoing : plan.incoming
        var new = edit
        for code in EffectPreset.group(of: id) {
            if code == id, base?.automations[code] != nil {
                let v = side.neutralValue(code)
                new.setLane(outgoing, code, [.init(offset: 0, value: v, curve: "linear"),
                                             .init(offset: side.end - side.start, value: v, curve: "linear")])
            } else {
                new.setLane(outgoing, code, nil)
            }
        }
        // Effects added over a plan that bypasses them switched the bypass off; switch it back once none are left.
        let lanes = new.lanes(outgoing)
        if lanes.keys.allSatisfy({ $0 == "bypa" || base?.automations[$0] != nil }) { new.setLane(outgoing, "bypa", nil) }
        apply(new, ended: true)
    }

    /// Puts one of the plan's lanes back as Apple planned it, for lanes the plan has.
    private func resetLane(_ outgoing: Bool, _ base: TransitionSide?) -> (String) -> Void {
        { id in
            guard base?.automations[id] != nil else { return }
            var new = edit
            new.setLane(outgoing, id, nil)
            apply(new, ended: true)
        }
    }
}

/// The plans Apple's planner makes for a pair as other genres or with lower complexity, to pick from.
struct StylePicker: View {
    @EnvironmentObject var library: Library
    let ref: TransitionRef
    let current: PlanVariant?
    let choose: (PlanVariant?) -> Void
    @State private var alternatives: [Library.Alternative]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Styles").font(.headline)
            if let alternatives {
                ForEach(alternatives) { alt in
                    Button { choose(alt.variant) } label: { row(alt) }.buttonStyle(.plain)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Planning…").foregroundStyle(.secondary) }
            }
            Text("Choosing a style starts over from its plan.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 400)
        .task { alternatives = await library.alternatives(from: ref.from, to: ref.to) }
    }

    private func row(_ alt: Library.Alternative) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").opacity(alt.variant == current ? 1 : 0).foregroundStyle(Theme.accent)
            StyleChip(plan: alt.plan)
            Text(String(format: "%.1f s", alt.plan.duration)).monospacedDigit()
            Text("in at \(Theme.time(alt.plan.incoming.start))").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text(label(alt.variant)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func label(_ v: PlanVariant?) -> String {
        guard let v else { return "as planned" }
        return v.complexity?.label ?? "as \(v.fromGenre.rawValue)"
    }
}

// MARK: - Lanes

private func xPosition(_ t: Double, _ range: ClosedRange<Double>, _ width: Double) -> Double {
    (t - range.lowerBound) / (range.upperBound - range.lowerBound) * width
}

struct TimeRuler: View {
    let range: ClosedRange<Double>
    let duration: Double
    let pivot: Double
    var body: some View {
        Canvas { ctx, size in
            let x = { (t: Double) in xPosition(t, range, size.width) }
            ctx.fill(Path(CGRect(x: x(0), y: 0, width: x(duration) - x(0), height: size.height)), with: .color(Theme.accent.opacity(0.18)))
            var t = (range.lowerBound / 2).rounded(.up) * 2
            while t <= range.upperBound {
                ctx.draw(Text(String(format: "%+.0fs", t)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: x(t), y: size.height / 2))
                t += 2
            }
            ctx.draw(Text("◆").font(.system(size: 10)).foregroundColor(Theme.accent), at: CGPoint(x: x(pivot), y: size.height / 2))
        }
        .padding(.leading, 110)
    }
}

struct DeckLane: View {
    let title: String
    let color: Color
    let timeline: SideTimeline
    let analysis: SongAnalysis?
    let range: ClosedRange<Double>
    let plan: TransitionPlan
    let playhead: Double?
    var onDrag: ((Double, Bool) -> Void)?   // seconds dragged on the timeline, and whether the drag ended

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(2)
                if let analysis {
                    HStack(spacing: 5) { Text("\(analysis.bpm) BPM").font(.system(size: 10)).foregroundStyle(.secondary); KeyBadge(key: analysis.key) }
                }
            }
            .frame(width: 104, alignment: .leading).padding(.trailing, 6)
            GeometryReader { geo in
                let seconds = { (dx: Double) in dx / geo.size.width * (range.upperBound - range.lowerBound) }
                Canvas { ctx, size in draw(&ctx, size) }
                    .background(Theme.lane, in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .pointerStyle(onDrag == nil ? .default : .grabIdle)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { onDrag?(seconds($0.translation.width), false) }
                        .onEnded { onDrag?(seconds($0.translation.width), true) })
                    .help("Drag to move this song's side of the transition by bars, ⌥ for beats")
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let width = Double(size.width), mid = size.height / 2
        let x = { (t: Double) in xPosition(t, range, width) }
        // Transition window.
        ctx.fill(Path(CGRect(x: x(0), y: 0, width: x(plan.duration) - x(0), height: size.height)), with: .color(Theme.accent.opacity(0.06)))
        guard let analysis else { return }
        let wf = analysis.waveform
        let spp = wf.secondsPerPoint
        let volume = timeline.side.automations["out_gain"]
        // Waveform columns, colored by band (low red, mid green, high blue), height × output volume.
        for col in stride(from: 0.0, to: width, by: 1) {
            let t = range.lowerBound + col / width * (range.upperBound - range.lowerBound)
            guard let s = timeline.songTime(at: t), s >= 0 else { continue }
            let i = Int(s / spp)
            guard i >= 0, i < wf.peak.count else { continue }
            var gain = 1.0
            if t >= 0, t <= plan.duration, let v = volume?.value(at: s) { gain = v }
            let dim = timeline.audible(at: t) ? 1.0 : 0.25
            let h = Double(wf.peak[i]) * gain * (mid - 2)
            let c = Color(red: Double(wf.low[i]) * 1.6 + 0.15, green: Double(wf.mid[i]) * 1.3 + 0.15, blue: Double(wf.high[i]) * 1.6 + 0.2)
            ctx.fill(Path(CGRect(x: col, y: mid - h, width: 1, height: max(1, 2 * h))), with: .color(c.opacity(0.85 * dim)))
        }
        // Beat grid, bars, sections.
        let bars = Set(analysis.bars.map { Int(($0 * 100).rounded()) })
        for b in analysis.beats {
            let t = timeline.transitionTime(at: b)
            guard range.contains(t) else { continue }
            let isBar = bars.contains(Int((b * 100).rounded()))
            ctx.fill(Path(CGRect(x: x(t), y: isBar ? 0 : size.height - 8, width: isBar ? 1 : 0.5, height: isBar ? size.height : 8)),
                     with: .color(.white.opacity(isBar ? 0.22 : 0.18)))
        }
        for sec in analysis.sections {
            let t = timeline.transitionTime(at: sec)
            guard range.contains(t) else { continue }
            ctx.draw(Text("◆").font(.system(size: 9)).foregroundColor(Theme.accent), at: CGPoint(x: x(t), y: 7))
        }
        // Transition edges and pivot.
        for (t, o) in [(0.0, 0.6), (plan.duration, 0.6), (plan.pivot, 0.35)] {
            ctx.fill(Path(CGRect(x: x(t), y: 0, width: 1, height: size.height)), with: .color(Theme.accent.opacity(o)))
        }
        if let playhead, range.contains(playhead) {
            ctx.fill(Path(CGRect(x: x(playhead), y: 0, width: 2, height: size.height)), with: .color(.white))
        }
    }
}

/// One song's automation lanes. Points can be dragged, double-clicking adds a point (or removes the one under the
/// pointer), and each lane's menu sets its curve or removes it. The tempo lane is shown but not editable: it sets the
/// beat match and the transition's length.
struct EffectLanes: View {
    let plan: TransitionPlan
    let timeline: SideTimeline
    let color: Color
    let range: ClosedRange<Double>
    let playhead: Double?
    var pinned: Set<String> = []
    var presets: [EffectPreset] = []
    var onChange: ((String, [TransitionEdit.Point], Bool) -> Void)?
    var onAdd: ((EffectPreset) -> Void)?
    var onRemove: ((String) -> Void)?
    var onReset: ((String) -> Void)?
    @State private var dragging: (lane: String, index: Int)?
    private static let height = 30.0
    private static let handle = 3.5

    private var side: TransitionSide { timeline.side }

    private var lanes: [Automation] {
        side.automations.values.filter { ($0.moves || pinned.contains($0.id)) && $0.id != "bypa" }
            .sorted { Self.order($0.id) < Self.order($1.id) }
    }

    static func order(_ id: String) -> String {
        let rank = ["ts_rate": "0", "out_gain": "1"][id] ?? (EffectCatalog.family(of: id) == "filters" ? "2" : "3")
        return rank + id
    }

    var body: some View {
        VStack(spacing: 3) {
            if timeline.isOutgoing { addMenu }
            ForEach(lanes, id: \.id) { lane in
                HStack(spacing: 0) {
                    Menu {
                        laneMenu(lane)
                    } label: {
                        Text(EffectCatalog.name(lane.id)).font(.system(size: 10)).foregroundStyle(color.opacity(0.9)).lineLimit(1)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .frame(width: 104, alignment: .leading).padding(.trailing, 6)
                    .disabled(lane.id == "ts_rate" || onChange == nil)
                    GeometryReader { geo in
                        Canvas { ctx, size in draw(lane, &ctx, size) }
                            .background(Theme.lane.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .gesture(dragGesture(lane, geo.size), including: lane.id == "ts_rate" ? .none : .all)
                            .onTapGesture(count: 2, coordinateSpace: .local) { doubleClick(lane, at: $0, geo.size) }
                    }
                }
                .frame(height: Self.height)
            }
            if !timeline.isOutgoing { addMenu }
        }
    }

    @ViewBuilder private var addMenu: some View {
        if let onAdd, !presets.isEmpty {
            HStack(spacing: 0) {
                Menu {
                    ForEach(presets) { p in Button(p.name) { onAdd(p) } }
                } label: {
                    Label("Add effect", systemImage: "plus").font(.system(size: 10)).foregroundStyle(color.opacity(0.8))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer()
            }
            .frame(height: 16)
        }
    }

    @ViewBuilder private func laneMenu(_ lane: Automation) -> some View {
        if !EffectCatalog.isStepped(lane.id) {
            ForEach([("Linear", "linear"), ("Ease In", "easedIn"), ("Ease Out", "easedOut")], id: \.1) { name, curve in
                Button(name) { onChange?(lane.id, points(lane).map { .init(offset: $0.offset, value: $0.value, curve: curve) }, true) }
            }
            Divider()
        }
        Button("Reset to Plan") { onReset?(lane.id) }
        if lane.id != "out_gain" { Button("Remove", role: .destructive) { onRemove?(lane.id) } }
    }

    private func points(_ lane: Automation) -> [TransitionEdit.Point] { side.editPoints(lane.id) }

    private func location(_ p: Automation.Point, _ lane: Automation, _ size: CGSize) -> CGPoint {
        let h = Double(size.height)
        return CGPoint(x: xPosition(timeline.transitionTime(at: p.time), range, size.width),
                       y: h - 2 - EffectCatalog.normalize(lane, p.value) * (h - 4))
    }

    private func hit(_ lane: Automation, _ at: CGPoint, _ size: CGSize) -> Int? {
        let near = lane.points.indices.map { ($0, hypot(location(lane.points[$0], lane, size).x - at.x, location(lane.points[$0], lane, size).y - at.y)) }
            .filter { $0.1 < 8 }
        return near.min { $0.1 < $1.1 }?.0
    }

    /// A position in the lane as an edit point: song time from the side's start, and value.
    private func point(at loc: CGPoint, _ lane: Automation, _ size: CGSize) -> (offset: Double, value: Double) {
        let t = min(max(range.lowerBound + loc.x / size.width * (range.upperBound - range.lowerBound), 0), plan.duration)
        let s = timeline.songTime(at: t) ?? side.end
        let h = Double(size.height)
        return (min(max(s, side.start), side.end) - side.start, EffectCatalog.denormalize(lane, (h - 2 - loc.y) / (h - 4)))
    }

    private func dragGesture(_ lane: Automation, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                guard let onChange else { return }
                if dragging == nil {
                    guard let i = hit(lane, g.startLocation, size) else { return }
                    dragging = (lane.id, i)
                }
                guard let d = dragging, d.lane == lane.id else { return }
                var pts = points(lane)
                let p = point(at: g.location, lane, size)
                let lo = d.index > 0 ? pts[d.index - 1].offset : 0
                let hi = d.index + 1 < pts.count ? pts[d.index + 1].offset : side.end - side.start
                pts[d.index].offset = min(max(p.offset, lo), hi)
                pts[d.index].value = p.value
                onChange(lane.id, pts, false)
            }
            .onEnded { _ in
                if let d = dragging, d.lane == lane.id { onChange?(lane.id, points(lane), true) }
                dragging = nil
            }
    }

    private func doubleClick(_ lane: Automation, at loc: CGPoint, _ size: CGSize) {
        guard let onChange, lane.id != "ts_rate" else { return }
        var pts = points(lane)
        if let i = hit(lane, loc, size) {
            guard pts.count > 2 else { return }
            pts.remove(at: i)
        } else {
            let p = point(at: loc, lane, size)
            let i = pts.firstIndex { $0.offset > p.offset } ?? pts.count
            let curve = i > 0 ? pts[i - 1].curve : pts.first?.curve ?? "linear"
            pts.insert(.init(offset: p.offset, value: p.value, curve: curve), at: i)
        }
        onChange(lane.id, pts, true)
    }

    private func draw(_ lane: Automation, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let width = Double(size.width), h = Double(size.height)
        let x = { (t: Double) in xPosition(t, range, width) }
        ctx.fill(Path(CGRect(x: x(0), y: 0, width: x(plan.duration) - x(0), height: h)), with: .color(Theme.accent.opacity(0.05)))
        let isToggle = EffectCatalog.isToggle(lane.id)
        var path = Path()
        var fill = Path()
        var started = false
        for col in stride(from: max(0, x(0)), through: min(width, x(plan.duration)), by: 1) {
            let t = range.lowerBound + col / width * (range.upperBound - range.lowerBound)
            guard let s = timeline.songTime(at: t), let v = lane.value(at: s) else { continue }
            let n = EffectCatalog.normalize(lane, v)
            if isToggle {
                if n > 0.5 { fill.addRect(CGRect(x: col, y: 3, width: 1, height: h - 6)) }
            } else {
                let y = h - 2 - n * (h - 4)
                if started { path.addLine(to: CGPoint(x: col, y: y)) } else { path.move(to: CGPoint(x: col, y: y)); started = true }
            }
        }
        if isToggle {
            ctx.fill(fill, with: .color(color.opacity(0.55)))
        } else {
            ctx.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        if onChange != nil, lane.id != "ts_rate" {
            let r = Self.handle
            for p in lane.points {
                let c = location(p, lane, size)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.9)))
            }
        }
        if let playhead, range.contains(playhead) {
            ctx.fill(Path(CGRect(x: x(playhead), y: 0, width: 1.5, height: h)), with: .color(.white.opacity(0.8)))
        }
    }
}

// MARK: - Preview playback

@MainActor
final class PreviewPlayer: ObservableObject {
    @Published var isRendering = false
    @Published var isPlaying = false
    @Published var playhead: Double?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var offset = 0.0

    func renderAndPlay(_ items: [MixRenderer.Item], startTime: Double, tail: Double, offset: Double) {
        stop()
        isRendering = true
        self.offset = offset
        let url = AppPaths.cacheDir("previews").appendingPathComponent(UUID().uuidString + ".wav")
        Task.detached {
            do {
                _ = try MixRenderer.render(items, startTime: startTime, tail: tail, to: url)
                await MainActor.run { self.play(url) }
            } catch {
                await MainActor.run { self.isRendering = false }
            }
        }
    }

    private func play(_ url: URL) {
        isRendering = false
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                if p.isPlaying { self.playhead = p.currentTime + self.offset } else { self.stop() }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        playhead = nil
    }
}
