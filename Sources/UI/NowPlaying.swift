import SwiftUI

/// The song playing from a playlist, with transport controls. Shown under every view while a playlist plays.
struct NowPlayingBar: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    @State private var error: String?

    private var playlist: Playlist? { library.playlists.first { $0.id == player.queue?.context } }
    private var song: Song? { player.currentSongID.flatMap(library.song) }

    var body: some View {
        let duration = song.flatMap { library.analyses[$0.id]?.duration } ?? 0
        HStack(spacing: 12) {
            Artwork(image: song.flatMap { library.cover($0.id) }, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song?.title ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([song?.artist ?? "", playlist?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 140, maxWidth: 280, alignment: .leading)
            Spacer()
            HStack(spacing: 18) {
                Button { skip(-1) } label: { Image(systemName: "backward.fill") }
                    .help("Previous song")
                Button { player.togglePause() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 18))
                }
                .help(player.isPaused ? "Play" : "Pause")
                Button { skip(1) } label: { Image(systemName: "forward.fill") }
                    .help("Next song")
                    .disabled((player.currentPosition ?? 0) + 1 >= (playlist?.songIDs.count ?? 0))
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 8) {
                Text(Theme.time(player.songTime).dropLast(2)).monospacedDigit()
                ProgressView(value: min(player.songTime, duration), total: max(duration, 1)).frame(width: 140)
                Text(Theme.time(duration).dropLast(2)).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Button { player.stop() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .alert("Can't play", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    /// Restarts playback one song forward or back. Back within the first few seconds of a song goes to the one
    /// before it, later it restarts the current song, as in Music.
    private func skip(_ step: Int) {
        guard let playlist, let position = player.currentPosition else { return }
        let target = step < 0 && player.songTime - player.enteredAt > 3 ? position : position + step
        guard playlist.songIDs.indices.contains(target) else { return }
        do { try player.play(playlist, from: target, in: library) } catch { self.error = String(describing: error) }
    }
}
