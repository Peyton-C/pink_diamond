import AVFoundation
import Foundation
import SwiftUI

struct Song: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String?               // nil until read from the file's tags (older libraries predate it)
    var genre: Genre = .pop
    var isStem: Bool
    var fileKey: String

    var url: URL { URL(fileURLWithPath: path) }
    var albumName: String { album ?? "" }
    var fakeCatalogID: String { "99" + String(fileKey.prefix(8)) }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var songIDs: [UUID] = []
}

enum SongState: Equatable {
    case waiting, analyzing, ready, failed(String)
}

enum PlanState {
    case planning, ready(TransitionPlan), failed(String)
}

@MainActor
final class Library: ObservableObject {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]

    @Published var songs: [Song] = []
    @Published var playlists: [Playlist] = [] { didSet { loadPlaylistSongs() } }
    @Published private(set) var states: [UUID: SongState] = [:]
    /// BPM, key and length of every analyzed song.
    @Published private(set) var summaries: [UUID: SongSummary] = [:]
    /// Full analyses, loaded only for songs in playlists: the deck views, planner and renderer are the only users.
    @Published private(set) var analyses: [UUID: SongAnalysis] = [:]
    @Published private(set) var plans: [String: PlanState] = [:]
    @Published private(set) var artwork: [UUID: NSImage] = [:]
    private var albumArtwork: [String: NSImage] = [:]   // updated alongside `artwork`, whose publish redraws
    private var playable: [UUID: URL] = [:]
    private var pendingPlans: Set<String> = []
    private var analysisQueue: [UUID] = []
    private var analyzing = false
    private var summaryIndex: [String: SongSummary] = [:]   // by file key; persisted
    private var summarySavePending = false
    private var fullQueue: [UUID] = []
    private var fullLoading: Set<UUID> = []
    private var fullWorkers = 0
    private var started = false
    private var migrating = false

    private var storeURL: URL { AppPaths.support.appendingPathComponent("library.json") }
    private var summaryURL: URL { AppPaths.cacheDir("analysis").appendingPathComponent("summaries.json") }

    /// Launch fills in the library in order of what's on screen and needed: the summary index (one small file) for
    /// every row at once, then full analyses of playlist songs, off the main thread, then cover art and missing tags.
    /// Reading every analysis instead took minutes on the main thread for a 600-song library (~260 MB of JSON).
    init() {
        load()
        if let data = try? Data(contentsOf: summaryURL), let index = try? JSONDecoder().decode([String: SongSummary].self, from: data) {
            summaryIndex = index
        }
        var known: [UUID: SongSummary] = [:], pending: [Song] = []
        for song in songs {
            if let summary = summaryIndex[song.fileKey] { known[song.id] = summary } else { pending.append(song) }
        }
        summaries = known
        states = known.mapValues { _ in .ready }.merging(pending.map { ($0.id, .waiting) }) { a, _ in a }
        started = true
        loadPlaylistSongs()
        Task {
            if !pending.isEmpty { await summarize(pending) }
            await loadCoversWhenIdle()
        }
    }

    /// Summaries for songs that have none: read from their cached analyses in parallel (a library that predates the
    /// index, or songs added since), or analyzed if there is no cache. Results are published in batches: publishing
    /// per song re-sorted and redrew the whole library table each time, which starved the main thread and slowed a
    /// 600-song index build from ~17 songs/s to ~3.5/s.
    private func summarize(_ pending: [Song]) async {
        migrating = true
        defer { migrating = false }
        await withTaskGroup(of: (UUID, String, SongSummary?).self) { group in
            var batch: [(UUID, String, SongSummary)] = [], next = 0
            func addTask() {
                guard next < pending.count else { return }
                let song = pending[next], file = Self.cacheFile(song); next += 1
                group.addTask { (song.id, song.fileKey, await Self.readAnalysis(file)?.summary) }
            }
            for _ in 0..<8 { addTask() }
            while let (id, key, summary) = await group.next() {
                if let summary { batch.append((id, key, summary)) } else { enqueue(id) }
                if batch.count >= 100 { publishSummaries(batch); batch = [] }
                addTask()
            }
            publishSummaries(batch)
        }
        saveSummariesSoon()
        loadPlaylistSongs()
    }

    // MARK: Persistence

    private struct Store: Codable { var songs: [Song]; var playlists: [Playlist] }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(Store.self, from: data) else {
            playlists = [Playlist(name: "Playlist 1")]
            return
        }
        songs = store.songs
        playlists = store.playlists.isEmpty ? [Playlist(name: "Playlist 1")] : store.playlists
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(Store(songs: songs, playlists: playlists)).write(to: storeURL, options: .atomic)
    }

    func song(_ id: UUID) -> Song? { songs.first { $0.id == id } }

    // MARK: Adding songs

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if Library.audioExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if Library.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        let known = Set(songs.map(\.path))
        for f in files.sorted(by: { $0.path < $1.path }) where !known.contains(f.path) {
            let stem = AudioSource.isStem(f)
            var name = f.deletingPathExtension().lastPathComponent
            if stem, name.lowercased().hasSuffix(".stem") { name = String(name.dropLast(5)) }
            let song = Song(path: f.path, title: name, artist: "", isStem: stem, fileKey: fileKey(f))
            songs.append(song)
            enqueue(song.id)
            Task {
                await self.loadMetadata(song.id)
                save()
                if let image = await Self.artwork(song) { self.setArtwork([(song.id, image)]) }
            }
        }
        save()
    }

    func remove(_ ids: Set<UUID>) {
        songs.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].songIDs.removeAll { ids.contains($0) } }
        save()
    }

    /// Reads title, artist and album from the file's tags. Callers save.
    private func loadMetadata(_ id: UUID) async {
        guard let song = song(id) else { return }
        let asset = AVURLAsset(url: song.url)
        guard let items = try? await asset.load(.commonMetadata) else { return }
        var title: String?, artist: String?, album: String?
        for item in items {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
        }
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { songs[i].title = title }
        if let artist { songs[i].artist = artist }
        songs[i].album = album ?? ""
    }

    private nonisolated static func artwork(_ song: Song) async -> NSImage? {
        let cache = AppPaths.cacheDir("artwork").appendingPathComponent(song.fileKey + ".jpg")
        return await AudioSource.artwork(for: song.url, cachedAt: cache).flatMap(NSImage.init(data:))
    }

    private func setArtwork(_ batch: [(UUID, NSImage)]) {
        for (id, image) in batch {
            guard let song = song(id), !song.albumName.isEmpty, albumArtwork[albumKey(song)] == nil else { continue }
            albumArtwork[albumKey(song)] = image
        }
        artwork.merge(batch) { _, new in new }   // one publish per batch, not per song
    }

    private func publishSummaries(_ batch: [(UUID, String, SongSummary)]) {
        for (_, key, summary) in batch { summaryIndex[key] = summary }
        summaries.merge(batch.map { ($0.0, $0.2) }) { _, new in new }
        states.merge(batch.map { ($0.0, .ready) }) { _, new in new }
    }

    /// Missing tags, then cover art, once the playlists' analyses are in: they're the last thing anyone waits on.
    private func loadCoversWhenIdle() async {
        while migrating || fullWorkers > 0 || !fullQueue.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        let untagged = songs.filter { $0.album == nil }
        for song in untagged { await loadMetadata(song.id) }
        if !untagged.isEmpty { save() }
        // Playlist songs first, the rest in library order; four files at a time, published in batches.
        let inPlaylists = Set(playlists.flatMap(\.songIDs))
        let ordered = songs.filter { inPlaylists.contains($0.id) } + songs.filter { !inPlaylists.contains($0.id) }
        await withTaskGroup(of: (UUID, NSImage?).self) { group in
            var batch: [(UUID, NSImage)] = [], next = 0
            func addTask() {
                guard next < ordered.count else { return }
                let song = ordered[next]; next += 1
                group.addTask { (song.id, await Self.artwork(song)) }
            }
            for _ in 0..<4 { addTask() }
            while let (id, image) = await group.next() {
                if let image { batch.append((id, image)) }
                if batch.count >= 40 { setArtwork(batch); batch = [] }
                addTask()
            }
            setArtwork(batch)
        }
    }

    /// A song's cover art: its own, or else that of another song from the same album and artist. Stem files often
    /// carry none while the plain release beside them does.
    func cover(_ id: UUID) -> NSImage? {
        if let own = artwork[id] { return own }
        guard let song = song(id), !song.albumName.isEmpty else { return nil }
        return albumArtwork[albumKey(song)]
    }

    private func albumKey(_ song: Song) -> String { "\(song.artist.lowercased())|\(song.albumName.lowercased())" }

    // MARK: Analysis

    private func enqueue(_ id: UUID) {
        states[id] = .waiting
        analysisQueue.append(id)
        pump()
    }

    private func pump() {
        guard !analyzing, !analysisQueue.isEmpty else { return }
        analyzing = true
        let id = analysisQueue.removeFirst()
        Task {
            await analyze(id)
            analyzing = false
            pump()
        }
    }

    private nonisolated static func cacheFile(_ song: Song) -> URL {
        AppPaths.cacheDir("analysis").appendingPathComponent(song.fileKey + ".json")
    }

    private nonisolated static func readAnalysis(_ url: URL) async -> SongAnalysis? {
        await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SongAnalysis.self, from: $0) }
        }.value
    }

    /// Songs without a summary: read their cached analysis once to make one, or analyze them.
    private func analyze(_ id: UUID) async {
        guard let song = song(id) else { return }
        do {
            let a: SongAnalysis
            if let cached = await Self.readAnalysis(Self.cacheFile(song)) {
                a = cached
            } else {
                states[id] = .analyzing
                let url = try await AudioSource.playableURL(for: song.url)
                playable[id] = url
                a = try await Analyzer.analyze(playable: url, id: song.fakeCatalogID)
                let file = Self.cacheFile(song)
                await Task.detached(priority: .utility) { try? JSONEncoder().encode(a).write(to: file) }.value
            }
            summaries[id] = a.summary
            summaryIndex[song.fileKey] = a.summary
            saveSummariesSoon()
            states[id] = .ready
            if playlists.contains(where: { $0.songIDs.contains(id) }) {
                analyses[id] = a
                invalidatePlans(involving: id)
            }
            loadPlaylistSongs()
        } catch {
            states[id] = .failed(String(describing: error))
        }
    }

    private func saveSummariesSoon() {
        guard !summarySavePending else { return }
        summarySavePending = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            summarySavePending = false
            let index = summaryIndex, url = summaryURL
            await Task.detached(priority: .utility) { try? JSONEncoder().encode(index).write(to: url, options: .atomic) }.value
        }
    }

    /// Queues full analyses (and playable files) for every analyzed song in a playlist that doesn't have them yet.
    private func loadPlaylistSongs() {
        guard started else { return }
        var seen = Set<UUID>()
        for id in playlists.flatMap(\.songIDs) where seen.insert(id).inserted {
            guard states[id] == .ready, analyses[id] == nil || playable[id] == nil, !fullLoading.contains(id) else { continue }
            fullLoading.insert(id)
            fullQueue.append(id)
        }
        while fullWorkers < 4, !fullQueue.isEmpty {
            let id = fullQueue.removeFirst()
            fullWorkers += 1
            Task {
                await loadFull(id)
                fullWorkers -= 1
                fullLoading.remove(id)
                loadPlaylistSongs()
            }
        }
    }

    private func loadFull(_ id: UUID) async {
        guard let song = song(id) else { return }
        do {
            if playable[id] == nil { playable[id] = try await AudioSource.playableURL(for: song.url) }
            if analyses[id] == nil {
                guard let a = await Self.readAnalysis(Self.cacheFile(song)) else {
                    enqueue(id)   // the cache file went missing: analyze again
                    return
                }
                analyses[id] = a
                invalidatePlans(involving: id)
            }
        } catch {
            states[id] = .failed(String(describing: error))
        }
    }

    func playableURL(_ id: UUID) -> URL? { playable[id] }

    // MARK: Genre changes

    func setGenre(_ genre: Genre, for id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[i].genre = genre
        invalidatePlans(involving: id)
        save()
    }

    // MARK: Plans

    private func planKey(_ a: Song, _ b: Song) -> String { "\(a.id)|\(a.genre.rawValue)>\(b.id)|\(b.genre.rawValue)" }

    private func invalidatePlans(involving id: UUID) {
        plans = plans.filter { !$0.key.contains(id.uuidString) }
    }

    /// The plan for a → b: cached, or started in the background (published when ready).
    func plan(from a: UUID, to b: UUID) -> PlanState? {
        guard let sa = song(a), let sb = song(b), let aa = analyses[a], let ab = analyses[b] else { return nil }
        let key = planKey(sa, sb)
        if let existing = plans[key] { return existing }
        guard !pendingPlans.contains(key) else { return .planning }
        pendingPlans.insert(key)   // not @Published: this is called while SwiftUI renders
        let (ga, gb) = (sa.genre, sb.genre)
        Task.detached {
            let state: PlanState
            do {
                let json = try SonicPlanner.shared.plan(from: try Analyzer.songJSON(aa, genre: ga), to: try Analyzer.songJSON(ab, genre: gb))
                state = .ready(try TransitionPlan(json: json))
            } catch {
                state = .failed(String(describing: error))
            }
            await MainActor.run {
                self.pendingPlans.remove(key)
                self.plans[key] = state
            }
        }
        return .planning
    }

    /// Renderer items for playing `ids` in order. Every song must be analyzed and every transition planned or
    /// failed; a failed transition becomes a straight cut to the next song rather than blocking the whole mix.
    func mixItems(_ ids: [UUID]) throws -> [MixRenderer.Item] {
        func side(_ a: UUID, _ b: UUID) throws -> TransitionPlan? {
            switch plan(from: a, to: b) {
            case .ready(let p): return p
            case .failed: return nil
            case .planning, nil: throw PlannerError("Some transitions aren't planned yet; wait for every ◆ to appear.")
            }
        }
        if let missing = ids.first(where: { playableURL($0) == nil || analyses[$0] == nil }) {
            throw PlannerError("\(song(missing)?.title ?? "A song") isn't ready yet.")
        }
        return try ids.enumerated().map { i, id in
            let audio = playableURL(id)!, a = analyses[id]!
            let entering = i > 0 ? try side(ids[i - 1], id)?.incoming : nil
            let leaving = i + 1 < ids.count ? try side(id, ids[i + 1])?.outgoing : nil
            return MixRenderer.Item(audio: audio, beats: a.beats, entering: entering, leaving: leaving)
        }
    }
}
