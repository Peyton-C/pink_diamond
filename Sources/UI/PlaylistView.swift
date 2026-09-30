import SwiftUI

/// A transition between two neighbouring songs of a playlist.
struct TransitionRef: Hashable { let from: UUID; let to: UUID }

struct PlaylistView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    let playlistID: UUID
    @State private var selected: TransitionRef?
    @State private var exporting = false
    @State private var exportProgress = 0.0
    @State private var failure: (title: String, message: String)?

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        VSplitView {
            Group {
                if player.queue?.context == playlistID {
                    LiveDeckView()
                } else if let selected, let plan = planIfReady(selected) {
                    TransitionView(ref: selected, plan: plan)
                } else {
                    ContentUnavailableView("Select a transition", systemImage: "arrow.down.forward.and.arrow.up.backward",
                                           description: Text("Click the ◆ between two songs below to open it in the deck view"))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            list.frame(maxWidth: .infinity, minHeight: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: liveRef) { _, new in if let new { selected = new } }
        .navigationTitle(playlist?.name ?? "Playlist")
        // Export lives in the menu bar (File → Export Mix…), fed by this playlist while it's focused.
        .focusedSceneValue(\.exportMix, (playlist?.songIDs.count ?? 0) >= 2 && !exporting ? { export() } : nil)
        .toolbar {
            ToolbarItem {
                let current = player.queue?.context == playlistID
                let playing = current && !player.isPaused
                Button { current ? player.togglePause() : play(from: 0) } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .help(current ? (playing ? "Pause" : "Resume") : "Play the whole playlist with its transitions")
                    .disabled(playlist?.songIDs.isEmpty ?? true)
            }
        }
        .overlay(alignment: .bottom) {
            if exporting {
                ProgressView("Rendering mix…", value: exportProgress).padding().frame(width: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
            }
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure?.message ?? "") }
    }

    private func play(from index: Int) {
        do { try player.play(playlistID, from: index) } catch { failure = ("Can't play", String(describing: error)) }
    }

    /// While this playlist plays, the transition coming up or under way.
    private var liveRef: TransitionRef? {
        guard let deck = player.deck, player.queue?.context == playlistID else { return nil }
        return TransitionRef(from: deck.from, to: deck.to)
    }

    private var list: some View {
        List {
            if let playlist {
                ForEach(Array(playlist.songIDs.enumerated()), id: \.offset) { index, id in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRow(song: library.song(id), artwork: library.cover(id), summary: library.summaries[id], index: index + 1,
                                playing: player.queue?.context == playlistID && player.currentPosition == index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { play(from: index) }
                            .contextMenu { Button("Play from Here") { play(from: index) } }
                        if index + 1 < playlist.songIDs.count {
                            let ref = TransitionRef(from: id, to: playlist.songIDs[index + 1])
                            TransitionRow(ref: ref, state: library.plan(from: ref.from, to: ref.to), selected: (liveRef ?? selected) == ref,
                                          edited: !library.edit(from: ref.from, to: ref.to).isEmpty)
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
        let items: [MixRenderer.Item]
        do { items = try library.mixItems(playlist.songIDs) } catch { failure = ("Export failed", String(describing: error)); return }
        exporting = true
        exportProgress = 0
        Task.detached {
            do {
                _ = try MixRenderer.render(items, startTime: 0, tail: nil, to: url) { p in
                    Task { @MainActor in exportProgress = p }
                }
                await MainActor.run { exporting = false; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run { exporting = false; failure = ("Export failed", String(describing: error)) }
            }
        }
    }
}

struct SongRow: View {
    let song: Song?
    let artwork: NSImage?
    let summary: SongSummary?
    let index: Int
    var playing = false
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent)
                } else {
                    Text("\(index)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            Artwork(image: artwork, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(song?.title ?? "Missing song").font(.system(size: 13, weight: .semibold))
                Text([song?.artist, song?.genre.rawValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let summary {
                Text("\(summary.bpm) BPM").monospacedDigit()
                KeyBadge(key: summary.key).frame(width: 44, alignment: .trailing)
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
    var edited = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).padding(.leading, 30)
            switch state {
            case .ready(let plan):
                StyleChip(plan: plan)
                if edited { Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent).help("Edited") }
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
