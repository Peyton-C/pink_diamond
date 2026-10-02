import AVFoundation
import Foundation

/// `pink diamond --mcp`: a Model Context Protocol server on stdin/stdout, so an agent can analyze songs, read and edit
/// the planned transitions and render them. It runs the same Core stages as the app but keeps its own songs and edits
/// in memory instead of going through `Library`: `Library` is main-actor bound and saves to the app's library and
/// edits files, which a server running beside the app would overwrite. Only the analysis cache is shared, since it is
/// keyed by file and the same for both.
///
/// The protocol is written out by hand (newline-delimited JSON-RPC, three methods) because `bundle.sh` compiles the
/// sources directly and has no way to pull in the MCP SDK.
final class MCPServer {
    private struct Entry {
        let id: String
        let path: String
        var title: String
        var artist: String
        var genre: Genre = .pop
        let playable: URL
        let analysis: SongAnalysis
    }

    private var songs: [Entry] = []
    private var basePlans: [String: TransitionPlan] = [:]   // Apple's plans, by plan key and variant
    private var edits: [String: TransitionEdit] = [:]       // by plan key
    private let output: FileHandle

    /// Frameworks under the planner and renderer may print, and anything on stdout that isn't a response breaks the
    /// client's parser, so responses go to a copy of stdout and descriptor 1 is pointed at stderr.
    init() {
        output = FileHandle(fileDescriptor: dup(STDOUT_FILENO))
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func run() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let response = await handle(line), let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
            output.write(data + Data("\n".utf8))
        }
        return 0
    }

    // MARK: Protocol

    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The response to one message, or nil for a notification.
    private func handle(_ line: String) async -> [String: Any]? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]
        }
        guard let id = message["id"], !(id is NSNull), let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "pink diamond", "version": "1.0.0"]]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            do {
                let value = try await call(name, params["arguments"] as? [String: Any] ?? [:])
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                result = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": String(describing: error)]], "isError": true]
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    // MARK: Tools

    private static let curves = ["linear", "easedIn", "easedOut", "easedInOut"]

    private static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
        let string = { (d: String) -> [String: Any] in ["type": "string", "description": d] }
        let number = { (d: String) -> [String: Any] in ["type": "number", "description": d] }
        let integer = { (d: String) -> [String: Any] in ["type": "integer", "description": d] }
        let genre: [String: Any] = ["type": "string", "enum": Genre.allCases.map(\.rawValue)]
        let from = string("Song id of the outgoing song"), to = string("Song id of the incoming song")
        let out = string("Where to write the WAV. Defaults to a file in pink diamond's cache")
        let variant: [String: Any] = [
            "type": ["object", "null"],
            "description": "Plan as if the songs had these genres, or under a lower complexity ceiling. Use an entry from list_variants. null goes back to Apple's own plan",
            "properties": ["from_genre": genre, "to_genre": genre,
                           "complexity": ["type": "string", "enum": PlanVariant.Complexity.allCases.map(\.rawValue)] as [String: Any]],
        ]
        let lanes = { (side: String) -> [String: Any] in
            ["type": "object",
             "description": "Automation lanes to replace or add on the \(side) song, by parameter code. Each is a list of points. Place a point with `at`, seconds since the transition started on the mix clock, which is the same for both songs, or with `offset`, song seconds from the start of that song's side. null puts a lane back as planned. Set these in the same call as length_bars or after it, since changing the length stretches them",
             "additionalProperties": [
                "type": ["array", "null"],
                "items": ["type": "object",
                          "properties": ["at": ["type": "number"], "offset": ["type": "number"], "value": ["type": "number"],
                                         "curve": ["type": "string", "enum": curves] as [String: Any]],
                          "required": ["value"]] as [String: Any],
             ] as [String: Any]]
        }
        let effects: [String: Any] = [
            "type": "array",
            "description": "Effects to add as a sweep across one side: in on the outgoing song, out on the incoming. get_transition lists the ones each side can take",
            "items": ["type": "object",
                      "properties": ["side": ["type": "string", "enum": ["outgoing", "incoming"]] as [String: Any],
                                     "effect": ["type": "string", "enum": EffectPreset.all.map(\.id)] as [String: Any]],
                      "required": ["side", "effect"]] as [String: Any],
        ]
        let bool = { (d: String) -> [String: Any] in ["type": "boolean", "description": d] }
        let ids = { (d: String) -> [String: Any] in ["type": "array", "items": ["type": "string"], "description": d] }
        let detail = { (standard: String) -> [String: Any] in
            ["type": "string", "enum": ["summary", "moving", "all"],
             "description": "How much to return: summary leaves the lanes out, moving has the lanes that change, all has every lane and the effects each side can take. Defaults to \(standard)"]
        }
        let soundCheck = bool("Play every song at the same loudness, as the app does with Sound Check on. Defaults to true")
        return [
            tool("add_songs", "Add audio files, Native Instruments stem files or folders, and analyze them. The first analysis of a song takes a few seconds; later ones come from the cache. Returns the songs added with their ids, or only how many when there are more than 25: find those with list_songs.",
                 ["paths": ids("Absolute paths")], required: ["paths"]),
            tool("list_songs", "Songs added this session: id, title, artist, genre, BPM, key and length. Returns the total that match and up to `limit` of them.",
                 ["query": string("Words that must all appear in the title, artist or path"),
                  "bpm_min": number("Lowest BPM"), "bpm_max": number("Highest BPM"),
                  "key": string("A key as list_songs shows it, such as G minor"), "genre": genre,
                  "unique": bool("One version of each song: songs whose artist and title match apart from a bracketed tag at the end, such as (Official), are listed once"),
                  "limit": integer("Most songs to return. Defaults to 50"), "offset": integer("Songs to skip, to page through a long list")]),
            tool("get_song", "A song's analysis: bars and vocal ranges in song seconds, its loudness, and its sections, each with its length in bars, how loud it is against the whole song, and how much of it has vocals. Sections have no names: Apple's analysis finds where they start, not which is a chorus.",
                 ["song": string("Song id"), "beats": bool("Include every beat time")], required: ["song"]),
            tool("set_genre", "Set the genre of one song, several, or all. Genres decide which transition styles Apple's planner can pick, and an edit belongs to the genres it was made with.",
                 ["song": string("Song id"), "songs": ids("Song ids"), "all": bool("Every song added"), "genre": genre], required: ["genre"]),
            tool("get_transition", "The planned transition between two songs with any edits applied: style, length, where each song's side starts and ends in song seconds, the handoff point, the automation lanes, and checks made on the plan without rendering: how far apart the two songs' beats and bars land, whether the keys go together, and how long both have vocals at once (whatever their volume).",
                 ["from": from, "to": to, "detail": detail("moving")], required: ["from", "to"]),
            tool("list_variants", "The other plans Apple's planner makes for the pair: as other genres, or with lower complexity. Takes about a second.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("list_parameters", "Every parameter of the transition's effect graph that a lane can automate: code, name, range, the value it rests at, and what each value means for the ones that pick a note length or filter type.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("edit_transition", "Change a transition. Only the fields given change; the rest of the edit is kept. Returns the transition as get_transition does.",
                 ["from": from, "to": to, "variant": variant, "detail": detail("summary"),
                  "style": string("Use the plan with this style name, from list_variants. Only styles the planner makes for this pair can be chosen"),
                  "outgoing_start": number("Song seconds where the outgoing song's side starts. Use a bar time from get_song to stay on the grid"),
                  "incoming_start": number("Song seconds where the incoming song's side starts"),
                  "length_bars": number("The transition's length in the outgoing song's bars. Both songs stretch together and stay beat-matched"),
                  "outgoing_shift_bars": integer("Bars to move the outgoing song's side from where Apple planned it. Positive is later in the song"),
                  "incoming_shift_bars": integer("Bars to move the incoming song's side from where Apple planned it. Positive is later in the song"),
                  "outgoing_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "incoming_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "outgoing_lanes": lanes("outgoing"), "incoming_lanes": lanes("incoming"), "add_effects": effects],
                 required: ["from", "to"]),
            tool("reset_transition", "Drop every edit to a transition and go back to Apple's plan.", ["from": from, "to": to], required: ["from", "to"]),
            tool("render_transition", "Render one transition to a WAV, with some of each song either side of it. Returns the level of the result second by second and its peak, in dB below full scale.",
                 ["from": from, "to": to, "out": out, "margin": number("Seconds of each song around the transition. Defaults to 15"), "sound_check": soundCheck], required: ["from", "to"]),
            tool("plan_set", "The timeline of playing songs in order, without rendering: where each transition starts in the mix, which part of each song plays and for how long, and the total length.",
                 ["songs": ids("Song ids in playing order")], required: ["songs"]),
            tool("render_set", "Render songs in order, with every transition, to one WAV. Returns the same timeline as plan_set. A transition that can't be planned becomes a straight cut.",
                 ["songs": ids("Song ids in playing order"), "out": out, "sound_check": soundCheck], required: ["songs"]),
        ]
    }()

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "add_songs":
            guard let paths = args["paths"] as? [String] else { throw PlannerError("paths must be a list of file or folder paths") }
            return await add(paths)
        case "list_songs":
            return list(args)
        case "get_song":
            return songDetail(try entry(args["song"]), beats: args["beats"] as? Bool ?? false)
        case "set_genre":
            guard let genre = (args["genre"] as? String).flatMap(Genre.init(rawValue:)) else {
                throw PlannerError("genre must be one of: \(Genre.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var ids = Set(try (args["songs"] as? [String] ?? []).map { try entry($0).id })
            if args["song"] != nil { ids.insert(try entry(args["song"]).id) }
            if args["all"] as? Bool == true { ids = Set(songs.map(\.id)) }
            guard !ids.isEmpty else { throw PlannerError("give song, songs or all") }
            for i in songs.indices where ids.contains(songs[i].id) { songs[i].genre = genre }
            return ["genre": genre.rawValue, "songs_set": ids.count]
        case "get_transition":
            let (a, b) = try pair(args)
            return try describe(a, b, detail: args["detail"] as? String ?? "moving")
        case "list_variants":
            let (a, b) = try pair(args)
            return variants(a, b)
        case "list_parameters":
            let (a, b) = try pair(args)
            return parameters(try plan(a, b))
        case "edit_transition":
            let (a, b) = try pair(args)
            try edit(a, b, args)
            return try describe(a, b, detail: args["detail"] as? String ?? "summary")
        case "reset_transition":
            let (a, b) = try pair(args)
            edits[planKey(a, b)] = nil
            return try describe(a, b, detail: "summary")
        case "render_transition":
            let (a, b) = try pair(args)
            return try renderTransition(a, b, margin: number(args["margin"]) ?? 15, out: args["out"] as? String,
                                        soundCheck: args["sound_check"] as? Bool ?? true)
        case "plan_set", "render_set":
            guard let ids = args["songs"] as? [String], !ids.isEmpty else { throw PlannerError("songs must be a list of song ids") }
            let list = try ids.map { try entry($0) }
            if name == "plan_set" { return timeline(list).json }
            return try renderSet(list, out: args["out"] as? String, soundCheck: args["sound_check"] as? Bool ?? true)
        default:
            throw PlannerError("unknown tool \(name)")
        }
    }

    // MARK: Songs

    private func entry(_ id: Any?) throws -> Entry {
        guard let id = id as? String, let entry = songs.first(where: { $0.id == id }) else {
            throw PlannerError("no song with id \(id ?? "nil"); add it with add_songs, or see list_songs")
        }
        return entry
    }

    private func pair(_ args: [String: Any]) throws -> (Entry, Entry) { (try entry(args["from"]), try entry(args["to"])) }

    private func add(_ paths: [String]) async -> [String: Any] {
        let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]
        var files: [URL] = [], failed: [[String: Any]] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                failed.append(["path": path, "error": "no such file"])
                continue
            }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                var found: [URL] = []
                while let f = e?.nextObject() as? URL { if audioExtensions.contains(f.pathExtension.lowercased()) { found.append(f) } }
                files += found.sorted { $0.path < $1.path }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            } else {
                failed.append(["path": path, "error": "not an audio file pink diamond reads"])
            }
        }
        var added: [[String: Any]] = []
        for url in files {
            if let known = songs.first(where: { $0.path == url.path }) {
                added.append(summary(known))
                continue
            }
            do {
                let key = fileKey(url)
                let playable = try await AudioSource.playableURL(for: url)
                // The app's analysis cache, by the same key and under the same catalog ID, so a song analyzed by
                // either is ready in both.
                let cache = AppPaths.cacheDir("analysis").appendingPathComponent(key + ".json")
                var analysis: SongAnalysis
                if let cached = (try? Data(contentsOf: cache)).flatMap({ try? JSONDecoder().decode(SongAnalysis.self, from: $0) }) {
                    analysis = cached
                    // As `Library.readAnalysis`: analyses cached before Sound Check hold their loudness only in the Apple-format JSON.
                    if analysis.loudness == nil { analysis.loudness = Loudness(audioAnalysis: analysis.audioAnalysisJSON) }
                } else {
                    analysis = try await Analyzer.analyze(playable: playable, id: "99" + String(key.prefix(8)))
                    try? JSONEncoder().encode(analysis).write(to: cache)
                }
                var name = url.deletingPathExtension().lastPathComponent
                if AudioSource.isStem(url), name.lowercased().hasSuffix(".stem") { name = String(name.dropLast(5)) }
                var song = Entry(id: String(key.prefix(8)), path: url.path, title: name, artist: "", playable: playable, analysis: analysis)
                for item in (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? [] {
                    guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                    if item.commonKey == .commonKeyTitle { song.title = value }
                    if item.commonKey == .commonKeyArtist { song.artist = value }
                }
                songs.append(song)
                added.append(summary(song))
            } catch {
                failed.append(["path": url.path, "error": String(describing: error)])
            }
        }
        // A folder of a few hundred songs would otherwise answer with every one of them.
        if added.count > 25 { return ["added": added.count, "failed": failed] }
        return ["added": added.count, "songs": added, "failed": failed]
    }

    private func summary(_ s: Entry) -> [String: Any] {
        ["id": s.id, "title": s.title, "artist": s.artist, "genre": s.genre.rawValue,
         "bpm": s.analysis.bpm, "key": s.analysis.key, "duration": r(s.analysis.duration)]
    }

    private func list(_ args: [String: Any]) -> [String: Any] {
        let words = (args["query"] as? String ?? "").lowercased().split(separator: " ")
        let low = number(args["bpm_min"]) ?? 0, high = number(args["bpm_max"]) ?? .infinity
        let key = (args["key"] as? String)?.lowercased(), genre = args["genre"] as? String
        var matches = songs.filter { s in
            let text = "\(s.title) \(s.artist) \(s.path)".lowercased()
            return words.allSatisfy { text.contains($0) } && Double(s.analysis.bpm) >= low && Double(s.analysis.bpm) <= high
                && (key == nil || s.analysis.key.lowercased() == key) && (genre == nil || s.genre.rawValue == genre)
        }
        if args["unique"] as? Bool == true {
            var seen = Set<String>()
            matches = matches.filter { s in
                let title = s.title.replacingOccurrences(of: #"(\s*[\(\[][^\)\]]*[\)\]])+\s*$"#, with: "", options: .regularExpression)
                return seen.insert("\(s.artist)|\(title)".lowercased()).inserted
            }
        }
        let offset = max(0, Int(number(args["offset"]) ?? 0)), limit = max(1, Int(number(args["limit"]) ?? 50))
        return ["total": matches.count, "songs": matches.dropFirst(offset).prefix(limit).map(summary)]
    }

    private func songDetail(_ s: Entry, beats: Bool) -> [String: Any] {
        var detail = summary(s)
        let a = s.analysis
        detail["path"] = s.path
        detail["bars"] = a.bars.map(r)
        detail["vocals"] = a.vocals.map { [r($0.lowerBound), r($0.upperBound)] }
        detail["beat_count"] = a.beats.count
        if beats { detail["beats"] = a.beats.map(r) }
        if let l = a.loudness {
            detail["loudness_lufs"] = r(l.integrated)
            detail["sound_check_db"] = r(20 * log10(Double(l.gain)))
        }
        // Apple's loudness curve: short-term loudness every half second from 0.5 s, as `Analyzer` writes it.
        let attributes = ((try? JSONSerialization.jsonObject(with: a.audioAnalysisJSON)) as? [String: Any])?["attributes"] as? [String: Any]
        let curve = (attributes?["loudnessCurve"] as? [String: Any])?["value"] as? [Double] ?? []
        let starts = a.sections.first.map { $0 > 0.5 ? [0] + a.sections : a.sections } ?? [0]
        detail["sections"] = zip(starts, starts.dropFirst() + [a.duration]).map { lo, hi -> [String: Any] in
            var section: [String: Any] = ["start": r(lo), "end": r(hi), "bars": a.bars.filter { $0 >= lo - 0.05 && $0 < hi - 0.05 }.count]
            let levels = curve.enumerated().filter { 0.5 * Double($0.offset + 1) >= lo && 0.5 * Double($0.offset + 1) < hi && $0.element > -70 }.map(\.element)
            if !levels.isEmpty, let l = a.loudness {
                section["loudness_vs_song_db"] = r(levels.reduce(0, +) / Double(levels.count) - l.integrated)
            }
            let sung = a.vocals.map { max(0, min($0.upperBound, hi) - max($0.lowerBound, lo)) }.reduce(0, +)
            section["vocals"] = r(hi > lo ? sung / (hi - lo) : 0)
            return section
        }
        return detail
    }

    // MARK: Plans

    /// As `Library.planKey`: genres are part of the key because they change the plan, so an edit stays with the plan
    /// it was made on.
    private func planKey(_ a: Entry, _ b: Entry) -> String { "\(a.id)|\(a.genre.rawValue)>\(b.id)|\(b.genre.rawValue)" }

    private func basePlan(_ a: Entry, _ b: Entry, variant: PlanVariant?) throws -> TransitionPlan {
        let key = planKey(a, b) + (variant.map { "#" + $0.key } ?? "")
        if let known = basePlans[key] { return known }
        let json = try SonicPlanner.shared.plan(from: try Analyzer.songJSON(a.analysis, genre: variant?.fromGenre ?? a.genre),
                                                to: try Analyzer.songJSON(b.analysis, genre: variant?.toGenre ?? b.genre),
                                                criteria: variant?.criteriaPatch)
        let plan = try TransitionPlan(json: json)
        basePlans[key] = plan
        return plan
    }

    private func plan(_ a: Entry, _ b: Entry) throws -> TransitionPlan {
        let edit = edits[planKey(a, b)] ?? TransitionEdit()
        let base = try basePlan(a, b, variant: edit.variant)
        return edit.isEmpty ? base : base.applying(edit)
    }

    private func variantJSON(_ v: PlanVariant?) -> Any {
        guard let v else { return NSNull() }
        var json: [String: Any] = ["from_genre": v.fromGenre.rawValue, "to_genre": v.toGenre.rawValue]
        if let c = v.complexity { json["complexity"] = c.rawValue }
        return json
    }

    /// The same set `Library.alternatives` offers in the deck view's Styles menu.
    private func variantPlans(_ a: Entry, _ b: Entry) -> [(variant: PlanVariant?, plan: TransitionPlan)] {
        var all: [PlanVariant?] = [nil]
        all += Genre.allCases.filter { $0 != a.genre || $0 != b.genre }.map { PlanVariant(fromGenre: $0, toGenre: $0) }
        all += PlanVariant.Complexity.allCases.map { PlanVariant(fromGenre: a.genre, toGenre: b.genre, complexity: $0) }
        var seen = Set<String>(), list: [(variant: PlanVariant?, plan: TransitionPlan)] = []
        for v in all {
            guard let plan = try? basePlan(a, b, variant: v) else { continue }
            let signature = String(format: "%@%d|%.1f|%.1f|%.1f", plan.algorithm, plan.styleID ?? -1, plan.outgoing.start,
                                   plan.incoming.start, plan.duration)
            if seen.insert(signature).inserted { list.append((v, plan)) }
        }
        return list
    }

    private func variants(_ a: Entry, _ b: Entry) -> [[String: Any]] {
        variantPlans(a, b).map { v, plan in
            ["variant": variantJSON(v), "style": plan.styleName, "duration": r(plan.duration),
             "outgoing_start": r(plan.outgoing.start), "incoming_start": r(plan.incoming.start), "effects": plan.effectSummary]
        }
    }

    /// The outgoing song's bar length around the transition, which is what the deck view counts the length in.
    private func barLength(_ a: Entry, _ side: TransitionSide) -> Double {
        let bars = a.analysis.bars.filter { $0 >= side.start - 8 && $0 <= side.end + 8 }
        let d = zip(bars.dropFirst(), bars).map { $0 - $1 }.sorted()
        return d.isEmpty ? 240 / Double(max(a.analysis.bpm, 1)) : d[d.count / 2]
    }

    /// The plan's own range for a parameter, widened to the catalog's: a plan's range can stop short of the value
    /// the parameter rests at (low-pass tops out at 21829.5 in a plan and rests at 22000), and a lane has to be able
    /// to hold it there.
    private func range(_ side: TransitionSide, _ id: String) -> ClosedRange<Double>? {
        guard let planned = side.automations[id]?.range else { return EffectCatalog.ranges[id] }
        guard let known = EffectCatalog.ranges[id] else { return planned }
        return min(planned.lowerBound, known.lowerBound)...max(planned.upperBound, known.upperBound)
    }

    private func describe(_ a: Entry, _ b: Entry, detail: String) throws -> [String: Any] {
        guard ["summary", "moving", "all"].contains(detail) else { throw PlannerError("detail must be summary, moving or all") }
        let edit = edits[planKey(a, b)] ?? TransitionEdit()
        let plan = try plan(a, b)
        func side(_ s: TransitionSide, _ song: Entry, shift: Double) -> [String: Any] {
            var json: [String: Any] = ["start": r(s.start), "end": r(s.end), "shift_seconds": r(shift)]
            guard detail != "summary" else { return json }
            // The song's bars inside the window on the mix clock, so points on either song can be put on the same bar.
            json["bars_at"] = song.analysis.bars.filter { $0 >= s.start - 0.01 && $0 <= s.end + 0.01 }.map { r(s.transitionTime(at: $0)) }
            json["lanes"] = s.automations.values.filter { detail == "all" || $0.moves }.sorted { $0.id < $1.id }.map { auto -> [String: Any] in
                var lane: [String: Any] = ["id": auto.id, "name": EffectCatalog.name(auto.id), "points": s.editPoints(auto.id).map {
                    ["at": r(s.transitionTime(at: s.start + $0.offset)), "offset": r($0.offset), "value": r($0.value), "curve": $0.curve]
                }]
                if let range = range(s, auto.id) { lane["range"] = [r(range.lowerBound), r(range.upperBound)] }
                if detail == "all" { lane["moves"] = auto.moves }
                return lane
            }
            if detail == "all" {
                let addable = EffectPreset.all.filter { p in p.requires.allSatisfy { s.wiring[$0] != nil } && s.automations[p.id]?.moves != true }
                json["addable_effects"] = addable.map { ["effect": $0.id, "name": $0.name] }
            }
            return json
        }
        return ["from": a.id, "to": b.id, "style": plan.styleName, "style_id": plan.styleID ?? -1,
                "duration": r(plan.duration), "handoff": r(plan.pivot),
                "length_bars": r((plan.outgoing.end - plan.outgoing.start) / barLength(a, plan.outgoing)),
                "effects": plan.effectSummary, "edited": !edit.isEmpty, "variant": variantJSON(edit.variant),
                "checks": checks(a, b, plan),
                "outgoing": side(plan.outgoing, a, shift: edit.outgoingShift),
                "incoming": side(plan.incoming, b, shift: edit.incomingShift)]
    }

    // MARK: Checks

    /// What can be said about a transition from the plan and the analyses alone. An agent can't listen to a render,
    /// so these stand in for the things a listener would catch first: beats that flam, bars that don't line up, keys
    /// that clash and two vocals at once.
    private func checks(_ a: Entry, _ b: Entry, _ plan: TransitionPlan) -> [String: Any] {
        var json: [String: Any] = [:]
        let (out, inc) = (plan.outgoing, plan.incoming)
        func onClock(_ times: [Double], _ side: TransitionSide) -> [Double] {
            times.filter { $0 >= side.start - 0.01 && $0 <= side.end + 0.01 }.map { side.transitionTime(at: $0) }
        }
        /// How far each of `x` lands from the nearest of `y`, on the mix clock: the mean and the worst, in ms.
        func apart(_ x: [Double], _ y: [Double]) -> (mean: Double, worst: Double)? {
            guard !x.isEmpty, !y.isEmpty else { return nil }
            let gaps = x.map { t in y.map { abs($0 - t) }.min()! * 1000 }
            return (gaps.reduce(0, +) / Double(gaps.count), gaps.max()!)
        }
        if let beats = apart(onClock(a.analysis.beats, out), onClock(b.analysis.beats, inc)) {
            json["beats_apart_ms"] = r(beats.mean)
            json["beats_apart_worst_ms"] = r(beats.worst)
        }
        if let bars = apart(onClock(a.analysis.bars, out), onClock(b.analysis.bars, inc)) { json["bars_apart_ms"] = r(bars.mean) }

        func sung(_ song: Entry, _ side: TransitionSide) -> [(Double, Double)] {
            song.analysis.vocals.compactMap { v in
                let lo = max(v.lowerBound, side.start), hi = min(v.upperBound, side.end)
                return hi > lo ? (side.transitionTime(at: lo), side.transitionTime(at: hi)) : nil
            }
        }
        let theirs = sung(b, inc)
        json["vocals_together_seconds"] = r(sung(a, out).map { x in theirs.map { max(0, min(x.1, $0.1) - max(x.0, $0.0)) }.reduce(0, +) }.reduce(0, +))

        if let ka = Self.camelot(a.analysis.key), let kb = Self.camelot(b.analysis.key) {
            let steps = min((ka.number - kb.number + 12) % 12, (kb.number - ka.number + 12) % 12)
            let relation = switch (steps, ka.minor == kb.minor) {
            case (0, true): "same key"
            case (0, false): "relative major and minor"
            case (1, true): "a fifth apart"
            default: "clash"
            }
            json["keys"] = ["from": "\(a.analysis.key) (\(ka.name))", "to": "\(b.analysis.key) (\(kb.name))", "relation": relation]
        }
        return json
    }

    /// A key's place on the Camelot wheel, where keys that mix sit next to each other: A minor is 8A, each fifth up is
    /// one step round, and a major key shares its relative minor's number.
    private static func camelot(_ key: String) -> (number: Int, minor: Bool, name: String)? {
        let parts = key.split(separator: " ")
        guard parts.count == 2, let pitch = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"].firstIndex(of: String(parts[0])) else { return nil }
        let minor = parts[1] == "minor"
        let asMinor = minor ? pitch : (pitch + 9) % 12
        let number = ((asMinor - 9 + 12) * 7 % 12 + 7) % 12 + 1
        return (number, minor, "\(number)\(minor ? "A" : "B")")
    }

    private func parameters(_ plan: TransitionPlan) -> [[String: Any]] {
        let side = plan.outgoing   // both sides are wired by the same graph
        return Set(side.wiring.keys).union(["out_gain", "ts_rate"]).sorted().map { id in
            var p: [String: Any] = ["id": id, "name": EffectCatalog.name(id), "rest": r(side.neutralValue(id))]
            if let range = range(side, id) { p["range"] = [r(range.lowerBound), r(range.upperBound)] }
            if EffectCatalog.isStepped(id) { p["whole_values"] = true }
            if let values = Self.steps[id] { p["values"] = values }
            return p
        }
    }

    /// What RemixFX's index parameters select, in index order, from the unit's own parameter list.
    private static let steps: [String: [String]] = {
        let lfo = ["16 bars", "8 bars", "4 bars", "2 bars", "1/1", "1/2", "1/2T", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"]
        let filter = ["low-pass", "high-pass", "combined"]
        return [
            "RXpr": ["2 bars", "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"],
            "RXdr": ["1/1", "1/2D", "1/1T", "1/2", "1/4D", "1/2T", "1/4", "1/8D", "1/4T", "1/8", "1/16D", "1/8T", "1/16", "1/32D", "1/16T",
                     "1/32", "1/64D", "1/32T", "1/64", "1/128D", "1/64T", "1/128", "1/256D", "1/128T"],
            "RXgr": lfo, "RXfr": lfo, "RXsr": lfo, "RXat": filter, "RXbt": filter,
            "RXtr": ["2 bars", "1/1", "1/2", "1/2T", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"],
        ]
    }()

    // MARK: Editing

    private func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// A move of `bars` on the song's bar grid from the bar nearest `start`, in song seconds. The grid continues past
    /// both ends of the song at its edge spacing, as in the deck view, so a side can be moved out beyond the song.
    private func shift(_ s: Entry, from start: Double, bars: Int) -> Double {
        var grid = s.analysis.bars.count > 1 ? s.analysis.bars : s.analysis.beats
        guard grid.count > 1 else { return 0 }
        let head = grid[1] - grid[0], tail = grid[grid.count - 1] - grid[grid.count - 2]
        grid = (1...64).reversed().map { grid[0] - Double($0) * head } + grid + (1...64).map { grid[grid.count - 1] + Double($0) * tail }
        let i = grid.indices.min { abs(grid[$0] - start) < abs(grid[$1] - start) }!
        return grid[min(max(i + bars, 0), grid.count - 1)] - grid[i]
    }

    private func edit(_ a: Entry, _ b: Entry, _ args: [String: Any]) throws {
        let key = planKey(a, b)
        var edit = edits[key] ?? TransitionEdit()
        if let v = args["variant"] {
            if let v = v as? [String: Any] {
                func genre(_ name: String, _ fallback: Genre) throws -> Genre {
                    guard let raw = v[name] as? String else { return fallback }
                    guard let genre = Genre(rawValue: raw) else { throw PlannerError("\(name): unknown genre \(raw)") }
                    return genre
                }
                var complexity: PlanVariant.Complexity?
                if let raw = v["complexity"] as? String {
                    guard let c = PlanVariant.Complexity(rawValue: raw) else { throw PlannerError("unknown complexity \(raw)") }
                    complexity = c
                }
                edit.variant = PlanVariant(fromGenre: try genre("from_genre", a.genre), toGenre: try genre("to_genre", b.genre), complexity: complexity)
            } else if v is NSNull {
                edit.variant = nil
            } else {
                throw PlannerError("variant must be an object or null")
            }
        }
        if let style = args["style"] as? String {
            let options = variantPlans(a, b)
            guard let match = options.first(where: { $0.plan.styleName.lowercased() == style.lowercased() }) else {
                throw PlannerError("the planner doesn't make \(style) for this pair; it makes: \(options.map(\.plan.styleName).joined(separator: ", "))")
            }
            edit.variant = match.variant
        }
        let base = try basePlan(a, b, variant: edit.variant)
        if let bars = number(args["length_bars"]) {
            guard bars > 0 else { throw PlannerError("length_bars must be above 0") }
            let planBars = (base.outgoing.end - base.outgoing.start) / barLength(a, base.outgoing)
            guard planBars > 0 else { throw PlannerError("this plan has no length to scale") }
            edit.setLengthScale(bars / planBars)
        }
        if let bars = number(args["outgoing_shift_bars"]) { edit.outgoingShift = shift(a, from: base.outgoing.start, bars: Int(bars)) }
        if let bars = number(args["incoming_shift_bars"]) { edit.incomingShift = shift(b, from: base.incoming.start, bars: Int(bars)) }
        if let seconds = number(args["outgoing_shift_seconds"]) { edit.outgoingShift = seconds }
        if let seconds = number(args["incoming_shift_seconds"]) { edit.incomingShift = seconds }
        if let start = number(args["outgoing_start"]) { edit.outgoingShift = start - base.outgoing.start }
        if let start = number(args["incoming_start"]) { edit.incomingShift = start - base.incoming.start }
        let placed = base.applying(edit)   // where the sides are now, for points given on the mix clock
        for outgoing in [true, false] {
            let name = outgoing ? "outgoing_lanes" : "incoming_lanes"
            guard let lanes = args[name] as? [String: Any] else { continue }
            let side = outgoing ? base.outgoing : base.incoming
            let current = outgoing ? placed.outgoing : placed.incoming
            for (id, value) in lanes {
                guard side.wiring[id] != nil || side.automations[id] != nil || id == "out_gain" || id == "ts_rate" else {
                    throw PlannerError("\(name): \(id) is not a parameter of this transition; see list_parameters")
                }
                if value is NSNull {
                    edit.setLane(outgoing, id, nil)
                    continue
                }
                guard let raw = value as? [[String: Any]], !raw.isEmpty else { throw PlannerError("\(name).\(id) must be a list of points, or null") }
                let range = range(side, id)
                let points = try raw.map { p -> TransitionEdit.Point in
                    let at = number(p["at"]).map { current.songTime(atTransitionTime: $0) - current.start }
                    guard let offset = at ?? number(p["offset"]), let v = number(p["value"]), offset.isFinite, v.isFinite else {
                        throw PlannerError("\(name).\(id): every point needs a value and either at or offset")
                    }
                    if let range, !range.contains(v) {
                        throw PlannerError("\(name).\(id): \(v) is outside \(range.lowerBound) to \(range.upperBound)")
                    }
                    let curve = p["curve"] as? String ?? "linear"
                    guard Self.curves.contains(curve) else { throw PlannerError("\(name).\(id): curve must be one of \(Self.curves.joined(separator: ", "))") }
                    return .init(offset: offset, value: v, curve: curve)
                }
                edit.setLane(outgoing, id, points.sorted { $0.offset < $1.offset })
            }
        }
        if let effects = args["add_effects"] as? [[String: Any]] {
            for e in effects {
                guard let which = e["side"] as? String, ["outgoing", "incoming"].contains(which),
                      let preset = EffectPreset.all.first(where: { $0.id == e["effect"] as? String }) else {
                    throw PlannerError("add_effects: each needs a side (outgoing or incoming) and an effect (\(EffectPreset.all.map(\.id).joined(separator: ", ")))")
                }
                let outgoing = which == "outgoing"
                // On the plan as edited so far, as the deck view does: the sweep spans the side at its current length.
                let current = base.applying(edit)
                let side = outgoing ? current.outgoing : current.incoming
                guard preset.requires.allSatisfy({ side.wiring[$0] != nil }) else {
                    throw PlannerError("add_effects: this transition's graph has no \(preset.name.lowercased()) on the \(which) side")
                }
                let bpm = Double((outgoing ? a : b).analysis.bpm)
                for (id, points) in preset.lanes(length: side.end - side.start, outgoing: outgoing, bpm: bpm, side: side) {
                    edit.setLane(outgoing, id, points)
                }
            }
        }
        edits[key] = edit.isEmpty ? nil : edit
    }

    // MARK: Rendering

    private func outputURL(_ path: String?) -> URL {
        if let path { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return AppPaths.cacheDir("mcp").appendingPathComponent(UUID().uuidString + ".wav")
    }

    private func item(_ s: Entry, entering: TransitionSide?, leaving: TransitionSide?, soundCheck: Bool) -> MixRenderer.Item {
        MixRenderer.Item(audio: s.playable, beats: s.analysis.beats, entering: entering, leaving: leaving,
                         gain: soundCheck ? s.analysis.loudness?.gain ?? 1 : 1)
    }

    private func renderTransition(_ a: Entry, _ b: Entry, margin: Double, out: String?, soundCheck: Bool) throws -> [String: Any] {
        let plan = try plan(a, b)
        let items = [item(a, entering: nil, leaving: plan.outgoing, soundCheck: soundCheck),
                     item(b, entering: plan.incoming, leaving: nil, soundCheck: soundCheck)]
        let url = outputURL(out), start = max(0, plan.outgoing.start - margin)
        let seconds = try MixRenderer.render(items, startTime: start, tail: margin, to: url)
        var json: [String: Any] = ["path": url.path, "seconds": r(seconds), "transition_starts_at": r(plan.outgoing.start - start),
                                   "transition_duration": r(plan.duration)]
        json.merge(levels(url)) { a, _ in a }
        return json
    }

    /// The render's level each second (RMS over both channels) and its peak, in dB below full scale. Not loudness as
    /// LUFS measures it, but enough to see a dip, a jump or a hole across a transition.
    private func levels(_ url: URL) -> [String: Any] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return [:] }
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength), second = Int(buffer.format.sampleRate)
        let db = { (x: Double) in x > 0 ? max(20 * log10(x), -100) : -100 }
        var seconds: [NSNumber] = [], peak = 0.0
        for start in stride(from: 0, to: frames, by: second) {
            let end = min(start + second, frames)
            var sum = 0.0
            for c in 0..<channels {
                for i in start..<end {
                    let x = Double(data[c][i])
                    sum += x * x
                    peak = max(peak, abs(x))
                }
            }
            seconds.append(NSDecimalNumber(string: String(format: "%.1f", db((sum / Double((end - start) * channels)).squareRoot()))))
        }
        return ["level_db_per_second": seconds, "peak_db": r(db(peak))]
    }

    /// Playing `list` in order: the plans between the songs (nil where planning failed, which plays as a straight
    /// cut) and the timeline that results, worked out from the plans as the renderer plays them.
    private func timeline(_ list: [Entry]) -> (plans: [TransitionPlan?], json: [String: Any]) {
        var plans: [TransitionPlan?] = [], transitions: [[String: Any]] = [], played: [[String: Any]] = []
        var clock = 0.0, songTime = 0.0   // the mix clock and the current song's time, at the point reached so far
        var enteredAt = 0.0, enteredFrom = 0.0
        for (a, b) in zip(list, list.dropFirst()) {
            var song: [String: Any] = ["id": a.id, "title": a.title, "enters_at": r(enteredAt), "plays_from": r(enteredFrom)]
            do {
                let plan = try plan(a, b)
                // Negative when this transition starts before the one into the song has finished.
                song["alone_seconds"] = r(plan.outgoing.start - songTime)
                song["plays_to"] = r(plan.outgoing.end)
                clock += plan.outgoing.start - songTime
                transitions.append(["from": a.id, "to": b.id, "style": plan.styleName, "starts_at": r(clock), "duration": r(plan.duration)])
                (enteredAt, enteredFrom) = (clock, plan.incoming.start)
                clock += plan.duration
                songTime = plan.incoming.end
                plans.append(plan)
            } catch {
                song["alone_seconds"] = r(a.analysis.duration - songTime)
                song["plays_to"] = r(a.analysis.duration)
                clock += a.analysis.duration - songTime
                transitions.append(["from": a.id, "to": b.id, "starts_at": r(clock), "error": String(describing: error)])
                (enteredAt, enteredFrom) = (clock, 0)
                songTime = 0
                plans.append(nil)
            }
            played.append(song)
        }
        let last = list[list.count - 1]
        played.append(["id": last.id, "title": last.title, "enters_at": r(enteredAt), "plays_from": r(enteredFrom),
                       "alone_seconds": r(last.analysis.duration - songTime), "plays_to": r(last.analysis.duration)])
        clock += last.analysis.duration - songTime
        return (plans, ["seconds": r(clock), "songs": played, "transitions": transitions])
    }

    private func renderSet(_ list: [Entry], out: String?, soundCheck: Bool) throws -> [String: Any] {
        var (plans, json) = timeline(list)
        let items = list.enumerated().map { i, s in
            item(s, entering: i > 0 ? plans[i - 1]?.incoming : nil, leaving: i < plans.count ? plans[i]?.outgoing : nil, soundCheck: soundCheck)
        }
        let url = outputURL(out)
        json["seconds"] = r(try MixRenderer.render(items, startTime: 0, tail: nil, to: url))
        json["path"] = url.path
        return json
    }

    /// Rounded to the millisecond to keep responses short, and never non-finite, which JSONSerialization can't write.
    /// As a decimal number, because JSONSerialization writes a Double out to 17 digits (268.1 as 268.10000000000002).
    private func r(_ x: Double) -> NSNumber { NSDecimalNumber(string: String(x.isFinite ? (x * 1000).rounded() / 1000 : 0)) }
}
