import AVFoundation
import Foundation
import MusicUnderstanding

/// Everything pink diamond knows about a song's audio, derived from MusicUnderstanding and shaped like Apple Music's
/// AutoMix analysis (`audio-analysis` + `flexml-analysis`), which is what the TransitionPlanner consumes.
struct SongAnalysis: Codable {
    var duration: Double
    var bpm: Int
    var key: String                  // e.g. "Ab minor"
    var beats: [Double]
    var bars: [Double]
    var sections: [Double]
    var vocals: [ClosedRange<Double>]
    var audioAnalysisJSON: Data      // Apple `audio-analysis` resource
    var flexAnalysisJSON: Data       // Apple `flexml-analysis` resource
    var waveform: Waveform
    var loudness: Loudness?          // nil in analyses cached before Sound Check; `Loudness(audioAnalysis:)` recovers it

    var summary: SongSummary { SongSummary(bpm: bpm, key: key, duration: duration) }
}

/// What the library lists about a song. Kept apart from SongAnalysis, which runs to hundreds of KB (the waveform),
/// so the library can show every song without reading every analysis.
struct SongSummary: Codable, Equatable {
    var bpm: Int
    var key: String
    var duration: Double
}

/// A song's level, which Sound Check turns into one gain for the whole song.
struct Loudness: Codable {
    var integrated: Double           // LUFS
    var peak: Double                 // linear, 1 = full scale

    /// Apple's Sound Check reference level.
    static let target = -16.0

    /// The gain that plays the song at the target loudness. A boost stops where the song's peak would reach full
    /// scale, as ReplayGain's clipping prevention does: quiet, dynamic recordings stay a little under the target
    /// rather than being pushed into the renderer's limiter for the whole song.
    var gain: Float {
        guard integrated.isFinite, integrated > -70 else { return 1 }   // silence, or loudness the analysis couldn't measure
        let wanted = pow(10, (Loudness.target - integrated) / 20)
        return Float(peak > 0 ? min(wanted, 1 / peak) : wanted)
    }
}

extension Loudness {
    /// The level stored in an Apple `audio-analysis` resource, for analyses cached without their own.
    init?(audioAnalysis json: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let main = ((root["attributes"] as? [String: Any])?["loudness"] as? [String: Any])?["main"] as? [String: Double],
              let value = main["value"], let peak = main["peak"] else { return nil }
        self.init(integrated: value, peak: peak)
    }
}

enum Genre: String, CaseIterable, Codable, Identifiable {
    case pop = "Pop", dance = "Dance", hipHop = "Hip-Hop/Rap", rnb = "R&B/Soul", electronic = "Electronic"
    case alternative = "Alternative", rock = "Rock", country = "Country", latin = "Latin", kpop = "K-Pop"
    case reggae = "Reggae", singerSongwriter = "Singer/Songwriter"
    var id: String { rawValue }
    /// Apple Music genre IDs (children of 34 "Music").
    var catalogID: String {
        switch self {
        case .pop: "14"; case .dance: "17"; case .hipHop: "18"; case .rnb: "15"; case .electronic: "7"
        case .alternative: "20"; case .rock: "21"; case .country: "6"; case .latin: "12"; case .kpop: "51"
        case .reggae: "24"; case .singerSongwriter: "10"
        }
    }

    /// The genre a file's genre tag names, or nil if it names none of these. Case, spaces and punctuation are ignored,
    /// so "Hip-Hop/Rap", "hip hop" and "HipHop" all match. A tag listing several genres ("Dance; Pop") goes by its first.
    init?(tag: String) {
        func normalized(_ s: Substring) -> String { String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
        let whole = normalized(tag[...]), first = normalized(tag.prefix { $0 != ";" && $0 != "," })
        guard let genre = Self.tagNames[whole] ?? Self.tagNames[first] else { return nil }
        self = genre
    }

    /// Normalized tag → genre: Apple's own names, then the common spellings that aren't Apple's.
    private static let tagNames: [String: Genre] = {
        var names: [String: Genre] = [
            "hiphop": .hipHop, "rap": .hipHop, "rnb": .rnb, "rb": .rnb, "soul": .rnb, "edm": .dance, "house": .dance,
            "electronica": .electronic, "indie": .alternative, "alternativerock": .alternative, "indierock": .alternative,
            "korean": .kpop, "latino": .latin, "folk": .singerSongwriter,
        ]
        for genre in allCases {
            names[String(genre.rawValue.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))] = genre
        }
        return names
    }()
}

enum Analyzer {
    /// MusicUnderstanding tonic names → Apple Music's spelling.
    private static let tonics = ["c": "C", "cSharp": "C#", "dFlat": "C#", "d": "D", "dSharp": "Eb", "eFlat": "Eb", "e": "E",
                                 "f": "F", "fSharp": "F#", "gFlat": "F#", "g": "G", "gSharp": "Ab", "aFlat": "Ab", "a": "A",
                                 "aSharp": "Bb", "bFlat": "Bb", "b": "B"]

    static func analyze(playable url: URL, id: String) async throws -> SongAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let session = try await MusicUnderstandingSession(asset: asset)
        let r = try await session.analyze()
        let pcm = try AudioSource.loadPCM(url)
        return build(result: r, duration: duration, id: id, waveform: Waveform.compute(pcm))
    }

    private static func build(result r: MusicUnderstandingSession.SessionResult, duration: Double, id: String,
                              waveform: Waveform) -> SongAnalysis {
        let beats = (r.rhythm?.beats ?? []).map(\.seconds)
        let bars = (r.rhythm?.bars ?? []).map(\.seconds)
        let ms = { (t: Double) in Int((t * 1000).rounded()) }
        let section = 30.0
        func sectioned<T>(_ f: (Double, Double) -> T) -> [String: T] {
            ["beginning": f(0, min(section, duration)), "main": f(0, duration), "ending": f(max(0, duration - section), duration)]
        }

        // Tempo per section from the median beat interval.
        func bpm(_ lo: Double, _ hi: Double) -> Int {
            let b = beats.filter { $0 >= lo && $0 <= hi }
            let use = b.count > 3 ? b : beats
            guard use.count > 3 else { return Int((r.rhythm?.beatsPerMinute ?? 120).rounded()) }
            let d = zip(use.dropFirst(), use).map { $0 - $1 }.sorted()
            return Int((60 / d[d.count / 2]).rounded())
        }

        // Key: the one covering most of each section.
        let keyRanges = r.key?.ranges ?? []
        func key(_ lo: Double, _ hi: Double) -> [String: String] {
            var weight: [String: Double] = [:]
            for kr in keyRanges {
                let s = kr.range.start.seconds, e = s + kr.range.duration.seconds
                let overlap = max(0, min(e, hi) - max(s, lo))
                weight["\(tonics[kr.value.tonic.rawValue] ?? kr.value.tonic.rawValue)|\(kr.value.mode.rawValue)", default: 0] += overlap
            }
            let best = weight.max { $0.value < $1.value }?.key.split(separator: "|").map(String.init) ?? ["C", "major"]
            return ["tonic": best[0], "mode": best[1]]
        }

        // Loudness: Apple's main value is integrated loudness; curve ~2 points/s from short-term loudness.
        let floor = { (v: Float) -> Double in v.isFinite ? Double(v) : -70 }
        let short = (r.loudness?.shortTerm ?? []).map { ($0.time.seconds, floor($0.value)) }
        let integrated = floor(r.loudness?.integrated.value ?? -14)
        let peakLinear = pow(10, floor(r.loudness?.peak.value ?? 0) / 20)
        func interp(_ t: Double) -> Double {
            guard let first = short.first else { return -60 }
            if t <= first.0 { return first.1 }
            if let i = short.firstIndex(where: { $0.0 >= t }), i > 0 {
                let (t0, v0) = short[i - 1], (t1, v1) = short[i]
                return v0 + (v1 - v0) * (t - t0) / max(t1 - t0, 1e-9)
            }
            return short.last!.1
        }
        let curve = stride(from: 0.5, to: duration, by: 0.5).map { (interp($0) * 10).rounded() / 10 }
        func sectionLoudness(_ lo: Double, _ hi: Double) -> [String: Double] {
            let v = short.filter { $0.0 >= lo && $0.0 <= hi && $0.1 > -70 }.map(\.1).sorted()
            guard !v.isEmpty else { return ["value": -60, "range": 0, "peak": peakLinear] }
            let pct = { (p: Double) in v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
            return ["value": v.reduce(0, +) / Double(v.count), "range": pct(0.95) - pct(0.10), "peak": peakLinear]
        }
        var loudness = sectioned(sectionLoudness)
        loudness["main"]?["value"] = integrated

        // Fades from where short-term loudness is within 20 dB of integrated.
        let audible = short.filter { $0.1 > integrated - 20 }.map(\.0)
        let fadeInEnd = min(audible.first ?? 0, 10)
        let fadeOutStart = max(audible.last ?? duration, duration - 15)

        // Vocal activity ranges with a strength from the mean activity.
        let vocalActivity = r.instrumentActivity?.activity[.vocal] ?? []
        let vocalRanges = (r.instrumentActivity?.ranges[.vocal] ?? []).map { ($0.start.seconds, $0.start.seconds + $0.duration.seconds) }
        let strength = { (v: Float) -> String in v < 0.2 ? "very-low" : v < 0.4 ? "low" : v < 0.6 ? "medium" : v < 0.8 ? "high" : "very-high" }
        let vocals: [[String: Any]] = vocalRanges.map { s, e in
            let vs = vocalActivity.filter { $0.time.seconds >= s && $0.time.seconds <= e }.map(\.value)
            let mean = vs.isEmpty ? 0.5 : vs.reduce(0, +) / Float(vs.count)
            return ["startInMilliseconds": ms(s), "endInMilliseconds": ms(e), "strength": strength(mean)]
        }

        // Video cues: song structure, which the planner uses for in/out points and genre styles.
        // Section start 899, segment 850, phrase 699, other bars 499/400, beats 200.
        var scores = [Int](repeating: 200, count: beats.count)
        let barIndex = Dictionary(bars.enumerated().map { (ms($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (i, b) in beats.enumerated() { if let k = barIndex[ms(b)] { scores[i] = k % 2 == 0 ? 499 : 400 } }
        func mark(_ times: [Double], _ score: Int) {
            for x in times {
                guard let i = beats.indices.min(by: { abs(beats[$0] - x) < abs(beats[$1] - x) }), abs(beats[i] - x) < 0.25 else { continue }
                scores[i] = max(scores[i], score)
            }
        }
        let structure = r.structure
        mark((structure?.phrases ?? []).map(\.start.seconds), 699)
        mark((structure?.segments ?? []).map(\.start.seconds), 850)
        mark((structure?.sections ?? []).map(\.start.seconds), 899)
        if structure == nil { for (i, b) in beats.enumerated() where (barIndex[ms(b)] ?? 1) % 4 == 0 { scores[i] = 899 } }

        let energy = min(max((integrated + 25) / 18, 0), 1)
        let scalar = { (v: Double) in ["beginning": v, "main": v, "ending": v] }
        var bpmSections: [String: Any] = sectioned(bpm)
        bpmSections["percentDeviation"] = 0
        let audio: [String: Any] = [
            "id": id, "type": "audio-analysis",
            "attributes": [
                "bpm": bpmSections,
                "beats": ["beatsInMilliseconds": beats.map(ms), "barsInMilliseconds": bars.map(ms)],
                "key": sectioned(key),
                "loudness": loudness,
                "loudnessCurve": ["value": curve],
                "fades": ["fadeIn": ["startInMilliseconds": 0, "endInMilliseconds": ms(fadeInEnd)],
                          "fadeOut": ["startInMilliseconds": ms(fadeOutStart), "endInMilliseconds": ms(duration)]],
                "energy": scalar((energy * 1000).rounded() / 1000), "danceability": scalar(0.7), "valence": scalar(0.5),
                "acousticness": scalar(0.2), "melodicness": scalar(0.4),
                "vocalActivity": vocals, "phrases": [Any](),
            ] as [String: Any],
        ]
        let flex: [String: Any] = [
            "id": id, "type": "flexml-analysis",
            "attributes": [
                "entryPoints": [["timeInSeconds": 0, "gainTimeInSeconds": [0, 0.01], "gainValue": [0, 1], "tags": [String]()]],
                "exitPoints": [["timeInSeconds": duration, "fadeToBlack": fadeOutStart, "gainTimeInSeconds": [0, 0.01],
                                "gainValue": [1, 0], "tags": [String]()]],
                "videoEvents": ["timeInSeconds": beats.map { ($0 * 100).rounded() / 100 }, "score": scores],
                "visualTempo": ["value": [Double(r.rhythm?.beatsPerMinute ?? 120) / 4], "samplingFrequency": -1],
                "valence": ["value": [0.5]], "arousal": ["value": [energy]],
            ] as [String: Any],
        ]
        let keyMain = key(0, duration)
        return SongAnalysis(
            duration: duration, bpm: bpm(0, duration), key: "\(keyMain["tonic"]!) \(keyMain["mode"]!)",
            beats: beats, bars: bars, sections: (structure?.sections ?? []).map(\.start.seconds),
            vocals: vocalRanges.map { $0.0...max($0.0, $0.1) },
            audioAnalysisJSON: (try? JSONSerialization.data(withJSONObject: audio)) ?? Data(),
            flexAnalysisJSON: (try? JSONSerialization.data(withJSONObject: flex)) ?? Data(),
            waveform: waveform,
            loudness: r.loudness == nil ? nil : Loudness(integrated: integrated, peak: peakLinear))
    }

    /// A TransitionPlanner.Song JSON for this analysis with the given genre.
    static func songJSON(_ a: SongAnalysis, genre: Genre) throws -> Data {
        let audio = try JSONSerialization.jsonObject(with: a.audioAnalysisJSON)
        let flex = try JSONSerialization.jsonObject(with: a.flexAnalysisJSON)
        let meta = { (id: String) -> [String: Any] in
            ["musicKit_identifierSet": ["catalogID": ["kind": "adamID", "value": id], "dataSources": ["catalog"], "id": id,
                                        "isLibrary": false, "type": "Genre"]]
        }
        let genres: [[String: Any]] = [
            ["id": genre.catalogID, "type": "genres", "meta": meta(genre.catalogID),
             "attributes": ["name": genre.rawValue, "parentId": "34", "parentName": "Music",
                            "url": "https://itunes.apple.com/ca/genre/id\(genre.catalogID)"]],
            ["id": "34", "type": "genres", "meta": meta("34"),
             "attributes": ["name": "Music", "url": "https://itunes.apple.com/ca/genre/id34"]],
        ]
        let id = ((audio as? [String: Any])?["id"] as? String) ?? "0"
        let song: [String: Any] = [
            "id": id, "duration": a.duration,
            "analysis": ["musicKit": ["_0": ["genres": genres, "duration": a.duration, "audioAnalysis": audio, "flexAnalysis": flex]]],
        ]
        return try JSONSerialization.data(withJSONObject: song)
    }
}
