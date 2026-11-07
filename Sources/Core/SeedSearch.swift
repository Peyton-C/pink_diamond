import Foundation

/// `pink diamond --find-seed '<list_songs arguments>' <song>... [--adjacent] [--library <folder>]...`: a seed under
/// which list_songs' random draw comes out with these songs in it, for a prompt to hand an agent so that it meets them
/// by what looks like chance.
///
/// The draw shuffles whatever passed the filters, so a seed holds for one exact call against one exact library. The
/// search runs `matching`, the code list_songs filters with, on the arguments the prompt will give, and loads the
/// library the way add_songs does. Adding or removing any song in it changes what every seed draws.
///
/// It tries every seed list_songs could pick and returns one of those that work at random, so the seed looks like
/// any other. Then it draws with it through `list` itself and prints that, so what it shows is what the agent gets.
extension MCPServer {
    static func findSeed(_ args: [String]) async -> Int32 {
        var rest: [String] = [], folders: [String] = [], adjacent = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--adjacent": adjacent = true
            case "--library" where i + 1 < args.count: folders.append(args[i + 1]); i += 1
            default: rest.append(args[i])
            }
            i += 1
        }
        guard rest.count >= 2, let data = rest[0].data(using: .utf8),
              var call = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("usage: --find-seed '<list_songs arguments as JSON>' <song> <song>... [--adjacent] [--library <folder>]...")
            print("  a song is its id or words from its title and artist. The library is ~/Music/Stereo Stems by default")
            return 2
        }
        guard let random = (call["random"] as? NSNumber)?.intValue else { print("error: the arguments need random, the number of songs drawn"); return 2 }
        guard call["seed"] == nil else { print("error: leave seed out of the arguments, it is what this finds"); return 2 }
        let count = max(1, min(100, random))
        let server = MCPServer(extensions: true, renders: nil)
        let added = await server.add(folders.isEmpty ? ["~/Music/Stereo Stems"] : folders)
        do {
            let sorted = try server.matching(call).songs.sorted { $0.id < $1.id }
            let library = try server.matching(["unique": false]).songs
            var targets: [Int] = []
            for wanted in rest.dropFirst() {
                let words = wanted.lowercased().split(separator: " ")
                let hits = { (list: [Entry]) in
                    list.indices.filter { list[$0].id == wanted || words.allSatisfy("\(list[$0].title) \(list[$0].artist)".lowercased().contains) }
                }
                let found = hits(sorted)
                if found.count == 1 { targets.append(found[0]); continue }
                if found.isEmpty {
                    let elsewhere = hits(library).map { library[$0] }
                    print(elsewhere.isEmpty ? "error: no song in the library matches \(wanted)"
                          : "error: \(wanted) is in the library but not among these arguments' matches, filtered out or another version of it listed in its place:")
                    for s in elsewhere { print("  \(s.id)  \(s.title) - \(s.artist)") }
                } else {
                    print("error: \(wanted) matches several songs, give one's id:")
                    for j in found { print("  \(sorted[j].id)  \(sorted[j].title) - \(sorted[j].artist)") }
                }
                return 1
            }
            guard Set(targets).count == targets.count else { print("error: a song is named twice"); return 1 }
            guard targets.count <= count else { print("error: \(targets.count) songs can't all come out of a draw of \(count)"); return 1 }

            var working: [Int] = []
            for seed in 0..<seeds {
                let picked = draw(sorted.count, count, seed: seed)
                let at = targets.compactMap { picked.firstIndex(of: $0) }
                guard at.count == targets.count else { continue }
                if !adjacent || at.max()! - at.min()! == targets.count - 1 { working.append(seed) }
            }
            print("\(added["added"] ?? 0) songs added, \(sorted.count) match the arguments")
            guard let seed = working.randomElement() else {
                print("no seed of the \(seeds) draws them\(adjacent ? " side by side" : ""); draw more songs\(adjacent ? " or drop --adjacent" : "")")
                return 1
            }
            call["seed"] = seed
            let rows = try server.list(call)["songs"] as? [[String: Any]] ?? []
            print("\(working.count) seeds work. Seed \(seed) draws:")
            for (n, row) in rows.enumerated() {
                let id = row["id"] as? String ?? ""
                let mark = targets.contains { sorted[$0].id == id } ? "*" : " "
                print("\(mark) \(n + 1). \(row["title"] ?? "") - \(row["artist"] ?? "")  (\(id))")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
