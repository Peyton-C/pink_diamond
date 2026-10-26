# Metadata export
pink diamond writes its analysis of a whole crate to one JSON file, for DJ apps and harnesses that play on a beat grid of their own. Every position in it is in seconds from the start of the file, so a reader can place it on another grid. pink diamond's own beat and bar times come with it.

## Export
```sh
"/Applications/pink diamond.app/Contents/MacOS/pink diamond" --export-metadata crate.json [files or folders]
```

Without files or folders it exports `~/Music/Stereo Stems`. Folders are searched with their subfolders, and every audio file is one entry, so two versions of a song are two entries with their own timings.

pink diamond reads its analysis cache and analyzes nothing. Analyze songs first, in the app or with the MCP server's `add_songs`, and they are exported from then on. A file changed since its analysis counts as not analyzed. Songs that cannot be exported are listed under `skipped` with the reason.

Stem levels missing from the cache are measured during the export, about a second a file, and kept for next time.

Tags come from the MCP server's `tags.json` as it is when the export runs, so export once tagging is finished and keep the file. The same crate with the same tags exports to the same bytes.

## File
One JSON object. Numbers are rounded to the millisecond. A field marked optional is left out when there is nothing to put there, never set to null, except `first_entry`. Keys are sorted.

| Field | What |
| --- | --- |
| `format` | Always `crate-metadata` |
| `schema_version` | 1. It goes up when a field changes meaning or is removed, so refuse a version you do not know. New fields can appear without it changing, so ignore fields you do not know |
| `songs` | One song object per file, sorted by path |
| `skipped` | Files not exported, sorted by path: `path` and `reason`, which is `not analyzed`, `no such file`, `not an audio file`, or an error reading the file |

Nothing in the file names the app, so fields can go to a model as they are.

## Song
| Field | What |
| --- | --- |
| `path` | The file's absolute path, as the file system gives it. Match songs by this |
| `title`, `artist` | The file's tags, the title with its stem marker, such as `Flashing Lights (RF)`. A file with no title tag has its file name |
| `duration` | The file's length in seconds |
| `bpm` | A whole number, the median beat interval. It can disagree with the grid, so go by `beats` and `bars` |
| `key` | Tonic and mode, such as `F# minor`. Tonics are C, C#, D, Eb, E, F, F#, G, Ab, A, Bb, B |
| `beats`, `bars` | Every beat and every bar start, in seconds |
| `sections` | See Sections |
| `vocals` | Where the song has vocals, as `[start, end]` pairs in seconds |
| `loudness_lufs` | Integrated loudness. Optional |
| `sound_check_db` | The gain that plays the song at -16 LUFS, held back where the peak would clip. Optional |
| `file_tags` | See File tags |
| `stems` | Stem files only. See Stems |
| `tags` | Tagged songs only. See Tags |

## Sections
pink diamond finds where a song's sections start but not what they are, so sections are numbered and not named. They run end to end from 0 to the song's end.

| Field | What |
| --- | --- |
| `n` | Its number, from 1 |
| `start`, `end` | In seconds |
| `detected` | False only for a first section from 0 to the first one found, which is added and is no downbeat |
| `bars` | Its length in pink diamond's bars |
| `loudness_vs_song_db` | Its loudness against the whole song. Optional |
| `vocal_share` | The share of it with vocals, 0 to 1 |
| `stems_up`, `stems_low` | Stem files only: the stems within 6 dB of their loudest section, and those 6 to 18 dB under it, by the file's own names in lower case |

The first section can start before the first beat. To find a track's first downbeat, use a detected section start or the drums' `first_entry`.

## File tags
| Field | What |
| --- | --- |
| `genre` | The genre tag as written. Optional |
| `year` | The year of release from the date tag. A date of eight digits is an upload date and is left out. Optional |
| `explicit` | True or false from the file's rating atom, or else from Clean, Dirty or Explicit in the title. Optional, and absent for most files |
| `version` | `original`, `extended`, `remix`, `edit`, `instrumental`, `acapella`, `live`, `mashup` or `other`, read from the title's brackets |
| `version_label` | The words in the brackets as written, such as `Select Mix Remix; Pt. 2`. Optional |
| `mashup` | Mashups only: `vocals` and `beat`, lists of song titles, and `form`, `blend` or `overlay`, from the file's MASHUP atoms |

`version` is a reading of the title, not a tag of its own. Credits such as feat. and From the X Album do not count. Select Mix Remix and Intro Edit are `extended`, since they are the original with a longer intro and outro, and a title naming a version no rule covers, such as Taylor's Version, is `other`.

## Stems
| Field | What |
| --- | --- |
| `source` | Where the stems came from, as the marker at the end of the title, such as `Official`, `FN`, `RF AT`, `DE`, or `Unmarked` for a stem file without one. See [Library](library.md) |
| `source_rank` | Lower is cleaner to play alone. 0 is official stems, 100 a stereo separation and 110 unmarked |
| `tracks` | The four stems in the file's order |

A track has `code` (`drums`, `bass`, `other`, `vocals`), `name`, the file's own name for it, which is not always the stock one (Run Away with Me has Bass & Synths and Sax), and `first_entry`. That is the beat in seconds where the stem first comes within 18 dB of its loudest section and stays there for at least half of the next two bars, or null for a stem the song never plays. A lone hit or a separation's bleed does not count. It is left out when the stems could not be read.

## Tags
An agent's judgement of the song, written with the MCP server's `tag_songs`, and not a measurement. A song the tagger did not know has none. Every version of a song shares them. See [Tags](mcp.md).

| Field | What |
| --- | --- |
| `energy` | 1, a still ballad, to 10, the hardest in the library. Optional |
| `style` | A few words, such as `French house`. Optional |
| `lyrics` | What the words are about. Optional |
| `mood_clash` | True when the sound and the words pull opposite ways |
