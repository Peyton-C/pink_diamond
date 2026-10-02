import Foundation

/// `pink diamond --selftest <from> <to> [out.wav]`: runs stems → analysis → planning → rendering without the UI.
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            print("usage: --selftest <from> <to> [out.wav] [from-genre] [to-genre]")
            return 2
        }
        let from = URL(fileURLWithPath: args[0]), to = URL(fileURLWithPath: args[1])
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : NSTemporaryDirectory() + "pink-diamond-selftest.wav")
        let ga = args.count > 3 ? Genre(rawValue: args[3]) ?? .pop : .pop
        let gb = args.count > 4 ? Genre(rawValue: args[4]) ?? .pop : .pop
        do {
            print("planner available: \(SonicPlanner.shared.isAvailable), RemixFX available: \(MixRenderer.remixFXAvailable)")
            var analyses: [SongAnalysis] = []
            var playable: [URL] = []
            for url in [from, to] {
                let t0 = Date()
                let p = try await AudioSource.playableURL(for: url)
                let a = try await Analyzer.analyze(playable: p, id: "99" + String(fileKey(url).prefix(8)))
                print("\(url.lastPathComponent): stem=\(AudioSource.isStem(url)) playable=\(p.lastPathComponent) " +
                      "\(a.bpm) BPM, \(a.key), \(String(format: "%.1f", a.duration)) s, \(a.beats.count) beats, " +
                      "\(a.sections.count) sections, waveform \(a.waveform.peak.count) pts (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
                if let l = a.loudness {
                    print(String(format: "  loudness %.1f LUFS, peak %.2f, Sound Check %+.1f dB", l.integrated, l.peak, 20 * log10(Double(l.gain))))
                }
                analyses.append(a); playable.append(p)
            }
            let json = try SonicPlanner.shared.plan(from: try Analyzer.songJSON(analyses[0], genre: ga),
                                                    to: try Analyzer.songJSON(analyses[1], genre: gb))
            let plan = try TransitionPlan(json: json)
            print("plan: \(plan.styleName) (style \(plan.styleID ?? -1)), \(String(format: "%.2f", plan.duration)) s, " +
                  "out \(plan.outgoing.start)→\(plan.outgoing.end), in \(plan.incoming.start)→\(plan.incoming.end), " +
                  "effects: \(plan.effectSummary.joined(separator: ", "))")
            let items = [
                MixRenderer.Item(audio: playable[0], beats: analyses[0].beats, entering: nil, leaving: plan.outgoing,
                                 gain: analyses[0].loudness?.gain ?? 1),
                MixRenderer.Item(audio: playable[1], beats: analyses[1].beats, entering: plan.incoming, leaving: nil,
                                 gain: analyses[1].loudness?.gain ?? 1),
            ]
            let seconds = try MixRenderer.render(items, startTime: plan.outgoing.start - 15, tail: 15, to: out)
            print("rendered \(String(format: "%.1f", seconds)) s to \(out.path)")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
