#!/usr/bin/env python3
"""Dev-only: export a byte-level reference for the htdemucs `.th` weights so the
Swift `TorchCheckpointReaderParityTests` can prove its pure-Swift reader is
byte-identical to PyTorch.

For every tensor in the checkpoint's `state` dict it records the dtype, shape,
byte count, and the SHA-256 of the tensor's contiguous, row-major, little-endian
storage bytes (exactly what the Swift reader emits as `TorchTensor.data`). The
reference is small (hashes, not weights) and is NOT the weights — it is safe to
keep out of the repo; regenerate it on the dev machine.

Usage:
    .venv/bin/python script/export_weights_reference.py \\
        "$HOME/Library/Application Support/Backbeat/Models/955717e8-8726e21a.th" \\
        [output.json]        # default: <weights>.reference.json

Then run the gated Swift test:
    BACKBEAT_WEIGHTS="<weights .th>" \\
      env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test --disable-sandbox \\
      --filter TorchCheckpointReaderParityTests
"""
import sys, os, json, hashlib
import torch

# torch dtype -> the string used by TorchTensor.DType.rawValue in Swift.
DTYPE_NAMES = {
    torch.float16: "float16", torch.float32: "float32", torch.float64: "float64",
    torch.bfloat16: "bfloat16", torch.int64: "int64", torch.int32: "int32",
    torch.int16: "int16", torch.int8: "int8", torch.uint8: "uint8", torch.bool: "bool",
}


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    weights = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else weights + ".reference.json"

    # weights_only=False is required and acceptable here: the checkpoint carries the
    # HTDemucs class object + training config, not just tensors, so the restricted
    # loader would reject it. This is a DEV-ONLY tool run against the SHA-256-pinned
    # Meta artifact — the very unpickling risk the Swift reader exists to avoid at
    # app runtime is not reintroduced into the shipped app by this script.
    pkg = torch.load(weights, map_location="cpu", weights_only=False)
    state = pkg["state"] if isinstance(pkg, dict) and "state" in pkg else pkg

    tensors = {}
    for name, value in state.items():
        if not torch.is_tensor(value):
            continue
        if value.dtype not in DTYPE_NAMES:
            raise SystemExit(f"unsupported dtype {value.dtype} for {name}")
        raw = value.contiguous().cpu().numpy().tobytes()  # row-major, little-endian
        tensors[name] = {
            "dtype": DTYPE_NAMES[value.dtype],
            "shape": list(value.shape),
            "nbytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
        }

    reference = {
        "source": os.path.basename(weights),
        "tensor_count": len(tensors),
        "tensors": tensors,
    }
    with open(out, "w") as f:
        json.dump(reference, f, indent=0, sort_keys=True)
    print(f"wrote {out}: {len(tensors)} tensors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
