import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Song.title)]

    var body: some View {
        Table(sortedSongs, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { song in StatusIcon(state: library.states[song.id]) }.width(18)
            TableColumn("Title", value: \.title) { song in
                HStack(spacing: 6) {
                    Text(song.title)
                    if song.isStem {
                        Text("STEMS").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            TableColumn("Artist", value: \.artist)
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { library.add($0) }
            return true
        }
        .toolbar {
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

    private var sortedSongs: [Song] { library.songs.sorted(using: sortOrder) }

    private func addToPlaylist(_ playlist: UUID, _ ids: Set<UUID>) {
        guard let i = library.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        let ordered = sortedSongs.map(\.id).filter { ids.contains($0) }
        library.playlists[i].songIDs.append(contentsOf: ordered)
        library.save()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .folder]
        if panel.runModal() == .OK { library.add(panel.urls) }
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
