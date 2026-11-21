#!/bin/bash
# Build, sign (Developer ID, hardened runtime), notarize, staple and package Mira.dmg.
#
#   scripts/release.sh [--no-notarize] [build-app.sh options]
#
# Credentials are read from files, never printed or passed on a command line you can see in
# the process list beyond notarytool's own flags:
#   ~/.appstoreconnect/mira-release-credentials   exports ASC_KEY_ID and ASC_ISSUER_ID
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTARIZE=1
ARGS=()
for a in "$@"; do
  if [ "$a" = "--no-notarize" ]; then NOTARIZE=0; else ARGS+=("$a"); fi
done

OUT="$HERE/build"
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  [ "${ARGS[$i]}" = "--out" ] && OUT="${ARGS[$((i + 1))]}"
done
APP="$OUT/Mira.app"

"$HERE/scripts/build-app.sh" ${ARGS[@]+"${ARGS[@]}"}

ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
[ -n "$ID" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }

echo "==> signing (inside-out, hardened runtime, no --deep)"
MACHO="$OUT/macho.txt"
find "$APP" -type f -exec file {} + 2>/dev/null | grep 'Mach-O' | cut -d: -f1 | sed 's/ (for architecture .*)$//' | grep -v '/Contents/MacOS/Mira$' | sort -u > "$MACHO"
echo "    $(wc -l < "$MACHO" | tr -d ' ') nested Mach-O files"
xargs -P 8 -I{} codesign --force --options runtime --timestamp --sign "$ID" {} < "$MACHO" 2>/dev/null
# Sparkle's nested bundles, innermost first (their executables were signed above).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for b in "$SPK"/XPCServices/*.xpc "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$b" ] && codesign --force --options runtime --timestamp --sign "$ID" "$b"
done
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/Mira"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

notarize() {  # notarize <file>
  set -a; . "$HOME/.appstoreconnect/mira-release-credentials"; set +a
  local key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  [ -f "$key" ] || { echo "API key file missing" >&2; return 1; }
  xcrun notarytool submit "$1" --key "$key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Mira-$VERSION.dmg"

if [ "$NOTARIZE" = 1 ]; then
  echo "==> notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/Mira.zip"
  notarize "$OUT/Mira.zip"
  xcrun stapler staple "$APP"
fi

echo "==> packaging $DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Mira.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mira" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$ID" "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  echo "==> notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Gatekeeper"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
