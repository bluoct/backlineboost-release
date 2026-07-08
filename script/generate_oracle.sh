#!/usr/bin/env bash
# generate_oracle.sh — cache a CPU-demucs fp32 stem oracle for the native-engine
# parity gate (G1). Dev-time only; nothing here ships in the app.
#
# For each input song it runs htdemucs on CPU at fp32 (--overlap 0.1, matching
# the pinned separation contract) and caches float32 stem WAVs under
# .build/oracle/<key>/{drums,bass,other,vocals}.wav. This is the ground-truth
# reference BackbeatSepBench measures a native engine's SI-SDR against.
#
# Optionally (BACKBEAT_ORACLE_MPS=1) it also runs the ACCELERATED (-d mps) path
# into .build/oracle/<key>/calibration-mps/, so the bench can report the
# MPS-vs-oracle calibration band (architecture G1: native ≥ band − 3 dB).
#
# It is cached and idempotent: a song whose four stems already exist is skipped,
# so re-running is a no-op. Delete .build/oracle to force regeneration.
#
# Usage:
#   ./script/generate_oracle.sh song1.wav song2.wav song3.wav
#   BACKBEAT_ORACLE_SONGS="$(printf '%s\n' ~/music/*.wav)" ./script/generate_oracle.sh
#   BACKBEAT_ORACLE_MPS=1 ./script/generate_oracle.sh song1.wav      # + MPS calibration set
#
# The ≥3 native-44.1 kHz songs are dev-local and never committed (like the
# gitignored 15 Gett Off.m4a); .build/ is gitignored, so the whole oracle tree
# stays out of git.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORACLE_DIR="$ROOT_DIR/.build/oracle"
VENV_BIN="$ROOT_DIR/.venv/bin"

# demucs is installed in the project .venv, not globally — put it first on PATH
# (this is also how it finds its own python and ffmpeg).
export PATH="$VENV_BIN:$PATH"

if ! command -v demucs >/dev/null 2>&1; then
    echo "generate_oracle: demucs not found (expected $VENV_BIN/demucs). Install it in the project .venv." >&2
    exit 1
fi

# Collect songs from argv, else from the BACKBEAT_ORACLE_SONGS newline list.
songs=()
if [ "$#" -gt 0 ]; then
    songs=("$@")
elif [ -n "${BACKBEAT_ORACLE_SONGS:-}" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && songs+=("$line")
    done <<< "$BACKBEAT_ORACLE_SONGS"
fi

if [ "${#songs[@]}" -eq 0 ]; then
    echo "generate_oracle: no songs given (pass paths as arguments or set BACKBEAT_ORACLE_SONGS)." >&2
    exit 2
fi

mkdir -p "$ORACLE_DIR"

STEMS=(drums bass other vocals)

# key: basename without extension, spaces/odd chars collapsed to underscores so
# the directory name matches BackbeatSepBench's songKey(for:) derivation.
song_key() {
    local base
    base="$(basename "$1")"
    base="${base%.*}"
    printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_'
}

# Escape a string for embedding in a JSON string literal (backslash first, then
# double-quote). The manifest keys/dirs are already sanitized, but the absolute
# `input` path is used verbatim — a macOS path may legally contain " or \, which
# would otherwise emit invalid JSON that BackbeatSepBench cannot parse.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Run demucs for one song/device into $2, then flatten the
# htdemucs/<basename>/*.wav layout into $2/{stem}.wav.
run_demucs() {
    local song="$1" out_dir="$2" device="$3"
    local tmp_out="$out_dir/.demucs-raw"
    rm -rf "$tmp_out"
    mkdir -p "$tmp_out"

    local device_args=()
    [ -n "$device" ] && device_args=(-d "$device")

    # --float32 saves stems as float WAVs (default is int16), which the SI-SDR
    # reference needs; --overlap 0.1 matches DemucsSeparationProfile. --shifts 0
    # is REQUIRED for a deterministic parity oracle: demucs's CLI default is
    # --shifts 1, which applies a *random* (unseeded) time-shift, so the CPU
    # oracle, the MPS calibration, and any re-run would each differ by random-shift
    # noise — contaminating the SI-SDR gate with non-numerical variance. The native
    # MLX engine likewise separates with no shift augmentation, so this is the
    # apples-to-apples reference.
    demucs --name htdemucs "${device_args[@]}" --overlap 0.1 --shifts 0 --float32 \
        --out "$tmp_out" "$song"

    # Strip the extension from the BASENAME (not the whole path), matching demucs's
    # own track.name.rsplit('.',1)[0]. `${song%.*}` on the full path would cut at a
    # dot in a parent directory name for an extensionless input.
    local song_base
    song_base="$(basename "$song")"
    local separated_base="$tmp_out/htdemucs/${song_base%.*}"
    for stem in "${STEMS[@]}"; do
        if [ ! -f "$separated_base/$stem.wav" ]; then
            echo "generate_oracle: demucs did not produce $stem.wav for $song" >&2
            return 1
        fi
        mv -f "$separated_base/$stem.wav" "$out_dir/$stem.wav"
    done
    rm -rf "$tmp_out"
}

all_present() {
    local dir="$1"
    for stem in "${STEMS[@]}"; do
        [ -f "$dir/$stem.wav" ] || return 1
    done
    return 0
}

# Manifest is assembled as we go, then written once at the end.
manifest_songs=()

for song in "${songs[@]}"; do
    if [ ! -f "$song" ]; then
        echo "generate_oracle: song not found: $song" >&2
        exit 3
    fi
    abs_song="$(cd "$(dirname "$song")" && pwd)/$(basename "$song")"
    key="$(song_key "$song")"
    song_dir="$ORACLE_DIR/$key"
    mkdir -p "$song_dir"

    if all_present "$song_dir"; then
        echo "generate_oracle: [$key] cached CPU oracle — skipping"
    else
        echo "generate_oracle: [$key] running CPU fp32 htdemucs (this is slow on CPU)…"
        run_demucs "$abs_song" "$song_dir" "cpu"
        echo "generate_oracle: [$key] CPU oracle → $song_dir"
    fi

    calibration_json="null"
    if [ "${BACKBEAT_ORACLE_MPS:-0}" = "1" ]; then
        calib_dir="$song_dir/calibration-mps"
        mkdir -p "$calib_dir"
        if all_present "$calib_dir"; then
            echo "generate_oracle: [$key] cached MPS calibration — skipping"
        else
            echo "generate_oracle: [$key] running MPS calibration htdemucs…"
            if run_demucs "$abs_song" "$calib_dir" "mps"; then
                echo "generate_oracle: [$key] MPS calibration → $calib_dir"
            else
                echo "generate_oracle: [$key] MPS calibration failed — band will be n/a" >&2
                rm -rf "$calib_dir"
            fi
        fi
        [ -d "$calib_dir" ] && calibration_json="\"$key/calibration-mps\""
    fi

    manifest_songs+=("{\"key\":\"$key\",\"input\":\"$(json_escape "$abs_song")\",\"stems\":\"$key\",\"calibration_mps\":$calibration_json}")
done

# Record the exact tool versions used, so a stale oracle is attributable.
demucs_version="$(.venv/bin/python -c 'import demucs; print(demucs.__version__)' 2>/dev/null || echo unknown)"
torch_version="$(.venv/bin/python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo unknown)"

songs_joined="$(printf '%s,' "${manifest_songs[@]}")"
songs_joined="${songs_joined%,}"

cat > "$ORACLE_DIR/manifest.json" <<EOF
{
  "generator": {
    "model": "htdemucs",
    "device": "cpu",
    "overlap": 0.1,
    "demucs": "$demucs_version",
    "torch": "$torch_version"
  },
  "songs": [$songs_joined]
}
EOF

echo "generate_oracle: wrote $ORACLE_DIR/manifest.json (demucs $demucs_version, torch $torch_version)"
echo "generate_oracle: ${#songs[@]} song(s) ready under $ORACLE_DIR"
