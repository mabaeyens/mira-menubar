#!/bin/bash
# Publish a built, notarized DMG as a GitHub release plus the Sparkle appcast.
#
#   scripts/publish.sh <path/to/Mira-X.Y.Z.dmg> [--notes "text"]
#
# The appcast is a release asset named appcast.xml. The app's SUFeedURL points at
# releases/latest/download/appcast.xml, so the newest release always answers with its own feed.
# The EdDSA signature comes from the private key in the login keychain (generate_keys);
# nothing secret is read from, or written to, the repo.
#
# This creates a PUBLIC release. Run it deliberately, after testing the DMG.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?usage: publish.sh <dmg> [--notes text]}"; shift || true
NOTES="Mira menu-bar app release."
[ "${1:-}" = "--notes" ] && NOTES="${2:?--notes needs text}"
[ -f "$DMG" ] || { echo "no such file: $DMG" >&2; exit 1; }

BIN="$HERE/.build/artifacts/sparkle/Sparkle/bin"
VERSION="$(basename "$DMG" | sed -E 's/^Mira-(.*)\.dmg$/\1/')"
TAG="v$VERSION"

# The DMG must be notarized and stapled, or the update would be refused on user machines.
xcrun stapler validate "$DMG" >/dev/null || { echo "DMG is not stapled/notarized" >&2; exit 1; }

SIG="$("$BIN/sign_update" "$DMG")"   # prints: sparkle:edSignature="..." length="..."
URL="https://github.com/mabaeyens/mira-menubar/releases/download/$TAG/$(basename "$DMG")"
FEED="$(dirname "$DMG")/appcast.xml"
cat > "$FEED" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mira</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/x-apple-diskimage" $SIG/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$FEED"

git -C "$HERE" tag -l "$TAG" | grep -q . || { echo "tag $TAG does not exist; create and push it first" >&2; exit 1; }
gh release create "$TAG" "$DMG" "$FEED" --repo mabaeyens/mira-menubar --title "Mira $VERSION" --notes "$NOTES"
echo "==> published $TAG"
