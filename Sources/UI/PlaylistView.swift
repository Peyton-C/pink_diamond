import SwiftUI

/// A transition between two neighbouring songs of a playlist.
struct TransitionRef: Hashable { let from: UUID; let to: UUID }

struct PlaylistView: View {
    @EnvironmentObject var library: Library
    let playlistID: UUID
    @State private var selected: TransitionRef?
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var exportError: String?

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        VSplitView {
            list.frame(maxWidth: .infinity, minHeight: 200)
            Group {
                if let selected, let plan = planIfReady(selected) {
                    TransitionView(ref: selected, plan: plan)
                } else {
                    ContentUnavailableView("Select a transition", systemImage: "arrow.down.forward.and.arrow.up.backward",
                                           description: Text("Click the ◆ between two songs to open it in the deck view"))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItem {
                Button { export() } label: { Label("Export Mix", systemImage: "square.and.arrow.up") }
                    .disabled((playlist?.songIDs.count ?? 0) < 2 || exporting)
                    .help("Render the whole playlist as one continuous AutoMix")
            }
        }
        .overlay(alignment: .bottom) {
            if exporting {
                ProgressView("Rendering mix…", value: exportProgress).padding().frame(width: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
            }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: { Text(exportError ?? "") }
    }

    private var list: some View {
        List {
            if let playlist {
                ForEach(Array(playlist.songIDs.enumerated()), id: \.offset) { index, id in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRow(song: library.song(id), analysis: library.analyses[id], index: index + 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index + 1 < playlist.songIDs.count {
                            let ref = TransitionRef(from: id, to: playlist.songIDs[index + 1])
                            TransitionRow(ref: ref, state: library.plan(from: ref.from, to: ref.to), selected: selected == ref)
                                .onTapGesture { selected = ref }
                        }
                    }
                }
                .onMove { from, to in
                    move(from, to)
                }
                .onDelete { offsets in
                    guard let i = library.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
                    library.playlists[i].songIDs.remove(atOffsets: offsets)
                    library.save()
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in
                library.add(urls)
                guard let i = library.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
                let paths = Set(urls.map(\.path))
                let added = library.songs.filter { paths.contains($0.path) || urls.contains(where: { $0.hasDirectoryPath && $0.path.hasPrefix($0.path) }) }
                library.playlists[i].songIDs.append(contentsOf: added.map(\.id).filter { !library.playlists[i].songIDs.contains($0) })
                library.save()
            }
            return true
        }
        .overlay {
            if (playlist?.songIDs.isEmpty ?? true) {
                ContentUnavailableView("Empty playlist", systemImage: "music.note.list",
                                       description: Text("Right-click songs in the Library → Add to Playlist, or drop files here"))
            }
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        guard let i = library.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        library.playlists[i].songIDs.move(fromOffsets: from, toOffset: to)
        library.save()
    }

    private func planIfReady(_ ref: TransitionRef) -> TransitionPlan? {
        if case .ready(let p) = library.plan(from: ref.from, to: ref.to) { return p }
        return nil
    }

    private func export() {
        guard let playlist else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(playlist.name).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = playlist.songIDs
        var items: [MixRenderer.Item] = []
        for (i, id) in ids.enumerated() {
            guard let audio = library.playableURL(id), let a = library.analyses[id] else {
                exportError = "\(library.song(id)?.title ?? "A song") isn't analyzed yet."
                return
            }
            let entering = i > 0 ? planIfReady(TransitionRef(from: ids[i - 1], to: id))?.incoming : nil
            let leaving = i + 1 < ids.count ? planIfReady(TransitionRef(from: id, to: ids[i + 1]))?.outgoing : nil
            if (i > 0 && entering == nil) || (i + 1 < ids.count && leaving == nil) {
                exportError = "Some transitions aren't planned yet; wait for every ◆ to appear."
                return
            }
            items.append(MixRenderer.Item(audio: audio, beats: a.beats, entering: entering, leaving: leaving))
        }
        exporting = true
        exportProgress = 0
        Task.detached {
            do {
                _ = try MixRenderer.render(items, startTime: 0, tail: nil, to: url) { p in
                    Task { @MainActor in exportProgress = p }
                }
                await MainActor.run { exporting = false; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run { exporting = false; exportError = String(describing: error) }
            }
        }
    }
}

struct SongRow: View {
    let song: Song?
    let analysis: SongAnalysis?
    let index: Int
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(song?.title ?? "Missing song").font(.system(size: 13, weight: .semibold))
                Text([song?.artist, song?.genre.rawValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let analysis {
                Text("\(analysis.bpm) BPM").monospacedDigit()
                Text(analysis.key).frame(width: 64, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 2)
    }
}

struct TransitionRow: View {
    let ref: TransitionRef
    let state: PlanState?
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).padding(.leading, 30)
            switch state {
            case .ready(let plan):
                StyleChip(plan: plan)
                Text(String(format: "%.1f s", plan.duration)).monospacedDigit().foregroundStyle(.secondary)
                Text(plan.effectSummary.filter { $0 != "tempo" && $0 != "volume" }.joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1)
            case .failed(let e):
                Text("couldn't plan").foregroundStyle(.orange).help(e)
            default:
                ProgressView().controlSize(.mini)
                Text("planning…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.vertical, 3)
        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
