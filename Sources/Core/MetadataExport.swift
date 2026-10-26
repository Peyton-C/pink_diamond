import AVFoundation
import Foundation

/// `pink diamond --export-metadata <out.json> [files or folders]`: the analysis of a whole crate in one JSON file, for
/// DJ harnesses that run on another app's beat grid to read. The AIDJ comparison gives every competitor the same song
/// metadata, taken from this analysis, and this is the file that carries it. docs/metadata.md lays out the format.
///
/// It goes through the MCP server's songs so that every number is the one `get_song` gives a pink diamond agent: the
/// same sections, loudness, vocal share and stems up and low. It reads the analysis cache and analyzes nothing, since
/// a fresh analysis can come out different on another macOS build, and the export is meant to be made once and
/// frozen. Stem levels are measured where the cache lacks them, as `get_song` measures them: that is decoding the
/// stems and summing their power, which comes out the same every time.
///
/// Nothing in it names the app. Another harness may hand fields straight to its model, and a model shown a server's
/// name picks it as a song: pink diamond is a Charli XCX title.
extension MCPServer {
    /// Bumped whenever a field changes meaning or goes away. Fields added alongside the old ones keep the version.
    static let metadataSchemaVersion = 1

    static func exportMetadata(_ args: [String]) async -> Int32 {
        guard let out = args.first else {
            print("usage: --export-metadata <out.json> [files or folders, ~/Music/Stereo Stems by default]")
            return 2
        }
        let paths = args.count > 1 ? Array(args.dropFirst()) : ["~/Music/Stereo Stems"]
        let server = MCPServer(extensions: true, renders: nil)
        do {
            let data = try await server.metadata(paths: paths)
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try data.write(to: url, options: .atomic)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let skipped = json?["skipped"] as? [[String: Any]] ?? []
            print("wrote \((json?["songs"] as? [Any])?.count ?? 0) songs to \(url.path), skipped \(skipped.count)")
            for s in skipped { print("  skipped \(s["path"] ?? ""): \(s["reason"] ?? "")") }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    /// The export for these files and folders, as the bytes written. Sorted by path with sorted keys and rounded
    /// numbers, so the same crate exports to the same file.
    func metadata(paths: [String]) async throws -> Data {
        var urls: [String: URL] = [:], skipped: [[String: Any]] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                skipped.append(["path": url.path, "reason": "no such file"])
            } else if isDir.boolValue {
                for f in Library.audioFiles(in: url) { urls[f.path] = f }
            } else if Library.audioExtensions.contains(url.pathExtension.lowercased()) {
                urls[url.path] = url
            } else {
                skipped.append(["path": url.path, "reason": "not an audio file"])
            }
        }

        // Read 8 at a time as add_songs reads the cache. A file whose analysis isn't cached under its current
        // `fileKey` is unanalyzed, or was written over since: either way its cached numbers would be wrong.
        var loaded: [String: (Entry, FileTags)] = [:]
        let files = urls.keys.sorted()
        await withTaskGroup(of: (String, Result<(Entry, FileTags)?, Error>).self) { group in
            var next = 0
            func addTask() {
                guard next < files.count, let url = urls[files[next]] else { return }
                next += 1
                group.addTask {
                    do {
                        guard let song = try await Self.load(url, analyze: false) else { return (url.path, .success(nil)) }
                        return (url.path, .success((song, await Self.fileTags(url))))
                    } catch { return (url.path, .failure(error)) }
                }
            }
            for _ in 0..<8 { addTask() }
            for await (path, result) in group {
                switch result {
                case .success(let song?): loaded[path] = song
                case .success(nil): skipped.append(["path": path, "reason": "not analyzed"])
                case .failure(let error): skipped.append(["path": path, "reason": String(describing: error)])
                }
                addTask()
            }
        }
        let songs = files.compactMap { loaded[$0] }

        // One at a time, as get_song measures them. Four decodes at once crashed the process inside CoreMedia's audio
        // queue thread (EXC_BREAKPOINT in AudioQueueConvertToScaledSampleTime) after about 1,000 files, twice.
        let unmeasured = songs.map(\.0).filter { stemSource($0) != nil && stemLevels[$0.id] == nil }
        for (i, song) in unmeasured.enumerated() {
            stemLevels[song.id] = try? await Self.measureStems(song)
            if (i + 1) % 25 == 0 || i + 1 == unmeasured.count {
                FileHandle.standardError.write(Data("stem levels \(i + 1)/\(unmeasured.count)\n".utf8))
            }
        }

        readTags()
        return try metadataDocument(songs, skipped: skipped)
    }

    /// The file's bytes for songs already loaded. Apart from `metadata(paths:)` so tests can give it songs of their own.
    func metadataDocument(_ songs: [(Entry, FileTags)], skipped: [[String: Any]]) throws -> Data {
        let document: [String: Any] = [
            "format": "crate-metadata",
            "schema_version": Self.metadataSchemaVersion,
            "songs": songs.sorted { $0.0.path < $1.0.path }.map { metadata($0.0, $0.1) },
            "skipped": skipped.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") },
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One file's entry. Every position is in seconds from the start of the file.
    func metadata(_ s: Entry, _ file: FileTags) -> [String: Any] {
        let a = s.analysis
        var json: [String: Any] = [
            "path": s.path, "title": s.title, "artist": s.artist, "duration": r(a.duration),
            "bpm": a.bpm, "key": a.key, "beats": a.beats.map(r), "bars": a.bars.map(r),
            "vocals": a.vocals.map { [r($0.lowerBound), r($0.upperBound)] },
        ]
        if let l = a.loudness {
            json["loudness_lufs"] = r(l.integrated)
            json["sound_check_db"] = r(20 * log10(Double(l.gain)))
        }

        let version = Self.version(of: s.title)
        var info: [String: Any] = ["version": s.mashup == nil ? version.type : "mashup"]
        info["version_label"] = version.label
        info["genre"] = file.genre
        info["year"] = s.year
        // The rating atom where the file has one, and else what the title says, as "(Clean)" or "(Dirty)" do.
        info["explicit"] = file.explicit ?? version.explicit
        if let m = s.mashup {
            var mashup: [String: Any] = ["vocals": m.vocals, "beat": m.beat]
            mashup["form"] = m.form
            info["mashup"] = mashup
        }
        json["file_tags"] = info

        // The section the get_song numbering puts in front of the first one found has no start of its own, so a
        // reader looking for downbeats must not take its 0 for one.
        let padded = a.sections.first.map { $0 > 0.5 } ?? true
        json["sections"] = sections(s).enumerated().map { i, span -> [String: Any] in
            let (lo, hi) = span
            var section: [String: Any] = ["n": i + 1, "start": r(lo), "end": r(hi), "detected": !(i == 0 && padded),
                                          "bars": a.bars.filter { $0 >= lo - 0.05 && $0 < hi - 0.05 }.count,
                                          "vocal_share": r(sung(s, from: lo, to: hi))]
            section["loudness_vs_song_db"] = loudness(s, from: lo, to: hi).map(r)
            if let (up, low) = stemsPlaying(s, from: lo, to: hi) {
                section["stems_up"] = up
                section["stems_low"] = low
            }
            return section
        }

        if let source = stemSource(s) {
            let peaks = self.peaks(s), levels = stemLevels[s.id]
            json["stems"] = [
                "source": source.name, "source_rank": source.rank,
                "tracks": AudioSource.stemNames.enumerated().map { k, code -> [String: Any] in
                    let name = s.stemLabels.map { $0[k].isEmpty ? code.capitalized : $0[k] } ?? code.capitalized
                    var track: [String: Any] = ["code": code, "name": name]
                    if let levels, let peaks, levels[k].count == a.beats.count {
                        track["first_entry"] = Self.firstEntry(levels[k], peak: peaks[k]).map { r(a.beats[$0]) } ?? NSNull()
                    }
                    return track
                },
            ] as [String: Any]
        }

        if let tag = judged(s) { json["tags"] = tag }
        return json
    }

    /// The song's tags from tag_songs, which every version of it shares. None for a song the tagger did not know.
    private func judged(_ s: Entry) -> [String: Any]? {
        guard let tag = tags[name(s)] else { return nil }
        var json: [String: Any] = ["mood_clash": tag.moodClash == true]
        json["energy"] = tag.energy
        json["style"] = tag.style
        json["lyrics"] = tag.lyrics
        return json
    }

    /// The beat a stem first comes in on, as an index into the song's beats, from its level over each beat. It comes
    /// in where it first reaches 18 dB under its loudest section, the level `plays` starts calling it low at, and
    /// plays at that level on at least half of the two bars from there. The half lets in a part that hits every
    /// other beat, and keeps out a lone hit: a riser or a stick click in a drumless intro. Against the stem's own
    /// peak, so bleed in a separation stays out: Take It Off's drums sit at -85 dB under its intro vocals and come
    /// in at -16 dB on beat 20, the second section's start.
    static func firstEntry(_ levels: [Double], peak: Double) -> Int? {
        guard peak > -50 else { return nil }   // as in `plays`, a stem the song barely has never comes in
        let floor = peak - 18
        for i in levels.indices where levels[i] >= floor {
            let window = levels[i..<min(i + 8, levels.count)]
            if window.filter({ $0 >= floor }).count * 2 >= min(8, window.count) { return i }
        }
        return nil
    }

    /// What `metadata` reads from a file beyond what `load` keeps: its genre tag as written, and whether its
    /// rating atom marks it explicit or clean.
    struct FileTags {
        var genre: String?
        var explicit: Bool?
    }

    static func fileTags(_ url: URL) async -> FileTags {
        var tags = FileTags()
        let genres: [AVMetadataIdentifier] = [.iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre]
        for item in (try? await AVURLAsset(url: url).load(.metadata)) ?? [] {
            guard let identifier = item.identifier else { continue }
            if genres.contains(identifier), tags.genre == nil, let value = try? await item.load(.stringValue), !value.isEmpty { tags.genre = value }
            // iTunes' rtng: 1 and 4 explicit, 2 clean, 0 not rated.
            if identifier == .iTunesMetadataContentRating, let value = try? await item.load(.numberValue)?.intValue {
                tags.explicit = value == 1 || value == 4 ? true : value == 2 ? false : nil
            }
        }
        return tags
    }

    /// What kind of version a title names, from the words in its brackets after the stem marker is taken off: its
    /// type, the words as written, and whether they say it is clean or explicit. A title with no such words is the
    /// original. "(feat. SZA)" and "(From Barbie The Album)" are credits and not versions. A Select Mix Remix is an
    /// extended intro and outro edit of the original, not a remix, and an Intro Edit is the same thing from Promo Only.
    static func version(of title: String) -> (type: String, label: String?, explicit: Bool?) {
        let name = StemSource.split(title).name
        let groups = name.matches(of: #/[\(\[]([^\(\)\[\]]*)[\)\]]/#).map { String($0.output.1) }
        let credits = ["feat", "ft.", "ft ", "with ", "from ", "prod"]
        let words = groups.flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { w in !w.isEmpty && !credits.contains { w.lowercased().hasPrefix($0) } }
        let lower = words.map { $0.lowercased() }
        var explicit: Bool?
        if lower.contains(where: { $0.contains("dirty") || $0.contains("explicit") }) { explicit = true }
        if lower.contains(where: { $0.contains("clean") }) { explicit = false }
        let label = words.isEmpty ? nil : words.joined(separator: "; ")
        func has(_ any: String...) -> Bool { lower.contains { w in any.contains { w.contains($0) } } }
        let type: String
        if has("acapella", "a cappella", "acappella") { type = "acapella" }
        else if has("instrumental") { type = "instrumental" }
        else if has("select mix remix", "select_mix_remix", "extended", "xtend", "intro") { type = "extended" }
        else if has("remix", "mix", "rework", "bootleg", "vip") { type = "remix" }
        else if has("edit") { type = "edit" }
        else if lower.contains(where: { $0 == "live" || $0.hasPrefix("live ") }) { type = "live" }
        else if lower.allSatisfy({ w in ["clean", "dirty", "explicit", "remaster", "deluxe", "edition", "album version", "main version", "original"].contains { w.contains($0) } }) { type = "original" }
        else { type = "other" }
        return (type, label, explicit)
    }
}
