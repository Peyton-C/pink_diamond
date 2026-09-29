import SwiftUI

/// The song playing from a playlist, with transport controls and a seek slider. Shown under every view while a
/// playlist plays.
struct NowPlayingBar: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    @State private var error: String?
    @State private var scrubbing: Double?   // the slider's value while it's dragged

    private var playlist: Playlist? { library.playlists.first { $0.id == player.queue?.context } }
    private var song: Song? { player.currentSongID.flatMap(library.song) }

    var body: some View {
        let duration = song.flatMap { library.analyses[$0.id]?.duration } ?? 0
        let time = scrubbing ?? min(player.songTime, duration)
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
                Button { run { try player.skip(-1) } } label: { Image(systemName: "backward.fill") }
                    .help("Previous song")
                Button { player.togglePause() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 18))
                }
                .help(player.isPaused ? "Play" : "Pause")
                Button { run { try player.skip(1) } } label: { Image(systemName: "forward.fill") }
                    .help("Next song")
                    .disabled((player.currentPosition ?? 0) + 1 >= (playlist?.songIDs.count ?? 0))
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 8) {
                Text(Theme.time(time).dropLast(2)).monospacedDigit().frame(width: 34, alignment: .trailing)
                Slider(value: Binding(get: { time }, set: { scrubbing = $0 }), in: 0...max(duration, 1)) { editing in
                    guard !editing, let target = scrubbing else { return }
                    run { try player.seek(to: target) }
                    scrubbing = nil
                }
                .controlSize(.small)
                .frame(width: 200)
                Text(Theme.time(duration).dropLast(2)).monospacedDigit().frame(width: 34, alignment: .leading)
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

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { self.error = String(describing: error) }
    }
}
