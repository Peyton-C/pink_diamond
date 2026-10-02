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
    private var moves: [String: String] = [:]               // the exit and entry moves a transition was built from, by plan key
    /// Whether the server offers what Apple's AutoMix has no counterpart for: stems, loops and outgoing tails. Off,
    /// an agent can do what the app's editor can and no more.
    private let extensions: Bool
    private lazy var tools = Self.tools(extensions: extensions)
    private let output: FileHandle

    /// Frameworks under the planner and renderer may print, and anything on stdout that isn't a response breaks the
    /// client's parser, so responses go to a copy of stdout and descriptor 1 is pointed at stderr.
    init(extensions: Bool) {
        self.extensions = extensions
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
            result = ["tools": tools]
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

    private static func tools(extensions: Bool) -> [[String: Any]] {
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
        let loop = { (song: String) -> [String: Any] in
            ["type": ["object", "null"],
             "description": "Repeat a stretch of the \(song) song inside its side of the transition, then carry on. The side gets longer by the repeats, and lane offsets on that song count them, so a filter can keep moving across the repeats. Set it before the lanes, or in the same call. null removes it",
             "properties": ["start": number("Song seconds where the stretch starts. Use a bar or beat time"),
                            "bars": number("Its length in bars; 0.25 is one beat"),
                            "repeats": integer("Times it plays again after the first")],
             "required": ["start", "bars", "repeats"]]
        }
        var editing: [String: Any] = ["from": from, "to": to, "variant": variant, "detail": detail("summary"),
                  "style": string("Use the plan with this style name, from list_variants. Only styles the planner makes for this pair can be chosen"),
                  "blank": bool("Start from a blank beat-matched transition: both songs at full volume for the whole window, tempo-matched afresh from their beat grids where the sides are now, every other lane held at rest, and any lanes set before dropped. The outgoing song stops when the window ends. Start both sides on a bar so the downbeats meet. Draw your own lanes over it, in the same call or later"),
                  "exit": ["type": "string", "enum": exits.filter { extensions || $0.tail == 0 }.map(\.0),
                           "description": "How the outgoing song leaves, built on a blank transition: " + exits.filter { extensions || $0.tail == 0 }.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")] as [String: Any],
                  "entry": ["type": "string", "enum": entries.map(\.0),
                            "description": "How the incoming song arrives, built on a blank transition: " + entries.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")] as [String: Any],
                  "outgoing_start": number("Song seconds where the outgoing song's side starts. Use a bar time from get_song to stay on the grid"),
                  "incoming_start": number("Song seconds where the incoming song's side starts"),
                  "length_bars": number("The transition's length in the outgoing song's bars, where its side is now. Both songs stretch together and stay beat-matched"),
                  "outgoing_shift_bars": integer("Bars to move the outgoing song's side from where Apple planned it. Positive is later in the song"),
                  "incoming_shift_bars": integer("Bars to move the incoming song's side from where Apple planned it. Positive is later in the song"),
                  "outgoing_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "incoming_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "outgoing_lanes": lanes("outgoing"), "incoming_lanes": lanes("incoming"), "add_effects": effects]
        if extensions {
            editing["outgoing_tail_bars"] = number("Bars the outgoing song plays on after the window ends, with its lanes carrying on, so an echo can ring out or a fade can finish under the new song. Lane offsets past the window reach into it. 0 removes it")
            editing["outgoing_loop"] = loop("outgoing")
            editing["incoming_loop"] = loop("incoming")
        }
        return [
            tool("add_songs", "Add audio files, Native Instruments stem files or folders, and analyze them. The first analysis of a song takes a few seconds; later ones come from the cache. Returns the songs added with their ids, or only how many when there are more than 25: find those with list_songs.",
                 ["paths": ids("Absolute paths")], required: ["paths"]),
            tool("list_songs", "Songs added this session: id, title, artist, genre, BPM, key and length, and for a stem file where its stems came from: Official, FN, RF AT, DE AT, RF, DE or stemgen, cleanest first. Returns the total that match and up to `limit` of them.",
                 ["query": string("Words that must all appear in the title, artist or path"),
                  "bpm_min": number("Lowest BPM"), "bpm_max": number("Highest BPM"),
                  "key": string("A key as list_songs shows it, such as G minor"), "genre": genre,
                  "unique": bool("One version of each song: songs whose artist and title match apart from a bracketed tag at the end, such as (Official), are listed once, as the version with the best stems"),
                  "limit": integer("Most songs to return. Defaults to 50"), "offset": integer("Songs to skip, to page through a long list")]),
            tool("get_song", "A song's analysis: bars and vocal ranges in song seconds, its loudness, and its sections, each with its length in bars, how loud it is against the whole song, and how much of it has vocals. Sections have no names: Apple's analysis finds where they start, not which is a chorus.",
                 ["song": string("Song id"), "beats": bool("Include every beat time"),
                  "bars": bool("Include every bar time. Defaults to true; turn it off when scanning many songs")], required: ["song"]),
            tool("set_genre", "Set the genre of one song, several, or all. Genres decide which transition styles Apple's planner can pick, and an edit belongs to the genres it was made with.",
                 ["song": string("Song id"), "songs": ids("Song ids"), "all": bool("Every song added"), "genre": genre], required: ["genre"]),
            tool("get_transition", "The planned transition between two songs with any edits applied: style, length, where each song's side starts and ends in song seconds, the handoff point, the automation lanes, and checks made on the plan without rendering: how far apart the two songs' beats and bars land, whether the keys go together, and how long both have vocals at once (whatever their volume).",
                 ["from": from, "to": to, "detail": detail("moving")], required: ["from", "to"]),
            tool("list_variants", "The other plans Apple's planner makes for the pair: as other genres, or with lower complexity. Takes about a second.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("list_parameters", "Every parameter of the transition's effect graph that a lane can automate: code, name, range, the value it rests at, and what each value means for the ones that pick a note length or filter type.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("edit_transition", "Change a transition. Only the fields given change; the rest of the edit is kept. Returns the transition as get_transition does." + (extensions ? " For songs that are stem files, lanes named stem_drums, stem_bass, stem_other and stem_vocals set each stem's level from 0 to 1; a stem is at 1 wherever no lane sets it, so bring it back to 1 before the incoming side ends." : ""),
                 editing, required: ["from", "to"]),
            tool("reset_transition", "Drop every edit to a transition and go back to Apple's plan.", ["from": from, "to": to], required: ["from", "to"]),
            tool("render_transition", "Render one transition to a WAV, with some of each song either side of it. Returns the level of the result second by second and its peak, in dB below full scale, and how many samples sit at full scale. The renderer ends in a limiter, so two songs at full volume are held under full scale rather than clipped, at the cost of pumping when it works hard.",
                 ["from": from, "to": to, "out": out, "margin": number("Seconds of each song around the transition. Defaults to 15"), "sound_check": soundCheck], required: ["from", "to"]),
            tool("plan_set", "The timeline of playing songs in order, without rendering: where each transition starts in the mix, its technique and length, which part of each song plays and for how long, the total length, and any run of three or more transitions in a row that use the same technique.",
                 ["songs": ids("Song ids in playing order")], required: ["songs"]),
            tool("render_set", "Render songs in order, with every transition, to one WAV. Returns the same timeline as plan_set, with the level each second from 4 seconds before each transition to 4 seconds after it. A transition that can't be planned becomes a straight cut.",
                 ["songs": ids("Song ids in playing order"), "out": out, "sound_check": soundCheck], required: ["songs"]),
        ]
    }

    /// The moves a transition can be put together from, with what each does. `tails` is in bars.
    private static let exits: [(String, String, tail: Double)] = [
        ("cut", "plays at full volume and stops when the window ends", 0),
        ("fade", "fades out across the window", 0),
        ("filter_fade", "a low-pass closes across the window, then it stops", 0),
        ("filter_rise", "a high-pass thins it out across the window, then it stops", 0),
        ("echo_out", "plays to the end of the window, then the song stops and its last beat echoes away over 2 more bars", 2),
    ]
    private static let entries: [(String, String)] = [
        ("full", "plays at full volume from the start of the window"),
        ("fade_in", "fades in across the window"),
        ("filter_in", "a high-pass opens across the window"),
        ("drop_in", "silent until the window ends, then in at full volume"),
    ]

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "add_songs":
            guard let paths = args["paths"] as? [String] else { throw PlannerError("paths must be a list of file or folder paths") }
            return await add(paths)
        case "list_songs":
            return list(args)
        case "get_song":
            return songDetail(try entry(args["song"]), beats: args["beats"] as? Bool ?? false, bars: args["bars"] as? Bool ?? true)
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
            moves[planKey(a, b)] = nil
            return try describe(a, b, detail: "summary")
        case "render_transition":
            let (a, b) = try pair(args)
            return try await renderTransition(a, b, margin: number(args["margin"]) ?? 15, out: args["out"] as? String,
                                        soundCheck: args["sound_check"] as? Bool ?? true)
        case "plan_set", "render_set":
            guard let ids = args["songs"] as? [String], !ids.isEmpty else { throw PlannerError("songs must be a list of song ids") }
            let list = try ids.map { try entry($0) }
            if name == "plan_set" { return timeline(list).json }
            return try await renderSet(list, out: args["out"] as? String, soundCheck: args["sound_check"] as? Bool ?? true)
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
        var json: [String: Any] = ["id": s.id, "title": s.title, "artist": s.artist, "genre": s.genre.rawValue,
                                   "bpm": s.analysis.bpm, "key": s.analysis.key, "duration": r(s.analysis.duration)]
        if let source = stemSource(s) { json["stems"] = source.name }
        return json
    }

    /// Where a stem file's stems came from, best first, read from the tag its maker leaves at the end of the name:
    /// official stems, Fortnite's, then separations by roformer and demucs, from an Atmos mix (AT) or from stereo,
    /// then stemgen's. A cleaner separation is the better one to pull a vocal or the drums out of.
    private static let stemSources = ["Official", "FN", "RF AT", "DE AT", "RF", "DE", "stemgen"]

    private func stemSource(_ s: Entry) -> (name: String, rank: Int)? {
        let url = URL(fileURLWithPath: s.path)
        guard AudioSource.isStem(url) else { return nil }
        let name = url.lastPathComponent.dropLast(".stem.mp4".count)
        let rank = Self.stemSources.firstIndex { name.hasSuffix("(\($0))") } ?? Self.stemSources.count - 1
        return (Self.stemSources[rank], rank)
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
            // The version with the best stems stands for the song; a file with no stems comes last.
            var best: [String: Entry] = [:], order: [String] = []
            let rank = { (s: Entry) in self.stemSource(s)?.rank ?? Self.stemSources.count }
            for s in matches {
                let title = s.title.replacingOccurrences(of: #"(\s*[\(\[][^\)\]]*[\)\]])+\s*$"#, with: "", options: .regularExpression)
                let key = "\(s.artist)|\(title)".lowercased()
                if let held = best[key] { if rank(s) < rank(held) { best[key] = s } } else { best[key] = s; order.append(key) }
            }
            matches = order.compactMap { best[$0] }
        }
        let offset = max(0, Int(number(args["offset"]) ?? 0)), limit = max(1, Int(number(args["limit"]) ?? 50))
        return ["total": matches.count, "songs": matches.dropFirst(offset).prefix(limit).map(summary)]
    }

    private func songDetail(_ s: Entry, beats: Bool, bars: Bool) -> [String: Any] {
        var detail = summary(s)
        let a = s.analysis
        detail["path"] = s.path
        if bars { detail["bars"] = a.bars.map(r) } else { detail["bar_count"] = a.bars.count }
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
            if let l = s.loop { json["loop"] = ["start": r(l.start), "seconds": r(l.length), "repeats": l.repeats] }
            guard detail != "summary" else { return json }
            // The song's bars inside the window on the mix clock, so points on either song can be put on the same bar.
            json["bars_at"] = played(song.analysis.bars, s).filter { $0 >= s.start - 0.01 && $0 <= s.end + 0.01 }.map { r(s.transitionTime(at: $0)) }
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
                "length_bars": r((plan.outgoing.end - edit.outgoingTail - plan.outgoing.start) / barLength(a, plan.outgoing)),
                "effects": plan.effectSummary, "edited": !edit.isEmpty, "variant": variantJSON(edit.variant),
                "checks": checks(a, b, plan), "technique": technique(a, b, plan),
                "outgoing_tail_seconds": r(edit.outgoingTail),
                "outgoing": side(plan.outgoing, a, shift: edit.outgoingShift),
                "incoming": side(plan.incoming, b, shift: edit.incomingShift)]
    }

    /// What a transition is, for telling one from the next across a set: the moves it was built from, or the
    /// planner's style, marked when lanes have been drawn over it.
    private func technique(_ a: Entry, _ b: Entry, _ plan: TransitionPlan) -> String {
        let key = planKey(a, b), edit = edits[key] ?? TransitionEdit()
        if let moves = moves[key] { return moves }
        guard edit.hasChanges, !(edit.outgoing.isEmpty && edit.incoming.isEmpty && !edit.isExtended) else { return plan.styleName }
        // Drawn by hand: named by what moves in it, so two different hand-drawn transitions don't read as a repeat.
        let parts = plan.effectSummary.filter { $0 != "tempo" }.sorted() + (edit.outgoingLoop != nil || edit.incomingLoop != nil ? ["loop"] : [])
        return "custom: " + parts.joined(separator: ", ")
    }

    // MARK: Checks

    /// What can be said about a transition from the plan and the analyses alone. An agent can't listen to a render,
    /// so these stand in for the things a listener would catch first: beats that flam, bars that don't line up, keys
    /// that clash and two vocals at once.
    private func checks(_ a: Entry, _ b: Entry, _ plan: TransitionPlan) -> [String: Any] {
        var json: [String: Any] = [:]
        let (out, inc) = (plan.outgoing, plan.incoming)
        /// A song's beats or bars that fall inside the transition, on the mix clock. A side can end before the
        /// transition does, and the song plays on at its own tempo, so times past the side's end count too.
        func onClock(_ times: [Double], _ side: TransitionSide) -> [Double] {
            played(times, side).filter { $0 >= side.start - 0.01 && $0 <= side.end + plan.duration }.map { side.transitionTime(at: $0) }
                .filter { $0 <= plan.duration + 0.01 }
        }
        /// How far the two grids are apart on the mix clock: the mean and the worst, in ms. Measured from the
        /// sparser grid to the nearest point of the denser, so a song at half or double time reads as aligned when
        /// every one of its beats lands on a beat of the other (Womanizer → 7 rings, 139 into 70 BPM: bars that
        /// line up two to one read 765 ms apart when measured from the faster song).
        func apart(_ a: [Double], _ b: [Double]) -> (mean: Double, worst: Double)? {
            guard !a.isEmpty, !b.isEmpty else { return nil }
            let (x, y) = a.count <= b.count ? (a, b) : (b, a)
            let gaps = x.map { t in y.map { abs($0 - t) }.min()! * 1000 }
            return (gaps.reduce(0, +) / Double(gaps.count), gaps.max()!)
        }
        let (beatsOut, beatsIn) = (onClock(a.analysis.beats, out), onClock(b.analysis.beats, inc))
        if let beats = apart(beatsOut, beatsIn) {
            json["beats_apart_ms"] = r(beats.mean)
            json["beats_apart_worst_ms"] = r(beats.worst)
            // From the spacing, not the counts: a song that starts late or ends inside the window has fewer beats
            // in it at the same tempo.
            func spacing(_ t: [Double]) -> Double? {
                let d = zip(t.dropFirst(), t).map { $0 - $1 }.sorted()
                return d.isEmpty ? nil : d[d.count / 2]
            }
            if let o = spacing(beatsOut), let i = spacing(beatsIn), o > 0, i / o > 1.5 || i / o < 0.67 {
                json["beats_out_per_beat_in"] = r((i / o * 2).rounded() / 2)
            }
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

    /// Times in the song's file (beats, bars) as that side plays them: those inside a loop come round again with each
    /// repeat, and those after it come later.
    private func played(_ times: [Double], _ side: TransitionSide) -> [Double] {
        guard let l = side.loop else { return times }
        return times.flatMap { t -> [Double] in
            if t < l.start - 1e-6 { return [t] }
            if t < l.start + l.length - 1e-6 { return (0...l.repeats).map { t + Double($0) * l.length } }
            return [t + l.extra]
        }
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
        return Set(side.wiring.keys).union(["out_gain", "ts_rate"]).union(extensions ? TransitionEdit.stemLanes : []).sorted().map { id in
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

    /// Seconds per beat around song time `t`: the median gap of the beats within two bars either side, so a song
    /// that drifts or changes tempo is matched where the transition is, not on its overall BPM.
    private func beatLength(_ s: Entry, around t: Double) -> Double {
        let overall = 60 / Double(max(s.analysis.bpm, 1))
        let near = s.analysis.beats.filter { abs($0 - t) <= overall * 8 }
        let gaps = zip(near.dropFirst(), near).map { $0 - $1 }.sorted()
        return gaps.isEmpty ? overall : gaps[gaps.count / 2]
    }

    private func hold(_ v: Double, _ length: Double) -> [TransitionEdit.Point] {
        [.init(offset: 0, value: v, curve: "linear"), .init(offset: length, value: v, curve: "linear")]
    }

    /// Makes the edit a blank beat-matched transition where its sides are now: both songs at full volume, every lane
    /// that moves held at rest, and a tempo match drawn from the two beat grids.
    ///
    /// The planner's own tempo lanes can't be kept. They are worked out for where it put the sides, so moving a side
    /// to a part of the song at another tempo, or starting from a style that doesn't beat-match at all, leaves the
    /// songs apart (Run It Up → Girl Like Me came out about 10% apart). Here both songs follow one tempo that runs
    /// from the outgoing song's to the incoming's across the window, as Apple's beat-matched styles do, with the
    /// incoming song's tempo halved or doubled first when that brings it closer. Each side's length follows from
    /// that, so the incoming side gets its own.
    private func blank(_ edit: inout TransitionEdit, _ a: Entry, _ b: Entry, _ base: TransitionPlan) {
        (edit.outgoing, edit.incoming) = ([:], [:])
        (edit.incomingLengthScale, edit.outgoingTail, edit.outgoingLoop, edit.incomingLoop) = (nil, 0, nil, nil)
        let placed = base.applying(edit)
        let out = placed.outgoing.end - placed.outgoing.start
        let from = 1 / beatLength(a, around: placed.outgoing.start + out / 2)
        var to = 1 / beatLength(b, around: placed.incoming.start + out / 2)
        while to / from > 1.42 { to /= 2 }
        while to / from < 0.705 { to *= 2 }
        let duration = out * 2 * from / (from + to), inc = duration * (from + to) / (2 * to)
        let baseIn = base.incoming.end - base.incoming.start
        if baseIn > 0 { edit.incomingLengthScale = inc / baseIn }
        let steps = 8
        for outgoing in [true, false] {
            let own = outgoing ? from : to
            edit.setLane(outgoing, "ts_rate", (0...steps).map { k in
                let t = duration * Double(k) / Double(steps)
                // Song time covered by clock time t at the shared tempo, and the rate that plays it at that tempo.
                return .init(offset: (from * t + (to - from) * t * t / (2 * duration)) / own,
                             value: (from + (to - from) * t / duration) / own, curve: "linear")
            })
            let side = outgoing ? base.outgoing : base.incoming, length = outgoing ? out : inc
            for auto in side.automations.values where auto.moves && auto.id != "ts_rate" && auto.id != "bypa" {
                edit.setLane(outgoing, auto.id, hold(side.neutralValue(auto.id), length))
            }
            // Effects on but at rest, which passes the song through, so lanes drawn later are heard. Held past the
            // window for a tail.
            edit.setLane(outgoing, "bypa", hold(0, length))
        }
    }

    /// Draws an exit or entry move over a blank transition. Offsets are song seconds on that side; `length` is the
    /// side's, `beat` and `bar` the song's around it, `tail` what follows the window.
    private func draw(_ move: String, outgoing: Bool, on edit: inout TransitionEdit, side: TransitionSide, length: Double,
                      beat: Double, tail: Double) throws {
        func need(_ codes: String...) throws {
            guard codes.allSatisfy({ side.wiring[$0] != nil }) else { throw PlannerError("this transition's graph has no effect for \(move); try another style as the starting point") }
        }
        func set(_ id: String, _ points: [(Double, Double, String)]) {
            edit.setLane(outgoing, id, points.map { .init(offset: $0.0, value: $0.1, curve: $0.2) })
        }
        let end = length + tail, snap = 0.02   // a switch takes 20 ms, short enough to hear as a cut without clicking
        switch move {
        case "cut", "full": break
        case "fade": set("out_gain", [(0, 1, "linear"), (length, 0, "linear")])
        case "fade_in": set("out_gain", [(0, 0, "linear"), (length, 1, "linear")])
        case "drop_in": set("out_gain", [(0, 0, "linear"), (length - snap, 0, "linear"), (length, 1, "linear")])
        case "filter_fade":
            try need("LP1f")
            set("LP1f", [(0, 22000, "easedOut"), (length, 200, "linear")])
            set("out_gain", [(0, 1, "linear"), (length - 0.3, 1, "linear"), (length, 0, "linear")])
        case "filter_rise":
            try need("HP1f")
            set("HP1f", [(0, 10, "easedIn"), (length, 2500, "linear")])
            set("out_gain", [(0, 1, "linear"), (length - 0.3, 1, "linear"), (length, 0, "linear")])
        case "filter_in":
            try need("HP1f")
            set("HP1f", [(0, 2500, "easedOut"), (length, 10, "linear")])
        case "echo_out":
            // The graph's echo branch: Ga2g sends into the delay, Ga4g returns it, Ga3g is the dry signal. The
            // return opens over the last beat, then the dry signal and the send close together, so the delay is
            // left repeating that beat.
            try need("Ga2g", "Ga3g", "Ga4g", "DLdt", "DLfb", "DLdw")
            for (id, v) in [("DLdt", min(2, beat)), ("DLfb", 55), ("DLdw", 100), ("DLlf", 3000)] where side.wiring[id] != nil { set(id, [(0, v, "linear"), (end, v, "linear")]) }
            set("Ga4g", [(0, 0, "linear"), (length - beat, 0, "linear"), (length, 1, "linear"), (end, 1, "linear")])
            set("Ga3g", [(0, 1, "linear"), (length, 1, "linear"), (length + snap, 0, "linear"), (end, 0, "linear")])
            set("Ga2g", [(0, 1, "linear"), (length, 1, "linear"), (length + snap, 0, "linear"), (end, 0, "linear")])
            set("out_gain", [(0, 1, "linear"), (length + tail / 2, 1, "linear"), (end, 0, "linear")])
        default: throw PlannerError("unknown move \(move)")
        }
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

        // Where the sides are, before how long they are: the length is counted in bars where the side now is.
        if let bars = number(args["outgoing_shift_bars"]) { edit.outgoingShift = shift(a, from: base.outgoing.start, bars: Int(bars)) }
        if let bars = number(args["incoming_shift_bars"]) { edit.incomingShift = shift(b, from: base.incoming.start, bars: Int(bars)) }
        if let seconds = number(args["outgoing_shift_seconds"]) { edit.outgoingShift = seconds }
        if let seconds = number(args["incoming_shift_seconds"]) { edit.incomingShift = seconds }
        if let start = number(args["outgoing_start"]) { edit.outgoingShift = start - base.outgoing.start }
        if let start = number(args["incoming_start"]) { edit.incomingShift = start - base.incoming.start }
        if let bars = number(args["length_bars"]) {
            guard bars > 0 else { throw PlannerError("length_bars must be above 0") }
            // Measured against the plan's length at the side's new place. Against the bars where Apple planned it,
            // a side moved to a slower part of the song came back short (4 bars asked, 3.5 given).
            let span = base.outgoing.end - base.outgoing.start
            let moved = base.outgoing.applying(shift: edit.outgoingShift, lanes: [:])
            guard span > 0 else { throw PlannerError("this plan has no length to scale") }
            edit.setLengthScale(bars * barLength(a, TransitionSide(start: moved.start, end: moved.start + bars * barLength(a, moved), automations: [:], wiring: [:])) / span)
        }

        let exit = args["exit"] as? String, entry = args["entry"] as? String
        if let exit, !Self.exits.contains(where: { $0.0 == exit }) { throw PlannerError("exit must be one of: \(Self.exits.map(\.0).joined(separator: ", "))") }
        if let entry, !Self.entries.contains(where: { $0.0 == entry }) { throw PlannerError("entry must be one of: \(Self.entries.map(\.0).joined(separator: ", "))") }
        var technique = moves[key]
        if args["blank"] as? Bool == true || exit != nil || entry != nil {
            blank(&edit, a, b, base)
            technique = nil
        }

        func refuse(_ what: String) -> PlannerError { PlannerError("\(what) is beyond Apple's AutoMix, and this server is running without extensions") }
        if let bars = number(args["outgoing_tail_bars"]) {
            guard extensions else { throw refuse("an outgoing tail") }
            guard bars >= 0 else { throw PlannerError("outgoing_tail_bars can't be negative") }
            // The renderer has three slots for songs; a tail long enough to still be playing when the song after
            // next loads would be cut off, and a minute is far short of that.
            edit.outgoingTail = min(60, bars * barLength(a, base.applying(edit).outgoing))
        }
        for outgoing in [true, false] {
            let name = outgoing ? "outgoing_loop" : "incoming_loop"
            guard let value = args[name] else { continue }
            guard extensions else { throw refuse("a loop") }
            if value is NSNull {
                if outgoing { edit.outgoingLoop = nil } else { edit.incomingLoop = nil }
                continue
            }
            guard let l = value as? [String: Any], let start = number(l["start"]), let bars = number(l["bars"]), let repeats = number(l["repeats"]),
                  bars > 0, repeats >= 1 else { throw PlannerError("\(name) needs start, bars above 0 and repeats of 1 or more, or null") }
            let song = outgoing ? a : b
            var unlooped = edit
            (unlooped.outgoingLoop, unlooped.incomingLoop, unlooped.outgoingTail) = (nil, nil, 0)
            let placed = base.applying(unlooped), side = outgoing ? placed.outgoing : placed.incoming
            // Measured on the beat grid from the nearest beat, so the repeat is a whole number of beats.
            let beats = song.analysis.beats, count = max(1, Int((bars * 4).rounded()))
            guard let i = beats.indices.min(by: { abs(beats[$0] - start) < abs(beats[$1] - start) }), i + count < beats.count else {
                throw PlannerError("\(name): no beats to loop at \(start)")
            }
            let length = beats[i + count] - beats[i]
            guard start >= side.start - 0.05, start + length <= side.end + 0.05 else {
                throw PlannerError("\(name): the stretch \(start) to \(start + length) must lie inside that song's side of the transition, \(side.start) to \(side.end)")
            }
            let loop = SongLoop(start: start - side.start, length: length, repeats: Int(repeats))
            if outgoing { edit.outgoingLoop = loop } else { edit.incomingLoop = loop }
        }

        if exit != nil || entry != nil {
            let exit = exit ?? "cut", entry = entry ?? "full"
            let tailBars = Self.exits.first { $0.0 == exit }!.tail
            if tailBars > 0 {
                guard extensions else { throw refuse("\(exit), which needs an outgoing tail,") }
                if edit.outgoingTail == 0 { edit.outgoingTail = tailBars * barLength(a, base.applying(edit).outgoing) }
            }
            let placed = base.applying(edit)
            let out = placed.outgoing.end - edit.outgoingTail - placed.outgoing.start
            try draw(exit, outgoing: true, on: &edit, side: base.outgoing, length: out,
                     beat: beatLength(a, around: placed.outgoing.start + out), tail: edit.outgoingTail)
            let inc = placed.incoming.end - placed.incoming.start
            try draw(entry, outgoing: false, on: &edit, side: base.incoming, length: inc, beat: beatLength(b, around: placed.incoming.start), tail: 0)
            technique = "\(exit) + \(entry)"
        }

        let placed = base.applying(edit)   // where the sides are now, for points given on the mix clock
        for outgoing in [true, false] {
            let name = outgoing ? "outgoing_lanes" : "incoming_lanes"
            guard let lanes = args[name] as? [String: Any] else { continue }
            let side = outgoing ? base.outgoing : base.incoming
            let current = outgoing ? placed.outgoing : placed.incoming
            for (id, value) in lanes {
                if TransitionEdit.stemLanes.contains(id) {
                    guard extensions else { throw refuse("a stem lane") }
                    let song = outgoing ? a : b
                    guard AudioSource.isStem(URL(fileURLWithPath: song.path)) else { throw PlannerError("\(name): \(song.title) is not a stem file, so it has no \(id)") }
                } else {
                    guard side.wiring[id] != nil || side.automations[id] != nil || ["out_gain", "ts_rate", "bypa"].contains(id) else {
                        throw PlannerError("\(name): \(id) is not a parameter of this transition; see list_parameters")
                    }
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
        moves[key] = technique
    }

    // MARK: Rendering

    private func outputURL(_ path: String?) -> URL {
        if let path { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return AppPaths.cacheDir("mcp").appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// A song as the renderer plays it. Its stems are extracted only if one of its sides sets a stem's level: the
    /// sum of the stems is not the mixdown sample for sample, so a song nobody remixes plays the mixdown, as it does
    /// in the app.
    private func item(_ s: Entry, entering: TransitionSide?, leaving: TransitionSide?, soundCheck: Bool) async throws -> MixRenderer.Item {
        let remixed = [entering, leaving].contains { side in TransitionEdit.stemLanes.contains { side?.automations[$0] != nil } }
        return MixRenderer.Item(audio: s.playable, beats: s.analysis.beats, entering: entering, leaving: leaving,
                                gain: soundCheck ? s.analysis.loudness?.gain ?? 1 : 1,
                                loops: [entering?.loop, leaving?.loop].compactMap { $0 },
                                stems: remixed ? try await AudioSource.stemURLs(for: URL(fileURLWithPath: s.path)) : [])
    }

    private func renderTransition(_ a: Entry, _ b: Entry, margin: Double, out: String?, soundCheck: Bool) async throws -> [String: Any] {
        let plan = try plan(a, b)
        let items = [try await item(a, entering: nil, leaving: plan.outgoing, soundCheck: soundCheck),
                     try await item(b, entering: plan.incoming, leaving: nil, soundCheck: soundCheck)]
        let url = outputURL(out), start = max(0, plan.outgoing.start - margin)
        let seconds = try MixRenderer.render(items, startTime: start, tail: margin, to: url)
        var json: [String: Any] = ["path": url.path, "seconds": r(seconds), "transition_starts_at": r(plan.outgoing.start - start),
                                   "transition_duration": r(plan.duration)]
        let levels = levels(url)
        json["level_db_per_second"] = levels.seconds
        json.merge(levels.summary) { a, _ in a }
        return json
    }

    /// The render's level each second (RMS over both channels), its peak and how many samples sit at full scale, in
    /// dB below full scale. Not loudness as LUFS measures it, but enough to see a dip, a jump or a hole across a
    /// transition, and whether two songs at full volume are being held down by the renderer's limiter. Read a
    /// second at a time: a 30-minute set is over 600 MB as one buffer.
    private func levels(_ url: URL) -> (seconds: [NSNumber], summary: [String: Any]) {
        guard let file = try? AVAudioFile(forReading: url) else { return ([], [:]) }
        let format = file.processingFormat, second = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: second) else { return ([], [:]) }
        let db = { (x: Double) in x > 0 ? max(20 * log10(x), -100) : -100 }
        var seconds: [NSNumber] = [], peak = 0.0, full = 0
        while file.framePosition < file.length, (try? file.read(into: buffer, frameCount: second)) != nil,
              buffer.frameLength > 0, let data = buffer.floatChannelData {
            var sum = 0.0
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    let x = abs(Double(data[c][i]))
                    sum += x * x
                    peak = max(peak, x)
                    if x >= 0.999 { full += 1 }
                }
            }
            let rms = (sum / Double(Int(buffer.frameLength) * Int(format.channelCount))).squareRoot()
            seconds.append(NSDecimalNumber(string: String(format: "%.1f", db(rms))))
        }
        return (seconds, ["peak_db": r(db(peak)), "samples_at_full_scale": full])
    }

    /// Playing `list` in order: each song's sides as the renderer needs them (nil where planning failed, which plays
    /// as a straight cut) and the timeline that results, worked out from the plans as the renderer plays them.
    ///
    /// Song times here are as played. A loop on the side that brings a song in pushes the rest of that song later,
    /// so the side that takes it out is moved by the same amount.
    private func timeline(_ list: [Entry]) -> (entering: [TransitionSide?], leaving: [TransitionSide?], json: [String: Any]) {
        var entering: [TransitionSide?] = [nil], leaving: [TransitionSide?] = []
        var transitions: [[String: Any]] = [], played: [[String: Any]] = [], techniques: [String] = []
        var clock = 0.0, songTime = 0.0   // the mix clock and the current song's time, at the point reached so far
        var enteredAt = 0.0, enteredFrom = 0.0, pushed = 0.0
        for (a, b) in zip(list, list.dropFirst()) {
            var song: [String: Any] = ["id": a.id, "title": a.title, "enters_at": r(enteredAt), "plays_from": r(enteredFrom)]
            do {
                let plan = try plan(a, b)
                let out = plan.outgoing.retimed(by: pushed)
                // Negative when this transition starts before the one into the song has finished.
                song["alone_seconds"] = r(out.start - songTime)
                song["plays_to"] = r(plan.outgoing.end - (plan.outgoing.loop?.extra ?? 0))
                clock += out.start - songTime
                let technique = technique(a, b, plan)
                transitions.append(["from": a.id, "to": b.id, "technique": technique, "starts_at": r(clock), "duration": r(plan.duration),
                                    "length_bars": r((plan.outgoing.end - (edits[planKey(a, b)]?.outgoingTail ?? 0) - plan.outgoing.start) / barLength(a, plan.outgoing))])
                techniques.append(technique)
                (enteredAt, enteredFrom) = (clock, plan.incoming.start)
                // The clock moves on by the incoming side's length on it, which is when that song is on its own.
                clock += plan.incoming.transitionTime(at: plan.incoming.end)
                (songTime, pushed) = (plan.incoming.end, plan.incoming.loop?.extra ?? 0)
                leaving.append(out)
                entering.append(plan.incoming)
            } catch {
                let end = a.analysis.duration + pushed
                song["alone_seconds"] = r(end - songTime)
                song["plays_to"] = r(a.analysis.duration)
                clock += end - songTime
                transitions.append(["from": a.id, "to": b.id, "technique": "cut", "starts_at": r(clock), "error": String(describing: error)])
                techniques.append("cut")
                (enteredAt, enteredFrom, songTime, pushed) = (clock, 0, 0, 0)
                leaving.append(nil)
                entering.append(nil)
            }
            played.append(song)
        }
        let last = list[list.count - 1], end = last.analysis.duration + pushed
        played.append(["id": last.id, "title": last.title, "enters_at": r(enteredAt), "plays_from": r(enteredFrom),
                       "alone_seconds": r(end - songTime), "plays_to": r(last.analysis.duration)])
        leaving.append(nil)
        clock += end - songTime
        // Three or more of the same technique in a row is what a listener hears as a set repeating itself.
        var runs: [[String: Any]] = [], i = 0
        while i < techniques.count {
            var j = i
            while j + 1 < techniques.count, techniques[j + 1] == techniques[i] { j += 1 }
            if j - i >= 2 { runs.append(["technique": techniques[i], "count": j - i + 1, "first_transition": i + 1]) }
            i = j + 1
        }
        return (entering, leaving, ["seconds": r(clock), "songs": played, "transitions": transitions, "repeated": runs])
    }

    private func renderSet(_ list: [Entry], out: String?, soundCheck: Bool) async throws -> [String: Any] {
        var (entering, leaving, json) = timeline(list)
        var items: [MixRenderer.Item] = []
        for (i, s) in list.enumerated() { items.append(try await item(s, entering: entering[i], leaving: leaving[i], soundCheck: soundCheck)) }
        let url = outputURL(out)
        json["seconds"] = r(try MixRenderer.render(items, startTime: 0, tail: nil, to: url))
        json["path"] = url.path
        let levels = levels(url)
        json.merge(levels.summary) { a, _ in a }
        // The level around each handoff, where an abrupt cut or a hole shows as a sudden drop.
        json["transitions"] = (json["transitions"] as? [[String: Any]] ?? []).map { t -> [String: Any] in
            guard let start = (t["starts_at"] as? NSNumber)?.doubleValue else { return t }
            let from = max(0, Int(start) - 4), to = min(levels.seconds.count, Int(start + ((t["duration"] as? NSNumber)?.doubleValue ?? 0)) + 5)
            var t = t
            if from < to {
                t["levels_from"] = from
                t["level_db_per_second"] = Array(levels.seconds[from..<to])
            }
            return t
        }
        return json
    }

    /// Rounded to the millisecond to keep responses short, and never non-finite, which JSONSerialization can't write.
    /// As a decimal number, because JSONSerialization writes a Double out to 17 digits (268.1 as 268.10000000000002).
    private func r(_ x: Double) -> NSNumber { NSDecimalNumber(string: String(x.isFinite ? (x * 1000).rounded() / 1000 : 0)) }
}
