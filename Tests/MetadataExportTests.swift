import Foundation

/// `./bundle.sh --test`: Core's tests, compiled with Core and without the UI. They run on made-up songs, and on two
/// files from the stem library when the machine has them analyzed.
@main
enum Tests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        guard !ok else { return }
        failures += 1
        FileHandle.standardError.write(Data("FAIL \(file):\(line): \(what)\n".utf8))
    }

    static func main() async {
        firstEntry()
        version()
        document()
        await library()
        FileHandle.standardError.write(Data((failures == 0 ? "all tests passed\n" : "\(failures) failed\n").utf8))
        exit(failures == 0 ? 0 : 1)
    }

    static func firstEntry() {
        let silent = [Double](repeating: -85, count: 20)
        // Take It Off: nothing under the intro vocals, then the drums on beat 20.
        check(MCPServer.firstEntry(silent + [Double](repeating: -16, count: 40), peak: -16) == 20, "drums after a silent intro")
        // A lone hit in the intro is not the entry.
        var hit = silent + [Double](repeating: -16, count: 40)
        hit[5] = -10
        check(MCPServer.firstEntry(hit, peak: -16) == 20, "a lone hit is not an entry")
        // A part on every other beat comes in on its first.
        let offbeat = (0..<32).map { $0 % 2 == 0 ? -20.0 : -60 }
        check(MCPServer.firstEntry(offbeat, peak: -20) == 0, "a part on every other beat")
        // Bleed 25 dB under the stem's peak is not the stem.
        check(MCPServer.firstEntry([Double](repeating: -40, count: 16) + [Double](repeating: -15, count: 16), peak: -15) == 16, "bleed")
        check(MCPServer.firstEntry([Double](repeating: -60, count: 32), peak: -60) == nil, "a stem the song barely has")
        check(MCPServer.firstEntry([], peak: -10) == nil, "no beats")
    }

    static func version() {
        func is_(_ title: String, _ type: String, _ label: String?, _ explicit: Bool? = nil) {
            let v = MCPServer.version(of: title)
            check(v.type == type && v.label == label && v.explicit == explicit, "\(title): \(v)")
        }
        is_("Flashing Lights (RF)", "original", nil)
        is_("Flashing Lights (Select Mix Remix) (RF)", "extended", "Select Mix Remix")
        is_("Cheap Thrills (feat. Sean Paul) (FN)", "original", nil)
        is_("Dance The Night (From Barbie The Album)", "original", nil)
        is_("Toxic (Promo Only Quick Edit; Clean)", "edit", "Promo Only Quick Edit; Clean", false)
        is_("Toxic (Promo Only Intro Edit)", "extended", "Promo Only Intro Edit")
        is_("Gimme More (Ultimix by Stacy Mier; Dirty)", "remix", "Ultimix by Stacy Mier; Dirty", true)
        is_("Levitating (Clean)", "original", "Clean", false)
        is_("All Too Well (Taylor's Version)", "other", "Taylor's Version")
        is_("Flowers (Instrumental) (RF AT)", "instrumental", "Instrumental")
    }

    /// A made-up song the way the cache holds one: four beats a bar at 120 BPM, a section at bar 4 and one at bar 12.
    static func song(_ id: String, _ path: String, title: String, artist: String, sectionsAt: [Double] = [8, 24]) -> MCPServer.Entry {
        let beats = (0..<64).map { Double($0) * 0.5 }
        let curve = (0..<64).map { $0 < 16 ? -20.0 : -10 }   // half-second points from 0.5 s: quiet before section 1
        let audio = try! JSONSerialization.data(withJSONObject: ["attributes": ["loudnessCurve": ["value": curve]]])
        let analysis = SongAnalysis(duration: 32, bpm: 120, key: "A minor", beats: beats, bars: stride(from: 0, to: 32, by: 2).map { $0 },
                                    sections: sectionsAt, vocals: [12...20], audioAnalysisJSON: audio, flexAnalysisJSON: Data(),
                                    waveform: Waveform(), loudness: Loudness(integrated: -10, peak: 0.9))
        return MCPServer.Entry(id: id, path: path, title: title, artist: artist, analysis: analysis)
    }

    static func document() {
        let server = MCPServer(extensions: true, renders: nil)
        let stem = song("b", "/crate/b/Song (RF).stem.mp4", title: "Song (RF)", artist: "Artist")
        let plain = song("a", "/crate/a/Other Song.m4a", title: "Other Song", artist: "Someone")
        // Drums in at the second section (beat 16), vocals at the third (beat 48), the rest from the top.
        server.stemLevels[stem.id] = [
            [Double](repeating: -90, count: 16) + [Double](repeating: -12, count: 48),
            [Double](repeating: -15, count: 64),
            [Double](repeating: -18, count: 64),
            [Double](repeating: -90, count: 48) + [Double](repeating: -14, count: 16),
        ]
        server.tags = [server.name(stem): MCPServer.Tag(energy: 6, style: "synth-pop", lyrics: "leaving", moodClash: nil)]
        let songs = [(stem, MCPServer.FileTags(genre: "Pop", explicit: nil)), (plain, MCPServer.FileTags())]
        let skipped: [[String: Any]] = [["path": "/crate/c.m4a", "reason": "not analyzed"]]
        guard let data = try? server.metadataDocument(songs, skipped: skipped),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return check(false, "the document serializes")
        }
        check((try? server.metadataDocument(Array(songs.reversed()), skipped: skipped)) == data, "the same songs in any order give the same bytes")
        check(json["schema_version"] as? Int == MCPServer.metadataSchemaVersion && json["format"] as? String == "crate-metadata", "format and version")
        check((json["skipped"] as? [[String: Any]])?.first?["reason"] as? String == "not analyzed", "skipped songs are listed")
        let list = json["songs"] as? [[String: Any]] ?? []
        check(list.map { $0["path"] as? String ?? "" } == ["/crate/a/Other Song.m4a", "/crate/b/Song (RF).stem.mp4"], "sorted by path")
        guard list.count == 2 else { return }
        let (a, b) = (list[0], list[1])

        check(a["stems"] == nil && a["tags"] == nil, "no stems or tags for a plain, untagged file")
        let sections = b["sections"] as? [[String: Any]] ?? []
        check(sections.map { ($0["start"] as? NSNumber)?.doubleValue ?? -1 } == [0, 8, 24], "sections from the top, in seconds")
        check(sections.map { $0["detected"] as? Bool ?? true } == [false, true, true], "the section put in front is not detected")
        check(sections[1]["stems_up"] as? [String] == ["drums", "bass", "other"] && sections[1]["stems_low"] as? [String] == [], "stems up and low")
        check((sections[1]["vocal_share"] as? NSNumber)?.doubleValue == 0.5, "vocal share")
        let entries = ((b["stems"] as? [String: Any])?["tracks"] as? [[String: Any]] ?? []).map { ($0["first_entry"] as? NSNumber)?.doubleValue }
        check(entries == [8, 0, 0, 24], "first entries in seconds: \(entries)")
        check((b["stems"] as? [String: Any])?["source"] as? String == "RF", "stem source")
        let tags = b["tags"] as? [String: Any]
        check(tags?["energy"] as? Int == 6 && tags?["mood_clash"] as? Bool == false, "tags, with mood_clash false when unset")
        check((b["file_tags"] as? [String: Any])?["genre"] as? String == "Pop", "file genre")

        // The model-facing-name rule: nothing the export writes itself may name the app. The made-up songs don't.
        let text = String(decoding: data, as: UTF8.self).lowercased()
        check(!text.contains("pink") && !text.contains("diamond"), "the app's name stays out of the file")
    }

    /// The songs the first reader matches on, when this machine has them analyzed: Take It Off's drums come in on
    /// its third section, 9.6 s in, and Flashing Lights' after its drumless intro.
    static func library() async {
        let stems = ("~/Music/Stereo Stems" as NSString).expandingTildeInPath
        let files = ["\(stems)/Official/Take It Off (Official).stem.mp4", "\(stems)/bejeweled roformer/Flashing Lights (RF).stem.mp4"]
        guard files.allSatisfy(FileManager.default.fileExists(atPath:)) else { return print("skipped the library test: no stem library") }
        let first = try? await MCPServer(extensions: true, renders: nil).metadata(paths: files + ["/no/such.m4a"])
        let again = try? await MCPServer(extensions: true, renders: nil).metadata(paths: files.reversed() + ["/no/such.m4a"])
        check(first != nil && first == again, "the same crate exports to the same file")
        guard let first, let json = try? JSONSerialization.jsonObject(with: first) as? [String: Any] else { return }
        let songs = json["songs"] as? [[String: Any]] ?? []
        guard songs.count == 2 else { return print("skipped the library test: songs not analyzed") }
        func drums(_ song: [String: Any]) -> Double? {
            (((song["stems"] as? [String: Any])?["tracks"] as? [[String: Any]])?.first?["first_entry"] as? NSNumber)?.doubleValue
        }
        let named = { (title: String) in songs.first { $0["title"] as? String == title } ?? [:] }
        let flashing = named("Flashing Lights (RF)"), takeItOff = named("Take It Off (Official)")
        check(abs((drums(takeItOff) ?? 0) - 9.626) < 0.05, "Take It Off's drums: \(drums(takeItOff) ?? -1)")
        check((drums(flashing) ?? 0) > 15, "Flashing Lights' drums after the intro: \(drums(flashing) ?? -1)")
        check((json["skipped"] as? [[String: Any]])?.first?["reason"] as? String == "no such file", "a missing file is listed")
    }
}
