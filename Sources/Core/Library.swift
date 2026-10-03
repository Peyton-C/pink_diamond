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
    /// Plans with the user's edits applied, which is what everything plays and draws.
    @Published private(set) var plans: [String: PlanState] = [:]
    /// The user's changes to transitions, by plan key.
    @Published private(set) var edits: [String: TransitionEdit] = [:]
    private var basePlans: [String: PlanState] = [:]   // Apple's plans, by plan key and variant
    @Published private(set) var artwork: [UUID: NSImage] = [:]
    /// Whether songs play at the same loudness. On unless turned off, and kept across launches.
    @Published var soundCheck = UserDefaults.standard.object(forKey: "soundCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundCheck, forKey: "soundCheck") }
    }
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
    private var editsURL: URL { AppPaths.support.appendingPathComponent("edits.json") }

    /// Launch fills in the library in order of what's on screen and needed: the summary index (one small file) for
    /// every row at once, then full analyses of playlist songs, off the main thread, then cover art and missing tags.
    /// Reading every analysis instead took minutes on the main thread for a 600-song library (~260 MB of JSON).
    init() {
        load()
        if let data = try? Data(contentsOf: summaryURL), let index = try? JSONDecoder().decode([String: SongSummary].self, from: data) {
            summaryIndex = index
        }
        if let data = try? Data(contentsOf: editsURL), let saved = try? JSONDecoder().decode([String: TransitionEdit].self, from: data) {
            edits = saved
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
                await self.loadMetadata(song.id, genre: true)
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

    /// Reads title, artist and album from the file's tags. Callers save. The genre tag is read only for a song being
    /// added (`genre`): filling in tags on an older library must not replace a genre the user has set by hand.
    private func loadMetadata(_ id: UUID, genre: Bool = false) async {
        guard let song = song(id) else { return }
        let asset = AVURLAsset(url: song.url)
        guard let items = try? await asset.load(.commonMetadata) else { return }
        var title: String?, artist: String?, album: String?
        for item in items {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
        }
        let tagged = genre ? await Genre.tagged(in: asset) : nil
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { songs[i].title = title }
        if let artist { songs[i].artist = artist }
        songs[i].album = album ?? ""
        if let tagged { songs[i].genre = tagged }
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
            guard var a = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(SongAnalysis.self, from: $0) }) else {
                return nil
            }
            // Analyses cached before Sound Check hold their loudness only in the Apple-format JSON.
            if a.loudness == nil { a.loudness = Loudness(audioAnalysis: a.audioAnalysisJSON) }
            return a
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

    /// The gain Sound Check plays a song at: 1 when it is off, or the song's loudness isn't known.
    func gain(_ id: UUID) -> Float { soundCheck ? analyses[id]?.loudness?.gain ?? 1 : 1 }

    // MARK: Genre changes

    func setGenre(_ genre: Genre, for id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[i].genre = genre
        invalidatePlans(involving: id)
        save()
    }

    // MARK: Plans

    /// A transition's key: the two songs as planned, genres included, since genres change the plan. Edits are keyed
    /// the same way, so an edit belongs to the plan it was made on and comes back if the genres are set back.
    private func planKey(_ a: Song, _ b: Song) -> String { "\(a.id)|\(a.genre.rawValue)>\(b.id)|\(b.genre.rawValue)" }

    private nonisolated func baseKey(_ key: String, _ variant: PlanVariant?) -> String { variant.map { key + "#" + $0.key } ?? key }

    private func invalidatePlans(involving id: UUID) {
        plans = plans.filter { !$0.key.contains(id.uuidString) }
        basePlans = basePlans.filter { !$0.key.contains(id.uuidString) }
    }

    /// The plan for a → b with the user's edits applied: cached, or started in the background (published when ready).
    /// Everything that plays or draws a transition gets it from here, so edits reach the deck views, playback and export.
    func plan(from a: UUID, to b: UUID) -> PlanState? {
        guard let sa = song(a), let sb = song(b) else { return nil }
        let key = planKey(sa, sb)
        if let existing = plans[key] { return existing }
        let edit = edits[key] ?? TransitionEdit()
        guard let base = basePlan(from: a, to: b, variant: edit.variant) else { return nil }
        guard case .ready(let plan) = base else { return base }
        let state = PlanState.ready(edit.isEmpty ? plan : plan.applying(edit))
        // Called while SwiftUI renders, where publishing isn't allowed; the next call finds it cached.
        Task { @MainActor in if self.plans[key] == nil { self.plans[key] = state } }
        return state
    }

    /// Apple's plan for a → b before any edits, as `variant` if given: cached, or started in the background.
    func basePlan(from a: UUID, to b: UUID, variant: PlanVariant? = nil) -> PlanState? {
        guard let sa = song(a), let sb = song(b), let aa = analyses[a], let ab = analyses[b] else { return nil }
        let key = planKey(sa, sb), base = baseKey(key, variant)
        if let existing = basePlans[base] { return existing }
        guard !pendingPlans.contains(base) else { return .planning }
        pendingPlans.insert(base)   // not @Published: this is called while SwiftUI renders
        let (ga, gb) = (variant?.fromGenre ?? sa.genre, variant?.toGenre ?? sb.genre)
        let criteria = variant?.criteriaPatch
        Task.detached {
            let state = Self.makePlan(aa, ga, ab, gb, criteria: criteria)
            await MainActor.run {
                self.pendingPlans.remove(base)
                self.basePlans[base] = state
                self.plans[key] = nil   // recomputed with the edit on the next request
            }
        }
        return .planning
    }

    private nonisolated static func makePlan(_ a: SongAnalysis, _ ga: Genre, _ b: SongAnalysis, _ gb: Genre,
                                             criteria: [String: Any]?) -> PlanState {
        do {
            let json = try SonicPlanner.shared.plan(from: try Analyzer.songJSON(a, genre: ga), to: try Analyzer.songJSON(b, genre: gb),
                                                    criteria: criteria)
            return .ready(try TransitionPlan(json: json))
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Edits

    func edit(from a: UUID, to b: UUID) -> TransitionEdit {
        guard let sa = song(a), let sb = song(b) else { return TransitionEdit() }
        return edits[planKey(sa, sb)] ?? TransitionEdit()
    }

    /// Replaces a transition's edit. With an undo manager the change is undoable (and redoable) and saved; without
    /// one it's a step of a drag still under way, applied but not saved.
    func setEdit(_ edit: TransitionEdit, from a: UUID, to b: UUID, undo: UndoManager? = nil, previous: TransitionEdit? = nil) {
        guard let sa = song(a), let sb = song(b) else { return }
        let key = planKey(sa, sb)
        let old = previous ?? edits[key] ?? TransitionEdit()
        if (edits[key] ?? TransitionEdit()) != edit {
            edits[key] = edit.isEmpty ? nil : edit
            plans[key] = nil
        }
        guard let undo else { return }
        saveEdits()
        guard old != edit else { return }
        undo.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.setEdit(old, from: a, to: b, undo: undo, previous: edit) }
        }
        undo.setActionName("Edit Transition")
    }

    private func saveEdits() {
        try? JSONEncoder().encode(edits).write(to: editsURL, options: .atomic)
    }

    struct Alternative: Identifiable {
        let variant: PlanVariant?
        let plan: TransitionPlan
        var id: String { variant?.key ?? "" }
    }

    /// The different plans Apple's planner makes for a → b: as planned, with both songs taken as each genre in turn,
    /// and under lower complexity ceilings. Plans that come out the same are listed once. About a second of planning.
    func alternatives(from a: UUID, to b: UUID) async -> [Alternative] {
        guard let sa = song(a), let sb = song(b), let aa = analyses[a], let ab = analyses[b] else { return [] }
        let key = planKey(sa, sb)
        var variants: [PlanVariant?] = [nil]
        variants += Genre.allCases.filter { $0 != sa.genre || $0 != sb.genre }.map { PlanVariant(fromGenre: $0, toGenre: $0) }
        variants += PlanVariant.Complexity.allCases.map { PlanVariant(fromGenre: sa.genre, toGenre: sb.genre, complexity: $0) }
        let cached = basePlans
        let results = await Task.detached { () -> [(PlanVariant?, PlanState)] in
            variants.map { v in
                if let known = cached[self.baseKey(key, v)] { return (v, known) }
                return (v, Self.makePlan(aa, v?.fromGenre ?? sa.genre, ab, v?.toGenre ?? sb.genre, criteria: v?.criteriaPatch))
            }
        }.value
        var seen = Set<String>(), list: [Alternative] = []
        for (v, state) in results {
            basePlans[baseKey(key, v)] = state
            guard case .ready(let plan) = state else { continue }
            let signature = String(format: "%@%d|%.1f|%.1f|%.1f", plan.algorithm, plan.styleID ?? -1, plan.outgoing.start,
                                   plan.incoming.start, plan.duration)
            if seen.insert(signature).inserted { list.append(Alternative(variant: v, plan: plan)) }
        }
        return list
    }

    /// Waits for every transition of playing `ids` in order to be planned or to fail. A shuffled order pairs songs
    /// the playlist doesn't, so nothing has asked for those plans yet and `mixItems` would refuse it.
    func planTransitions(_ ids: [UUID]) async {
        while true {
            var pending = false
            for (a, b) in zip(ids, ids.dropFirst()) {   // every pair, each pass: asking is what starts a plan
                if case .planning = plan(from: a, to: b) { pending = true }
            }
            guard pending else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
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
            return MixRenderer.Item(audio: audio, beats: a.beats, entering: entering, leaving: leaving, gain: gain(id))
        }
    }
}
