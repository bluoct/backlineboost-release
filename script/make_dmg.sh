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
#   README.txt                      install instructions + release notes
#                                   (renamed 2026-07-14 from "READ ME FIRST -
#                                   no really.txt" for the notarized 2.2.0
#                                   release)
#   background.tiff                 the window background (wordmark + the
#                                   drag-to-install arrow), staged into the
#                                   volume as .background/background.tiff;
#                                   regenerate with
#                                   script/generate_dmg_background.swift —
#                                   its arrow endpoints must stay in sync
#                                   with the icon positions in DS_Store
#
# The Applications drag target is NOT a template piece: a Finder alias is only
# an alias by virtue of its com.apple.FinderInfo xattr, which git strips, so an
# alias checked into the repo ships as a plain document (preview-b185 through
# 2.1.0 had exactly that bug). It is created fresh as a symlink at build time.
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
#   default output: dist/Backline-Boost-<CFBundleShortVersionString>.dmg
#   (release-asset naming; the bare make_dmg.sh output is NOT the release
#   artifact — releases go through notarize_and_package.sh)
#
# The app bundle must already exist — run ./script/build_and_run.sh first so the
# image always wraps a bundle that was just built, signed, and launch-verified.

APP_NAME="Backline Boost"
VOLUME_NAME="Backline Boost"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
TEMPLATE_DIR="$ROOT_DIR/script/dmg-template"
README_NAME="README.txt"
BACKGROUND_NAME="background.tiff"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "missing app bundle: $APP_BUNDLE — run ./script/build_and_run.sh first" >&2
  exit 1
fi
for piece in DS_Store "$README_NAME" "$BACKGROUND_NAME"; do
  if [[ ! -f "$TEMPLATE_DIR/$piece" ]]; then
    echo "missing layout piece: $TEMPLATE_DIR/$piece" >&2
    exit 1
  fi
done

# Refuse to package a bundle whose signature is broken (e.g. a file edited
# inside the bundle after signing); recipients would get an app Gatekeeper
# rejects outright.
codesign --verify --deep --strict "$APP_BUNDLE"

APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
OUT="${1:-$DIST_DIR/Backline-Boost-$APP_VERSION.dmg}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/backline-dmg.XXXXXX")"
MOUNT_POINT="$STAGE/mnt"
cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# ditto (not cp) preserves the code signature and extended attributes.
mkdir -p "$STAGE/vol"
ditto "$APP_BUNDLE" "$STAGE/vol/$APP_NAME.app"
ditto "$TEMPLATE_DIR/DS_Store" "$STAGE/vol/.DS_Store"
ln -s /Applications "$STAGE/vol/Applications"
ditto "$TEMPLATE_DIR/$README_NAME" "$STAGE/vol/$README_NAME"
mkdir "$STAGE/vol/.background"
ditto "$TEMPLATE_DIR/$BACKGROUND_NAME" "$STAGE/vol/.background/$BACKGROUND_NAME"

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
if ! cmp -s "$MOUNT_POINT/.background/$BACKGROUND_NAME" "$TEMPLATE_DIR/$BACKGROUND_NAME"; then
  echo "verify: window background in the image differs from the template" >&2
  exit 1
fi
for item in "$APP_NAME.app" "$README_NAME"; do
  if [[ ! -e "$MOUNT_POINT/$item" ]]; then
    echo "verify: missing item in the image: $item" >&2
    exit 1
  fi
done
# -L, not -e: the drag target must still BE a symlink in the image, not a
# flattened copy of the /Applications folder or a plain file.
if [[ ! -L "$MOUNT_POINT/Applications" ]] || \
   [[ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]]; then
  echo "verify: Applications in the image is not a symlink to /Applications" >&2
  exit 1
fi
codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME.app"
hdiutil detach "$MOUNT_POINT" -quiet

echo "dmg: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' ') — build $APP_BUILD, layout verified)"
