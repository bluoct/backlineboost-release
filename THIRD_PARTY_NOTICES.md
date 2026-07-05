# Third-Party Notices

Backline Boost is licensed under GPL-3.0 (see [LICENSE](LICENSE)). It relies on the third-party software listed below.

In the current source release, these tools are **invoked from the user's environment** and are **not bundled or redistributed** by this project. Each is provided by its own project under its own license.

## FFmpeg

- **Use:** audio decode/transcode, waveform/loudness analysis, and render support (invoked as a subprocess).
- **License:** LGPL-2.1-or-later by default; a given build may include GPL-covered parts.
- **Project:** <https://ffmpeg.org/> · **Legal:** <https://ffmpeg.org/legal.html>
- "FFmpeg" is a trademark of Fabrice Bellard, originator of the FFmpeg project.

## Demucs

- **Use:** music source separation (drums vs. backing track), invoked as a subprocess.
- **License:** MIT. Copyright (c) Meta Platforms, Inc. and affiliates.
- **Project:** <https://github.com/facebookresearch/demucs>
- **License text:** <https://github.com/facebookresearch/demucs/blob/main/LICENSE>
- **Model weights:** the pretrained `htdemucs` weights are downloaded by Demucs itself from Meta on first use. This project does not host or redistribute the model weights.

## Python / PyTorch / torchaudio / NumPy (transitive, via Demucs)

Demucs runs on Python with PyTorch, torchaudio, and NumPy. These are installed by the user (e.g. via `pip`) and are not bundled by this project.

- Python — PSF License
- PyTorch — BSD-3-Clause
- torchaudio — BSD-2-Clause
- NumPy — BSD-3-Clause

## Planned native runtime (future release)

A future self-contained build will replace the Python/PyTorch/FFmpeg toolchain with a native on-device runtime (e.g. Core ML) plus a first-run model download. When that ships, this file will be updated with the exact runtime, model, license status (as-of date), and versions distributed.
