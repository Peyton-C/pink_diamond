# pink diamond
Apple Music AutoMix, without Apple Music

pink diamond plays transitions between local songs with macOS's own AutoMix planner, and displays them like a DJ application, with a full waveform. beat grid and effect lane.

## Build
Needs macOS 27 and Xcode 27.

```sh
./bundle.sh            # build/pink diamond.app
./bundle.sh --install  # and copy it to /Applications
```

`pink diamond --selftest <from> <to> [out.wav] [from genre] [to genre]` runs the whole pipeline without the UI.

`pink diamond --mcp` runs it as an MCP server, so an agent can plan, edit and render transitions. See [docs/mcp.md](docs/mcp.md).

## Use
- **Library**: drop in audio files, Native Instruments `.stem.mp4` files, or whole folders. Each song is analyzed once (tempo, beats, bars, sections, key, loudness, vocals). Browse by Songs, Artists, Albums or Genres with the tabs in the toolbar; cover art comes from each file's tags. A song's genre comes from its genre tag when that names one of Apple's twelve (Pop, Dance, Hip-Hop/Rap, R&B/Soul, Electronic, Alternative, Rock, Country, Latin, K-Pop, Reggae, Singer/Songwriter) and is Pop otherwise; change it in the Genre column. Keys show in Mixxx's key colours, in Lancelot (8A) or musical (Am) names, set in Settings.
- **Playlists**: right-click songs in the Library → Add to Playlist, or drop files onto a playlist; drag to reorder. Between every two songs, the ◆ row shows the planned transition. Click it to open the deck view.
- **Playback**: Play in a playlist's toolbar plays it through with every transition, and double-clicking a song plays from there. Shuffle, beside Play, plays the songs in a random order, planning the transitions that order needs; the playlist and Export Mix keep their own order. The bar at the bottom seeks within the song, and the media keys and Control Centre work too. Sound Check, on by default in Settings, plays every song at the same loudness, in previews and Export Mix as well.
- **Deck view**: both songs's RGB waveforms on the transition's timeline (coloured by low/mid/high), with beat grid, bars, sections (◆), the transition window and handoff point, and a lane for each automated effect. **Preview** (space) renders and plays it with a moving playhead.
- **Editing**: the deck view is also a mix editor. Drag a song to move its side of the transition by bars (⌥ for beats), even past the song's start or end. Set the length in bars with the control in the header or the handle at the end of the ruler, in phrase lengths or one bar at a time with ⇧; both songs stretch together and stay beat-matched. Drag automation points, double-click a lane to add or remove a point, and click a lane's name to change its curve or remove it. **Add effect** puts a filter sweep, reverb, echo, repeater, gater or flanger on either side. **Styles** lists the other plans Apple's planner makes for the pair, as other genres or with lower complexity. Edits are saved per transition and used for playback and export; ⌘Z undoes, **Reset** goes back to Apple's plan. An edit belongs to the genres it was made with, so changing a song's genre starts from a fresh plan.

## How it works
| Path | What |
| --- | --- |
| `Sources/Core/AudioSource.swift` | Stem detection and mixdown extraction (track 0, passthrough), decoding, DJ-style waveform data |
| `Sources/Core/Analyzer.swift` | MusicUnderstanding → Apple Music's AutoMix analysis format (incl. structure-based video cues, which the planner needs for genre styles) |
| `Sources/Core/SonicPlanner.swift`, `Trampoline.s` | macOS 27's `TransitionPlanner` from the private `_SonicKit_MusicKit`, called in-process |
| `Sources/Core/TransitionPlan.swift` | The plan: automation curves over song time, the plan's DSP-graph wiring, song time ↔ transition time |
| `Sources/Core/MixEdit.swift` | Transition edits applied over the plan: moved and stretched sides, replaced or added automation, planner variants, and the MCP server's loops, tails and stem levels |
| `Sources/Core/MixRenderer.swift` | Offline AVAudioEngine rebuilding the plan's DSP graph per song, including Apple's private AURemixFX |
| `Sources/Core/MCPServer.swift` | The `--mcp` server: its own songs and edits over the same analysis, planner and renderer |
| `Sources/Core/MixPlayer.swift` | Playlist playback: runs the renderer ahead of a realtime engine |
| `Sources/UI/` | SwiftUI: library, playlists, deck view |

Data lives in `~/Library/Application Support/pink diamond/` (library, playlists, transition edits) and `~/Library/Caches/pink diamond/` (analysis, stem mixdowns, cover art, previews).
