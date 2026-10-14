# Library
pink diamond keeps one row per song and plays the best file it has of it. This covers the folders it looks in, how files become versions of a song, how their sources rank, and when one file replaces another.

## Folders
Drop a folder into the library and pink diamond remembers it. It looks through every remembered folder at launch and each time you come back to the app, and adds what has turned up. Scan Folders, in the library's toolbar menu, does the same on demand. Settings lists the folders, and the button beside one stops pink diamond looking there. Its songs stay.

A song you remove from the library stays removed while its file is still in the folder. Add the file or the folder again to bring it back.

## Versions
Files are versions of one song when they share a title and a first artist, ignoring case, accents, punctuation and the source marker at the end of the title. Only the first artist counts, since sources credit features differently. The rest of the title has to match, so a remix or a re-recording is a song of its own.

pink diamond goes by tags alone. Two recordings tagged alike become one song, and the way to split them is to retag one.

A song's row shows the file it plays. Right-click it and choose Version to see the others and play one. Choosing a file below the best pins the song to it, and Choose Automatically lets go.

A library made before versions existed has them as rows of their own. pink diamond merges those the first time it scans, keeps the oldest row's genre, and points playlists, mixes and edits at the row that is left.

## Sources
pink diamond reads a stem file's source from the marker at the end of its title, or of its file name when the title has none. The markers are bejeweled's. Best first:

| Marker | Stems |
| --- | --- |
| `(Official)` | Official stems |
| `(+RF)` | Official stems with a separated part grafted in |
| `(FN +RF)` | Fortnite Festival stems with a separated part grafted in |
| `(FN)` | Fortnite Festival |
| `(RF AC IN)` | Separated with the song's acapella and instrumental |
| `(RF IN SX)` | Separated with one of them, and a model of its own for one stem |
| `(RB +RF)`, `(RB)` | Rock Band |
| `(RF AC)`, `(RF IN)` | Separated with the acapella or the instrumental |
| `(RF AT)` | Separated from an Atmos mix |
| `(RF SR)` | Separated from a surround mix |
| `(RF)` | Separated from stereo |
| None | A stem file that does not say |
| | An audio file with no stems |

`RF` is roformer. `HY`, hybrid, and `DE`, demucs, come after it at every level, so `(DE AT)` is below `(RF AT)` and above `(RF SR)`. Any other two letters after a separator put the file just above the same marker without them.

The Source column shows the marker of the file a song plays, and sorts in this order.

## Replacement
When a better file of a song turns up, pink diamond moves the song to it, analyzes it and plans its transitions again. Edits stay, since they are kept relative to the plan.

| The song's file | What pink diamond does |
| --- | --- |
| Is gone | Plays the best version left |
| Has a better version within 5 seconds of its length | Plays it |
| Has a better version of another length | Plays it, unless either file is from Fortnite Festival or Rock Band, or the song has an edited transition or is in a mix |
| Was written over where it is | Analyzes it again |

A better version pink diamond leaves alone is a different cut of the song, and shows as an arrow in the Source column. Choose it yourself under Version. A pinned song moves only when its file is gone.

A song whose file is gone and has no other version shows a question mark. Remove Missing Songs, in the toolbar menu, clears them all.
