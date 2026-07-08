# Third-Party Notices

Backline Boost is licensed under GPL-3.0 (see [LICENSE](LICENSE)). It relies on the
third-party software and model weights listed below.

Backline Boost separates drums and renders audio **entirely on-device**. It no longer
invokes any external command-line tool — the earlier `demucs` and `ffmpeg` subprocesses
(and the Python/PyTorch toolchain behind them) were removed when the native MLX engine
landed, and there is no runtime network access.

## MLX Swift

- **Use:** the array / neural-network framework the native separation engine runs on,
  linked into the app.
- **License:** MIT. Copyright (c) 2023 Apple Inc.
- **Project:** <https://github.com/ml-explore/mlx-swift> (pinned to exactly `0.30.6`)
- It transitively resolves `swift-numerics` (<https://github.com/apple/swift-numerics>,
  `1.1.1`), under the Apache License 2.0 with the Swift runtime-library exception.

The separation engine itself is first-party Backline Boost code; MLX Swift enters only as
a linked, exactly-pinned package dependency. The MIT License is compatible with Backline
Boost's GPLv3 license; the combined work is distributed under GPLv3, and retaining the
MIT notice satisfies the attribution requirement with no relicensing or added obligation.

## htdemucs model weights (Meta)

- **Use:** the pretrained htdemucs checkpoint the engine converts and runs. **Bundled**
  inside the distributed app and redistributed unmodified (byte-identical to Meta's
  published artifact).
- **License:** MIT. Copyright (c) Meta Platforms, Inc. and affiliates. Published for
  research purposes.
- **Project:** <https://github.com/facebookresearch/demucs>
- **License text:** <https://github.com/facebookresearch/demucs/blob/main/LICENSE>
- **Provenance & integrity:** the source URL, checkpoint version, license, SHA-256, and
  size are recorded in [WEIGHTS.md](WEIGHTS.md). The build fetches the checkpoint and
  verifies it against its pinned SHA-256 before it is bundled and signed; the source
  repository itself contains no weights.

## Apple platform frameworks

Backline Boost uses Apple platform APIs — SwiftUI, AppKit, AVFoundation, Accelerate,
WebKit, and MLX's Metal backend — as system / first-party SDKs. These are supplied by
Apple and are not redistributed in this repository.
