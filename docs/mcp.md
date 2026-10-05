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
The server keeps its songs, genres and edits in memory and forgets them when it exits, unless they are saved as a set. Tags are kept, see below. It does not read or change the app's library, playlists or saved edits. It shares only the analysis cache, so a song either has analyzed is ready in both. A saved set can be brought into the app, see below.

Add songs first with `add_songs`. Every other tool takes the song ids it returns. An id stays the same for a file between sessions, as long as the file is not moved or changed.

A large library is meant to be searched, not listed. The overview shows what is there, with artists counted ignoring case and shown in the spelling most of their songs have, and `list_songs` finds the songs.

## Tools
| Tool | What |
| --- | --- |
| `add_songs` | Adds audio files, stem files or folders and analyzes them. A song's first analysis takes several seconds, so add a large uncached folder in parts if the client times out. Later adds read the cache, and a library of 600 songs takes a couple of seconds. Past 25 songs it returns an overview in place of the list: how many songs, how many by each artist and in each band of ten BPM |
| `list_songs` | Songs added, filtered by words, BPM range, key or genre, at most 100 at a time. A row has the year of release when the file's date tag gives one, and the genre as `planner_genre`, since it is the setting the planner is given and not a description of the song. It leaves that out when it is Pop, and a stem file's source when the title ends with it. A song there in several versions is listed once, as the one with the best stems; `unique: false` lists them all. `key_tempo_like` keeps the songs in a key that does not clash with a song's key, and at a tempo within 8% of its own, or of half or double it. It tests nothing else, so it narrows the library and leaves the agent to choose a song that belongs there. Give it two songs to find one that goes between them, which has to pass for both. `tempo_percent` widens that, up to 25. `any_key` keeps songs in a clashing key too, listed after the others and marked `key_clash`, for bringing in by their drums alone. `not_in_set` leaves out the songs a saved set already has, in any version. `overview: true` returns the counts by artist and BPM band for whatever matches, in place of the songs. A tagged song's row has its tags, `energy_min` and `energy_max` keep songs by their energy tag, and `untagged` keeps the songs with no tags yet |
| `tag_songs` | Writes down what songs are like to hear: energy, style, what the lyrics are about, and whether the sound and the words disagree. See Tags |
| `get_song` | Takes one song, or several as `songs`. A song's bars, vocal ranges, loudness and Sound Check gain, and its sections. Beats on request, and `bars: false` leaves the bar times out. `stems: true` adds each stem's level per section and bar by bar |
| `set_song` | A song's key shift in semitones and its gain in dB, kept for the whole time it plays |
| `set_genre` | Sets the genre the planner is given for one song, several, or all. It decides which styles the planner can pick and says nothing about how the song sounds. A song starts with the genre its genre tag names when that is one of Apple's twelve, and as Pop otherwise |
| `get_transition` | The transition between two songs with edits applied: style, length, each side's start and end, handoff point, automation lanes, and the checks below |
| `list_variants` | The other plans the planner makes for the pair, as other genres or at lower complexity |
| `list_parameters` | Every parameter a lane can automate: code, name, range, resting value, and what each value of a note-length or filter-type parameter selects |
| `edit_transition` | Changes a transition. Only the fields given change |
| `reset_transition` | Drops the edit and goes back to Apple's plan |
| `plan_set` | The timeline of songs played in order, without rendering: where each transition starts, its technique and length, the checks below, which part of each song plays, how long it plays alone, the total length, any run of three or more transitions using the same technique, and any song that is there twice |
| `save_set`, `load_set`, `list_sets` | Saves songs and the edited transitions between them to a file, and loads them back after a restart |
| `render_transition` | Renders one transition to a WAV with some of each song around it, and reports the result's level each second, its peak, and how many samples sit at full scale |
| `render_set` | Renders songs in order with every transition to one WAV, with the same timeline as `plan_set` and the level each second around every transition |

`get_transition` and `edit_transition` take `detail`: `summary` leaves the lanes out, `moving` has the lanes that change, `all` has every lane and the effects each side can take. Reading defaults to `moving` and editing to `summary`.

`plan_set` and `render_set` take `first` and `last`, positions in the song list counted from 1, to report only that stretch. pink diamond still plans or renders the whole set, and the times are still on its clock. A reply stays in the agent's context, and a long set's timeline is most of what fills it, so ask for the songs being worked on.

Renders take a `name`, which puts the WAV in the renders folder, or `out` for a full path. With neither it goes in the cache under a random name.

`render_transition` takes `solo`, `outgoing` or `incoming`, to render one song's part of the transition alone. It lines up with the full render to the sample, so the two solos show what each song is doing where the mix is hard to pick apart.

Renders play every song at the same loudness, as the app does with Sound Check on. Pass `sound_check: false` to turn it off. The renderer ends in a limiter, so two songs at full volume are held just under full scale rather than clipped, and a peak near 0 dB means the limiter is working.

## Tags
The analysis says nothing about how a song sounds or what it is about, and key and tempo alone will put a house track into a country song. Tags are where an agent writes that down, once, for every later session to read in `list_songs`.

| Tag | What |
| --- | --- |
| `energy` | How hard the song hits as a whole, from 1, a still ballad, to 10, the hardest in the library |
| `style` | Its style in a few words, such as French house or country pop |
| `lyrics` | What the words are about and how they feel |
| `mood_clash` | The sound and the words pull opposite ways, as in a bright dance song about misery |
| `unknown` | The agent did not know the recording. It has no other tags and is not offered for tagging again |

Tag the library in a session that does nothing else, in batches, searching with `untagged`. An agent tags from what it knows of a recording, so a song it does not know should be marked `unknown` and not guessed at. Energy is a judgement and not a measurement: it is for seeing a jump between two songs, and tagging a song again replaces the fields given.

pink diamond keeps tags in `~/Library/Application Support/pink diamond/tags.json`, by artist and title, so they outlast the session and every version of a song shares them. Two files of one song with different artist tags count as two songs.

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
`save_set` writes the songs you name, in order, with their genres and settings and every edited transition between any two of them, to `~/Library/Application Support/pink diamond/sets/`. `load_set` adds the songs again and puts the edits back, so a set can be fixed after a restart instead of rebuilt. It returns the set's songs in order, each with its position, id, title and artist, which is enough to carry on without planning all of it.

To add to a set or replace a song in it, search with `not_in_set` so nothing is repeated, plan only the songs around the change, and save the new order. Transitions are kept by pair of songs, so the ones that did not change keep their edits. `save_set` and `plan_set` list any song that is there twice as `duplicates`, counting two versions of a song as one. A set saved with extensions loads without its extended transitions when the server runs with `--automix-only`.

## Sets in the app
Choose File, Import Set in the app to bring a saved set in as a mix, a playlist of its own marked with a ◆ in the sidebar. pink diamond adds any songs the library does not have, and plays and exports the mix exactly as `render_set` renders it, stems, loops, tails, key shifts and gains included.

A mix is a copy. Saving the set again does not change it, and importing the set again makes a second mix beside the first, so earlier versions stay until you delete them. The mix keeps its own genres, settings and transitions, so the same songs in another playlist are not affected.

A mix is read-only. The deck view shows its transitions with their lanes, loops and tails, and previews them, but nothing can be dragged, and its songs cannot be reordered, added to or shuffled.

## Tails and loops
A tail lets the outgoing song play past the window, so a fade can finish or an echo can ring under the new song. Lane offsets past the window reach into the tail, and the song stops when the tail ends, so bring its volume down before then.

A loop repeats a stretch of a song before it carries on. The stretch has to lie inside the side, and is measured in whole beats from the nearest beat. Setting a loop switches the transition to pink diamond's own tempo match, as a blank transition has.

An outgoing loop makes the window longer by its repeats, for both songs. Lanes already drawn move with it: on both songs, everything from where the loop starts shifts later, so a fade's last drop or a drop-in at the end of the window is still at the end, and a filter drawn across the window closes across the repeats. Changing the repeats or removing the loop moves them back.

An incoming loop leaves the window as it is and changes what fills it: the incoming song repeats the stretch and gets less far into itself by the end.

## Stems
For a stem file, lanes named `stem_drums`, `stem_bass`, `stem_other` and `stem_vocals` set each stem's level from 0 to 2, where 1 is as recorded. A stem is at 1 wherever no lane sets it, so bring it back to 1 before the incoming side ends or it jumps back. A song with a stem lane plays as the sum of its stems for the whole song, which is close to the mixdown but not identical; every other song plays its mixdown.

## Limits
The server has no playback, playlists or live mode. Tails, loops, stems and song settings are made only here: the app shows and plays them in an imported set, and its editor does not set them. An agent hears nothing: rendering gives it a WAV file and timings.

One request runs at a time, and a render blocks until it finishes.

## Log
pink diamond writes a line to stderr for every call: the tool, the size of its reply in bytes and how long it took. A reply stays in the agent's context for the rest of the session, so this is where to look when a session costs more than expected. Claude desktop keeps it in `~/Library/Logs/Claude/mcp-server-pink-diamond.log`.
