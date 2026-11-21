#!/bin/bash
# Assemble Mira.app: the menu-bar executable, an embedded Python runtime, locked
# dependencies and the mira-core source. Unsigned; scripts/release.sh signs and notarizes.
#
#   scripts/build-app.sh [--core DIR] [--out DIR] [--version X.Y.Z]
#
# --core defaults to ../mira-core (tracked files at HEAD are bundled, never the working tree).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$HERE/../mira-core"
OUT="$HERE/build"
VERSION="$(git -C "$HERE" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.1.0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --core) CORE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
CORE="$(cd "$CORE" && pwd)"
APP="$OUT/Mira.app"
R="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$R"

echo "==> menu-bar executable"
(cd "$HERE" && swift build -c release --arch arm64 >/dev/null)
BIN="$(cd "$HERE" && swift build -c release --arch arm64 --show-bin-path)/MiraMenuBar"
cp "$BIN" "$APP/Contents/MacOS/Mira"

echo "==> Python runtime"
PYBIN="$(uv python find 3.13)"
# Resolve links: the bundle must hold real files, never a link back into ~/.local/share/uv.
PYSRC="$(cd "$(dirname "$PYBIN")/.." && pwd -P)"
[ -x "$PYSRC/bin/python3.13" ] || { echo "no python-build-standalone 3.13 (run: uv python install 3.13)" >&2; exit 1; }
cp -R "$PYSRC" "$R/python"
# Not needed at runtime. Writing .pyc into the signed bundle would break its signature,
# so the app sets PYTHONDONTWRITEBYTECODE and these are simply dead weight.
rm -rf "$R/python/share" "$R/python/include" \
  "$R/python/lib/python3.13/test" "$R/python/lib/python3.13/idlelib" \
  "$R/python/lib/python3.13/tkinter" "$R/python/lib/python3.13/turtledemo"

echo "==> locked dependencies"
REQ="$OUT/requirements.txt"
(cd "$CORE" && uv export --frozen --no-hashes --no-dev --no-emit-project -o "$REQ" >/dev/null 2>&1)
uv pip install --python "$R/python/bin/python3.13" --target "$R/site-packages" -r "$REQ" --quiet

echo "==> mira-core source (HEAD, tracked files only)"
mkdir -p "$R/mira-core"
git -C "$CORE" archive HEAD | tar -x -C "$R/mira-core"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mab.mira-menubar</string>
<key>CFBundleName</key><string>Mira</string>
<key>CFBundleDisplayName</key><string>Mira</string>
<key>CFBundleExecutable</key><string>Mira</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Mira</string>
</dict></plist>
EOF

echo "==> done: $APP ($(du -sh "$APP" | cut -f1), $(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c 'Mach-O') Mach-O files)"
