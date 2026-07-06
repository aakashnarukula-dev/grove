#!/bin/bash
# Build the "Grove" macOS app from source into a .app bundle.
# Requires Swift + macOS 13+. Re-run anytime; output goes to build/.
#
#   ./build.sh          # compile + bundle
#   ./build.sh --open   # compile + bundle + launch it
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Grove.app"
BIN="Grove"
BUNDLE_ID="com.grove.app"

# Build for whatever architecture this Mac is (arm64 or x86_64).
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"

echo "── Building Grove (${ARCH}) ───────────────────────────────"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling Swift sources"
swiftc -O \
  -target "$TARGET" \
  -o "$APP/Contents/MacOS/$BIN" \
  "$HERE"/Sources/*.swift

echo "→ writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Grove</string>
    <key>CFBundleDisplayName</key><string>Grove</string>
    <key>CFBundleExecutable</key><string>${BIN}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>Grove — MIT licensed open source</string>
    <!-- Friendly text for the macOS permission prompts when you open a folder
         inside one of these protected locations. -->
    <key>NSDesktopFolderUsageDescription</key><string>Grove needs access to show the folder you opened from the Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Grove needs access to show the folder you opened from Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Grove needs access to show the folder you opened from Downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Grove needs access to show a folder you opened from a removable volume.</string>
</dict>
</plist>
PLIST

echo "→ copying app icon"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
  && echo "  (AppIcon.icns bundled)" \
  || echo "  (no AppIcon.icns — run ./make-icon.sh first, or skip for the default icon)"

echo "→ ad-hoc signing (so it launches without warnings)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✅ Built: $APP"
if [ "${1:-}" = "--open" ]; then
  echo "→ launching"
  open "$APP"
else
  echo "Run it with:  open \"$APP\""
fi
