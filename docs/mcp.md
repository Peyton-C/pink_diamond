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
| `add_songs` | Adds audio files, stem files or folders and analyzes them. A song's first analysis takes several seconds, so add a large folder in parts if the client times out |
| `list_songs` | Every song added: id, title, artist, genre, BPM, key, length |
| `get_song` | A song's bars, sections and vocal ranges in song seconds, and its loudness. Beats on request |
| `set_genre` | Sets a song's genre. Every song starts as Pop |
| `get_transition` | The transition between two songs with edits applied: style, length, each side's start and end, handoff point, every automation lane, and the effects each side can take |
| `list_variants` | The other plans the planner makes for the pair, as other genres or at lower complexity |
| `list_parameters` | Every parameter a lane can automate: code, name, range, resting value |
| `edit_transition` | Changes a transition. Only the fields given change |
| `reset_transition` | Drops the edit and goes back to Apple's plan |
| `render_transition` | Renders one transition to a WAV with some of each song around it |
| `render_set` | Renders songs in order with every transition to one WAV, and reports where each transition starts |

## Editing
`edit_transition` takes any of these, and applies them in this order.

| Field | What |
| --- | --- |
| `variant` | A plan from `list_variants`, or null for Apple's own. Other edits are kept and applied to the new plan |
| `length_bars` | The transition's length in the outgoing song's bars. Both songs stretch together and stay beat-matched, and lanes already set stretch with them |
| `outgoing_shift_bars`, `incoming_shift_bars` | Moves a song's side along its bar grid, counted from where Apple planned it. Positive is later in the song |
| `outgoing_shift_seconds`, `incoming_shift_seconds` | The same move in song seconds, for moves off the bar grid |
| `outgoing_lanes`, `incoming_lanes` | Replaces or adds automation lanes by parameter code. null puts a lane back as planned |
| `add_effects` | Adds a filter sweep, reverb, echo, repeater, gater or flanger across one side |

Shifts are absolute, not cumulative: `outgoing_shift_bars: -4` twice is still four bars earlier.

A lane is a list of points, each an `offset`, a `value` and a `curve` (`linear`, `easedIn`, `easedOut`, `easedInOut`). The offset is in song seconds from the start of that song's side of the transition, so a lane follows its side when the side moves. A value outside the parameter's range is refused.

An edit belongs to the genres it was made with, as in the app. Changing a song's genre starts its transitions from a fresh plan, and setting the genre back brings the edit back.

## Limits
The server has no playback, playlists or live mode. An agent hears nothing: rendering gives it a WAV file and timings.

One request runs at a time, and a render blocks until it finishes.
