#!/usr/bin/env python3
"""Dev-only: regenerate the small, authentic torch.save fixtures used by
TorchCheckpointReaderTests. Run with the project .venv:

    .venv/bin/python script/make_checkpoint_fixtures.py

The committed BINARY fixtures under Tests/BackbeatCoreTests/Fixtures/ are the
source of truth for the tests (real torch output — parsing them proves the Swift
reader agrees with PyTorch, not merely with a hand-rolled re-encoder). This
script documents exactly how they were produced so they can be regenerated.
"""
import os, collections, struct
import torch

FIX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Tests", "BackbeatCoreTests", "Fixtures")
os.makedirs(FIX, exist_ok=True)

def save(obj, name):
    path = os.path.join(FIX, name)
    torch.save(obj, path)
    print(f"wrote {name} ({os.path.getsize(path)} bytes)")

# 1. Flat float32 state dict — two named tensors, known values.
flat32 = collections.OrderedDict()
flat32["a.weight"] = torch.arange(6, dtype=torch.float32).reshape(2, 3)   # 0..5
flat32["b.bias"]   = torch.tensor([1.5, -2.5, 3.25], dtype=torch.float32)
save(flat32, "flat_f32.pt")

# 2. Flat float16 state dict — the dtype the real htdemucs file uses.
flat16 = collections.OrderedDict()
flat16["a.weight"] = torch.arange(6, dtype=torch.float16).reshape(2, 3)
flat16["b.bias"]   = torch.tensor([1.5, -2.5, 3.25], dtype=torch.float16)
save(flat16, "flat_f16.pt")

# 3. Nested "demucs bag" shape: tensors under 'state', plus a foreign object
#    (a numpy scalar) in training_args that forces the pickle to emit a
#    non-torch REDUCE (numpy.core.multiarray.scalar). Parsing this proves the
#    VM stays INERT on unknown reducers (never imports/executes) yet still
#    recovers every tensor under 'state'.
import numpy as np
class FakeHTDemucs:  # stands in for demucs.htdemucs.HTDemucs as the 'klass' global
    pass
state = collections.OrderedDict()
state["enc.0.conv.weight"] = torch.tensor([[1.0, 2.0], [3.0, 4.0]], dtype=torch.float16)
state["enc.0.conv.bias"]   = torch.tensor([-1.0, 0.5], dtype=torch.float16)
nested = {
    "klass": FakeHTDemucs,
    "args": (),
    "kwargs": {"channels": 48, "depth": 4, "sources": ["drums", "bass", "other", "vocals"]},
    "state": state,
    "training_args": {"epochs": np.int64(360), "lr": np.float64(3e-4), "flag": True, "nothing": None},
}
save(nested, "nested_bag.pt")

print("done. Fixtures in", FIX)
