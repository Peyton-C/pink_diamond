# pink diamond
Apple Music AutoMix, without Apple Music

pink diamond plays transitions between local songs with macOS's own AutoMix planner, and displays them like a DJ application, with a full waveform. beat grid and effect lane.

## Build
Needs macOS 27 and Xcode (not just the Command Line Tools).

```sh
./bundle.sh            # build/pink diamond.app
./bundle.sh --install  # and copy it to /Applications
```

`pink diamond --selftest <from> <to> [out.wav] [from genre] [to genre]` runs the whole pipeline without the UI.

## Use
- **Library**: drop in audio files, Native Instruments `.stem.mp4` files, or whole folders. Each song is analyzed once (tempo, beats, bars, sections, key, loudness, vocals). Browse by Songs, Artists, Albums or Genres with the tabs in the toolbar; cover art comes from each file's tags.
- **Playlists**: right-click songs in the Library → Add to Playlist, or drop files onto a playlist; drag to reorder. Between every two songs, the ◆ row shows the planned transition. Click it to open the deck view.
- **Playback**: Play in a playlist's toolbar plays it through with every transition, and double-clicking a song plays from there. It sounds exactly like Export Mix, and needs every song analyzed and every ◆ planned first. A transition that can't be planned becomes a straight cut.
- **Deck view**: both songs' waveforms on the transition's timeline (coloured by low/mid/high), with beat grid, bars, sections (◆), the transition window and handoff point, and a lane for each automated effect. **Preview** (space) renders and plays it with a moving playhead.
- **Export Mix** renders the whole playlist as one WAV.

## How it works
| Path | What |
| --- | --- |
| `Sources/Core/AudioSource.swift` | Stem detection and mixdown extraction (track 0, passthrough), decoding, DJ-style waveform data |
| `Sources/Core/Analyzer.swift` | MusicUnderstanding → Apple Music's AutoMix analysis format (incl. structure-based video cues, which the planner needs for genre styles) |
| `Sources/Core/SonicPlanner.swift`, `Trampoline.s` | macOS 27's `TransitionPlanner` from the private `_SonicKit_MusicKit`, called in-process |
| `Sources/Core/TransitionPlan.swift` | The plan: automation curves over song time, the plan's DSP-graph wiring, song time ↔ transition time |
| `Sources/Core/MixRenderer.swift` | Offline AVAudioEngine rebuilding the plan's DSP graph per song, including Apple's private AURemixFX |
| `Sources/Core/MixPlayer.swift` | Playlist playback: runs the renderer ahead of a realtime engine |
| `Sources/UI/` | SwiftUI: library, playlists, deck view |

Data lives in `~/Library/Application Support/pink diamond/` (library, playlists) and `~/Library/Caches/pink diamond/` (analysis, stem mixdowns, cover art, previews).
