import Foundation

/// Where a stem file's stems came from, read from the marker bejeweled leaves at the end of the title: `(Official)`,
/// `(FN)`, `(RF AT)`, `(FN +RF)`. The marker is parsed by its grammar and not matched against a list, because the
/// set is open: a separation names its separator, then its input, then whatever helped it, and Run Away with Me
/// carries `(RF IN SX)` for a saxophone model no other file has used.
struct StemSource: Hashable {
    /// The marker as written, or what the file is when it has none.
    let label: String
    /// Lower is better. The order is a judgement of how clean the stems are to pull apart, the user's own, and the
    /// gaps between the numbers leave room for the separator and for letters this doesn't know.
    let rank: Int
    /// Stems taken from a game, which plays its own cut of the song: Therefore I Am runs 80 s in Rock Band and
    /// 171 s in Fortnite Festival. A game's cut never replaces another cut of a different length on its own.
    let gameCut: Bool

    /// A file with no stems.
    static let audio = StemSource(label: "Audio", rank: 120, gameCut: false)
    /// A stem file that doesn't say where its stems came from. Last among stem files: the unmarked ones here were
    /// stemgen's, the worst separation of the lot.
    static let unmarked = StemSource(label: "Unmarked", rank: 110, gameCut: false)

    private static let separators = ["RF", "HY", "DE"]   // roformer, hybrid, demucs: best first

    private init(label: String, rank: Int, gameCut: Bool) {
        self.label = label
        self.rank = rank
        self.gameCut = gameCut
    }

    /// The source a marker names, without its brackets, or nil if it isn't a marker.
    init?(marker: String) {
        let tokens = marker.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        func separator(_ token: String) -> Int? { Self.separators.firstIndex(of: token) }
        if first.hasPrefix("+") || ["Official", "FN", "RB"].contains(first) {
            // Real stems, alone or with a separated part grafted in: (FN), (FN +RF), and (+RF) on official stems.
            // A graft is only ever built on real stems, so it stays with them, ahead of every separation.
            let graft = first.hasPrefix("+") ? tokens : Array(tokens.dropFirst())
            guard graft.count <= 1, graft.allSatisfy({ $0.hasPrefix("+") && separator(String($0.dropFirst())) != nil }) else { return nil }
            let grafted = graft.first.flatMap { separator(String($0.dropFirst())) }
            switch first {
            case "FN": rank = grafted.map { 20 + $0 } ?? 30
            // Rock Band's files are real multitracks for most stems and a separation worse than stemgen's for the
            // rest, and nothing in the file says which, so they sit below the best of the assembled separations.
            case "RB": rank = grafted.map { 60 + $0 } ?? 65
            default: rank = grafted.map { 10 + $0 } ?? 0
            }
            gameCut = first == "FN" || first == "RB"
        } else if let s = separator(first) {
            // A separation: (RF), then SR or AT for a surround or Atmos input, then AC and IN for an acapella or
            // instrumental that helped, then anything else two letters long.
            let rest = tokens.dropFirst()
            guard rest.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isLetter && $0.isUppercase } }) else { return nil }
            let helped = rest.filter { $0 == "AC" || $0 == "IN" }.count
            let extra = rest.contains { !["AC", "IN", "SR", "AT"].contains($0) }
            switch helped {
            case 2: rank = 40 + 2 * s - (extra ? 1 : 0)
            // One helper and a model of its own for a single stem is above Rock Band; one helper alone is below it.
            case 1: rank = (extra ? 50 : 70) + 2 * s
            default: rank = (rest.contains("AT") ? 80 : rest.contains("SR") ? 90 : 100) + 2 * s - (extra ? 1 : 0)
            }
            gameCut = false
        } else {
            return nil
        }
        label = marker
    }

    /// `name` without the marker at its end, and the source the marker names. Only a bracket that parses as a marker
    /// comes off: "(feat. SZA)" and "(Taylor's Version)" are part of the title, and tell two recordings apart.
    static func split(_ name: String) -> (name: String, source: StemSource?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("),
              let source = StemSource(marker: String(trimmed[trimmed.index(after: open)...].dropLast())) else { return (name, nil) }
        return (trimmed[..<open].trimmingCharacters(in: .whitespaces), source)
    }

    /// The source of the file at `path`, tagged with `title`: the marker in the title, or else in the file's name.
    static func of(title: String, path: String) -> StemSource {
        let url = URL(fileURLWithPath: path)
        guard AudioSource.isStem(url) else { return .audio }
        let name = String(url.lastPathComponent.dropLast(".stem.mp4".count))
        return split(title).source ?? split(name).source ?? .unmarked
    }
}

enum SongName {
    /// What a song is called whichever file it is: its first artist and its title without the marker, ignoring
    /// case, accents and punctuation. Files that share it are versions of one song, and nothing else makes them so.
    ///
    /// Only the first artist, because sources credit the same recording differently: Just Dance is by "Lady Gaga" in
    /// Rock Band and "Lady Gaga ft. Colby O'Donis" in Fortnite Festival. Of the eight songs in the library whose
    /// files disagree on the full credit, Cheap Thrills is the one where a feature marks another recording: the
    /// official stems are Sia alone and both games have the Sean Paul remix, at the same 216 s, so neither the credit
    /// rule nor length can part them. What parts them is the title: "Cheap Thrills (feat. Sean Paul)" on the game
    /// files, as Apple Music names the remix. The rest of the title is kept whole, so All Too
    /// Well stays apart from its ten-minute version, and Monster by Lady Gaga from Monster by Slayyyter.
    static func key(title: String, artist: String) -> String {
        func folded(_ s: String) -> String {
            let plain = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
                .replacingOccurrences(of: "$", with: "s")   // Ke$ha, A$AP
            return String(String.UnicodeScalarView(plain.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
        var first = artist.lowercased()
        for mark in [",", "&", ";", "(", " ft ", " ft.", " feat ", " feat.", " featuring ", " f. ", " f/", " x ", " with "] {
            if let range = first.range(of: mark) { first = String(first[..<range.lowerBound]) }
        }
        return folded(first) + "|" + folded(StemSource.split(title).name)
    }
}
