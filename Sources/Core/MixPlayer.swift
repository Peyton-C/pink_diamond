import AVFoundation
import Foundation
import MediaPlayer

/// Plays a playlist with its transitions. MixRenderer runs ahead on a background thread and its output is queued on a
/// realtime engine, so playback starts once the first second is rendered rather than after the whole mix, and it
/// sounds exactly like Export Mix. Registers with macOS's media controls (media keys, Control Centre).
@MainActor
final class MixPlayer: ObservableObject {
    /// What is playing: the playlist, and a snapshot of its songs from `startIndex` on. `shuffled` is the whole
    /// order being played when it isn't the playlist's own, which `startIndex` then counts into.
    struct Queue { let context: UUID; let ids: [UUID]; let startIndex: Int; var shuffled: [UUID]? = nil }

    @Published private(set) var queue: Queue?
    /// Whether playlists play in a random order. Kept across launches.
    @Published private(set) var shuffle = UserDefaults.standard.bool(forKey: "shuffle")
    @Published private(set) var isPaused = false
    @Published private(set) var position: MixRenderer.Position?
    /// Song time at which the current song took over; transitions enter songs partway through.
    private(set) var enteredAt = 0.0

    private let library: Library
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var session: Session?
    private var timer: Timer?

    /// Index into `queue.ids` of the song the listener hears, and its song time.
    var index: Int { position?.index ?? 0 }
    var songTime: Double { position?.songTime ?? 0 }
    var currentSongID: UUID? { queue.map { $0.ids[min(index, $0.ids.count - 1)] } }
    /// Position of the current song in the order being played: the playlist, or the shuffled order.
    var currentPosition: Int? { queue.map { $0.startIndex + index } }

    /// The transition coming up or under way, with the song times of both its songs.
    struct Deck: Equatable { let from: UUID; let to: UUID; let outTime: Double; let inTime: Double? }
    var deck: Deck? {
        guard let queue, let p = position, p.deck + 1 < queue.ids.count else { return nil }
        return Deck(from: queue.ids[p.deck], to: queue.ids[p.deck + 1], outTime: p.deckOut, inTime: p.deckIn)
    }

    init(library: Library) {
        self.library = library
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: MixRenderer.format)
        registerRemoteCommands()
    }

    // MARK: Transport

    /// Plays `playlist` from the song at `index`, starting `time` seconds into it.
    func play(_ playlist: UUID, from index: Int, at time: Double = 0, paused: Bool = false) throws {
        guard let ids = library.playlists.first(where: { $0.id == playlist })?.songIDs else { return }
        try play(ids, in: playlist, shuffled: false, from: index, at: time, paused: paused)
    }

    /// Starts `playlist` from the song at `index`, or from the top. With shuffle on that song comes first and the
    /// rest follow in a random order, and from the top means from any song.
    func start(_ playlist: UUID, from index: Int? = nil) async throws {
        guard shuffle, var rest = library.playlists.first(where: { $0.id == playlist })?.songIDs else {
            return try play(playlist, from: index ?? 0)
        }
        let first = index.flatMap { rest.indices.contains($0) ? rest.remove(at: $0) : nil }
        let order = (first.map { [$0] } ?? []) + rest.shuffled()
        await library.planTransitions(order)
        try play(order, in: playlist, shuffled: true, from: 0)
    }

    /// Turns shuffle on or off. A playlist that is playing carries on from the current song: into the rest of it in
    /// a random order, or into the songs after it in the playlist. That restarts the renderer, as a seek does.
    func setShuffle(_ on: Bool) async throws {
        shuffle = on
        UserDefaults.standard.set(on, forKey: "shuffle")
        guard let queue, (queue.shuffled != nil) != on, let id = currentSongID,
              var rest = library.playlists.first(where: { $0.id == queue.context })?.songIDs,
              let at = rest.firstIndex(of: id) else { return }
        guard on else { return try play(queue.context, from: at, at: songTime, paused: isPaused) }
        rest.remove(at: at)
        let order = [id] + rest.shuffled()
        await library.planTransitions(order)
        // Planning took a moment: only carry on if the same song is still playing and shuffle is still wanted.
        guard shuffle, self.queue?.context == queue.context, currentSongID == id else { return }
        try play(order, in: queue.context, shuffled: true, from: 0, at: songTime, paused: isPaused)
    }

    private func play(_ order: [UUID], in playlist: UUID, shuffled: Bool, from index: Int, at time: Double = 0,
                      paused: Bool = false) throws {
        guard order.indices.contains(index) else { return }
        let queue = Queue(context: playlist, ids: Array(order[index...]), startIndex: index, shuffled: shuffled ? order : nil)
        let items = try library.mixItems(queue.ids)
        stop()
        do { try engine.start() } catch { throw PlannerError("couldn't start audio output: \(error)") }
        let session = Session()
        self.session = session
        self.queue = queue
        isPaused = paused
        position = MixRenderer.Position(index: 0, songTime: time, deck: 0, deckOut: time, deckIn: nil)
        enteredAt = time
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let node = node
        Thread.detachNewThread {
            session.run(items, startTime: time, node: node) { event in
                Task { @MainActor [weak self] in
                    guard let self, self.session === session else { return }
                    switch event {
                    case .ready: if !self.isPaused { node.play() }
                    case .finished: self.stop()
                    }
                }
            }
        }
        updateNowPlaying()
    }

    /// One song forward or back. Back within the first few seconds of a song goes to the one before it, later it
    /// restarts the current song, as in Music.
    func skip(_ step: Int) throws {
        guard let queue, let position = currentPosition else { return }
        let target = step < 0 && songTime - enteredAt > 3 ? position : position + step
        try replay(queue, from: max(0, target))
    }

    /// Jumps to `time` in the current song.
    func seek(to time: Double) throws {
        guard let queue, let position = currentPosition else { return }
        try replay(queue, from: position, at: max(0, time))
    }

    /// Restarts `queue` at `index` of its order: the shuffled one, or else the playlist as it is now.
    private func replay(_ queue: Queue, from index: Int, at time: Double = 0) throws {
        if let order = queue.shuffled {
            try play(order, in: queue.context, shuffled: true, from: index, at: time, paused: isPaused)
        } else {
            try play(queue.context, from: index, at: time, paused: isPaused)
        }
    }

    func togglePause() {
        guard session != nil else { return }
        isPaused.toggle()
        isPaused ? node.pause() : node.play()
        updateNowPlaying()
    }

    func pause() { if !isPaused { togglePause() } }

    func stop() {
        session?.cancel()
        session = nil
        node.stop()
        engine.stop()
        timer?.invalidate()
        timer = nil
        queue = nil
        position = nil
        isPaused = false
        updateNowPlaying()
    }

    private func tick() {
        guard let session, let last = node.lastRenderTime, let t = node.playerTime(forNodeTime: last) else { return }
        let played = max(0, t.sampleTime)
        session.setPlayed(played)
        guard let p = session.position(at: played) else { return }
        let changed = p.index != position?.index
        if changed { enteredAt = p.songTime }
        position = p
        if changed { updateNowPlaying() }
    }

    // MARK: Media controls

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MixPlayer) throws -> Void) {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.queue != nil else { return .noActionableNowPlayingItem }
                    do { try action(self); return .success } catch { return .commandFailed }
                }
            }
        }
        handle(center.togglePlayPauseCommand) { $0.togglePause() }
        handle(center.playCommand) { if $0.isPaused { $0.togglePause() } }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.stopCommand) { $0.stop() }
        handle(center.nextTrackCommand) { try $0.skip(1) }
        handle(center.previousTrackCommand) { try $0.skip(-1) }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.queue != nil, let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .noActionableNowPlayingItem
                }
                do { try self.seek(to: event.positionTime); return .success } catch { return .commandFailed }
            }
        }
    }

    /// Tells macOS what is playing. Sent on song changes, pauses and seeks; the system advances elapsed time itself.
    private func updateNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        guard let id = currentSongID, let song = library.song(id) else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var now: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: songTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        if let duration = library.summaries[id]?.duration { now[MPMediaItemPropertyPlaybackDuration] = duration }
        if let image = library.cover(id) {
            now[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        info.nowPlayingInfo = now
        info.playbackState = isPaused ? .paused : .playing
    }
}

/// One run of the renderer feeding the player node. Shared between the rendering thread and the main actor.
private final class Session: @unchecked Sendable {
    enum Event { case ready, finished }
    private struct Mark { let frame: AVAudioFramePosition; let position: MixRenderer.Position }

    private let lock = NSLock()
    private var cancelled = false
    private var played: AVAudioFramePosition = 0
    private var marks: [Mark] = []

    /// Seconds rendered ahead of the listener. Enough to cover decoding the next song; a seek or skip starts a new
    /// session, so this costs nothing in responsiveness.
    private static let lead = 20.0
    private static let chunk = AVAudioFrameCount(sampleRate / 2)

    func cancel() { lock.withLock { cancelled = true } }
    func setPlayed(_ frame: AVAudioFramePosition) { lock.withLock { played = frame } }

    /// The position of the block playing at `frame`. Marks are per 512-frame block, so this is within 12 ms.
    func position(at frame: AVAudioFramePosition) -> MixRenderer.Position? {
        lock.withLock {
            guard let i = marks.lastIndex(where: { $0.frame <= frame }) else { return nil }
            marks.removeFirst(i)   // earlier marks are behind the listener for good
            return marks.first?.position
        }
    }

    func run(_ items: [MixRenderer.Item], startTime: Double, node: AVAudioPlayerNode, notify: @escaping (Event) -> Void) {
        let format = MixRenderer.format
        var pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunk)!
        var scheduled: AVAudioFramePosition = 0
        var announced = false

        func flush(last: Bool) {
            guard pending.frameLength > 0 || last else { return }
            if pending.frameLength == 0 {   // the end still needs a buffer to signal it
                pending.frameLength = 512
                for c in 0..<Int(format.channelCount) { pending.floatChannelData![c].update(repeating: 0, count: 512) }
            }
            let buffer = pending
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in if last { notify(.finished) } }
            scheduled += AVAudioFramePosition(buffer.frameLength)
            pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunk)!
            // Start the node only once audio is queued: its sample time runs from play(), so starting it starved
            // would offset every mark.
            if !announced, scheduled >= AVAudioFramePosition(sampleRate) || last { announced = true; notify(.ready) }
        }

        _ = try? MixRenderer.render(items, startTime: startTime, tail: nil) { block, position in
            if lock.withLock({ cancelled }) { return false }
            let mark = Mark(frame: scheduled + AVAudioFramePosition(pending.frameLength), position: position)
            lock.withLock { marks.append(mark) }
            let n = Int(block.frameLength), at = Int(pending.frameLength)
            for c in 0..<Int(format.channelCount) {
                (pending.floatChannelData![c] + at).update(from: block.floatChannelData![c], count: n)
            }
            pending.frameLength += block.frameLength
            if pending.frameLength + block.frameLength > pending.frameCapacity {
                flush(last: false)
                while lock.withLock({ !cancelled && Double(scheduled - played) / sampleRate > Self.lead }) {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            return true
        }
        if lock.withLock({ cancelled }) { return }
        flush(last: true)
    }
}
