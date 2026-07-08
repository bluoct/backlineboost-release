# Backline Boost

A free macOS practice player for drummers. Import a song, boost the drums against the backing mix, and practice with pitch-preserving speed control and A/B section loops.

> Free & open source (GPL-3.0) · a drummer's practice player for macOS 14+

## What it does

Backline Boost separates a song into drums and backing track — **entirely on-device**, using a native [MLX](https://github.com/ml-explore/mlx-swift) port of Meta's [htdemucs](https://github.com/facebookresearch/demucs) model — so you can practice against a mix where the drums sit exactly where you want them:

- **Original** — the imported song, as-is.
- **Drum Boost** — a live mix of the separated drums over the backing track, at the drum level you set per song.
- **Drumless** — the backing track with the drums removed, for playing along.

Plus the tools you actually practice with: pitch-preserving **speed control (0.5×–1.5×)**, **A/B section looping** on a waveform timeline, a per-song drum-boost level that follows the song into playlists, and local playlists and a play queue.

Everything runs and stays **local** — separation, rendering, and playback happen on-device with no network access; nothing streams from Apple Music, Spotify, or any subscription service, and no audio leaves your machine.

## Status

This is the **source release** for people comfortable building from source. It runs today on macOS 14+ and needs **no external tools** — the separation engine is native (Apple's MLX) and the htdemucs model ships inside the app. Separation, analysis, and rendering are fully on-device.

The built app is roughly **250 MB**: it bundles the ~84 MB model checkpoint alongside the MLX Metal library and the app binary. The checkpoint is fetched and SHA-256-verified once at build time and is not committed to the repository — see [WEIGHTS.md](WEIGHTS.md).

## Quick start

```sh
git clone <your-repo-url>
cd backline-boost
# build & launch (the first build fetches + verifies the model checkpoint)
./script/build_and_run.sh
```

Then: import a track → it separates into stems automatically in the background → open it in the **Player**, switch to **Drum Boost**, set the drum level, and practice with speed control and A/B loops. Full walkthrough in the [User Manual](docs/user-manual.md).

## Requirements

- macOS 14 or newer
- A Swift 6 toolchain (Xcode or Apple Command Line Tools)
- Network access on the **first** build only, to fetch the model checkpoint (cached per machine afterward, so later builds are offline)

## Documentation

- [User Manual](docs/user-manual.md) — full feature guide
- [INSTALL.md](INSTALL.md) — setup & troubleshooting
- [LEGAL.md](LEGAL.md) — licensing & audio-rights notes
- [WEIGHTS.md](WEIGHTS.md) — bundled model provenance & integrity
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — third-party software licenses

## License

Backline Boost is free and open source under the [GNU General Public License v3](LICENSE). You're free to use, study, and modify it; if you distribute a modified version, it must also be GPL-3.0 and preserve the attribution notices (GPL §5). It is a free practice tool and a personal portfolio project.

The separation engine is Backline Boost's own code, built on Apple's MIT-licensed MLX Swift framework (a linked, exactly-pinned dependency), and the app bundles Meta's MIT-licensed htdemucs weights — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [WEIGHTS.md](WEIGHTS.md). You are responsible for having the rights to any audio you import — see [LEGAL.md](LEGAL.md).

## Contact

Questions or feedback: justin@bluoct.com
