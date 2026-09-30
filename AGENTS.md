# Working in this repo

## Naming
The project is always written `pink diamond`, fully lowercase, everywhere: prose, headings, code comments, commit messages, window titles, menus, and the start of a sentence. Never `Pink Diamond` or `PINK DIAMOND`. Identifiers that can't contain a space use `pink_diamond` (files, the icon) or `PinkDiamond` (the Swift module and type names), and those are the only exceptions.

## What goes where
`README.md` is what a user needs to build pink diamond and find their way around it, nothing more. It keeps the build commands and the one-line `--selftest` usage, because running it once is part of getting started. It does not carry the depth.

`docs/`, when it exists, holds one file per subject, and those files own it: stem files, the analysis format, the planner, the renderer. A doc should stand on its own rather than assume the reader came through another one.

Technical detail is welcome in `docs/`, more so than in the README. How the planner is called, what the analysis fields mean and how the DSP graph is rebuilt belong there.

That is mechanism, not evidence, and the distinction matters. That the planner needs the song's structure in its video cues to pick genre styles is mechanism and can be documented. The ablations and song pairs that proved it are evidence, and stay out under the rule below.

## Documentation voice
The house style is set by `README.md`. Match it.

**Be short.** Roughly half the length of a first draft. State what pink diamond does and, if it is not obvious, why. Then stop.

**Cut the evidence, keep the consequence.** The test is whether it changes what the reader does. Measurements, worked examples and the reasoning that justifies a decision come out. A caveat that would change someone's choice stays in, even when it is unflattering: pink diamond depends on private macOS frameworks and breaks when their symbols change, and a user needs to know that before relying on it.

**Name the app as the subject.** "pink diamond plans...", "pink diamond draws...". Prefer that to passive voice or an abstract subject.

**Address the reader directly** for anything they do: "drop in audio files", "set each song's genre". A reference section is mostly descriptive and will barely use it, which is fine, do not manufacture instructions to satisfy the rule.

**Use a table for any fixed set a reader might look up**: the source layout, genres and the styles they unlock, supported file types. Prose gets trimmed; tables do not.

### Mechanics
- No hard wrapping. One long line per paragraph, however wide it runs.
- No blank line between a heading and the text under it.
- Commas where a dash would be tempting. No em-dashes.
- No bold or italics in prose. Emphasis comes from sentence structure.
- Headings are short noun phrases: "Build", "Library", "Deck view".

### Common corrections
Drafts written without this file in mind tend to need the same fixes: they run about twice the necessary length, wrap lines, lean on em-dashes for asides, and explain the reasoning behind a decision where stating the decision would do.

Where a later document contradicts this file, the document is right and this file should be updated.

## Code
Each stage hands the next a plain value, and none knows about the UI:

```
AudioSource        Analyzer          SonicPlanner        TransitionPlan       MixRenderer
file or stem  ->   SongAnalysis  ->  Transition JSON ->  sides, automation -> WAV (preview or mix)
(mixdown m4a)      (Apple format)    (macOS planner)     graph wiring
```

| Path | What |
| --- | --- |
| `Sources/Core/` | Everything that isn't UI, runnable headless through `--selftest` |
| `Sources/UI/` | SwiftUI views; they go through `Library` and `MixPlayer` rather than calling the planner or renderer themselves |
| `bundle.sh` | The only build. There is no Xcode project; do not add one without asking |

pink diamond reproduces Apple Music's AutoMix, so the analysis it feeds the planner must match Apple's format, not an approximation of it. When the planner behaves differently from Music, suspect the analysis before the planner. Several fields that look cosmetic are load-bearing: the video cue scores decide which genre styles are possible, genres need Apple's catalog identifier objects, and non-finite loudness breaks the planner's JSON decoding.

The private-API surface is small on purpose and lives in three places: the mangled symbols and calling convention in `SonicPlanner.swift` and `Trampoline.s`, and the Sonic Audio Unit registration in `MixRenderer.swift`. It is specific to one macOS build. Keep it there, so a macOS update is fixed in one place, and never let a failure in it crash the app when a clear error will do.

The renderer mirrors the plan's own DSP graph and applies its automation against each song's song time. Anything outside a transition must pass through untouched, since the effect units' factory defaults are not neutral.

Test with `pink diamond --selftest <from> <to>` before the UI; it runs stems, analysis, planning and rendering the same way the app does.

Code comments are the place for the reasoning the docs leave out. Explain why something is done a particular way, especially where the obvious approach fails, and cite the measurement or the specific song pair that proves it.

## Commits
Commit messages are held to the same measure as the docs: short, plain, and specific about what changed. A subject line in the imperative, then a sentence or two on why, only when the why is not obvious from the diff.

No essays, and no restating the diff as a list of touched files. Reasoning that needs more room than that belongs in a code comment beside the thing it explains, where it stays attached to the code instead of being buried in history.
