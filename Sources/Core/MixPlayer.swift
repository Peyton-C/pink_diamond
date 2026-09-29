import AVFoundation
import Foundation

/// Plays songs in sequence with their transitions. MixRenderer runs ahead on a background thread and its output is
/// queued on a realtime engine, so playback starts once the first second is rendered rather than after the whole mix,
/// and it sounds exactly like Export Mix.
@MainActor
final class MixPlayer: ObservableObject {
    /// What is playing: `context` names the source (a playlist), `ids` the songs from `startIndex` on.
    struct Queue { let context: UUID; let ids: [UUID]; let startIndex: Int }

    @Published private(set) var queue: Queue?
    @Published private(set) var isPaused = false
    /// Index into `queue.ids` of the song the listener hears, and its song time.
    @Published private(set) var index = 0
    @Published private(set) var songTime = 0.0
    /// Song time at which the current song took over; transitions enter songs partway through.
    private(set) var enteredAt = 0.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var session: Session?
    private var timer: Timer?

    var currentSongID: UUID? { queue.map { $0.ids[min(index, $0.ids.count - 1)] } }
    /// Position of the current song in the source's full list.
    var currentPosition: Int? { queue.map { $0.startIndex + index } }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: MixRenderer.format)
    }

    func play(_ items: [MixRenderer.Item], queue: Queue) {
        stop()
        guard !items.isEmpty else { return }
        do { try engine.start() } catch { return }
        let session = Session()
        self.session = session
        self.queue = queue
        index = 0
        songTime = 0
        enteredAt = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let node = node
        Thread.detachNewThread {
            session.run(items, node: node) { event in
                Task { @MainActor [weak self] in
                    guard let self, self.session === session else { return }
                    switch event {
                    case .ready: if !self.isPaused { node.play() }
                    case .finished: self.stop()
                    }
                }
            }
        }
    }

    func togglePause() {
        guard session != nil else { return }
        isPaused.toggle()
        isPaused ? node.pause() : node.play()
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
        isPaused = false
    }

    private func tick() {
        guard let session, let last = node.lastRenderTime, let t = node.playerTime(forNodeTime: last) else { return }
        let played = max(0, t.sampleTime)
        session.setPlayed(played)
        if let mark = session.mark(at: played) {
            if index != mark.position.index { index = mark.position.index; enteredAt = mark.position.songTime }
            songTime = mark.position.songTime + Double(played - mark.frame) / sampleRate
        }
    }
}

/// One run of the renderer feeding the player node. Shared between the rendering thread and the main actor.
private final class Session: @unchecked Sendable {
    enum Event { case ready, finished }
    struct Mark { let frame: AVAudioFramePosition; let position: MixRenderer.Position }

    private let lock = NSLock()
    private var cancelled = false
    private var played: AVAudioFramePosition = 0
    private var marks: [Mark] = []

    /// Seconds rendered ahead of the listener. Enough to cover decoding the next song, small enough that a
    /// playlist edit or genre change is heard soon after a restart.
    private static let lead = 20.0
    private static let chunk = AVAudioFrameCount(sampleRate / 2)

    func cancel() { lock.withLock { cancelled = true } }
    func setPlayed(_ frame: AVAudioFramePosition) { lock.withLock { played = frame } }

    func mark(at frame: AVAudioFramePosition) -> Mark? {
        lock.withLock {
            guard let i = marks.lastIndex(where: { $0.frame <= frame }) else { return marks.first }
            marks.removeFirst(i)   // earlier marks are behind the listener for good
            return marks.first
        }
    }

    func run(_ items: [MixRenderer.Item], node: AVAudioPlayerNode, notify: @escaping (Event) -> Void) {
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

        _ = try? MixRenderer.render(items, startTime: 0, tail: nil) { block, position in
            if lock.withLock({ cancelled }) { return false }
            if pending.frameLength == 0 {
                let mark = Mark(frame: scheduled, position: position)
                lock.withLock { marks.append(mark) }
            }
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
