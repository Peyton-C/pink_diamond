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

struct TransitionView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var mixPlayer: MixPlayer
    let ref: TransitionRef
    let plan: TransitionPlan
    @StateObject private var player = PreviewPlayer()
    static let margin = 8.0

    private var from: Song? { library.song(ref.from) }
    private var to: Song? { library.song(ref.to) }

    var body: some View {
        let out = SideTimeline(side: plan.outgoing, isOutgoing: true, duration: plan.duration)
        let inc = SideTimeline(side: plan.incoming, isOutgoing: false, duration: plan.duration)
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                let range = -Self.margin...(plan.duration + Self.margin)
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        TimeRuler(range: range, duration: plan.duration, pivot: plan.pivot)
                            .frame(height: 18)
                        DeckLane(title: from?.title ?? "outgoing", color: Theme.outgoing, timeline: out,
                                 analysis: library.analyses[ref.from], range: range, plan: plan, playhead: player.playhead)
                            .frame(height: 92)
                        DeckLane(title: to?.title ?? "incoming", color: Theme.incoming, timeline: inc,
                                 analysis: library.analyses[ref.to], range: range, plan: plan, playhead: player.playhead)
                            .frame(height: 92)
                        EffectLanes(plan: plan, out: out, inc: inc, range: range, playhead: player.playhead)
                    }
                    .frame(width: geo.size.width)
                }
            }
        }
        .padding(14)
        .background(Theme.panel)
        .onDisappear { player.stop() }
        .onChange(of: ref) { player.stop() }
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

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(2)
                if let analysis { Text("\(analysis.bpm) BPM · \(analysis.key)").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .frame(width: 104, alignment: .leading).padding(.trailing, 6)
            Canvas { ctx, size in draw(&ctx, size) }
                .background(Theme.lane, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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

struct EffectLanes: View {
    let plan: TransitionPlan
    let out: SideTimeline
    let inc: SideTimeline
    let range: ClosedRange<Double>
    let playhead: Double?

    private struct Lane: Identifiable {
        let id: String
        let name: String
        let automation: Automation
        let timeline: SideTimeline
        let color: Color
    }

    private var lanes: [Lane] {
        var result: [Lane] = []
        for (timeline, color, tag) in [(out, Theme.outgoing, "out"), (inc, Theme.incoming, "in")] {
            let autos = timeline.side.automations.values.filter { $0.moves && $0.id != "bypa" }
            for a in autos.sorted(by: { order($0.id) < order($1.id) }) {
                result.append(Lane(id: "\(tag).\(a.id)", name: EffectCatalog.name(a.id), automation: a, timeline: timeline, color: color))
            }
        }
        return result
    }

    private func order(_ id: String) -> String {
        let rank = ["ts_rate": "0", "out_gain": "1"][id] ?? (EffectCatalog.family(of: id) == "filters" ? "2" : "3")
        return rank + id
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(lanes) { lane in
                HStack(spacing: 0) {
                    Text(lane.name).font(.system(size: 10)).foregroundStyle(lane.color.opacity(0.9))
                        .frame(width: 104, alignment: .leading).padding(.trailing, 6).lineLimit(1)
                    Canvas { ctx, size in draw(lane, &ctx, size) }
                        .background(Theme.lane.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 20)
            }
        }
    }

    private func normalize(_ a: Automation, _ v: Double) -> Double {
        let id = a.id
        if id.hasSuffix("f") && (id.hasPrefix("RX") || id.hasPrefix("HP") || id.hasPrefix("LP")) || id == "Fcf1" {
            return (log10(max(v, 20)) - log10(20)) / (log10(20000) - log10(20))   // cutoff: log scale
        }
        if id == "ts_rate" { return min(max((v - 0.75) / 0.5, 0), 1) }        // 0.75×…1.25×
        let values = a.points.map(\.value)
        let lo = min(values.min() ?? 0, a.range?.lowerBound ?? 0), hi = max(values.max() ?? 1, 1)
        return hi > lo ? (v - lo) / (hi - lo) : 0
    }

    private func draw(_ lane: Lane, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let width = Double(size.width), h = Double(size.height)
        let x = { (t: Double) in xPosition(t, range, width) }
        ctx.fill(Path(CGRect(x: x(0), y: 0, width: x(plan.duration) - x(0), height: h)), with: .color(Theme.accent.opacity(0.05)))
        let isToggle = lane.id.hasSuffix("e") && lane.automation.id.hasPrefix("RX") || lane.automation.id == "RXte"
        var path = Path()
        var fill = Path()
        var started = false
        for col in stride(from: max(0, x(0)), through: min(width, x(plan.duration)), by: 1) {
            let t = range.lowerBound + col / width * (range.upperBound - range.lowerBound)
            guard let s = lane.timeline.songTime(at: t), let v = lane.automation.value(at: s) else { continue }
            let n = normalize(lane.automation, v)
            if isToggle {
                if n > 0.5 { fill.addRect(CGRect(x: col, y: 3, width: 1, height: h - 6)) }
            } else {
                let y = h - 2 - n * (h - 4)
                if started { path.addLine(to: CGPoint(x: col, y: y)) } else { path.move(to: CGPoint(x: col, y: y)); started = true }
            }
        }
        if isToggle {
            ctx.fill(fill, with: .color(lane.color.opacity(0.55)))
        } else {
            ctx.stroke(path, with: .color(lane.color), lineWidth: 1.5)
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
