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
             "description": "Automation lanes to replace or add on the \(side) song, by parameter code. Each is a list of points, offset in song seconds from the start of that song's side of the transition. null puts a lane back as planned. Set these in the same call as length_bars or after it, since changing the length stretches them",
             "additionalProperties": [
                "type": ["array", "null"],
                "items": ["type": "object",
                          "properties": ["offset": ["type": "number"], "value": ["type": "number"],
                                         "curve": ["type": "string", "enum": curves] as [String: Any]],
                          "required": ["offset", "value"]] as [String: Any],
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
        return [
            tool("add_songs", "Add audio files, Native Instruments stem files or folders, and analyze them. The first analysis of a song takes a few seconds; later ones come from the cache. Returns every song added with its id.",
                 ["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths"] as [String: Any]], required: ["paths"]),
            tool("list_songs", "Every song added this session: id, title, artist, genre, BPM, key and length."),
            tool("get_song", "A song's analysis: bars, sections and vocal ranges in song seconds, and its loudness.",
                 ["song": string("Song id"), "beats": ["type": "boolean", "description": "Include every beat time"] as [String: Any]], required: ["song"]),
            tool("set_genre", "Set a song's genre. Genres decide which transition styles Apple's planner can pick, and an edit belongs to the genres it was made with.",
                 ["song": string("Song id"), "genre": genre], required: ["song", "genre"]),
            tool("get_transition", "The planned transition between two songs with any edits applied: style, length, where each song's side starts and ends in song seconds, the handoff point, and every automation lane.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("list_variants", "The other plans Apple's planner makes for the pair: as other genres, or with lower complexity. Takes about a second.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("list_parameters", "Every parameter of the transition's effect graph that a lane can automate: code, name, range and the value it rests at.",
                 ["from": from, "to": to], required: ["from", "to"]),
            tool("edit_transition", "Change a transition. Only the fields given change; the rest of the edit is kept. Returns the transition as get_transition does.",
                 ["from": from, "to": to, "variant": variant,
                  "length_bars": number("The transition's length in the outgoing song's bars. Both songs stretch together and stay beat-matched"),
                  "outgoing_shift_bars": integer("Bars to move the outgoing song's side from where Apple planned it. Positive is later in the song"),
                  "incoming_shift_bars": integer("Bars to move the incoming song's side from where Apple planned it. Positive is later in the song"),
                  "outgoing_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "incoming_shift_seconds": number("The same move in song seconds, for moves off the bar grid"),
                  "outgoing_lanes": lanes("outgoing"), "incoming_lanes": lanes("incoming"), "add_effects": effects],
                 required: ["from", "to"]),
            tool("reset_transition", "Drop every edit to a transition and go back to Apple's plan.", ["from": from, "to": to], required: ["from", "to"]),
            tool("render_transition", "Render one transition to a WAV, with some of each song either side of it.",
                 ["from": from, "to": to, "out": out, "margin": number("Seconds of each song around the transition. Defaults to 15")], required: ["from", "to"]),
            tool("render_set", "Render songs in order, with every transition, to one WAV. Returns where each transition starts in the mix. A transition that can't be planned becomes a straight cut.",
                 ["songs": ["type": "array", "items": ["type": "string"], "description": "Song ids in playing order"] as [String: Any], "out": out], required: ["songs"]),
        ]
    }()

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "add_songs":
            guard let paths = args["paths"] as? [String] else { throw PlannerError("paths must be a list of file or folder paths") }
            return await add(paths)
        case "list_songs":
            return songs.map(summary)
        case "get_song":
            return songDetail(try entry(args["song"]), beats: args["beats"] as? Bool ?? false)
        case "set_genre":
            let id = try entry(args["song"]).id
            guard let genre = (args["genre"] as? String).flatMap(Genre.init(rawValue:)) else {
                throw PlannerError("genre must be one of: \(Genre.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let i = songs.firstIndex { $0.id == id }!
            songs[i].genre = genre
            return summary(songs[i])
        case "get_transition":
            let (a, b) = try pair(args)
            return try describe(a, b)
        case "list_variants":
            let (a, b) = try pair(args)
            return variants(a, b)
        case "list_parameters":
            let (a, b) = try pair(args)
            return parameters(try plan(a, b))
        case "edit_transition":
            let (a, b) = try pair(args)
            try edit(a, b, args)
            return try describe(a, b)
        case "reset_transition":
            let (a, b) = try pair(args)
            edits[planKey(a, b)] = nil
            return try describe(a, b)
        case "render_transition":
            let (a, b) = try pair(args)
            return try renderTransition(a, b, margin: number(args["margin"]) ?? 15, out: args["out"] as? String)
        case "render_set":
            guard let ids = args["songs"] as? [String], !ids.isEmpty else { throw PlannerError("songs must be a list of song ids") }
            return try renderSet(try ids.map { try entry($0) }, out: args["out"] as? String)
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
                let analysis: SongAnalysis
                if let cached = (try? Data(contentsOf: cache)).flatMap({ try? JSONDecoder().decode(SongAnalysis.self, from: $0) }) {
                    analysis = cached
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
        return ["songs": added, "failed": failed]
    }

    private func summary(_ s: Entry) -> [String: Any] {
        ["id": s.id, "title": s.title, "artist": s.artist, "path": s.path, "genre": s.genre.rawValue,
         "bpm": s.analysis.bpm, "key": s.analysis.key, "duration": r(s.analysis.duration)]
    }

    private func songDetail(_ s: Entry, beats: Bool) -> [String: Any] {
        var detail = summary(s)
        let a = s.analysis
        detail["bars"] = a.bars.map(r)
        detail["sections"] = a.sections.map(r)
        detail["vocals"] = a.vocals.map { [r($0.lowerBound), r($0.upperBound)] }
        detail["beat_count"] = a.beats.count
        if beats { detail["beats"] = a.beats.map(r) }
        let attributes = ((try? JSONSerialization.jsonObject(with: a.audioAnalysisJSON)) as? [String: Any])?["attributes"] as? [String: Any]
        if let loudness = ((attributes?["loudness"] as? [String: Any])?["main"] as? [String: Any])?["value"] as? Double {
            detail["loudness_lufs"] = r(loudness)
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
    private func variants(_ a: Entry, _ b: Entry) -> [[String: Any]] {
        var all: [PlanVariant?] = [nil]
        all += Genre.allCases.filter { $0 != a.genre || $0 != b.genre }.map { PlanVariant(fromGenre: $0, toGenre: $0) }
        all += PlanVariant.Complexity.allCases.map { PlanVariant(fromGenre: a.genre, toGenre: b.genre, complexity: $0) }
        var seen = Set<String>(), list: [[String: Any]] = []
        for v in all {
            guard let plan = try? basePlan(a, b, variant: v) else { continue }
            let signature = String(format: "%@%d|%.1f|%.1f|%.1f", plan.algorithm, plan.styleID ?? -1, plan.outgoing.start,
                                   plan.incoming.start, plan.duration)
            guard seen.insert(signature).inserted else { continue }
            list.append(["variant": variantJSON(v), "style": plan.styleName, "duration": r(plan.duration),
                         "outgoing_start": r(plan.outgoing.start), "incoming_start": r(plan.incoming.start),
                         "effects": plan.effectSummary])
        }
        return list
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

    private func describe(_ a: Entry, _ b: Entry) throws -> [String: Any] {
        let edit = edits[planKey(a, b)] ?? TransitionEdit()
        let plan = try plan(a, b)
        func side(_ s: TransitionSide, shift: Double) -> [String: Any] {
            let lanes = s.automations.values.sorted { $0.id < $1.id }.map { auto -> [String: Any] in
                var lane: [String: Any] = ["id": auto.id, "name": EffectCatalog.name(auto.id), "moves": auto.moves,
                                           "points": s.editPoints(auto.id).map { ["offset": r($0.offset), "value": r($0.value), "curve": $0.curve] }]
                if let range = range(s, auto.id) { lane["range"] = [r(range.lowerBound), r(range.upperBound)] }
                return lane
            }
            let addable = EffectPreset.all.filter { p in p.requires.allSatisfy { s.wiring[$0] != nil } && s.automations[p.id]?.moves != true }
            return ["start": r(s.start), "end": r(s.end), "shift_seconds": r(shift), "lanes": lanes,
                    "addable_effects": addable.map { ["effect": $0.id, "name": $0.name] }]
        }
        return ["from": a.id, "to": b.id, "style": plan.styleName, "style_id": plan.styleID ?? -1,
                "duration": r(plan.duration), "handoff": r(plan.pivot),
                "length_bars": r((plan.outgoing.end - plan.outgoing.start) / barLength(a, plan.outgoing)),
                "effects": plan.effectSummary, "edited": !edit.isEmpty, "variant": variantJSON(edit.variant),
                "outgoing": side(plan.outgoing, shift: edit.outgoingShift),
                "incoming": side(plan.incoming, shift: edit.incomingShift)]
    }

    private func parameters(_ plan: TransitionPlan) -> [[String: Any]] {
        let side = plan.outgoing   // both sides are wired by the same graph
        return Set(side.wiring.keys).union(["out_gain", "ts_rate"]).sorted().map { id in
            var p: [String: Any] = ["id": id, "name": EffectCatalog.name(id), "rest": r(side.neutralValue(id))]
            if let range = range(side, id) { p["range"] = [r(range.lowerBound), r(range.upperBound)] }
            if EffectCatalog.isStepped(id) { p["whole_values"] = true }
            return p
        }
    }

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
        for outgoing in [true, false] {
            let name = outgoing ? "outgoing_lanes" : "incoming_lanes"
            guard let lanes = args[name] as? [String: Any] else { continue }
            let side = outgoing ? base.outgoing : base.incoming
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
                    guard let offset = number(p["offset"]), let v = number(p["value"]), offset.isFinite, v.isFinite else {
                        throw PlannerError("\(name).\(id): every point needs a numeric offset and value")
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

    private func renderTransition(_ a: Entry, _ b: Entry, margin: Double, out: String?) throws -> [String: Any] {
        let plan = try plan(a, b)
        let items = [MixRenderer.Item(audio: a.playable, beats: a.analysis.beats, entering: nil, leaving: plan.outgoing),
                     MixRenderer.Item(audio: b.playable, beats: b.analysis.beats, entering: plan.incoming, leaving: nil)]
        let url = outputURL(out), start = max(0, plan.outgoing.start - margin)
        let seconds = try MixRenderer.render(items, startTime: start, tail: margin, to: url)
        return ["path": url.path, "seconds": r(seconds), "transition_starts_at": r(plan.outgoing.start - start),
                "transition_duration": r(plan.duration)]
    }

    private func renderSet(_ list: [Entry], out: String?) throws -> [String: Any] {
        var plans: [TransitionPlan?] = [], transitions: [[String: Any]] = []
        var clock = 0.0, songTime = 0.0   // the mix clock and the current song's time, at the point reached so far
        for (a, b) in zip(list, list.dropFirst()) {
            do {
                let plan = try plan(a, b)
                clock += plan.outgoing.start - songTime
                transitions.append(["from": a.id, "to": b.id, "style": plan.styleName, "starts_at": r(clock), "duration": r(plan.duration)])
                clock += plan.duration
                songTime = plan.incoming.end
                plans.append(plan)
            } catch {
                clock += a.analysis.duration - songTime
                transitions.append(["from": a.id, "to": b.id, "starts_at": r(clock), "error": String(describing: error)])
                songTime = 0
                plans.append(nil)
            }
        }
        let items = list.enumerated().map { i, s in
            MixRenderer.Item(audio: s.playable, beats: s.analysis.beats, entering: i > 0 ? plans[i - 1]?.incoming : nil,
                             leaving: i < plans.count ? plans[i]?.outgoing : nil)
        }
        let url = outputURL(out)
        let seconds = try MixRenderer.render(items, startTime: 0, tail: nil, to: url)
        return ["path": url.path, "seconds": r(seconds), "transitions": transitions]
    }

    /// Rounded to the millisecond to keep responses short, and never non-finite, which JSONSerialization can't write.
    /// As a decimal number, because JSONSerialization writes a Double out to 17 digits (268.1 as 268.10000000000002).
    private func r(_ x: Double) -> NSNumber { NSDecimalNumber(string: String(x.isFinite ? (x * 1000).rounded() / 1000 : 0)) }
}
