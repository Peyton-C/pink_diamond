import SwiftUI

@main
struct Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--selftest" {
            let done = DispatchSemaphore(value: 0)
            var status: Int32 = 0
            Task.detached {
                status = await SelfTest.run(Array(args.dropFirst()))
                done.signal()
            }
            done.wait()
            exit(status)
        }
        PinkDiamondApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ExportMixKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var exportMix: (() -> Void)? {
        get { self[ExportMixKey.self] }
        set { self[ExportMixKey.self] = newValue }
    }
}

struct ExportMixCommand: View {
    @FocusedValue(\.exportMix) private var exportMix
    var body: some View {
        Button("Export Mix…") { exportMix?() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportMix == nil)
    }
}

struct PinkDiamondApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var player = MixPlayer()

    var body: some Scene {
        WindowGroup("pink diamond") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .importExport) { ExportMixCommand() }
        }
    }
}

enum SidebarItem: Hashable { case library, playlist(UUID) }

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    @State private var selection: SidebarItem? = .library
    @State private var renaming: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("pink diamond") {
                    Label("Library", systemImage: "music.note.house").tag(SidebarItem.library)
                }
                Section("Playlists") {
                    ForEach($library.playlists) { $playlist in
                        Group {
                            if renaming == playlist.id {
                                TextField("Name", text: $playlist.name).onSubmit { renaming = nil; library.save() }
                            } else {
                                Label(playlist.name, systemImage: player.queue?.context == playlist.id ? "speaker.wave.2.fill" : "music.note.list")
                            }
                        }
                        .tag(SidebarItem.playlist(playlist.id))
                        .contextMenu {
                            Button("Rename") { renaming = playlist.id }
                            Button("Delete", role: .destructive) { delete(playlist.id) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                Button { newPlaylist() } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch selection {
                case .playlist(let id): PlaylistView(playlistID: id).id(id)
                default: LibraryView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.queue != nil { NowPlayingBar() }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func newPlaylist() {
        let p = Playlist(name: "Playlist \(library.playlists.count + 1)")
        library.playlists.append(p)
        library.save()
        selection = .playlist(p.id)
        renaming = p.id
    }

    private func delete(_ id: UUID) {
        if player.queue?.context == id { player.stop() }
        library.playlists.removeAll { $0.id == id }
        library.save()
        if selection == .playlist(id) { selection = .library }
    }
}
