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
    // Optional from here on, as older libraries predate them.
    var added: Date?
    /// Every file pink diamond has seen this song as, the one at `path` included. Nil until a scan has read its tags.
    var versions: [SongVersion]?
    var pinned: Bool?                // the user chose the file at `path`, so a better one doesn't replace it
    var formerPaths: [String]?       // files it used to play, so a set saved with one of them still finds the song

    var url: URL { URL(fileURLWithPath: path) }
    var albumName: String { album ?? "" }
    var fakeCatalogID: String { "99" + String(fileKey.prefix(8)) }
    var source: StemSource { StemSource.of(title: title, path: path) }
    var key: String { SongName.key(title: title, artist: artist) }
}

/// One file of a song. A song keeps every file it has been seen as and plays one of them.
struct SongVersion: Codable, Hashable {
    var path: String
    var title: String                // as tagged, with the marker its source is read from
    var duration: Double             // 0 when the file couldn't be read
    /// As tagged, so a song that moves to this file shows its credits and not the last file's: a library that met
    /// Cheap Thrills in Fortnite first moved it to the official stems and went on showing Fortnite's "Sia ft. Sean
    /// Paul" and no album. Nil in libraries saved before versions kept them, and for a file written over in place.
    var artist: String?
    var album: String?
    /// The file's `fileKey` when its tags were read, so a scan notices a version written over and reads it again.
    /// Nil in libraries saved before versions kept it, which reads every version again once.
    var fileKey: String?
    var source: StemSource { StemSource.of(title: title, path: path) }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var songIDs: [UUID] = []
    /// Set on a playlist made by importing a saved set, which plays with the set's own genres, settings and edits.
    var mix: Mix?
}

enum SongState: Equatable {
    case waiting, analyzing, ready, failed(String)
    case missing                     // its file is gone and it has no other
}

enum PlanState {
    case planning, ready(TransitionPlan), failed(String)
}

@MainActor
final class Library: ObservableObject {
    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "flac", "caf", "alac"]

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
    private var stemFiles: [UUID: [URL]] = [:]   // for songs a mix plays as their stems
    private var pendingPlans: Set<String> = []
    private var analysisQueue: [UUID] = []
    private var analysisWorkers = 0
    private var summaryIndex: [String: SongSummary] = [:]   // by file key; persisted
    private var summarySavePending = false
    private var fullQueue: [UUID] = []
    private var fullLoading: Set<UUID> = []
    private var fullWorkers = 0
    private var started = false
    private var migrating = false
    /// Folders the user added, which pink diamond looks through again for files that have turned up since.
    @Published private(set) var folders: [String] = []
    private var ignored: Set<String> = []     // files removed by hand, which a scan would otherwise bring back
    private var scanning = false
    private var settling: Set<UUID> = []

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
            await scan()
            // The scan has already queued the songs it moved to another file, and marked the ones with none.
            let waiting = pending.filter { old in song(old.id)?.fileKey == old.fileKey && states[old.id] == .waiting }
            if !waiting.isEmpty { await summarize(waiting) }
            await loadCoversWhenIdle()
        }
        // Coming back to the app is when files have changed underneath it: they were ripped, culled or separated
        // again somewhere else. Looking then costs a directory listing, and needs no file-system watcher.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
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

    private struct Store: Codable { var songs: [Song]; var playlists: [Playlist]; var folders: [String]?; var ignored: [String]? }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(Store.self, from: data) else {
            playlists = [Playlist(name: "Playlist 1")]
            return
        }
        songs = store.songs
        folders = store.folders ?? []
        ignored = Set(store.ignored ?? [])
        playlists = store.playlists.isEmpty ? [Playlist(name: "Playlist 1")] : store.playlists
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(Store(songs: songs, playlists: playlists, folders: folders, ignored: ignored.sorted())).write(to: storeURL, options: .atomic)
    }

    func song(_ id: UUID) -> Song? { songs.first { $0.id == id } }

    // MARK: Mixes

    private func mix(_ playlist: UUID?) -> Mix? { playlist.flatMap { id in playlists.first { $0.id == id }?.mix } }

    func isMix(_ playlist: UUID?) -> Bool { mix(playlist) != nil }

    /// A song as `playlist` plays it: with the genre a mix gives it, which decides its plans there.
    func song(_ id: UUID, in playlist: UUID?) -> Song? {
        guard var song = song(id) else { return nil }
        if let genre = mix(playlist)?.songs[id.uuidString]?.genre { song.genre = genre }
        return song
    }

    /// Imports a set saved by the MCP server as a playlist of its own, adding the songs the library doesn't have, and
    /// returns the playlist's id. The set is copied, so saving over it later leaves this mix as it was.
    @discardableResult
    func importSet(_ url: URL) throws -> UUID {
        let saved: SavedSet
        do { saved = try JSONDecoder().decode(SavedSet.self, from: Data(contentsOf: url)) } catch {
            throw PlannerError("\(url.lastPathComponent) isn't a saved set.")
        }
        // Transitions are saved by position, so a set with a song missing can't be played as it was made. A file
        // that is gone is not a song missing when the library has the song as another file.
        let missing = saved.songs.map(\.path).filter { path in
            song(forFile: path) == nil
                && (!FileManager.default.fileExists(atPath: path) || !Self.audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()))
        }
        guard missing.isEmpty else {
            throw PlannerError("These songs of the set can't be found:\n" + missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n"))
        }
        add(saved.songs.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        let ids = saved.songs.compactMap { song(forFile: $0.path)?.id }
        guard ids.count == saved.songs.count else { throw PlannerError("Couldn't add every song of the set to the library.") }
        var mix = Mix()
        for (song, id) in zip(saved.songs, ids) {
            mix.songs[id.uuidString] = .init(genre: song.genre, keyShift: song.keyShift, gainDB: song.gainDB)
        }
        for t in saved.transitions where ids.indices.contains(t.from) && ids.indices.contains(t.to) {
            mix.edits[Mix.key(ids[t.from], ids[t.to])] = t.edit
        }
        let base = url.deletingPathExtension().lastPathComponent
        var name = base, n = 2
        while playlists.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        let playlist = Playlist(name: name, songIDs: ids, mix: mix)
        playlists.append(playlist)
        save()
        return playlist.id
    }

    /// Songs a mix sets stem levels on. They play as the sum of their stems, which have to be extracted first.
    private var remixedSongs: Set<UUID> {
        var ids = Set<UUID>()
        for mix in playlists.compactMap(\.mix) {
            for (key, edit) in mix.edits {
                let pair = key.split(separator: ">").compactMap { UUID(uuidString: String($0)) }
                guard pair.count == 2 else { continue }
                if TransitionEdit.stemLanes.contains(where: { edit.outgoing[$0] != nil }) { ids.insert(pair[0]) }
                if TransitionEdit.stemLanes.contains(where: { edit.incoming[$0] != nil }) { ids.insert(pair[1]) }
            }
        }
        return ids
    }

    // MARK: Adding songs

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                watch(url.path)
                files += Self.audioFiles(in: url)
            } else if Library.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        ignored.subtract(files.map(\.path))   // asked for by name, so wanted whatever was removed before
        let added = addRows(files)
        save()
        guard !added.isEmpty else { return }
        Task { await settle(added, new: Set(added)) }
    }

    /// A row for each file the library doesn't have, as a song or as another version of one. The rows wait for
    /// `settle` before they are analyzed: analysis takes seconds a song, and a file that turns out to be a worse
    /// version of a song is never played.
    private func addRows(_ files: [URL]) -> [UUID] {
        var known = Set(songs.flatMap { [$0.path] + ($0.versions ?? []).map(\.path) })
        var list = songs, added: [UUID] = []
        for f in files.sorted(by: { $0.path < $1.path }) where known.insert(f.path).inserted {
            let stem = AudioSource.isStem(f)
            var name = f.deletingPathExtension().lastPathComponent
            if stem, name.lowercased().hasSuffix(".stem") { name = String(name.dropLast(5)) }
            let song = Song(path: f.path, title: name, artist: "", isStem: stem, fileKey: fileKey(f), added: Date())
            list.append(song)
            added.append(song.id)
        }
        guard !added.isEmpty else { return [] }
        songs = list
        states.merge(added.map { ($0, .waiting) }) { _, new in new }
        return added
    }

    func remove(_ ids: Set<UUID>) {
        // Their files are still in the folders, and the next scan would bring them straight back.
        for song in songs where ids.contains(song.id) { ignored.formUnion([song.path] + (song.versions ?? []).map(\.path)) }
        songs.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].songIDs.removeAll { ids.contains($0) } }
        save()
    }

    /// Removes the songs whose files are gone and that have no other file to play.
    func removeMissing() {
        remove(Set(songs.filter { states[$0.id] == .missing }.map(\.id)))
    }

    // MARK: Folders

    private func watch(_ path: String) {
        guard !folders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        folders.removeAll { $0.hasPrefix(path + "/") }
        folders.append(path)
    }

    /// Stops looking in a folder. The songs already found there stay.
    func unwatch(_ path: String) {
        folders.removeAll { $0 == path }
        save()
    }

    nonisolated static func audioFiles(in folder: URL) -> [URL] {
        var files: [URL] = []
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let f = e?.nextObject() as? URL {
            if audioExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
        }
        return files
    }

    func rescan() { Task { await scan() } }

    /// Looks through the folders again and at every file the library knows: new files become songs or versions of
    /// them, versions that are gone are forgotten, and a file written over in place is read again. Then `reconcile`
    /// moves each song to the best file it has left. The looking is off the main thread, and a scan that finds
    /// nothing changed publishes nothing, since one runs every time the app comes forward.
    private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let folders = folders, skip = ignored
        let playing = songs.map { ($0.id, $0.path, $0.fileKey) }
        let others = songs.flatMap { song in (song.versions ?? []).filter { $0.path != song.path }.map { ($0.path, $0.fileKey) } }
        let (found, gone, changed, rewritten) = await Task.detached(priority: .utility) { () -> ([URL], Set<String>, [UUID], Set<String>) in
            let files = FileManager.default
            let found = folders.flatMap { Self.audioFiles(in: URL(fileURLWithPath: $0)) }.filter { !skip.contains($0.path) }
            var gone = Set(others.map(\.0).filter { !files.fileExists(atPath: $0) }), changed: [UUID] = []
            for (id, path, key) in playing {
                if !files.fileExists(atPath: path) { gone.insert(path) } else if fileKey(URL(fileURLWithPath: path)) != key { changed.append(id) }
            }
            let rewritten = Set(others.filter { !skip.contains($0.0) && files.fileExists(atPath: $0.0) && fileKey(URL(fileURLWithPath: $0.0)) != $0.1 }.map(\.0))
            return (found, gone, changed, rewritten)
        }.value

        // A version written over may be another song now: the Fortnite and Rock Band Cheap Thrills, retitled
        // "(feat. Sean Paul)" as the remix they are, stayed versions of the solo official stems, and adding them
        // again did nothing, since the library knew their paths. Taken off the song, they come back through
        // `addRows` as files turning up, and `reconcile` puts each back with its song or makes it one.
        var list = songs, pruned = false
        for i in list.indices {
            guard let versions = list[i].versions else { continue }
            let kept = versions.filter { $0.path == list[i].path || !gone.contains($0.path) && !rewritten.contains($0.path) }
            if kept.count != versions.count { list[i].versions = kept; pruned = true }
        }
        if pruned { songs = list }
        // Written over where it was, as bejeweled does when a song is separated again: the same path is a new file.
        for id in changed {
            if let song = song(id), song.path == playing.first(where: { $0.0 == id })?.1 {
                use(SongVersion(path: song.path, title: song.title, duration: 0), for: id)
            }
        }
        // A file that was gone and is back, on a drive that was unplugged say.
        for song in songs where states[song.id] == .missing && !gone.contains(song.path) { enqueue(song.id) }
        let fresh = addRows(found + rewritten.map { URL(fileURLWithPath: $0) })
        // Also a song whose file's version has no credits, from a library saved before versions kept them, or one
        // `use` moved without them: its tags are read again, which puts back the artist and album of the file it plays.
        let untagged = songs.filter { song in
            (song.versions?.first { $0.path == song.path }?.artist == nil) && !gone.contains(song.path) && !settling.contains(song.id)
        }.map(\.id)
        let lost = songs.contains { gone.contains($0.path) && states[$0.id] != .missing }
        guard !fresh.isEmpty || !untagged.isEmpty || !changed.isEmpty || pruned || lost else { return }
        await settle(Array(Set(fresh + untagged + changed)), new: Set(fresh))
    }

    struct FileTags {
        var path: String
        var title: String?, artist: String?, album: String?, genre: Genre?
        var duration = 0.0
        var read = false
    }

    nonisolated static func tags(of url: URL, genre: Bool) async -> FileTags {
        var tags = FileTags(path: url.path)
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return tags }
        for item in items {
            if item.commonKey == .commonKeyTitle { tags.title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { tags.artist = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyAlbumName { tags.album = try? await item.load(.stringValue) }
        }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite { tags.duration = seconds }
        if genre { tags.genre = await Genre.tagged(in: asset) }
        tags.read = true
        return tags
    }

    /// Reads the tags of rows that were just added, or added before songs had versions, then lets `reconcile`
    /// decide which of them are songs of their own, and only those are analyzed. The genre tag is read only for a
    /// song being added (`new`): filling in an older library must not replace a genre the user has set by hand.
    /// Tags are read eight files at a time and applied in one publish, for the reason `summarize` batches.
    private func settle(_ ids: [UUID], new: Set<UUID>) async {
        settling.formUnion(ids)
        let files = ids.compactMap { id in song(id).map { (id, $0.url, new.contains(id)) } }
        var read: [UUID: FileTags] = [:]
        await withTaskGroup(of: (UUID, FileTags).self) { group in
            var next = 0
            func addTask() {
                guard next < files.count else { return }
                let (id, url, genre) = files[next]; next += 1
                group.addTask { (id, await Self.tags(of: url, genre: genre)) }
            }
            for _ in 0..<8 { addTask() }
            while let (id, tags) = await group.next() {
                read[id] = tags
                addTask()
            }
        }
        var list = songs
        for i in list.indices {
            // Not if the song moved to another file while its tags were being read.
            guard let tags = read[list[i].id], tags.path == list[i].path else { continue }
            if let title = tags.title, !title.isEmpty { list[i].title = title }
            if let artist = tags.artist { list[i].artist = artist }
            if tags.read { list[i].album = tags.album ?? "" }
            if let genre = tags.genre { list[i].genre = genre }
            let version = SongVersion(path: list[i].path, title: list[i].title, duration: tags.duration, artist: list[i].artist, album: list[i].album,
                                      fileKey: list[i].fileKey)
            list[i].versions = (list[i].versions ?? []).filter { $0.path != version.path } + [version]
        }
        songs = list
        settling.subtract(ids)
        reconcile(new: new)
        for id in new where states[id] == .waiting && !analysisQueue.contains(id) { enqueue(id) }
        save()
        await loadArtwork(songs.filter { new.contains($0.id) })
    }

    // MARK: Versions

    /// How far apart two files of a song can run and still be taken for the same cut of it. Stems of one recording
    /// from different sources differ by a few seconds of silence at either end (Poker Face: 236.8 s official,
    /// 240.0 s in Fortnite Festival), and a different cut by more (Bad Romance: 301.5 s against 292.5 s).
    nonisolated static let sameCut = 5.0

    /// The song that plays the file at `path`, has it as another version, or played it once.
    func song(forFile path: String) -> Song? {
        songs.first { $0.path == path }
            ?? songs.first { ($0.versions ?? []).contains { $0.path == path } }
            ?? songs.first { ($0.formerPaths ?? []).contains(path) }
    }

    /// The songs that files and folders given to `add` ended up as, whether as rows of their own or as versions.
    func songs(from urls: [URL]) -> [Song] {
        songs.filter { song in
            ([song.path] + (song.versions ?? []).map(\.path)).contains { path in
                urls.contains { $0.path == path || $0.hasDirectoryPath && path.hasPrefix($0.path + "/") }
            }
        }
    }

    /// A better file of the song than the one it plays, which `reconcile` left alone because it is another cut or
    /// because the user chose this one.
    func betterVersion(of song: Song) -> SongVersion? {
        let rank = song.source.rank
        return (song.versions ?? []).filter { $0.path != song.path && $0.source.rank < rank }.min { $0.source.rank < $1.source.rank }
    }

    /// Plays a song from the file the user picked, or with nil goes back to choosing for them. Picking the best
    /// file there is doesn't pin the song to it: that is taking an upgrade, and the next one should still arrive.
    func setVersion(_ path: String?, for id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        if let path, let version = songs[i].versions?.first(where: { $0.path == path }) {
            let best = (songs[i].versions ?? []).allSatisfy { $0.source.rank >= version.source.rank }
            songs[i].pinned = best ? nil : true
            if path != songs[i].path { use(version, for: id) }
        } else {
            songs[i].pinned = nil
            reconcile()
        }
        save()
    }

    private func isEdited(_ id: UUID) -> Bool {
        let id = id.uuidString
        return edits.keys.contains { $0.contains(id) } || playlists.contains { $0.mix?.edits.keys.contains { $0.contains(id) } ?? false }
    }

    /// The file a song should move to, if any. A song whose file is gone takes the best it has. Otherwise a better
    /// file replaces the one it plays when the two are the same cut. A different cut replaces it only when nothing
    /// was built on the old one, no edited transition and no mix, and neither file is a game's cut, which is
    /// shortened to fit the game.
    private func choice(for song: Song) -> SongVersion? {
        let files = FileManager.default
        let others = (song.versions ?? []).filter { $0.path != song.path && files.fileExists(atPath: $0.path) }
            .sorted { $0.source.rank < $1.source.rank }
        guard !others.isEmpty else { return nil }
        let length = song.versions?.first { $0.path == song.path && $0.duration > 0 }?.duration ?? summaries[song.id]?.duration
        let source = song.source
        func fits(_ v: SongVersion) -> Bool {
            if let length, v.duration > 0, abs(v.duration - length) <= Self.sameCut { return true }
            return !v.source.gameCut && !source.gameCut && !isEdited(song.id)
        }
        guard files.fileExists(atPath: song.path) else { return others.first(where: fits) ?? others[0] }
        guard song.pinned != true else { return nil }
        return others.first { $0.source.rank < source.rank && fits($0) }
    }

    /// Makes the library one row a song, each playing the best file it can.
    ///
    /// Rows of the same song become one, and playlists, mixes and edits that named the others name it instead.
    /// The row kept is the oldest, so the song keeps its genre. A row just added (`new`) is a file turning up,
    /// which `choice` weighs against the one the song plays. Rows that were both here already are versions an
    /// older library kept as songs of their own, and the song plays the best of those that still exists.
    ///
    /// Then every song moves to the file `choice` gives it, and a song left with no file at all is marked missing.
    private func reconcile(new: Set<UUID> = []) {
        let files = FileManager.default
        var groups: [String: [Int]] = [:]
        for (i, song) in songs.enumerated() { groups[song.key, default: []].append(i) }
        var list = songs, into: [UUID: UUID] = [:], moves: [(UUID, SongVersion)] = []
        for members in groups.values where members.count > 1 {
            let order = { (i: Int) in (files.fileExists(atPath: list[i].path) ? 0 : 1, list[i].source.rank, i) }
            let settled = members.filter { !new.contains(list[$0].id) }
            let best = (settled.isEmpty ? members : settled).min { order($0) < order($1) }!
            let keep = settled.first ?? best
            if best != keep, files.fileExists(atPath: list[best].path) {
                let length = list[best].versions?.first { $0.path == list[best].path }?.duration ?? 0
                moves.append((list[keep].id, SongVersion(path: list[best].path, title: list[best].title, duration: length,
                                                         artist: list[best].artist, album: list[best].album, fileKey: list[best].fileKey)))
            }
            for i in members where i != keep {
                into[list[i].id] = list[keep].id
                let held = Set((list[keep].versions ?? []).map(\.path))
                let more = (list[i].versions ?? []).filter { !held.contains($0.path) }
                if !more.isEmpty { list[keep].versions = (list[keep].versions ?? []) + more }
                // A row that was a song of its own may be in a saved set under its file. A new one never was.
                guard !new.contains(list[i].id) else { continue }
                var former = list[keep].formerPaths ?? []
                for path in [list[i].path] + (list[i].formerPaths ?? []) where !former.contains(path) { former.append(path) }
                list[keep].formerPaths = former
            }
        }
        if !into.isEmpty {
            func rekeyed<V>(_ old: [String: V]) -> [String: V] {
                var new: [String: V] = [:], moved: [(String, V)] = []
                for (key, value) in old {
                    var k = key
                    for (from, to) in into where k.contains(from.uuidString) { k = k.replacingOccurrences(of: from.uuidString, with: to.uuidString) }
                    if k == key { new[key] = value } else { moved.append((k, value)) }
                }
                for (key, value) in moved where new[key] == nil { new[key] = value }   // what the kept row had stays
                return new
            }
            songs = list.filter { into[$0.id] == nil }
            var lists = playlists
            for i in lists.indices {
                lists[i].songIDs = lists[i].songIDs.map { into[$0] ?? $0 }
                if let mix = lists[i].mix { lists[i].mix = Mix(songs: rekeyed(mix.songs), edits: rekeyed(mix.edits)) }
            }
            playlists = lists
            edits = rekeyed(edits)
            saveEdits()
            for id in into.keys {
                playable[id] = nil; stemFiles[id] = nil
                states[id] = nil; summaries[id] = nil; analyses[id] = nil; artwork[id] = nil
                invalidatePlans(involving: id)
            }
            for id in Set(into.values) { invalidatePlans(involving: id) }
            for (id, version) in moves { use(version, for: id) }
        }
        for song in songs {
            if let version = choice(for: song) { use(version, for: song.id) }
        }
        // A file that is now another song's is no longer one this song played: the Fortnite Cheap Thrills, split off
        // the official stems as the Sean Paul remix, stayed in the official row's former paths.
        let held = Set(songs.flatMap { [$0.path] + ($0.versions ?? []).map(\.path) })
        var cleaned = songs, stale = false
        for i in cleaned.indices {
            guard let former = cleaned[i].formerPaths else { continue }
            let own = Set([cleaned[i].path] + (cleaned[i].versions ?? []).map(\.path))
            let kept = former.filter { !held.contains($0) || own.contains($0) }
            if kept.count != former.count { cleaned[i].formerPaths = kept.isEmpty ? nil : kept; stale = true }
        }
        if stale { songs = cleaned }
        let missing = songs.filter { states[$0.id] != .missing && !files.fileExists(atPath: $0.path) }
        if !missing.isEmpty { states.merge(missing.map { ($0.id, .missing) }) { _, new in new } }
        loadPlaylistSongs()
    }

    /// Points a song at another of its files. Everything known about the old file is dropped, since the new one is
    /// a different recording as far as an analysis or a plan can tell, and the song is analyzed again.
    private func use(_ version: SongVersion, for id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        let old = songs[i].path
        if old != version.path {
            songs[i].formerPaths = ((songs[i].formerPaths ?? []).filter { $0 != old && $0 != version.path }) + [old]
        }
        songs[i].path = version.path
        songs[i].title = version.title
        if let artist = version.artist {
            songs[i].artist = artist
            songs[i].album = version.album
        }
        songs[i].isStem = AudioSource.isStem(songs[i].url)
        songs[i].fileKey = fileKey(songs[i].url)
        playable[id] = nil
        stemFiles[id] = nil
        analyses[id] = nil
        summaries[id] = nil
        artwork[id] = nil
        invalidatePlans(involving: id)
        enqueue(id)
        let song = songs[i]
        Task { await loadArtwork([song]) }
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

    /// Cover art, once the playlists' analyses are in: they're the last thing anyone waits on.
    private func loadCoversWhenIdle() async {
        while migrating || fullWorkers > 0 || !fullQueue.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        // Playlist songs first, the rest in library order.
        let inPlaylists = Set(playlists.flatMap(\.songIDs))
        await loadArtwork(songs.filter { inPlaylists.contains($0.id) } + songs.filter { !inPlaylists.contains($0.id) })
    }

    /// Cover art for `ordered`, four files at a time, published in batches.
    private func loadArtwork(_ ordered: [Song]) async {
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
        while analysisWorkers < Analyzer.workerLimit, !analysisQueue.isEmpty {
            let id = analysisQueue.removeFirst()
            analysisWorkers += 1
            Task {
                await analyze(id)
                analysisWorkers -= 1
                pump()
            }
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
        guard FileManager.default.fileExists(atPath: song.path) else { states[id] = .missing; return }
        do {
            let a: SongAnalysis
            var extracted: URL?
            if let cached = await Self.readAnalysis(Self.cacheFile(song)) {
                a = cached
            } else {
                states[id] = .analyzing
                let url = try await AudioSource.playableURL(for: song.url)
                extracted = url
                a = try await Analyzer.analyze(playable: url, id: song.fakeCatalogID)
                let file = Self.cacheFile(song)
                await Task.detached(priority: .utility) { try? JSONEncoder().encode(a).write(to: file) }.value
            }
            // The song moved to another file while this one was being read, and that file's analysis is on its way.
            guard self.song(id)?.fileKey == song.fileKey else { return }
            if let extracted { playable[id] = extracted }
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
            if self.song(id)?.fileKey == song.fileKey { states[id] = .failed(String(describing: error)) }
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
        let remixed = remixedSongs
        for id in playlists.flatMap(\.songIDs) where seen.insert(id).inserted {
            guard states[id] == .ready, analyses[id] == nil || playable[id] == nil || remixed.contains(id) && stemFiles[id] == nil,
                  !fullLoading.contains(id) else { continue }
            fullLoading.insert(id)
            fullQueue.append(id)
        }
        while fullWorkers < 4, !fullQueue.isEmpty {
            let id = fullQueue.removeFirst()
            fullWorkers += 1
            Task {
                await loadFull(id, stems: remixed.contains(id))
                fullWorkers -= 1
                fullLoading.remove(id)
                loadPlaylistSongs()
            }
        }
    }

    private func loadFull(_ id: UUID, stems: Bool) async {
        guard let song = song(id) else { return }
        guard FileManager.default.fileExists(atPath: song.path) else { states[id] = .missing; return }
        // Nothing read here is kept if the song moved to another file meanwhile: `use` has queued that one.
        let current = { self.song(id)?.fileKey == song.fileKey }
        do {
            if playable[id] == nil {
                let url = try await AudioSource.playableURL(for: song.url)
                guard current() else { return }
                playable[id] = url
            }
            if stems, stemFiles[id] == nil {
                let urls = try await AudioSource.stemURLs(for: song.url)
                guard current() else { return }
                stemFiles[id] = urls
            }
            if analyses[id] == nil {
                let cached = await Self.readAnalysis(Self.cacheFile(song))
                guard current() else { return }
                guard let a = cached else {
                    enqueue(id)   // the cache file went missing: analyze again
                    return
                }
                analyses[id] = a
                invalidatePlans(involving: id)
            }
        } catch {
            if current() { states[id] = .failed(String(describing: error)) }
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

    /// Where a transition's plan with its edit applied is kept. A mix's edits are its own, so its plans are too.
    private func planKey(_ key: String, in playlist: UUID?) -> String {
        isMix(playlist) ? "\(playlist?.uuidString ?? "")/\(key)" : key
    }

    private func invalidatePlans(involving id: UUID) {
        plans = plans.filter { !$0.key.contains(id.uuidString) }
        basePlans = basePlans.filter { !$0.key.contains(id.uuidString) }
    }

    /// The plan for a → b with the user's edits applied: cached, or started in the background (published when ready).
    /// Everything that plays or draws a transition gets it from here, so edits reach the deck views, playback and export.
    /// In a mix, `playlist` makes it the mix's transition and not the user's own between the same two songs.
    func plan(from a: UUID, to b: UUID, in playlist: UUID? = nil) -> PlanState? {
        guard let sa = song(a, in: playlist), let sb = song(b, in: playlist) else { return nil }
        let key = planKey(planKey(sa, sb), in: playlist)
        if let existing = plans[key] { return existing }
        let edit = edit(from: a, to: b, in: playlist)
        guard let base = basePlan(from: a, to: b, variant: edit.variant, in: playlist) else { return nil }
        guard case .ready(let plan) = base else { return base }
        let state = PlanState.ready(edit.isEmpty ? plan : plan.applying(edit))
        // Called while SwiftUI renders, where publishing isn't allowed; the next call finds it cached.
        Task { @MainActor in if self.plans[key] == nil { self.plans[key] = state } }
        return state
    }

    /// Apple's plan for a → b before any edits, as `variant` if given: cached, or started in the background.
    func basePlan(from a: UUID, to b: UUID, variant: PlanVariant? = nil, in playlist: UUID? = nil) -> PlanState? {
        guard let sa = song(a, in: playlist), let sb = song(b, in: playlist), let aa = analyses[a], let ab = analyses[b] else { return nil }
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
                // Recomputed with the edit on the next request, in every mix that has the pair too.
                self.plans = self.plans.filter { !$0.key.hasSuffix(key) }
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

    func edit(from a: UUID, to b: UUID, in playlist: UUID? = nil) -> TransitionEdit {
        if let mix = mix(playlist) { return mix.edits[Mix.key(a, b)] ?? TransitionEdit() }
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

    /// A song as the renderer plays it in `playlist`, between these two sides. A mix adds what Apple's AutoMix has no
    /// counterpart for: its loops, its key shift, its gain on top of Sound Check, and its stems. As in the MCP server,
    /// a song plays as its stems only if one of its sides sets a stem's level: the sum of the stems is not the
    /// mixdown sample for sample, so a song nobody remixes plays the mixdown.
    private func item(_ id: UUID, entering: TransitionSide?, leaving: TransitionSide?, in playlist: UUID?) throws -> MixRenderer.Item {
        let remixed = [entering, leaving].contains { side in TransitionEdit.stemLanes.contains { side?.automations[$0] != nil } }
        guard let audio = playableURL(id), let a = analyses[id], !remixed || stemFiles[id] != nil else {
            throw PlannerError("\(song(id)?.title ?? "A song") isn't ready yet.")
        }
        let settings = mix(playlist)?.songs[id.uuidString]
        return MixRenderer.Item(audio: audio, beats: a.beats, entering: entering, leaving: leaving,
                                gain: gain(id) * Float(pow(10, (settings?.gainDB ?? 0) / 20)),
                                loops: [entering?.loop, leaving?.loop].compactMap { $0 },
                                stems: remixed ? stemFiles[id] ?? [] : [], pitch: Double(settings?.keyShift ?? 0))
    }

    /// Renderer items for one transition on its own, for the deck view's preview.
    func previewItems(_ plan: TransitionPlan, from a: UUID, to b: UUID, in playlist: UUID? = nil) throws -> [MixRenderer.Item] {
        [try item(a, entering: nil, leaving: plan.outgoing, in: playlist), try item(b, entering: plan.incoming, leaving: nil, in: playlist)]
    }

    /// Renderer items for playing `ids` in order. Every song must be analyzed and every transition planned or
    /// failed; a failed transition becomes a straight cut to the next song rather than blocking the whole mix.
    func mixItems(_ ids: [UUID], in playlist: UUID? = nil) throws -> [MixRenderer.Item] {
        func side(_ a: UUID, _ b: UUID) throws -> TransitionPlan? {
            switch plan(from: a, to: b, in: playlist) {
            case .ready(let p): return p
            case .failed: return nil
            case .planning, nil: throw PlannerError("Some transitions aren't planned yet; wait for every ◆ to appear.")
            }
        }
        if let missing = ids.first(where: { playableURL($0) == nil || analyses[$0] == nil }) {
            throw PlannerError("\(song(missing)?.title ?? "A song") isn't ready yet.")
        }
        return try ids.enumerated().map { i, id in
            let entering = i > 0 ? try side(ids[i - 1], id)?.incoming : nil
            let leaving = i + 1 < ids.count ? try side(id, ids[i + 1])?.outgoing : nil
            return try item(id, entering: entering, leaving: leaving?.following(entering), in: playlist)
        }
    }
}
