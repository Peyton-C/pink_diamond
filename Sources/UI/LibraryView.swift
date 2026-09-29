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
    @State private var sortOrder = [KeyPathComparator(\Song.title)]

    var body: some View {
        Table(sortedSongs, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { song in StatusIcon(state: library.states[song.id]) }.width(18)
            TableColumn("Title", value: \.title) { song in
                HStack(spacing: 8) {
                    Artwork(image: library.cover(song.id), size: 24)
                    Text(song.title).lineLimit(1)
                    if song.isStem {
                        Text("STEMS").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.accent)
                            .fixedSize()
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artist).width(min: 80, ideal: 150)
            TableColumn("Album", value: \.albumName).width(min: 80, ideal: 150)
            TableColumn("BPM") { song in Text(library.analyses[song.id].map { "\($0.bpm)" } ?? "–").monospacedDigit() }.width(44)
            TableColumn("Key") { song in Text(library.analyses[song.id]?.key ?? "–") }.width(70)
            TableColumn("Length") { song in
                Text(library.analyses[song.id].map { Theme.time($0.duration).dropLast(2) } ?? "–").monospacedDigit()
            }.width(52)
            TableColumn("Genre") { song in
                Picker("", selection: Binding(get: { song.genre }, set: { library.setGenre($0, for: song.id) })) {
                    ForEach(Genre.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }.width(130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Menu("Add to Playlist") {
                ForEach(library.playlists) { p in
                    Button(p.name) { addToPlaylist(p.id, ids) }
                }
            }
            Divider()
            Button("Remove from Library", role: .destructive) { library.remove(ids) }
        }
    }

    private var sortedSongs: [Song] { songs.sorted(using: sortOrder) }

    private func addToPlaylist(_ playlist: UUID, _ ids: Set<UUID>) {
        guard let i = library.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        let ordered = sortedSongs.map(\.id).filter { ids.contains($0) }
        library.playlists[i].songIDs.append(contentsOf: ordered)
        library.save()
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
