# Installing Backline Boost

Last updated: 2026-07-07

Backline Boost is currently a local macOS app built from source. There is not yet a signed, notarized installer package.

## Requirements

- macOS 14 or newer.
- Xcode or Apple Command Line Tools with a Swift 6 toolchain.
- Local audio files to import. Backline Boost does not import or stream protected Apple Music, Spotify, or other subscription-library tracks.
- Network access on the **first** build only, to fetch the drum-separation model checkpoint (~84 MB). It is verified against a pinned SHA-256, cached per machine, and bundled into the app — the app itself never accesses the network.

No external command-line tools are required. Separation, analysis, and rendering run entirely on-device via the native MLX engine; the earlier `demucs`/`ffmpeg` toolchain is gone.

## Get The Source

Clone the repository:

```sh
git clone <your-repo-url>
cd backline-boost
```

If you already have the repo, update `main`:

```sh
git checkout main
git pull origin main
```

## Install Apple Build Tools

If Swift is not available, install Apple's command line tools:

```sh
xcode-select --install
```

Then confirm Swift is visible:

```sh
swift --version
```

Backline Boost's package declares `swift-tools-version: 6.0`, so use an Xcode/Swift toolchain that supports Swift 6.

## The Bundled Model

Backline Boost bundles Meta's htdemucs model checkpoint inside the app — you do not download or install it separately. The build handles it:

- On the first build, `script/build_and_run.sh` fetches the checkpoint, verifies it against a pinned SHA-256 (the build fails on mismatch), caches it under `~/Library/Caches/backline-boost/weights/`, and copies it into the app bundle before signing.
- Later builds reuse the cached, verified copy and need no network.

See [WEIGHTS.md](WEIGHTS.md) for the checkpoint's provenance and integrity details.

## Build And Launch

For normal local use, double-click:

```text
Launch Backline Boost.command
```

That command builds the Swift package, creates a local app bundle in `dist/Backline Boost.app`, and opens it.

You can also launch from Terminal:

```sh
./script/build_and_run.sh run
```

Useful launcher modes:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

## Verify The Build

Run the test suite:

```sh
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test --disable-sandbox
```

Build without launching:

```sh
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift build --disable-sandbox
```

Verify the app bundle launches:

```sh
./script/build_and_run.sh --verify
```

## First Run

1. Launch Backline Boost.
2. Click `Import Track` or `Import Folder` (or drag files in).
3. Import a local AAC, AIFF/AIF, FLAC, M4A, MP3, or WAV file.
4. Wait for the track's status to reach `Ready` — Backline Boost separates it into stems automatically in the background. The first render after installing prepares the on-device model, which can add a few seconds.
5. Open the track in the Player and choose `Drum Boost` (or `Drumless`).
6. Set the drum level with the `Drums` slider and practice with speed control and A/B loops.

## Troubleshooting

### Build Fails Fetching The Model

The first build downloads the model checkpoint from Meta's servers. If it fails:

- Check your network connection and re-run `./script/build_and_run.sh`.
- A `SHA-256 mismatch` message means the downloaded bytes didn't match the pin, so the build refuses to bundle them. Re-run to retry; a persistently wrong checksum means the upstream artifact or the pinned value changed (see [WEIGHTS.md](WEIGHTS.md)).

### Build Fails With Missing Swift Toolchain

Install or select an Xcode version with Swift 6 support:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift --version
```

### App Launches But Render Fails

Original playback is separate from stem processing. If `Original` works but stem separation (Drum Boost/Drumless) fails, use `Retry render` on the track. The separation model is bundled, so a persistent failure usually means a corrupt build — rebuild with `./script/build_and_run.sh`.

## Uninstall Local Build Artifacts

To remove the built app bundle from the repo:

```sh
rm -rf dist
```

Backline Boost's managed user library lives under:

```text
~/Library/Application Support/Backbeat/
```

Do not delete that folder unless you intentionally want to remove imported source copies, artwork, playlists, and render outputs managed by Backline Boost. The machine-local model cache the build uses lives separately under `~/Library/Caches/backline-boost/`.
