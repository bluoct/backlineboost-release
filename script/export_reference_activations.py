#!/usr/bin/env python3
"""Dev-only: export per-block HTDemucs reference activations for the custom-engine
rewrite's layer-parity checks (custom-engine-plan.md, Phase 0; consumed in Phase 2).

Runs ONE deterministic forward pass of the pinned htdemucs checkpoint (CPU, fp32,
eval — exactly one training-length segment, the same shape the app's segment loop
feeds the model) and records the output of every block the Swift engine must
reproduce:

  - module outputs, named exactly as in upstream demucs 4.0.1 `named_modules()`:
    `encoder.0..3`, `tencoder.0..3`, `decoder.0..3`, `tdecoder.0..3`, their
    `.dconv` branches where present, `channel_upsampler[_t]` /
    `channel_downsampler[_t]`, `crosstransformer`, and
    `crosstransformer.layers[_t].0..4`;
  - the non-module seams, recorded by patching the bound methods: `_spec`
    (complex STFT), `_magnitude` (CaC packing — the freq-encoder input),
    `_mask` (mask application, complex), `_ispec` (freq-branch waveform);
  - `freq_emb` (the frequency embedding added AFTER encoder.0 — the Swift side
    recomputes `x = encoder0_out + freq_emb_scale * emb` from these two);
  - `input` (the exact mixture fed in) and `output` (the 4-stem waveform).

Tuple outputs (HDecLayer returns `(z, pre)`, the crosstransformer returns
`(x, xt)`) are stored per element as `<name>.out<i>`. Complex tensors are stored
via `torch.view_as_real` (trailing dim 2) and flagged `"complex": true`.

Each activation is saved as `<name>.npy` (float32) plus a `manifest.json` entry
recording shape, dtype, and the SHA-256 of the tensor's contiguous row-major
little-endian bytes (the same hashing convention as export_weights_reference.py).
THE NAMES IN THE MANIFEST ARE THE PHASE 2 PARITY CONTRACT: the Swift bring-up
compares each block it implements against the entry of the same name, so numeric
drift is localized to the block that introduced it (architecture gate 2).

The saved `input.npy` — not the generator parameters — is the contract input:
the Swift harness feeds those exact samples, so torch-version drift in the
generator can never desynchronize the two sides.

Everything lands under gitignored .build/ (~400 MB); nothing ships. Regenerate
after any demucs/torch upgrade and record the new manifest hashes.

Usage:
    .venv/bin/python script/export_reference_activations.py \\
        [weights.th] [output-dir]
    # defaults: ~/Library/Caches/backline-boost/weights/955717e8-8726e21a.th
    #           .build/reference-activations/htdemucs-v1
"""
import hashlib
import json
import math
import os
import re
import sys

import numpy as np
import torch

SEED = 20260707
SCHEMA = "htdemucs-activations-v1"

# The pinned htdemucs checkpoint digest (WeightsIdentity.htdemucs in
# Sources/BackbeatCore/Services/WeightsIdentity.swift). Loading the checkpoint
# requires unpickling (`weights_only=False` — it carries the model class/config),
# so the digest is verified BEFORE torch.load: only the known Meta artifact is
# ever unpickled. Override the default only via an explicit argv path AND a
# matching digest.
PINNED_WEIGHTS_SHA256 = "8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4"

# Module names whose forward outputs form the parity contract. Anything matching
# one of these in named_modules() gets a hook; the list is patterns, not a
# hardcoded census, so a checkpoint with more/fewer blocks self-describes.
HOOK_PATTERNS = [
    r"^encoder\.\d+$",
    r"^tencoder\.\d+$",
    r"^decoder\.\d+$",
    r"^tdecoder\.\d+$",
    r"^(?:encoder|tencoder|decoder|tdecoder)\.\d+\.dconv$",
    r"^channel_(?:up|down)sampler(?:_t)?$",
    r"^crosstransformer$",
    r"^crosstransformer\.layers(?:_t)?\.\d+$",
    r"^freq_emb$",
]

# The forward seams that are plain methods, not nn.Modules; recorded by patching
# the bound method so upstream code runs unmodified.
METHOD_SEAMS = ["_spec", "_magnitude", "_mask", "_ispec"]


def deterministic_mixture(samplerate: float, frames: int) -> torch.Tensor:
    """A seeded, full-band stereo test signal: bass + chord (steady tones for the
    tonal stems' pathways), periodic broadband transients (the drum-shaped
    content G1 cares most about), and low-level noise. Channels differ by gain
    skew so stereo processing isn't degenerate. Phases computed in float64, cast
    to float32 at the end."""
    generator = torch.Generator().manual_seed(SEED)
    t = torch.arange(frames, dtype=torch.float64) / samplerate
    two_pi = 2 * math.pi

    bass = 0.30 * torch.sin(two_pi * 55.0 * t)
    chord = 0.12 * (
        torch.sin(two_pi * 440.0 * t)
        + torch.sin(two_pi * 554.37 * t)
        + torch.sin(two_pi * 659.25 * t)
    )
    noise = 0.02 * torch.randn(2, frames, dtype=torch.float64, generator=generator)

    # A 3 ms decaying broadband burst every 0.5 s.
    transients = torch.zeros(frames, dtype=torch.float64)
    burst_len = int(0.003 * samplerate)
    envelope = torch.exp(torch.linspace(0.0, -6.0, burst_len, dtype=torch.float64))
    for start in range(0, frames - burst_len, int(0.5 * samplerate)):
        burst = torch.randn(burst_len, dtype=torch.float64, generator=generator)
        transients[start:start + burst_len] += 0.5 * envelope * burst

    mono = bass + chord + transients
    left = 1.0 * mono + noise[0]
    right = 0.9 * mono + noise[1]
    return torch.stack([left, right]).to(torch.float32)[None]  # [1, 2, frames]


def main() -> int:
    weights = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/Library/Caches/backline-boost/weights/955717e8-8726e21a.th")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        ".build", "reference-activations", "htdemucs-v1")
    if not os.path.isfile(weights):
        print(f"export_reference_activations: weights not found at {weights}", file=sys.stderr)
        return 2

    from demucs.states import load_model  # after argv checks: import is slow

    with open(weights, "rb") as fh:
        weights_sha = hashlib.sha256(fh.read()).hexdigest()
    if weights_sha != PINNED_WEIGHTS_SHA256:
        print(
            f"export_reference_activations: {weights} does not match the pinned "
            f"checkpoint digest ({PINNED_WEIGHTS_SHA256[:12]}…) — refusing to "
            f"unpickle an unverified file", file=sys.stderr)
        return 2

    # weights_only=False for the same reason as export_weights_reference.py: the
    # checkpoint carries the model class/config, and this is a dev-only tool. The
    # digest check above guarantees only the pinned Meta artifact is unpickled.
    package = torch.load(weights, map_location="cpu", weights_only=False)
    model = load_model(package)
    model.eval().float()
    torch.set_grad_enabled(False)

    training_length = int(model.segment * model.samplerate)
    mixture = deterministic_mixture(float(model.samplerate), training_length)

    records: dict[str, torch.Tensor] = {}

    def record(name: str, value) -> None:
        if isinstance(value, torch.Tensor):
            if name in records:  # a block firing twice would silently alias
                raise SystemExit(f"duplicate activation record for {name}")
            records[name] = value.detach()
        elif isinstance(value, (tuple, list)):
            for index, element in enumerate(value):
                if isinstance(element, torch.Tensor):
                    record(f"{name}.out{index}", element)

    hooked = []
    for name, module in model.named_modules():
        if any(re.match(pattern, name) for pattern in HOOK_PATTERNS):
            module.register_forward_hook(
                lambda _module, _inputs, output, name=name: record(name, output))
            hooked.append(name)

    for seam in METHOD_SEAMS:
        original = getattr(model, seam)

        def patched(*args, _original=original, _seam=seam, **kwargs):
            output = _original(*args, **kwargs)
            record(_seam, output)
            return output

        setattr(model, seam, patched)

    record("input", mixture)
    record("output", model(mixture))

    os.makedirs(out_dir, exist_ok=True)
    manifest_entries = {}
    total_bytes = 0
    for name in sorted(records):
        tensor = records[name]
        is_complex = tensor.is_complex()
        if is_complex:
            tensor = torch.view_as_real(tensor)
        array = tensor.contiguous().to(torch.float32).numpy()
        filename = f"{name}.npy"
        np.save(os.path.join(out_dir, filename), array)
        raw = array.tobytes()  # row-major, little-endian — matches the weights reference
        total_bytes += len(raw)
        manifest_entries[name] = {
            "file": filename,
            "shape": list(array.shape),
            "dtype": "float32",
            "complex": is_complex,
            "sha256": hashlib.sha256(raw).hexdigest(),
        }

    import demucs
    manifest = {
        "schema": SCHEMA,
        "generator": {
            "script": os.path.basename(__file__),
            "seed": SEED,
            "demucs": demucs.__version__,
            "torch": torch.__version__,
            "weights_file": os.path.basename(weights),
            "weights_sha256": weights_sha,
            "device": "cpu",
            "dtype": "float32",
        },
        "model": {
            "sources": list(model.sources),
            "samplerate": int(model.samplerate),
            "segment_seconds": str(model.segment),
            "training_length": training_length,
            "cac": bool(model.cac),
            "nfft": int(model.nfft),
            "hop_length": int(model.hop_length),
            "bottom_channels": int(model.bottom_channels),
            "freq_emb_scale": float(model.freq_emb_scale),
            "hooked_modules": hooked,
        },
        "activations": manifest_entries,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)

    print(f"export_reference_activations: {len(manifest_entries)} activations "
          f"({total_bytes / 1e6:.0f} MB) -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
