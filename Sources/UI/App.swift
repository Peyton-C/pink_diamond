import SwiftUI

@main
struct Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--selftest" || args.first == "--mcp" {
            let done = DispatchSemaphore(value: 0)
            var status: Int32 = 0
            Task.detached {
                status = args.first == "--mcp" ? await MCPServer().run() : await SelfTest.run(Array(args.dropFirst()))
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
    @StateObject private var library: Library
    @StateObject private var player: MixPlayer

    init() {
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: MixPlayer(library: library))
    }

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
        Settings { SettingsView().environmentObject(library).environmentObject(player) }
    }
}

struct SettingsView: View {
    @AppStorage(KeyNotation.storageKey) private var notation = KeyNotation.lancelot
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    var body: some View {
        Form {
            Toggle("Sound Check", isOn: Binding(get: { library.soundCheck }, set: { on in
                library.soundCheck = on
                // The renderer runs ahead of playback with the gains it started with: restart it where it is.
                try? player.seek(to: player.songTime)
            }))
            .help("Play every song at the same loudness")
            Picker("Key names", selection: $notation) {
                ForEach(KeyNotation.allCases) { n in
                    HStack { KeyBadge(key: "A minor", notation: n); Text(n.label) }.tag(n)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }
}

enum SidebarItem: Hashable { case library, playlist(UUID) }

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: MixPlayer
    @State private var selection: SidebarItem? = .library
    @State private var renaming: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("pink diamond") {
                    Label("Library", systemImage: "music.note.house").tag(SidebarItem.library)
                }
                Section("Playlists") {
                    ForEach($library.playlists) { $playlist in
                        Label {
                            if renaming == playlist.id {
                                TextField("Name", text: $playlist.name)
                                    .focused($renameFocused)
                                    .onSubmit { endRename() }
                                    .onAppear { renameFocused = true }
                            } else {
                                Text(playlist.name)
                            }
                        } icon: {
                            Image(systemName: player.queue?.context == playlist.id ? "speaker.wave.2.fill" : "music.note.list")
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
            // Clicking away ends a rename as Return does; without this the field stayed up indefinitely.
            .onChange(of: renameFocused) { _, focused in if !focused { endRename() } }
            .safeAreaInset(edge: .bottom) {
                Button { newPlaylist() } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            // A plain stack rather than a safe-area inset: the playlist's split view is AppKit-backed and ignores
            // insets, so the bar would cover its last row.
            VStack(spacing: 0) {
                switch selection {
                case .playlist(let id): PlaylistView(playlistID: id).id(id)
                default: LibraryView()
                }
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

    private func endRename() {
        guard renaming != nil else { return }
        renaming = nil
        library.save()
    }

    private func delete(_ id: UUID) {
        if player.queue?.context == id { player.stop() }
        library.playlists.removeAll { $0.id == id }
        library.save()
        if selection == .playlist(id) { selection = .library }
    }
}
