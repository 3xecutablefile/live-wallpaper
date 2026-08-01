#!/bin/bash
# Builds LiveWallpaper.app without a full Xcode project, using swiftc directly
# (the repo has no .xcodeproj checked in — the original build relied on Xcode).
# Produces:
#   dist/LiveWallpaper.app          (ad-hoc signed, sandbox-off entitlements)
#   dist/LiveWallpaper-<ver>.zip    (release artifact)
#
# Works locally and on GitHub Actions (macos runner).
set -euo pipefail

# Resolve the repo root relative to this script (works from anywhere).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$(mktemp -d /tmp/lw_build.XXXXXX)}"
DIST="$SRC/dist"

VERSION="1.1.0"
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  VERSION="1.1.0.${GITHUB_RUN_NUMBER}"
fi

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK/Sources" "$DIST"
mkdir -p "$WORK/LiveWallpaper.app/Contents/MacOS"
mkdir -p "$WORK/LiveWallpaper.app/Contents/Resources"

echo "=== [1] collect swift sources (exclude Preview Content) ==="
SOURCES=$(find "$SRC/LiveWallpaper" -name '*.swift' -not -path '*Preview Content*' | sort)

# Copy all sources to the build dir, stripping #Preview macro blocks from files
# that use them (the PreviewsMacros plugin only ships with full Xcode — plain
# swiftc can't compile them, and the CI runner's swiftc may lack it).
while IFS= read -r f; do
  rel="${f#"$SRC/LiveWallpaper"/}"
  mkdir -p "$WORK/Sources/$(dirname "$rel")"
  out="$WORK/Sources/$rel"
  if grep -q '^#Preview' "$f"; then
    awk '/^#Preview/{exit} {print}' "$f" > "$out"
    echo "stripped #Preview from: $rel"
  else
    cp "$f" "$out"
  fi
done <<< "$SOURCES"

BUILD_SOURCES=$(find "$WORK/Sources" -name '*.swift' | sort)
echo "compiling source count: $(echo "$BUILD_SOURCES" | wc -l)"

echo
echo "=== [2] compile with swiftc (Swift 5 mode) ==="
cd "$WORK"
# shellcheck disable=SC2086
swiftc -swift-version 5 -O \
  -target arm64-apple-macosx14.7 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation -framework UniformTypeIdentifiers \
  -o LiveWallpaper $BUILD_SOURCES 2>&1 | grep -E 'error:' | head -20 || true
echo "compile done (exit ${PIPESTATUS[0]})"
if [ ! -f "$WORK/LiveWallpaper" ]; then echo 'COMPILE FAILED'; exit 1; fi
ls -la "$WORK/LiveWallpaper" && echo 'BINARY OK'

echo
echo "=== [3] assemble .app bundle ==="
cp "$WORK/LiveWallpaper" "$WORK/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"

cat > "$WORK/LiveWallpaper.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>LiveWallpaper</string>
	<key>CFBundleIdentifier</key>
	<string>com.baonguyen.LiveWallpaper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>LiveWallpaper</string>
	<key>CFBundleDisplayName</key>
	<string>LiveWallpaper</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.7</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Bundle the ambient sounds.
cp "$SRC/LiveWallpaper/Sounds/"*.mp3 "$WORK/LiveWallpaper.app/Contents/Resources/" 2>/dev/null || true
echo "sounds bundled: $(ls "$WORK/LiveWallpaper.app/Contents/Resources/" | wc -l)"

echo
echo "=== [4] codesign ad-hoc with entitlements ==="
codesign --force --deep --sign - --entitlements "$SRC/LiveWallpaper/LiveWallpaper.entitlements" "$WORK/LiveWallpaper.app" 2>&1 | tail -2
codesign -dv "$WORK/LiveWallpaper.app" 2>&1 | grep -iE 'Identifier|Signature' | head -3
echo '--- sandbox entitlement check ---'
codesign -d --entitlements :- "$WORK/LiveWallpaper.app" 2>/dev/null | grep -A1 'app-sandbox' | head -3

echo
echo "=== [5] package release artifact ==="
cp -R "$WORK/LiveWallpaper.app" "$DIST/LiveWallpaper.app"
ditto -c -k --sequesterRsrc --keepParent "$DIST/LiveWallpaper.app" "$DIST/LiveWallpaper-$VERSION.zip"
rm -rf "$DIST/LiveWallpaper.app"
echo "artifact: $DIST/LiveWallpaper-$VERSION.zip ($(stat -f '%z' "$DIST/LiveWallpaper-$VERSION.zip" 2>/dev/null || stat -c '%s' "$DIST/LiveWallpaper-$VERSION.zip") bytes)"
echo "=== BUILD DONE ==="
