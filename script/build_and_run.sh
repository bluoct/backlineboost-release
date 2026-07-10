#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Backline Boost"
PRODUCT_NAME="Backbeat"   # Swift executable target name; the built binary is named this
BUNDLE_ID="com.bluoct.backlineboost"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="2.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="Backbeat"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME.icns"
ICON_ARCHIVE="$ROOT_DIR/icons/Backbeat.iconset.zip"
ICON_WORK_DIR="$DIST_DIR/icon-work"
BUILD_ICON="$ICON_WORK_DIR/$APP_ICON_NAME.icns"
HELP_SOURCE_DIR="$ROOT_DIR/Sources/Backbeat/Resources/Help"
HELP_RESOURCES="$APP_RESOURCES/Help"
BRAND_ICON_SOURCE="$ROOT_DIR/Sources/Backbeat/Resources/BackbeatIcon.png"
BRAND_ICON_DEST="$APP_RESOURCES/BackbeatIcon.png"

# htdemucs checkpoint bundled into the app. Meta's raw .th is shipped and converted
# on-device; the app itself performs no network I/O. Keep these pinned values in sync
# with WeightsIdentity.htdemucs (BundledWeightsTests asserts they match).
WEIGHTS_FILENAME="955717e8-8726e21a.th"
WEIGHTS_SHA256="8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4"
WEIGHTS_BYTES="84141911"
WEIGHTS_URL="https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th"
WEIGHTS_CACHE_DIR="$HOME/Library/Caches/backline-boost/weights"
WEIGHTS_CACHE_FILE="$WEIGHTS_CACHE_DIR/$WEIGHTS_FILENAME"
WEIGHTS_DEST="$APP_RESOURCES/$WEIGHTS_FILENAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
swift build --disable-sandbox
BIN_PATH="$(swift build --disable-sandbox --show-bin-path)"
BUILD_BINARY="$BIN_PATH/$PRODUCT_NAME"
MLX_METALLIB="$BIN_PATH/mlx.metallib"

# MLX (the native separation engine) loads its Metal kernels from mlx.metallib
# colocated with the executable at runtime; `swift build` does not produce it, so
# build it once if missing (needs the Metal Toolchain — see build_mlx_metallib.sh).
if [[ ! -f "$MLX_METALLIB" ]]; then
  "$ROOT_DIR/script/build_mlx_metallib.sh" "$(basename "$BIN_PATH")"
fi

rm -rf "$APP_BUNDLE"
rm -rf "$ICON_WORK_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$ICON_WORK_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Colocate mlx.metallib next to the app binary (MLX's load_colocated_library looks
# beside the executable) so the first GPU separation succeeds; without it the native
# engine dies with "Failed to load the default metallib". Copied before codesign so
# the signature covers it.
cp "$MLX_METALLIB" "$APP_MACOS/mlx.metallib"

if [[ ! -f "$HELP_SOURCE_DIR/index.html" ]]; then
  echo "missing help file: $HELP_SOURCE_DIR/index.html" >&2
  exit 1
fi
mkdir -p "$HELP_RESOURCES"
cp -R "$HELP_SOURCE_DIR/." "$HELP_RESOURCES/"

if [[ ! -f "$BRAND_ICON_SOURCE" ]]; then
  echo "missing brand icon: $BRAND_ICON_SOURCE" >&2
  exit 1
fi
cp "$BRAND_ICON_SOURCE" "$BRAND_ICON_DEST"

if [[ ! -f "$ICON_ARCHIVE" ]]; then
  echo "missing icon archive: $ICON_ARCHIVE" >&2
  exit 1
fi

unzip -q "$ICON_ARCHIVE" -d "$ICON_WORK_DIR"
if ! iconutil -c icns "$ICON_WORK_DIR/$APP_ICON_NAME.iconset" -o "$BUILD_ICON"; then
  FALLBACK_TIFF="$ICON_WORK_DIR/$APP_ICON_NAME.tiff"
  sips -s format tiff "$ICON_WORK_DIR/$APP_ICON_NAME.iconset/icon_512x512@2x.png" --out "$FALLBACK_TIFF" >/dev/null
  tiff2icns "$FALLBACK_TIFF" "$BUILD_ICON"
fi
cp "$BUILD_ICON" "$APP_ICON"
rm -rf "$ICON_WORK_DIR"

# Bundle the htdemucs checkpoint (fetch-at-build, SHA-256 verified). To avoid a
# per-build download of an ~84 MB file, cache the verified artifact once per machine,
# keyed by its digest, under ~/Library/Caches/backline-boost/weights/. Copied into the
# bundle before codesign so the signature seals verified bytes; the app then reads it
# from Bundle.main and never touches the network.
weights_sha_ok() {
  [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$WEIGHTS_SHA256" ]]
}
mkdir -p "$WEIGHTS_CACHE_DIR"
if weights_sha_ok "$WEIGHTS_CACHE_FILE"; then
  echo "weights: cache hit ($WEIGHTS_CACHE_FILE)"
else
  echo "weights: cache miss or mismatch — fetching $WEIGHTS_URL" >&2
  rm -f "$WEIGHTS_CACHE_FILE"
  WEIGHTS_TMP="$WEIGHTS_CACHE_DIR/.$WEIGHTS_FILENAME.partial"
  rm -f "$WEIGHTS_TMP"
  curl -fL --retry 3 --output "$WEIGHTS_TMP" "$WEIGHTS_URL"
  if ! weights_sha_ok "$WEIGHTS_TMP"; then
    echo "weights: SHA-256 mismatch after download — refusing to bundle" >&2
    rm -f "$WEIGHTS_TMP"
    exit 1
  fi
  mv "$WEIGHTS_TMP" "$WEIGHTS_CACHE_FILE"
  echo "weights: fetched + verified, cached at $WEIGHTS_CACHE_FILE"
fi
cp "$WEIGHTS_CACHE_FILE" "$WEIGHTS_DEST"
# Final gate: the bytes actually placed in the bundle must match the pin (guards against
# a truncated copy); codesign seals them next.
if ! weights_sha_ok "$WEIGHTS_DEST"; then
  echo "weights: bundled checkpoint failed checksum verification" >&2
  exit 1
fi
WEIGHTS_DEST_BYTES="$(stat -f '%z' "$WEIGHTS_DEST")"
if [[ "$WEIGHTS_DEST_BYTES" != "$WEIGHTS_BYTES" ]]; then
  echo "weights: bundled checkpoint size $WEIGHTS_DEST_BYTES != expected $WEIGHTS_BYTES" >&2
  exit 1
fi
echo "weights: bundled $WEIGHTS_DEST ($WEIGHTS_DEST_BYTES bytes)"

# Monotonic build number so successive builds are tellable apart in
# About/crash logs; falls back to 1 outside a git checkout.
APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleMusicUsageDescription</key>
  <string>Backline Boost reads your Music library to import the tracks you drag in and to fetch their album artwork.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps TCC grants (Media & Apple Music) across
# rebuilds: the linker's ad-hoc signature changes every build, so macOS
# treats each build as a new app and re-prompts — with a garbage app name,
# since TCC can't trust an ad-hoc bundle's Info.plist. Prefer an Apple
# Development certificate when one exists; override with
# BACKBEAT_CODESIGN_IDENTITY, fall back to ad-hoc.
CODESIGN_IDENTITY="${BACKBEAT_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
# Sign inside-out: mlx.metallib sits in Contents/MacOS (where MLX's
# load_colocated_library finds it), so codesign treats it as a nested code object
# that must be signed before the enclosing bundle, or bundle signing fails with
# "code object is not signed at all".
SIGN_ID="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_ID" "$APP_MACOS/mlx.metallib"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  echo "signed: $CODESIGN_IDENTITY"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
  echo "signed: ad-hoc (no Apple Development identity; TCC grants reset every build)" >&2
fi

# Refresh the bundle's Finder/Dock icon. An in-place rebuild reuses the bundle
# path, so LaunchServices/IconServices can keep serving a stale, generic icon
# even though Contents/Resources/$APP_ICON_NAME.icns was freshly regenerated.
# Bumping the bundle mtime and re-registering it forces the caches to re-read
# the icon; guarded and non-fatal so a locked-down machine never fails the build.
touch "$APP_BUNDLE"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
