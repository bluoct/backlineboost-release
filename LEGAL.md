# Legal Notices

Last updated: 2026-07-07

Contact: justin@bluoct.com

This document summarizes the legal and attribution status of the current Backline Boost repository. It is a project-maintenance note, not legal advice.

## Backline Boost License

Backline Boost is licensed under the GNU General Public License version 3. See `LICENSE`.

If Backline Boost is distributed as source or as an app binary, include the GPLv3 license text and provide the corresponding source code as required by the license.

## Repository Dependency Status

Backline Boost separates drums and renders audio entirely on-device. It no longer invokes any external command-line tool (the demucs and ffmpeg subprocesses were removed when the native MLX engine landed).

`Package.swift` declares one third-party Swift Package Manager dependency:

- `mlx-swift` — <https://github.com/ml-explore/mlx-swift>, pinned to exactly `0.30.6`. Licensed under the MIT License. It transitively resolves `swift-numerics` (<https://github.com/apple/swift-numerics>, `1.1.1`, Apache License 2.0 with the Swift runtime-library exception).

The package's local Swift targets are:

- `BackbeatCore`
- `BackbeatSeparationMLX`
- `Backbeat`
- `BackbeatWorkflowSmoke`
- `BackbeatSepBench`
- `BackbeatCoreTests`

Backline Boost also uses Apple platform APIs such as SwiftUI, AppKit, AVFoundation, Accelerate, and MLX as system/first-party SDKs. Those are supplied by Apple and are not redistributed in this repository.

## Third-Party Components

### MLX Swift

Backline Boost runs its on-device drum separation on Apple's MLX Swift array/neural-network framework.

MLX Swift is licensed under the MIT License. Copyright (c) 2023 Apple Inc.

Project link: <https://github.com/ml-explore/mlx-swift>

The separation engine itself is first-party Backline Boost code; MLX Swift enters only as a linked, exactly-pinned package dependency. The MIT License is compatible with Backline Boost's GPLv3 license; the combined work is distributed under GPLv3, and retaining the MIT notice satisfies the attribution requirement with no relicensing or added obligation.

## Drum-Separation Model Weights

Backline Boost bundles Meta's published htdemucs (Hybrid Transformer Demucs) model weights inside the distributed app and converts them to the engine's layout on-device. The source repository does not contain the weights: the build script fetches Meta's own artifact, verifies it against a pinned SHA-256, and copies it into the app bundle before signing — so the shipped checkpoint is byte-identical to Meta's published artifact and unmodified. `WEIGHTS.md` records the exact provenance (source URL, checkpoint version, license, SHA-256, size).

The weights originate from the Demucs project and are licensed under the MIT License.

```text
Copyright (c) Meta Platforms, Inc. and affiliates.
```

The htdemucs weights are published for research purposes. The MIT License permits redistribution provided the copyright notice and license text are retained; this project retains them (here and in `WEIGHTS.md`) and redistributes the checkpoint unmodified. Users remain responsible for confirming their own rights to use the model for their purposes.

Project link: <https://github.com/facebookresearch/demucs>

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
- Include the MIT license text and copyright notice for `mlx-swift`.
- Include `WEIGHTS.md` and retain Meta's MIT copyright + license notice for the bundled htdemucs checkpoint. The checkpoint is redistributed unmodified and byte-identical to Meta's published artifact (build-verified against a pinned SHA-256); the source repository itself contains no weights.
- Do not bundle sample songs, album art, or user-imported media unless rights are cleared.
- Add an in-app About/Legal surface if the app is packaged for non-developer users.
