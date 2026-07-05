# Installing Backline Boost

Last updated: 2026-07-03

Backline Boost is currently a local macOS prototype built from source. There is not yet a signed, notarized installer package.

## Requirements

- macOS 14 or newer.
- Xcode or Apple Command Line Tools with a Swift 6 toolchain.
- Local audio files to import. Backline Boost does not import or stream protected Apple Music, Spotify, or other subscription-library tracks.
- `ffmpeg` for analysis, waveform, loudness, and render support.
- `demucs` for drum/source separation.

Backline Boost can still launch and play imported songs in `Original` mode without Demucs, but `Drum Boost` and `Drumless` (stem separation) require the helper tools.

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

## Install FFmpeg

The easiest macOS path is Homebrew:

```sh
brew install ffmpeg
ffmpeg -version
```

Backline Boost looks for `ffmpeg` in common Homebrew/MacPorts locations, the app process `PATH`, and the project-local `.venv/bin`.

## Install Demucs

The most predictable setup for Backline Boost is a repo-local Python virtual environment. Backline Boost checks `.venv/bin` automatically when launched from the GUI.

```sh
python3 -m venv .venv
./.venv/bin/python -m pip install --upgrade pip setuptools wheel
./.venv/bin/python -m pip install demucs
./.venv/bin/demucs --help
```

If the install fails because of your Python version, create the virtual environment with a supported Python 3 version from Homebrew or pyenv, then repeat the `pip install demucs` step.

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
4. Wait for the track's status to reach `Ready` — Backline Boost separates it into stems automatically in the background.
5. Open the track in the Player and choose `Drum Boost` (or `Drumless`).
6. Set the drum level with the `Drums` slider and practice with speed control and A/B loops.

## Troubleshooting

### Demucs Not Available

Backline Boost could not find the `demucs` command.

Check:

```sh
./.venv/bin/demucs --help
```

If that works, relaunch Backline Boost with `Launch Backline Boost.command` so the app can resolve the repo-local virtual environment.

### FFmpeg Not Available

Backline Boost could not find `ffmpeg`.

Check:

```sh
ffmpeg -version
```

If Homebrew installed FFmpeg but the app still cannot find it, relaunch through `Launch Backline Boost.command`; the app also checks common Homebrew paths such as `/opt/homebrew/bin`.

### Build Fails With Missing Swift Toolchain

Install or select an Xcode version with Swift 6 support:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift --version
```

### App Launches But Render Fails

Original playback is separate from stem processing. If `Original` works but stem separation (Drum Boost/Drumless) fails, verify both helper tools:

```sh
ffmpeg -version
./.venv/bin/demucs --help
```

Then retry the failed render in Backline Boost.

## Uninstall Local Build Artifacts

To remove the built app bundle from the repo:

```sh
rm -rf dist
```

Backline Boost's managed user library lives under:

```text
~/Library/Application Support/Backbeat/
```

Do not delete that folder unless you intentionally want to remove imported source copies, artwork, playlists, and render outputs managed by Backline Boost.
