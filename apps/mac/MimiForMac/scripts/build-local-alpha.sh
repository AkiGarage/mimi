#!/usr/bin/env bash
set -euo pipefail

# Build a local-alpha .app. The completed bundle receives an ad-hoc signature
# so macOS can bind TCC permissions to this exact build. Developer ID signing,
# notarization, and distribution remain outside this script.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PRODUCT="MimiForMacDebug"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
APP_DIR="$PACKAGE_DIR/.build/local-alpha/Mimi.app"
ICON_SOURCE="$PACKAGE_DIR/Packaging/MimiAppIcon.png"
ICONSET_DIR="$PACKAGE_DIR/.build/local-alpha/MimiAppIcon.iconset"

swift build \
  --package-path "$PACKAGE_DIR" \
  --configuration "$BUILD_CONFIGURATION" \
  --product "$PRODUCT"

BIN_DIR="$(swift build \
  --package-path "$PACKAGE_DIR" \
  --configuration "$BUILD_CONFIGURATION" \
  --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP_DIR/Contents/MacOS/$PRODUCT"
cp "$PACKAGE_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
for LANGUAGE in en ja; do
  mkdir -p "$APP_DIR/Contents/Resources/$LANGUAGE.lproj"
  cp \
    "$PACKAGE_DIR/Sources/MimiForMac/Resources/$LANGUAGE.lproj/Localizable.strings" \
    "$APP_DIR/Contents/Resources/$LANGUAGE.lproj/Localizable.strings"
  cp \
    "$PACKAGE_DIR/Packaging/$LANGUAGE.lproj/InfoPlist.strings" \
    "$APP_DIR/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings"
done
test -s "$ICON_SOURCE"
cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/MimiAppIcon.png"
sips -z 88 88 "$ICON_SOURCE" --out "$APP_DIR/Contents/Resources/MimiHeaderIcon.png" >/dev/null

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/MimiAppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built ad-hoc signed local alpha: $APP_DIR"
