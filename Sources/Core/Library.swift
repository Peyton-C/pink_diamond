import AVFoundation
import Foundation
import SwiftUI

struct Song: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var genre: Genre = .pop
    var isStem: Bool
    var fileKey: String

    var url: URL { URL(fileURLWithPath: path) }
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
    @Published var playlists: [Playlist] = []
    @Published private(set) var states: [UUID: SongState] = [:]
    @Published private(set) var analyses: [UUID: SongAnalysis] = [:]
    @Published private(set) var plans: [String: PlanState] = [:]
    private var playable: [UUID: URL] = [:]
    private var pendingPlans: Set<String> = []
    private var analysisQueue: [UUID] = []
    private var analyzing = false

    private var storeURL: URL { AppPaths.support.appendingPathComponent("library.json") }

    init() {
        load()
        for song in songs { enqueue(song.id) }
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
            Task { await self.loadMetadata(song.id) }
        }
        save()
    }

    func remove(_ ids: Set<UUID>) {
        songs.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].songIDs.removeAll { ids.contains($0) } }
        save()
    }

    private func loadMetadata(_ id: UUID) async {
        guard let song = song(id) else { return }
        let asset = AVURLAsset(url: song.url)
        guard let items = try? await asset.load(.commonMetadata) else { return }
        var title: String?, artist: String?
        for item in items {
            if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
        }
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { songs[i].title = title }
        if let artist { songs[i].artist = artist }
        save()
    }

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

    private func analyze(_ id: UUID) async {
        guard let song = song(id) else { return }
        let cacheFile = AppPaths.cacheDir("analysis").appendingPathComponent(song.fileKey + ".json")
        do {
            let url = try await AudioSource.playableURL(for: song.url)
            playable[id] = url
            if let data = try? Data(contentsOf: cacheFile), let a = try? JSONDecoder().decode(SongAnalysis.self, from: data) {
                analyses[id] = a
            } else {
                states[id] = .analyzing
                let a = try await Analyzer.analyze(playable: url, id: song.fakeCatalogID)
                try? JSONEncoder().encode(a).write(to: cacheFile)
                analyses[id] = a
            }
            states[id] = .ready
            invalidatePlans(involving: id)
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
}
