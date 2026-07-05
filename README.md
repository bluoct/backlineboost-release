# Backline Boost

A free macOS practice player for drummers. Import a song, boost the drums against the backing mix, and practice with pitch-preserving speed control and A/B section loops.

> Free & open source (GPL-3.0) · a drummer's practice player for macOS 14+

## What it does

Backline Boost separates a song into drums and backing track (using [Demucs](https://github.com/facebookresearch/demucs)) so you can practice against a mix where the drums sit exactly where you want them:

- **Original** — the imported song, as-is.
- **Drum Boost** — a live mix of the separated drums over the backing track, at the drum level you set per song.
- **Drumless** — the backing track with the drums removed, for playing along.

Plus the tools you actually practice with: pitch-preserving **speed control (0.5×–1.5×)**, **A/B section looping** on a waveform timeline, a per-song drum-boost level that follows the song into playlists, and local playlists and a play queue.

Everything runs and stays **local** — nothing streams from Apple Music, Spotify, or any subscription service, and no audio leaves your machine.

## Status

This is the **source release** for people comfortable building from source. It runs today on macOS 14+ and needs two external tools installed (`demucs`, `ffmpeg`) — see [INSTALL.md](INSTALL.md). The app still plays imported files without them; only stem separation (Drum Boost / Drumless) requires them.

A self-contained, notarized binary — no separate tool install — is planned: the stem engine is moving to a native on-device runtime.

## Quick start

```sh
git clone <your-repo-url>
cd backline-boost
# install helper tools (details in INSTALL.md)
brew install ffmpeg
python3 -m venv .venv && ./.venv/bin/python -m pip install demucs
# build & launch
./script/build_and_run.sh
```

Then: import a track → it separates into stems automatically in the background → open it in the **Player**, switch to **Drum Boost**, set the drum level, and practice with speed control and A/B loops. Full walkthrough in the [User Manual](docs/user-manual.md).

## Requirements

- macOS 14 or newer
- A Swift 6 toolchain (Xcode or Apple Command Line Tools)
- `ffmpeg` and `demucs` for stem separation (see [INSTALL.md](INSTALL.md))

## Documentation

- [User Manual](docs/user-manual.md) — full feature guide
- [INSTALL.md](INSTALL.md) — setup & troubleshooting
- [LEGAL.md](LEGAL.md) — licensing & audio-rights notes
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — third-party software licenses

## License

Backline Boost is free and open source under the [GNU General Public License v3](LICENSE). You're free to use, study, and modify it; if you distribute a modified version, it must also be GPL-3.0 and preserve the attribution notices (GPL §5). It is a free practice tool and a personal portfolio project.

Stem separation relies on third-party tools (Demucs, FFmpeg) under their own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). You are responsible for having the rights to any audio you import — see [LEGAL.md](LEGAL.md).

## Contact

Questions or feedback: justin@bluoct.com
