# Backline Boost User Manual

Last updated: 2026-07-07

Backline Boost is a local macOS practice player for drummers. It imports your own audio files, separates them into drum and backing stems, and lets you practice with three main playback modes:

- `Original`: the imported song as-is.
- `Drum Boost`: a live mix of the separated drums and backing track, with the drum level you chose for that song.
- `Drumless`: the separated backing track without drums.

Backline Boost stores each song locally. It does not stream from Apple Music, Spotify, or other subscription libraries.

## Requirements

Backline Boost plays imported files immediately in `Original` mode and creates `Drum Boost` and `Drumless` **entirely on-device** — no external tools are required.

- Supported import formats: AAC, AIFF/AIF, FLAC, M4A, MP3, and WAV.
- Separation, analysis, and rendering run natively (Apple's MLX). The drum-separation model ships inside the app; nothing is downloaded and no audio leaves your machine.

For full setup instructions, see [INSTALL.md](../INSTALL.md). For licensing and attribution notes, see [LEGAL.md](../LEGAL.md) and [WEIGHTS.md](../WEIGHTS.md).

## Launching Backline Boost

From the repo, double-click:

```text
Launch Backline Boost.command
```

The launcher builds and opens the current Backline Boost app bundle. If macOS asks whether to allow the command file to run, approve it for this local project.

## Help Menu

Choose `Help > Backline Boost Help` or press `Command-?` to open the bundled Help window. The Help window includes a formatted user manual, README summary, install notes, troubleshooting, and legal notices.

## Main Workflow

1. Open Backline Boost.
2. Import one song or a folder of songs (or drag them in).
3. The song plays as `Original` right away. In the background, Backline Boost automatically separates it into drum and backing stems — there is no separate "prepare" step. Its status moves `Imported` → `Rendering…` → `Ready`.
4. Open the song in the `Player` and switch the source to `Drum Boost` or `Drumless`.
5. With `Drum Boost` selected, set the per-song drum level with the live `Drums` slider, and practice with speed control and A/B looping.
6. Create playlists when you want an ordered practice queue.

The important detail: `Drum Boost` is not a fixed exported file. Backline Boost renders durable `Drums` and `Drumless` files once, then mixes them live during playback using the drum level you set for that song.

## Library View

The `Library view` is the home screen for imported tracks.

Use it to:

- Import a single audio file with `Import Track`.
- Import the top-level supported audio files in a folder with `Import Folder`.
- Drag supported audio files onto the Backline Boost window, either from Finder or directly from the Apple Music app.
- Browse imported tracks.
- Select a track to inspect or play.
- Delete a track from Backline Boost after confirmation.

Each row shows the track's title, length, and status, plus a render "Version" column and quick actions. The status reflects where the track is in separation: `Imported`, `Waiting to render (#N)`, its current stage while separating, `Ready`, or `Render failed` (with a retry button).

When a track is imported, Backline Boost copies the source file into its managed app library. It also reads embedded title, artist, album, and artwork metadata when available. If a song has no artwork, Backline Boost shows a generated initial tile.

If you import a file that is identical to one already in your library, Backline Boost skips it and shows an `Already in library` notice rather than creating a duplicate.

Single-clicking a track opens it for inspection without stealing whatever is currently playing in the mini-player. Double-clicking a track title starts playback from `0:00`.

Deleting a track removes Backline Boost's app-managed source copy, artwork, and render files for that track. It does not delete the original file from wherever you imported it.

## Stem Separation (Automatic)

Backline Boost separates every imported song into drum and backing stems for you. There is no "prepare" screen and nothing to start by hand.

- As soon as a track is imported it is playable as `Original`, and a background job is queued to separate it.
- Separation runs **one track at a time**. A track that is waiting shows `Waiting to render (#N)`; the one in progress shows its current stage.
- The stages are: `Separating stems` → `Creating drums track` → `Creating drumless track` → `Finalizing render`. When it finishes, the track's status becomes `Ready`, and `Drum Boost` and `Drumless` become available for it.
- Each separation produces one durable `Drums` file and one durable `Drumless` file. `Drum Boost` mixes those two live during playback (see the Player) — it is not a separate mixed-down file. Backline Boost keeps only the newest Drums/Drumless pair for each track.
- If separation fails, the status shows `Render failed` with a `Retry render` action — see Troubleshooting, then retry.
- Separations keep running in the background while you use the app, and resume automatically after you quit and relaunch.

You can change where the rendered files are saved and their audio quality in `Settings ▸ Rendering`.

## Player View

The `Player view` is the full practice surface for one track.

Use it to:

- Switch playback source.
- Play, pause, seek, and scrub.
- Set the per-song drum boost.
- Change practice speed.
- Loop the whole song or a selected section.

### Playback Sources

A segmented picker switches among:

- `Original`: plays the imported source copy.
- `Drum Boost`: live-mixes Drums and Drumless with the saved boost for this song.
- `Drumless`: plays the drumless backing track.

If a rendered source is missing (for example, the track has not finished separating), Backline Boost falls back to `Original` rather than failing silently.

### Drum Boost

When the source is set to `Drum Boost` and the track has finished separating, the `Drums` slider sets the per-song drum level, from `0` to `+8 dB` (default `+4 dB`). Raising the drums also gently lowers the backing stems to keep the overall level steady.

The saved level follows the song wherever it is used, including playlists. Changing it does not create a new file — the mix updates live during playback. If you switch away from `Drum Boost`, the slider is disabled with a hint to switch back.

### Transport And Scrubbing

The Player view includes:

- Previous track.
- Seek back 15 seconds.
- Play/pause.
- Seek forward 15 seconds.
- Next track.
- Click/drag progress scrubbing.
- Elapsed and remaining time display.

When the inspected track is the active now-playing track, Player progress mirrors the mini-player. If you inspect another track while music continues, the Player shows that inspected track without taking over playback until you start it.

### Practice Speed

The Player view includes a pitch-preserving speed control from `0.5x` to `1.5x`.

Use it to:

- Slow down difficult sections.
- Gradually raise speed during practice.
- Double-click the speed slider (or use the `Reset` button) to return to `1.0x`.
- Use the slow/fast step buttons for small changes.

Speed changes work with `Original`, `Drum Boost`, and `Drumless`.

### Looping

The loop control has three modes:

- `Off`: normal playback.
- `Song`: loops the full song.
- `Section`: loops between A/B markers.

In `Section` mode, use the waveform timeline and the `A` / `B` buttons to set and drag loop markers around beats, fills, or transitions. The clear-markers button (the `✕` next to the loop controls) removes the A/B markers and turns looping off. It does not change the current speed setting.

## Mini-Player

The `Mini-player` stays at the bottom of the app and controls active playback.

It shows:

- Current track artwork or fallback tile.
- Track title and artist.
- Current source tag.
- Progress and time remaining.
- Volume.
- Transport controls.

Use it to:

- Play or pause the active track.
- Skip to previous or next.
- Seek back or forward 15 seconds.
- Scrub by clicking or dragging the progress bar.
- Adjust volume by clicking or dragging the volume bar.
- Toggle repeat and shuffle.
- Click the track area to open the Player view.

The source tag cycles the active playback source. If the preferred source is unavailable for the current song, the tag reflects that Backline Boost is falling back to `Original`.

The mini-player and Player detail can hold independent source selections. The mini-player controls what is actively playing. The Player detail controls the inspected track until playback starts from that detail view.

## Playlist Detail View

Playlists are saved practice queues.

Use playlists to:

- Create named practice sets.
- Rename playlists.
- Add imported tracks.
- Remove tracks from the playlist.
- Choose the playlist's default playback source.
- Play the playlist as an ordered queue.
- Delete a playlist after confirmation.

Deleting a playlist does not delete the library tracks, source files, artwork, or render files.

Double-clicking a playlist item starts that track in the playlist queue. Playing a playlist keeps the main pane on the playlist, highlights the currently playing item, and leaves the upcoming queue visible.

The playlist source preference persists across tracks. If a track does not have the selected rendered source yet, that track falls back to `Original`.

Drum boost values are stored per song, not per playlist. A song uses the same saved drum boost wherever it appears.

## Settings

Open **Backline Boost ▸ Settings** (`⌘,`). The window has three sections.

### Playback

- **Normalize playback volume** — a loudness assist that evens out big volume jumps between songs. It boosts quieter songs more than it reins in loud ones, so older or quieter recordings sit closer to modern masters. It applies during playback across `Original`, `Drum Boost`, and `Drumless`, and does not replace the per-song drum boost.

### Rendering

- **Renders folder** — where the durable Drums and Drumless files are saved (in subfolders). Click **Choose…** to pick a custom folder, or **Reset to Default** to return to the app's Application Support location. Existing rendered tracks keep playing from their current location; re-render a track to move it.
- **Render quality** — the audio quality (bitrate) used for new renders. Applies to new renders only; already-rendered tracks are unchanged until re-rendered.

### Diagnostics

- **Write debug log** — while enabled, captures the app's full system log to `debug.log`. Turn it on, reproduce a problem, then use **Reveal in Finder** to grab the file and share it. The capture restarts (and the file is overwritten) each time the app launches.

## Where Backline Boost Stores Files

Backline Boost stores its managed library in Application Support:

```text
~/Library/Application Support/Backbeat/
```

Important locations:

- Source copies: `~/Library/Application Support/Backbeat/AppAudioLibrary/sources`
- Library snapshot: `~/Library/Application Support/Backbeat/AppAudioLibrary/library.json`
- Artwork: `~/Library/Application Support/Backbeat/artwork`
- Render outputs: `~/Library/Application Support/Backbeat/renders` (unless you set a custom renders folder in Settings)

Backline Boost migrates older project-root library snapshots into Application Support on first load when the new snapshot is missing.

## Troubleshooting

### Render Failed

Use the `Retry render` action shown on the Library row or in the Player. The separation engine and its model are bundled with Backline Boost, so a persistent failure usually means a corrupt build — rebuild Backline Boost and retry.

### Drum Boost Or Drumless Plays Original

The separated assets are not ready for that track yet. Wait for its status to reach `Ready`, or use `Retry render` if it failed. Backline Boost falls back to `Original` so playback stays usable.

### Dragging From Apple Music Does Nothing

Dragging a track directly from the Apple Music app works for local, purchased, or DRM-free downloaded songs that have a real audio file behind them. Protected Apple Music downloads (`.m4p`) are DRM-encrypted, so Backline Boost can't decode or separate them — dropping one shows a **"Can't import this track"** message rather than doing nothing. A subscription/streaming item that hasn't been downloaded has no local file at all. In every case, the fix is the same: use a purchased, CD, or file copy of the song, or drag it in from Finder.

### macOS Asks For Permission On A Music Drag

The first Apple Music drag shows a one-time system prompt: *"Backline Boost would like to access Apple Music, your music and video activity, and your media library."* Approve it — Backline Boost reads the dragged track's file from your Music library and fetches its album artwork from Music's database (Apple Music keeps artwork there, not inside the audio file). Declining still imports the audio when possible, but artwork and future Music drags may fail until the permission is granted in System Settings ▸ Privacy & Security ▸ Media & Apple Music.

### A Folder Import Skipped Files

Folder import currently imports supported top-level audio files. It does not recursively scan nested folders.

## Current Limits

The current prototype intentionally keeps some things narrow:

- `Import Track` uses a single-file picker.
- `Import Folder` imports supported top-level audio files only.
- Batch import and batch processing are not built yet.
- Apple Music drag/drop imports only tracks with a real, DRM-free local audio file. DRM-protected downloads show a "Can't import this track" message; subscription-only items that aren't downloaded have no local file to import.
- Exporting the current live `Drum Boost` mix to a standalone file is a future feature.

## Quick Workflows

### Add A New Song For Drum Boost Practice

1. Click `Import Track` (or drag a file in).
2. Choose a supported local audio file.
3. Wait for its status to reach `Ready` — Backline Boost separates it automatically in the background.
4. Open the track in the Player and choose `Drum Boost`.
5. Set the `Drums` level to taste and start practicing.

### Practice A Difficult Fill

1. Open the song in the Player view.
2. Choose `Drum Boost` or `Drumless`.
3. Set speed below `1.0x`.
4. Switch loop mode to `Section`.
5. Drag the A/B markers around the fill.
6. Practice the loop.
7. Raise speed as the part gets cleaner.

### Build A Practice Playlist

1. Create a playlist from the sidebar.
2. Add imported tracks.
3. Choose the playlist source, usually `Drum Boost` or `Drumless`.
4. Double-click the first track or press play for the playlist.
5. Use the mini-player to skip, scrub, change volume, or cycle source while the queue continues.

## Glossary

- `Original`: the managed copy of the file you imported.
- `Drums`: the separated drum stem Backline Boost stores after separating a track.
- `Drumless`: the separated backing track without drums.
- `Drum Boost`: live playback that mixes Drums and Drumless using the saved per-song boost.
- `Render` / separation: the background full-song processing that creates the durable Drums and Drumless files.
- `Mini-player`: the persistent bottom playback controller.
- `Library snapshot`: the saved JSON file that remembers imported tracks, playlists, render paths, boost settings, and playback preferences.
