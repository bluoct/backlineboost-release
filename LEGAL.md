# Legal Notices

Last updated: 2026-07-05

Contact: justin@bluoct.com

This document summarizes the legal and attribution status of the current Backline Boost repository. It is a project-maintenance note, not legal advice.

## Backline Boost License

Backline Boost is licensed under the GNU General Public License version 3. See `LICENSE`.

If Backline Boost is distributed as source or as an app binary, include the GPLv3 license text and provide the corresponding source code as required by the license.

## Repository Dependency Status

At this checkpoint, `Package.swift` declares only local Swift targets:

- `BackbeatCore`
- `Backbeat`
- `BackbeatWorkflowSmoke`
- `BackbeatCoreTests`

There are no third-party Swift Package Manager dependencies vendored or linked by the package.

Backline Boost uses Apple platform APIs such as SwiftUI, AppKit, AVFoundation, and Accelerate as system SDKs. Those are supplied by Apple and are not redistributed in this repository.

## External Helper Tools

The current prototype invokes external command-line tools when they are installed on the user's machine. These tools are not bundled in the repository or the locally built app bundle at this checkpoint.

### FFmpeg

Backline Boost uses the `ffmpeg` command for audio analysis, waveform/loudness support, and render-related audio processing.

FFmpeg states that it is licensed under LGPL version 2.1 or later by default, with optional GPL-covered parts that can make a given FFmpeg build GPL-covered. FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

Project link: <https://ffmpeg.org/>

Legal information: <https://ffmpeg.org/legal.html>

If a future Backline Boost distribution bundles FFmpeg or FFmpeg libraries, update this file with the exact FFmpeg build, license mode, source-offer location, configure flags, and required notices.

### Demucs

Backline Boost uses the `demucs` command for source separation.

Demucs is licensed under the MIT License.

Copyright notice from the Demucs license:

```text
Copyright (c) Meta Platforms, Inc. and affiliates.
```

Project link: <https://github.com/facebookresearch/demucs>

License link: <https://github.com/facebookresearch/demucs/blob/main/LICENSE>

If a future Backline Boost distribution bundles Demucs, Python, PyTorch, torchaudio, or other transitive packages, update this file with the complete third-party license inventory and include required notices.

## App Icon And Project Assets

The app icon archive is stored at:

```text
icons/Backbeat.iconset.zip
```

The repository does not currently include a separate third-party attribution record for this icon. Treat it as a project asset unless its source changes. If the icon is replaced with a third-party asset, add that asset's author, license, source URL, and required attribution here before distribution.

The design prototypes and screenshots under `docs/Music player front end design/` are project documentation assets. Do not include copyrighted third-party music, album art, or commercial media in distributed screenshots unless the rights are cleared.

## User-Provided Audio

Backline Boost processes audio files imported by the user. Backline Boost does not grant rights to copy, modify, stem-separate, export, or redistribute those songs.

Users are responsible for having the rights required for the audio they import and for any rendered outputs they create.

## Distribution Checklist

Before distributing Backline Boost beyond local development:

- Include `LICENSE`.
- Include this `LEGAL.md`.
- Provide corresponding Backline Boost source code for the distributed build.
- Confirm whether FFmpeg, Demucs, Python, PyTorch, or related dependencies are bundled or merely invoked from the user's environment.
- If any helper tools are bundled, include their exact license texts, copyright notices, source locations, and build details.
- Confirm the FFmpeg build license mode, especially whether it was built with GPL or nonfree components.
- Do not bundle sample songs, album art, or user-imported media unless rights are cleared.
- Add an in-app About/Legal surface if the app is packaged for non-developer users.
