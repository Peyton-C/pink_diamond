import SwiftUI
import UniformTypeIdentifiers

enum LibraryTab: String, CaseIterable, Identifiable {
    case songs = "Songs", artists = "Artists", albums = "Albums", genres = "Genres"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @SceneStorage("libraryTab") private var tab = LibraryTab.songs
    @State private var selectedGroup: [LibraryTab: String] = [:]

    var body: some View {
        Group {
            if tab == .songs {
                SongTable(songs: library.songs)
            } else {
                grouped
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { library.add($0) }
            return true
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(LibraryTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ToolbarItem {
                Button { addFiles() } label: { Label("Add Music", systemImage: "plus") }
                    .help("Add audio files, stem files, or folders")
            }
            ToolbarItem {
                Menu {
                    Button("Scan Folders") { library.rescan() }.disabled(library.folders.isEmpty)
                    Button("Remove Missing Songs") { library.removeMissing() }.disabled(!library.states.values.contains(.missing))
                } label: { Label("Library", systemImage: "ellipsis.circle") }
            }
        }
        .overlay {
            if library.songs.isEmpty {
                ContentUnavailableView("Drop music here", systemImage: "diamond",
                                       description: Text("Audio files, NI .stem.mp4 files, or whole folders"))
            }
        }
        .navigationTitle("Library")
    }

    private var grouped: some View {
        let groups = SongGroup.make(tab, from: library.songs)
        let selected = groups.first { $0.id == selectedGroup[tab] } ?? groups.first
        return HSplitView {
            List(groups, selection: Binding(get: { selected?.id }, set: { selectedGroup[tab] = $0 })) { group in
                GroupRow(group: group, image: group.songs.lazy.compactMap { library.cover($0.id) }.first, round: tab == .artists).tag(group.id)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
            SongTable(songs: selected?.songs ?? [])
                .frame(minWidth: 400, maxWidth: .infinity)
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .folder]
        if panel.runModal() == .OK { library.add(panel.urls) }
    }
}

/// The songs sharing an artist, album or genre.
struct SongGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let songs: [Song]

    static func make(_ tab: LibraryTab, from songs: [Song]) -> [SongGroup] {
        let count = { (s: [Song]) in s.count == 1 ? "1 song" : "\(s.count) songs" }
        // Tags spell the same album or artist differently between releases ("Brat", "BRAT", "brat"), so names are
        // grouped ignoring case and shown in their most common spelling.
        func named(_ name: (Song) -> String, unknown: String, subtitle: ([Song]) -> String) -> [SongGroup] {
            Dictionary(grouping: songs) { name($0).lowercased() }.map { key, songs in
                let spellings = Dictionary(grouping: songs.map(name)) { $0 }
                let title = spellings.max { $0.value.count < $1.value.count }?.key ?? key
                return SongGroup(id: key, title: key.isEmpty ? unknown : title, subtitle: subtitle(songs), songs: songs)
            }
            .sorted { ($0.id.isEmpty ? 1 : 0, $0.id) < ($1.id.isEmpty ? 1 : 0, $1.id) }
        }
        switch tab {
        case .songs:
            return []
        case .artists:
            return named(\.artist, unknown: "Unknown Artist", subtitle: count)
        case .albums:
            return named(\.albumName, unknown: "Unknown Album") { songs in
                let artists = Set(songs.map(\.artist).filter { !$0.isEmpty }.map { $0.lowercased() })
                let by = artists.count == 1 ? songs.first { !$0.artist.isEmpty }!.artist : artists.isEmpty ? "" : "Various Artists"
                return [by, count(songs)].filter { !$0.isEmpty }.joined(separator: " · ")
            }
        case .genres:
            let byGenre = Dictionary(grouping: songs) { $0.genre }
            return Genre.allCases.compactMap { g in
                byGenre[g].map { SongGroup(id: g.rawValue, title: g.rawValue, subtitle: count($0), songs: $0) }
            }
        }
    }
}

struct GroupRow: View {
    let group: SongGroup
    let image: NSImage?
    let round: Bool
    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: image, size: 36, round: round)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(group.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SongTable: View {
    @EnvironmentObject var library: Library
    let songs: [Song]
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Row.song.title)]

    /// A song with what its columns sort by and its own fields don't hold.
    struct Row: Identifiable {
        let song: Song
        let bpm: Int
        let key: Int                 // in Lancelot order, so keys that mix sort next to each other
        let duration: Double
        let source: StemSource
        let added: Date
        var id: UUID { song.id }
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in StatusIcon(state: library.states[row.id]) }.width(18)
            TableColumn("Title", value: \.song.title) { row in
                HStack(spacing: 8) {
                    Artwork(image: library.cover(row.id), size: 24)
                    Text(row.song.title).lineLimit(1)
                    if row.song.isStem {
                        Text("STEMS").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.accent)
                            .fixedSize()
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.song.artist).width(min: 80, ideal: 150)
            TableColumn("Album", value: \.song.albumName).width(min: 80, ideal: 150)
            TableColumn("BPM", value: \.bpm) { row in Text(row.bpm > 0 ? "\(row.bpm)" : "–").monospacedDigit() }.width(44)
            TableColumn("Key", value: \.key) { row in
                if let key = library.summaries[row.id]?.key { KeyBadge(key: key) } else { Text("–") }
            }.width(48)
            TableColumn("Length", value: \.duration) { row in
                Text(row.duration > 0 ? String(Theme.time(row.duration).dropLast(2)) : "–").monospacedDigit()
            }.width(52)
            TableColumn("Genre", value: \.song.genre.rawValue) { row in
                Picker("", selection: Binding(get: { row.song.genre }, set: { library.setGenre($0, for: row.id) })) {
                    ForEach(Genre.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }.width(130)
            TableColumn("Source", value: \.source.rank) { row in
                SourceLabel(source: row.source, pinned: row.song.pinned == true, better: library.betterVersion(of: row.song)?.source)
            }.width(min: 60, ideal: 84)
            TableColumn("Added", value: \.added) { row in
                Text(row.song.added.map { $0.formatted(date: .numeric, time: .omitted) } ?? "–").monospacedDigit()
            }.width(min: 60, ideal: 76)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Menu("Add to Playlist") {
                ForEach(library.playlists.filter { $0.mix == nil }) { p in
                    Button(p.name) { addToPlaylist(p.id, ids) }
                }
            }
            if ids.count == 1, let song = ids.first.flatMap(library.song), let versions = song.versions, versions.count > 1 {
                Menu("Version") {
                    ForEach(versions.sorted { $0.source.rank < $1.source.rank }, id: \.path) { version in
                        let name = "\(version.source.label), \(Theme.time(version.duration).dropLast(2))"
                        Button { library.setVersion(version.path, for: song.id) } label: {
                            if version.path == song.path { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                    if song.pinned == true {
                        Divider()
                        Button("Choose Automatically") { library.setVersion(nil, for: song.id) }
                    }
                }
            }
            Divider()
            Button("Remove from Library", role: .destructive) { library.remove(ids) }
        }
    }

    private var rows: [Row] {
        songs.map { song -> Row in
            let summary = library.summaries[song.id]
            let key = summary.map { MusicalKey($0.key) }
            let lancelot = key.flatMap { k in k.lancelot.map { $0 * 2 + (k.minor ? 0 : 1) } }
            return Row(song: song, bpm: summary?.bpm ?? 0, key: lancelot ?? 0, duration: summary?.duration ?? 0,
                       source: song.source, added: song.added ?? .distantPast)
        }
        .sorted(using: sortOrder)
    }

    private func addToPlaylist(_ playlist: UUID, _ ids: Set<UUID>) {
        guard let i = library.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        let ordered = rows.map(\.id).filter { ids.contains($0) }
        library.playlists[i].songIDs.append(contentsOf: ordered)
        library.save()
    }
}

/// Where the file a song plays came from, with a pin when the user chose it over a better one and an arrow when a
/// better one is waiting to be chosen. It is handed what it shows and doesn't read the library itself: a table
/// cell is hosted outside the view tree the environment object was put in, and reading it there crashed at launch.
struct SourceLabel: View {
    let source: StemSource
    let pinned: Bool
    let better: StemSource?

    var body: some View {
        HStack(spacing: 4) {
            Text(source.label).lineLimit(1)
            if let better {
                if pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.secondary).help("You chose this version over \(better.label)")
                } else {
                    Image(systemName: "arrow.up.circle").foregroundStyle(Theme.accent)
                        .help("\(better.label) is a different cut of this song. Right-click, Version, to play it")
                }
            }
        }
    }
}

/// A song's cover art, or a placeholder when it has none.
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    var round = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? size / 2 : max(3, size / 10))
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.lane)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

struct StatusIcon: View {
    let state: SongState?
    var body: some View {
        switch state {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.7))
        case .analyzing: ProgressView().controlSize(.mini)
        case .failed(let e): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
        case .missing: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).help("Its file is gone")
        default: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}
