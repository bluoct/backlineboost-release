#!/usr/bin/env bash
# build_mlx_metallib.sh — compile MLX's Metal shader library (mlx.metallib) and
# place it next to the SwiftPM build products.
#
# WHY THIS EXISTS (native-engine Task 7): mlx-swift 0.30.6 does NOT build its
# Metal kernel library during `swift build` — it ships the .metal kernel sources
# and expects `mlx.metallib` to sit colocated with the executable at runtime (MLX's
# `load_colocated_library`). Without it, the first GPU call fails with
# "Failed to load the default metallib". This compiles the checked-out kernels once
# per build config. It is dev/build-time only; the shipped app bundles the result
# as a resource (nothing here runs on the user's machine at runtime).
#
# Requires the Metal Toolchain: if `xcrun metal` reports "missing Metal Toolchain",
# run:  xcodebuild -downloadComponent MetalToolchain
#
# Usage: script/build_mlx_metallib.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_DIR="$ROOT/.build/checkouts/mlx-swift"
KERNELS_DIR="$MLX_DIR/Source/Cmlx/mlx/mlx/backend/metal/kernels"
OUT_DIR="$ROOT/.build/$CONFIG"

if [[ ! -d "$KERNELS_DIR" ]]; then
  echo "error: MLX kernels not found at $KERNELS_DIR (run 'swift build' first to resolve deps)" >&2
  exit 1
fi
if [[ ! -d "$OUT_DIR" ]]; then
  OUT_DIR="$(find "$ROOT/.build" -maxdepth 3 -type d -path "*/$CONFIG" | head -n1 || true)"
fi
[[ -d "$OUT_DIR" ]] || { echo "error: no SwiftPM output dir for '$CONFIG' (run 'swift build' first)" >&2; exit 1; }

# The _nax.metal variants target newer arch families and are excluded (matching the
# upstream port's build), leaving the portable kernel set. (portable to bash 3.2 —
# no `mapfile`).
METAL_SRCS=()
while IFS= read -r line; do METAL_SRCS+=("$line"); done < <(
  find "$KERNELS_DIR" -type f -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort
)
[[ "${#METAL_SRCS[@]}" -gt 0 ]] || { echo "error: no .metal kernels under $KERNELS_DIR" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# -fno-fast-math: keep IEEE semantics so GPU numerics match the fp32 reference
# (native-engine gate G1 — parity is measured to tight SI-SDR tolerances).
METAL_FLAGS=(-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions)

echo "Compiling ${#METAL_SRCS[@]} Metal kernels ($CONFIG)…"
AIR_FILES=()
for SRC in "${METAL_SRCS[@]}"; do
  KEY="$(printf '%s' "${SRC#"$KERNELS_DIR/"}" | shasum -a 256 | cut -c1-16)"
  OUT_AIR="$TMP/$KEY.air"
  if ! xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$SRC" \
        -I"$KERNELS_DIR" -I"$MLX_DIR/Source/Cmlx/mlx" -o "$OUT_AIR" 2>"$TMP/metal.err"; then
    grep -q "missing Metal Toolchain" "$TMP/metal.err" 2>/dev/null \
      && echo "error: missing Metal Toolchain — run: xcodebuild -downloadComponent MetalToolchain" >&2
    cat "$TMP/metal.err" >&2
    exit 1
  fi
  AIR_FILES+=("$OUT_AIR")
done

xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUT_DIR/mlx.metallib"
echo "OK: wrote $OUT_DIR/mlx.metallib ($(stat -f%z "$OUT_DIR/mlx.metallib") bytes)"
