#!/usr/bin/env bash
set -euo pipefail

# Packages dist/Backline Boost.app into a distributable disk image, reproducing
# the hand-arranged Finder layout of the original developer-preview DMG. The
# layout lives in script/dmg-template/ (extracted 2026-07-10 from the
# hand-built BacklineBoost-preview.dmg):
#
#   DS_Store                        Finder icon positions + window geometry
#                                   (stored un-dotted — .DS_Store is gitignored —
#                                   and staged into the volume as .DS_Store)
#   Applications                    Finder alias to /Applications (the drag target;
#                                   kept as an alias, byte-exact from the original)
#   READ ME FIRST - no really.txt   install + quarantine-strip instructions
#
# Finder keys icon positions to item names, so the app bundle, alias, and readme
# must keep these exact names for the saved layout to apply.
#
# To change the layout: build a DMG, convert it to read-write
# (hdiutil convert out.dmg -format UDRW -o rw.dmg), mount rw.dmg, arrange the
# window in Finder, eject, mount again, then copy the volume's .DS_Store over
# script/dmg-template/DS_Store.
#
# usage: script/make_dmg.sh [output.dmg]
#   default output: dist/BacklineBoost-preview-b<CFBundleVersion>.dmg
#
# The app bundle must already exist — run ./script/build_and_run.sh first so the
# image always wraps a bundle that was just built, signed, and launch-verified.

APP_NAME="Backline Boost"
VOLUME_NAME="Backline Boost"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
TEMPLATE_DIR="$ROOT_DIR/script/dmg-template"
README_NAME="READ ME FIRST - no really.txt"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "missing app bundle: $APP_BUNDLE — run ./script/build_and_run.sh first" >&2
  exit 1
fi
for piece in DS_Store Applications "$README_NAME"; do
  if [[ ! -f "$TEMPLATE_DIR/$piece" ]]; then
    echo "missing layout piece: $TEMPLATE_DIR/$piece" >&2
    exit 1
  fi
done

# Refuse to package a bundle whose signature is broken (e.g. a file edited
# inside the bundle after signing); recipients would get an app Gatekeeper
# rejects outright rather than one the readme's quarantine-strip step can fix.
codesign --verify --deep --strict "$APP_BUNDLE"

APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
OUT="${1:-$DIST_DIR/BacklineBoost-preview-b$APP_BUILD.dmg}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/backline-dmg.XXXXXX")"
MOUNT_POINT="$STAGE/mnt"
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# ditto (not cp) preserves the code signature, extended attributes, and the
# alias file's resource fork.
mkdir -p "$STAGE/vol"
ditto "$APP_BUNDLE" "$STAGE/vol/$APP_NAME.app"
ditto "$TEMPLATE_DIR/DS_Store" "$STAGE/vol/.DS_Store"
ditto "$TEMPLATE_DIR/Applications" "$STAGE/vol/Applications"
ditto "$TEMPLATE_DIR/$README_NAME" "$STAGE/vol/$README_NAME"

hdiutil create -ov -volname "$VOLUME_NAME" -srcfolder "$STAGE/vol" \
  -fs APFS -format UDZO "$OUT"

# Verify the shipped image: it mounts, the layout survived byte-for-byte, and
# the bundle's signature is still intact after the copy + compression round trip.
mkdir -p "$MOUNT_POINT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$OUT" >/dev/null
if ! cmp -s "$MOUNT_POINT/.DS_Store" "$TEMPLATE_DIR/DS_Store"; then
  echo "verify: .DS_Store in the image differs from the template" >&2
  exit 1
fi
for item in "$APP_NAME.app" Applications "$README_NAME"; do
  if [[ ! -e "$MOUNT_POINT/$item" ]]; then
    echo "verify: missing item in the image: $item" >&2
    exit 1
  fi
done
codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app"
hdiutil detach "$MOUNT_POINT" -quiet

echo "dmg: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' ') — build $APP_BUILD, layout verified)"
