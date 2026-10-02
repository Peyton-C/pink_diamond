# MCP server
pink diamond runs as a Model Context Protocol server with `--mcp`, so an agent can analyze songs, read the transitions Apple's planner makes, edit them and render the result. It uses the same analysis, planner and renderer as the app, without the UI.

## Setup
Build pink diamond, then point an MCP client at the binary inside the app with `--mcp`. The server speaks MCP over stdin and stdout.

```sh
claude mcp add pink-diamond -- "/Applications/pink diamond.app/Contents/MacOS/pink diamond" --mcp
```

## Session
The server keeps its songs, genres and edits in memory and forgets them when it exits. It does not read or change the app's library, playlists or saved edits. It shares only the analysis cache, so a song either has analyzed is ready in both.

Add songs first with `add_songs`. Every other tool takes the song ids it returns. An id stays the same for a file between sessions, as long as the file is not moved or changed.

## Tools
| Tool | What |
| --- | --- |
| `add_songs` | Adds audio files, stem files or folders and analyzes them. A song's first analysis takes several seconds, so add a large uncached folder in parts if the client times out. Past 25 songs it returns a count, not the list |
| `list_songs` | Songs added, filtered by words, BPM range, key or genre, a page at a time. `unique` lists each song once when it is there in several versions |
| `get_song` | A song's bars, vocal ranges, loudness and Sound Check gain, and its sections. Beats on request, and `bars: false` leaves the bar times out |
| `set_genre` | Sets the genre of one song, several, or all. Every song starts as Pop |
| `get_transition` | The transition between two songs with edits applied: style, length, each side's start and end, handoff point, automation lanes, and the checks below |
| `list_variants` | The other plans the planner makes for the pair, as other genres or at lower complexity |
| `list_parameters` | Every parameter a lane can automate: code, name, range, resting value, and what each value of a note-length or filter-type parameter selects |
| `edit_transition` | Changes a transition. Only the fields given change |
| `reset_transition` | Drops the edit and goes back to Apple's plan |
| `plan_set` | The timeline of songs played in order, without rendering: where each transition starts, which part of each song plays, how long it plays alone, and the total length |
| `render_transition` | Renders one transition to a WAV with some of each song around it, and reports the result's level each second, its peak, and how many samples sit at full scale |
| `render_set` | Renders songs in order with every transition to one WAV, with the same timeline as `plan_set` |

`get_transition` and `edit_transition` take `detail`: `summary` leaves the lanes out, `moving` has the lanes that change, `all` has every lane and the effects each side can take. Reading defaults to `moving` and editing to `summary`.

Renders play every song at the same loudness, as the app does with Sound Check on. Pass `sound_check: false` to turn it off. The renderer ends in a limiter, so two songs at full volume are held just under full scale rather than clipped, and a peak near 0 dB means the limiter is working.

## Sections
Apple's analysis finds where a song's sections start but not what they are, so pink diamond cannot name a chorus or a drop. `get_song` gives each section its length in bars, its loudness against the whole song, and the share of it that has vocals, which is usually enough to tell them apart.

## Checks
pink diamond works these out from the plan and the analyses, so they cost nothing and come with every transition.

| Check | What |
| --- | --- |
| `beats_apart_ms`, `beats_apart_worst_ms` | How far the outgoing song's beats land from the incoming song's on the mix clock, on average and at worst |
| `bars_apart_ms` | The same for bars. Beats can line up while bars do not |
| `beats_out_per_beat_in` | Present when one song runs at about half or double the other's tempo: 2 means two outgoing beats to each incoming one. The beat and bar checks allow for it |
| `vocals_together_seconds` | How long both songs have vocals inside the transition. It ignores volume, so a vocal that is faded out still counts |
| `keys` | Both keys with their Camelot numbers, and whether they are the same key, relative major and minor, a fifth apart, or a clash |

## Editing
`edit_transition` takes any of these, and applies them in this order.

| Field | What |
| --- | --- |
| `variant` | A plan from `list_variants`, or null for Apple's own. Other edits are kept and applied to the new plan |
| `style` | The plan with this style name. Only styles the planner makes for the pair can be chosen, and the error lists them |
| `length_bars` | The transition's length in the outgoing song's bars. Both songs stretch together and stay beat-matched, and lanes already set stretch with them |
| `outgoing_shift_bars`, `incoming_shift_bars` | Moves a song's side along its bar grid, counted from where Apple planned it. Positive is later in the song |
| `outgoing_shift_seconds`, `incoming_shift_seconds` | The same move in song seconds, for moves off the bar grid |
| `outgoing_start`, `incoming_start` | Where a song's side starts, in song seconds. Use a bar time from `get_song` to stay on the grid |
| `blank` | Starts from a blank beat-matched transition: both songs at full volume for the whole window with the plan's tempo match kept, every other lane at rest, and earlier lanes dropped. The outgoing song stops when the window ends |
| `outgoing_lanes`, `incoming_lanes` | Replaces or adds automation lanes by parameter code. null puts a lane back as planned |
| `add_effects` | Adds a filter sweep, reverb, echo, repeater, gater or flanger across one side |

Shifts are absolute, not cumulative: `outgoing_shift_bars: -4` twice is still four bars earlier.

A lane is a list of points, each a position, a `value` and a `curve` (`linear`, `easedIn`, `easedOut`, `easedInOut`). Give the position as `at`, seconds since the transition started on the mix clock, or as `offset`, song seconds from the start of that song's side. `at` is the same clock for both songs, so use it to make something happen on both at once; `get_transition` lists each song's bars on it as `bars_at`. A value outside the parameter's range is refused.

An edit belongs to the genres it was made with, as in the app. Changing a song's genre starts its transitions from a fresh plan, and setting the genre back brings the edit back.

## Limits
The server has no playback, playlists or live mode. An agent hears nothing: rendering gives it a WAV file and timings.

One request runs at a time, and a render blocks until it finishes.
