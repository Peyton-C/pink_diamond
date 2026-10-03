# MCP server
pink diamond runs as a Model Context Protocol server with `--mcp`, so an agent can analyze songs, read the transitions Apple's planner makes, edit them and render the result. It uses the same analysis, planner and renderer as the app, without the UI.

## Setup
Build pink diamond, then point an MCP client at the binary inside the app with `--mcp`. The server speaks MCP over stdin and stdout.

```sh
claude mcp add pink-diamond -- "/Applications/pink diamond.app/Contents/MacOS/pink diamond" --mcp
```

Add `--automix-only` after `--mcp` to leave out everything Apple's AutoMix has no counterpart for: stem levels, loops, key shift, song gain, and outgoing tails with the moves that need one. An agent can then do what the app's editor can and no more.

Add `--renders <folder>` to choose where named renders go. Without it they go to `~/Music/pink diamond`.

## Session
The server keeps its songs, genres and edits in memory and forgets them when it exits, unless they are saved as a set. It does not read or change the app's library, playlists or saved edits. It shares only the analysis cache, so a song either has analyzed is ready in both.

Add songs first with `add_songs`. Every other tool takes the song ids it returns. An id stays the same for a file between sessions, as long as the file is not moved or changed.

## Tools
| Tool | What |
| --- | --- |
| `add_songs` | Adds audio files, stem files or folders and analyzes them. A song's first analysis takes several seconds, so add a large uncached folder in parts if the client times out. Later adds read the cache, and a library of 600 songs takes a couple of seconds. Past 25 songs it returns a count, not the list |
| `list_songs` | Songs added, filtered by words, BPM range, key or genre, at most 100 at a time. A row leaves out the genre when it is Pop, and a stem file's source when the title ends with it. A song there in several versions is listed once, as the one with the best stems; `unique: false` lists them all |
| `get_song` | Takes one song, or several as `songs`. A song's bars, vocal ranges, loudness and Sound Check gain, and its sections. Beats on request, and `bars: false` leaves the bar times out. `stems: true` adds each stem's level per section and bar by bar |
| `set_song` | A song's key shift in semitones and its gain in dB, kept for the whole time it plays |
| `set_genre` | Sets the genre of one song, several, or all. A song starts with the genre its genre tag names when that is one of Apple's twelve, and as Pop otherwise |
| `get_transition` | The transition between two songs with edits applied: style, length, each side's start and end, handoff point, automation lanes, and the checks below |
| `list_variants` | The other plans the planner makes for the pair, as other genres or at lower complexity |
| `list_parameters` | Every parameter a lane can automate: code, name, range, resting value, and what each value of a note-length or filter-type parameter selects |
| `edit_transition` | Changes a transition. Only the fields given change |
| `reset_transition` | Drops the edit and goes back to Apple's plan |
| `plan_set` | The timeline of songs played in order, without rendering: where each transition starts, its technique and length, the checks below, which part of each song plays, how long it plays alone, the total length, and any run of three or more transitions using the same technique |
| `save_set`, `load_set`, `list_sets` | Saves songs and the edited transitions between them to a file, and loads them back after a restart |
| `render_transition` | Renders one transition to a WAV with some of each song around it, and reports the result's level each second, its peak, and how many samples sit at full scale |
| `render_set` | Renders songs in order with every transition to one WAV, with the same timeline as `plan_set` and the level each second around every transition |

`get_transition` and `edit_transition` take `detail`: `summary` leaves the lanes out, `moving` has the lanes that change, `all` has every lane and the effects each side can take. Reading defaults to `moving` and editing to `summary`.

Renders take a `name`, which puts the WAV in the renders folder, or `out` for a full path. With neither it goes in the cache under a random name.

Renders play every song at the same loudness, as the app does with Sound Check on. Pass `sound_check: false` to turn it off. The renderer ends in a limiter, so two songs at full volume are held just under full scale rather than clipped, and a peak near 0 dB means the limiter is working.

## Sections
Apple's analysis finds where a song's sections start but not what they are, so pink diamond cannot name a chorus or a drop. `get_song` gives each section its length in bars, its loudness against the whole song, and the share of it that has vocals, which is usually enough to tell them apart.

## Checks
pink diamond works these out from the plan and the analyses, so they cost nothing and come with every transition, in `get_transition` and in `plan_set`.

| Check | What |
| --- | --- |
| `beats_apart_ms`, `beats_apart_worst_ms` | How far the outgoing song's beats land from the incoming song's on the mix clock, on average and at worst |
| `bars_apart_ms` | The same for bars. Beats can line up while bars do not |
| `beats_out_per_beat_in` | Present when one song runs at about half or double the other's tempo: 2 means two outgoing beats to each incoming one. The beat and bar checks allow for it |
| `vocals_together_seconds` | How long both songs have vocals inside the transition. It ignores volume, so a vocal that is faded out still counts |
| `keys` | Both keys as they play, key shift included, with their Camelot numbers, and whether they are the same key, relative major and minor, a fifth apart, or a clash |
| `level` | The predicted loudness before, through and after the transition, and `sag_db`, how far it dips below the quieter of the two songs either side. It counts volume and stem levels, not filters or effects, so treat it as a warning and not a measurement |
| `stems` | For two stem files: how long the mix has no drums, no bass, two basses or two vocals. A stem counts when it is playing in the song and its level in the mix is up |

## Editing
`edit_transition` takes any of these, and applies them in this order.

| Field | What |
| --- | --- |
| `variant` | A plan from `list_variants`, or null for Apple's own. Other edits are kept and applied to the new plan |
| `style` | The plan with this style name. Only styles the planner makes for the pair can be chosen, and the error lists them |
| `outgoing_shift_bars`, `incoming_shift_bars` | Moves a song's side along its bar grid, counted from where Apple planned it. Positive is later in the song |
| `outgoing_shift_seconds`, `incoming_shift_seconds` | The same move in song seconds, for moves off the bar grid |
| `outgoing_start`, `incoming_start` | Where a song's side starts, in song seconds. Use a bar time from `get_song` to stay on the grid |
| `length_bars` | The transition's length in the outgoing song's bars, where its side is now. Both songs stretch together, and lanes already set stretch with them |
| `blank` | Starts from a blank beat-matched transition, see below |
| `outgoing_tail_bars` | Bars the outgoing song plays on after the window ends, with its lanes carrying on |
| `outgoing_loop`, `incoming_loop` | Repeats a stretch of a song inside its side: `start` in song seconds, `bars` (0.25 is a beat), `repeats`. null removes it |
| `exit`, `entry` | Builds the transition from a named move for each song, see below |
| `outgoing_lanes`, `incoming_lanes` | Replaces or adds automation lanes by parameter code. null puts a lane back as planned |
| `add_effects` | Adds a filter sweep, reverb, echo, repeater, gater or flanger across one side |

Shifts are absolute, not cumulative: `outgoing_shift_bars: -4` twice is still four bars earlier.

A lane is a list of points, each a position, a `value` and a `curve` (`linear`, `easedIn`, `easedOut`, `easedInOut`). Give the position as `at`, seconds since the transition started on the mix clock, or as `offset`, song seconds from the start of that song's side. `at` is the same clock for both songs, so use it to make something happen on both at once; `get_transition` lists each song's bars on it as `bars_at`. A value outside the parameter's range is refused. `get_transition` leaves a point's `curve` out when it is `linear`, and a lane's range is in `list_parameters`.

An edit belongs to the genres it was made with, as in the app. Changing a song's genre starts its transitions from a fresh plan, and setting the genre back brings the edit back.

## Blank transitions
`blank: true` clears the edit's lanes, loops and tail and leaves both songs at full volume for the whole window, with the effects on but at rest. pink diamond draws the tempo match itself, a bar or so at a time from the two beat grids where the sides are now, so it follows each song's real grid and not its listed BPM. It runs from the outgoing song's tempo to the incoming's across the window, and pairs two beats with one when one song is at about double the other's tempo. Start both sides on a bar so the downbeats meet. Moving a side, changing the length or setting a loop afterwards redraws the match. A `ts_rate` lane you draw yourself is kept from then on and reported as `tempo_match: hand-drawn`; set it to null to hand the tempo back. The outgoing song stops when the window ends unless it has a tail.

## Moves
`exit` and `entry` build a blank transition and draw one move on each song. Giving only one leaves the other as `cut` or `full`. Lanes drawn afterwards go over the moves.

| Exit | What the outgoing song does |
| --- | --- |
| `cut` | Plays at full volume and stops when the window ends |
| `fade` | Fades out across the window |
| `filter_fade` | A low-pass closes across the window, then it stops |
| `filter_rise` | A high-pass thins it out across the window, then it stops |
| `echo_out` | Plays to the end of the window, then stops while its last beat echoes away over a 2-bar tail |

| Entry | What the incoming song does |
| --- | --- |
| `full` | Plays at full volume from the start of the window |
| `fade_in` | Fades in across the window |
| `filter_in` | A high-pass opens across the window |
| `drop_in` | Silent until the window ends, then in at full volume |

A transition's `technique` is its moves, or the planner's style, or for one drawn by hand what moves in it. Stems are named by which are taken down on each song and in what order, such as `stems (out -bass -drums; in -vocals)`. `plan_set` compares techniques to find repeats.

## Song settings
`set_song` changes how a song plays for its whole length, in every transition and render. `key_shift` moves its key by up to 6 semitones either way without changing its tempo, and the key checks use the shifted key. A couple of semitones is clean, more starts to sound processed. `gain_db` adds up to 12 dB either way on top of Sound Check.

## Saved sets
`save_set` writes the songs you name, in order, with their genres and settings and every edited transition between any two of them, to `~/Library/Application Support/pink diamond/sets/`. `load_set` adds the songs again and puts the edits back, so a set can be fixed after a restart instead of rebuilt. A set saved with extensions loads without its extended transitions when the server runs with `--automix-only`.

## Tails and loops
A tail lets the outgoing song play past the window, so a fade can finish or an echo can ring under the new song. Lane offsets past the window reach into the tail, and the song stops when the tail ends, so bring its volume down before then.

A loop repeats a stretch of a song before it carries on. The stretch has to lie inside the side, and is measured in whole beats from the nearest beat. Setting a loop switches the transition to pink diamond's own tempo match, as a blank transition has.

An outgoing loop makes the window longer by its repeats, for both songs. Lanes already drawn move with it: on both songs, everything from where the loop starts shifts later, so a fade's last drop or a drop-in at the end of the window is still at the end, and a filter drawn across the window closes across the repeats. Changing the repeats or removing the loop moves them back.

An incoming loop leaves the window as it is and changes what fills it: the incoming song repeats the stretch and gets less far into itself by the end.

## Stems
For a stem file, lanes named `stem_drums`, `stem_bass`, `stem_other` and `stem_vocals` set each stem's level from 0 to 2, where 1 is as recorded. A stem is at 1 wherever no lane sets it, so bring it back to 1 before the incoming side ends or it jumps back. A song with a stem lane plays as the sum of its stems for the whole song, which is close to the mixdown but not identical; every other song plays its mixdown.

## Limits
The server has no playback, playlists or live mode. Tails, loops and stems exist only here: the app's editor does not show or set them. An agent hears nothing: rendering gives it a WAV file and timings.

One request runs at a time, and a render blocks until it finishes.

## Log
pink diamond writes a line to stderr for every call: the tool, the size of its reply in bytes and how long it took. A reply stays in the agent's context for the rest of the session, so this is where to look when a session costs more than expected. Claude desktop keeps it in `~/Library/Logs/Claude/mcp-server-pink-diamond.log`.
