# Bundled Model Weights

Backline Boost ships one third-party model checkpoint inside the distributed app and
converts it to its engine's layout on-device. This file records its provenance and the
integrity guarantee. The source repository does **not** contain the checkpoint — the
build fetches and verifies it (see [How it is bundled](#how-it-is-bundled)).

## htdemucs (Hybrid Transformer Demucs)

| Field | Value |
| --- | --- |
| Model | htdemucs — Hybrid Transformer Demucs (music source separation) |
| Checkpoint | `955717e8-8726e21a.th` (dora signature `955717e8`) |
| Source URL | <https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th> |
| Publisher | Meta Platforms, Inc. — the [Demucs](https://github.com/facebookresearch/demucs) project |
| License | MIT License. Copyright (c) Meta Platforms, Inc. and affiliates. |
| Usage note | Published for research purposes. |
| SHA-256 | `8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4` |
| Size | 84,141,911 bytes (≈84 MB) |
| Contents | 533 float16 tensors (Meta's raw PyTorch `state_dict`) |
| Modifications | None — bundled and redistributed unmodified, byte-identical to the published artifact. |

The single source of truth for these pinned values in code is
`WeightsIdentity.htdemucs` (`Sources/BackbeatCore/Services/WeightsIdentity.swift`);
`BundledWeightsTests` asserts the build script's pins match it.

## Attribution

The MIT License permits redistribution provided the copyright notice and license text
are retained. Backline Boost retains them here and in `LEGAL.md`, and redistributes the
checkpoint unmodified. Users remain responsible for confirming their own rights to use
the model for their purposes.

Demucs / htdemucs license text: <https://github.com/facebookresearch/demucs/blob/main/LICENSE>

## How it is bundled

The app performs **no** network I/O — the checkpoint is present in the app bundle at
`Contents/Resources/955717e8-8726e21a.th` and read via `Bundle.main`. To keep the ~84 MB
binary out of git while guaranteeing byte-identity, the checkpoint is resolved **at build
time** by `script/build_and_run.sh`:

1. It is cached once per machine, keyed by SHA-256, under
   `~/Library/Caches/backline-boost/weights/`.
2. On a cache hit whose checksum matches the pin, the cached file is copied into the app
   bundle. On a miss or mismatch, the build fetches it from the source URL above, verifies
   the SHA-256 (the build **fails** on mismatch), caches it, then copies it.
3. The copy is placed in the bundle **before** code-signing, so the signature seals the
   verified bytes.

At runtime the bundled checkpoint is converted in-process (no Python, no third-party
pre-converted weights) to an MLX safetensors cache under
`~/Library/Application Support/Backbeat/Models/`. That cache is derived, regenerable, and
never committed or redistributed.

## Converted (derived) form

The on-device MLX conversion produces `htdemucs.safetensors` + `htdemucs_config.json`
(573 tensors, samplerate 44100). This is a local, per-machine cache produced from the
bundled `.th`; it is not shipped and not part of this provenance record.
