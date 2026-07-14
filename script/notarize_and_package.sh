#!/usr/bin/env bash
set -euo pipefail

# Turns the QA'd dist/Backline Boost.app into the notarized, stapled DMG
# release artifact. The DMG itself is notarized and stapled — not just the
# app inside it — so Gatekeeper accepts the download with no quarantine
# gymnastics. Every step is a gate that fails loudly; nothing falls through.
#
# Flow (order is load-bearing):
#   1. Signature gate: the bundle must be validly signed BY THE DEVELOPER ID
#      IDENTITY with hardened runtime + secure timestamp. A merely-valid
#      Apple Development signature (what build_and_run.sh applies for local
#      TCC stability) passes codesign --verify but is rejected by the notary
#      service — so identity and runtime flags are checked explicitly, and a
#      wrong/missing signature triggers a re-sign, inside-out (mlx.metallib
#      in Contents/MacOS is a nested code object and must be signed first,
#      mirroring build_and_run.sh).
#   2. App notarization: skipped when the bundle already validates with
#      stapler; otherwise ditto-zip -> notarytool submit --wait -> require
#      Accepted -> staple -> re-validate.
#   3. DMG built via script/make_dmg.sh (the symlink-fix recipe) from the
#      stapled bundle, then codesigned with the Developer ID — an unsigned
#      DMG notarizes fine but spctl rejects it with "no usable signature"
#      (first live run, 2026-07-14), so the image itself must carry a
#      signature for the Gatekeeper gate.
#   4. DMG notarization: submit --wait -> require Accepted -> staple.
#   5. Gatekeeper gate: spctl must assess the DMG as
#      "source=Notarized Developer ID".
#
# usage: script/notarize_and_package.sh [output.dmg]
#   default output: dist/Backline-Boost-<CFBundleShortVersionString>.dmg
#   (the release-asset naming — Backline-Boost-2.2.0.dmg — matching the
#   2.0.0/2.1.0 GitHub Release assets)
#
# Prerequisites:
#   - the QA'd bundle at dist/Backline Boost.app (./script/build_and_run.sh)
#   - the Developer ID certificate in the login keychain
#   - notarytool credentials stored under the keychain profile "notary":
#       xcrun notarytool store-credentials notary --apple-id <id> --team-id 4VUX3B8635
#
# Note for the first run: hardened runtime is a runtime behavior change the
# local dev-signed build never exercises — launch the stapled app and run a
# quick separation before uploading the DMG anywhere.

APP_NAME="Backline Boost"
SIGNING_IDENTITY="Developer ID Application: Blue Octopus LLC (4VUX3B8635)"
NOTARY_PROFILE="notary"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gate() {
  echo
  echo "==> $*"
}

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/backline-notarize.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle: $APP_BUNDLE — run ./script/build_and_run.sh and QA it first"
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
grep -qF "$SIGNING_IDENTITY" <<<"$identities" \
  || fail "signing identity not found in the keychain: $SIGNING_IDENTITY"

# ---- 1. Signature gate ------------------------------------------------------

gate "1/5 signature: valid + Developer ID + hardened runtime"
# codesign -d prints to stderr; capture once and match on the captured text.
# A `codesign | grep -q` pipeline under pipefail can report a false mismatch
# (grep's early exit or a transient codesign error fails the whole pipeline),
# which mis-signed a correctly signed bundle as FAIL on the first live run.
sig_details() { codesign -dvv "$APP_BUNDLE" 2>&1 || true; }

needs_resign=0
if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
  echo "signature invalid or missing — will re-sign"
  needs_resign=1
elif ! grep -qF "Authority=$SIGNING_IDENTITY" <<<"$(sig_details)"; then
  echo "signed, but not by the Developer ID identity — will re-sign"
  needs_resign=1
elif ! grep -Eq 'flags=.*\(?runtime' <<<"$(sig_details)"; then
  echo "signed by Developer ID, but without hardened runtime — will re-sign"
  needs_resign=1
fi

if (( needs_resign )); then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
  # Inside-out, mirroring build_and_run.sh: the colocated metallib is a
  # nested code object; the bundle signature fails without it signed first.
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE/Contents/MacOS/mlx.metallib" \
    || fail "re-signing mlx.metallib failed"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" "$APP_BUNDLE" \
    || fail "re-signing the app bundle failed"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" \
    || fail "re-signed bundle does not verify"
  post_sign="$(sig_details)"
  grep -qF "Authority=$SIGNING_IDENTITY" <<<"$post_sign" \
    || fail "re-signed bundle is not signed by: $SIGNING_IDENTITY
--- codesign -dvv said: ---
$post_sign"
  echo "re-signed: $SIGNING_IDENTITY (hardened runtime, timestamped)"
else
  echo "signature OK: $SIGNING_IDENTITY (hardened runtime)"
fi

# ---- 2. App notarization ----------------------------------------------------

gate "2/5 app notarization"
if xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "app already notarized and stapled — skipping submission"
else
  APP_ZIP="$STAGE/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  echo "submitting app to the notary service (waits for the verdict)..."
  # notarytool can exit 0 on a completed-but-Invalid submission, so the
  # verdict is parsed from the output rather than trusted from the exit code.
  submit_output="$(xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" \
    || { echo "$submit_output" >&2; fail "app notarization submission failed"; }
  echo "$submit_output"
  grep -q "status: Accepted" <<<"$submit_output" \
    || fail "app notarization did not reach status Accepted (notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE for details)"
  xcrun stapler staple "$APP_BUNDLE" || fail "stapling the app failed"
  xcrun stapler validate "$APP_BUNDLE" || fail "stapled app does not validate"
  echo "app notarized and stapled"
fi

# ---- 3. DMG -----------------------------------------------------------------

gate "3/5 building + signing the DMG from the stapled app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
OUT="${1:-$DIST_DIR/Backline-Boost-$APP_VERSION.dmg}"
"$ROOT_DIR/script/make_dmg.sh" "$OUT" || fail "make_dmg.sh failed"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$OUT" \
  || fail "signing the DMG failed"
dmg_sig="$(codesign -dvv "$OUT" 2>&1 || true)"
grep -qF "Authority=$SIGNING_IDENTITY" <<<"$dmg_sig" \
  || fail "signed DMG is not signed by: $SIGNING_IDENTITY
--- codesign -dvv said: ---
$dmg_sig"
echo "DMG signed: $SIGNING_IDENTITY"

# ---- 4. DMG notarization ----------------------------------------------------

gate "4/5 DMG notarization"
echo "submitting DMG to the notary service (waits for the verdict)..."
submit_output="$(xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" \
  || { echo "$submit_output" >&2; fail "DMG notarization submission failed"; }
echo "$submit_output"
grep -q "status: Accepted" <<<"$submit_output" \
  || fail "DMG notarization did not reach status Accepted (notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE for details)"
xcrun stapler staple "$OUT" || fail "stapling the DMG failed"
xcrun stapler validate "$OUT" || fail "stapled DMG does not validate"

# ---- 5. Gatekeeper gate -----------------------------------------------------

gate "5/5 Gatekeeper assessment of the DMG"
spctl_output="$(spctl -a -vvv -t open --context context:primary-signature "$OUT" 2>&1)" \
  || { echo "$spctl_output" >&2; fail "spctl rejected the DMG"; }
echo "$spctl_output"
grep -q "source=Notarized Developer ID" <<<"$spctl_output" \
  || fail "spctl did not assess the DMG as Notarized Developer ID"

echo
echo "release artifact ready: $OUT (build $APP_BUILD — signed, notarized, stapled, Gatekeeper-verified)"
