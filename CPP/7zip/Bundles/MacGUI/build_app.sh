#!/bin/sh

# Builds universal (arm64 + x86_64) 7-Zip.app for macOS.
#
#   ./build_app.sh          : creates b/m_universal/7-Zip.app
#   ./build_app.sh dmg      : also creates b/7-Zip-<version>-mac.dmg
#
# Environment variables:
#   CODESIGN_IDENTITY : identity for codesign ("Developer ID Application: ...").
#                       Default is "-" (ad-hoc signature).
#   LANG_DIR          : folder with lang files (Lang/*.txt from 7-Zip for Windows).
#                       Default is ../../../../Lang (if it exists).

set -e

cd "$(dirname "$0")"

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
IDENTITY="${CODESIGN_IDENTITY:--}"

make -j"$JOBS" -f ../../cmpl_mac_arm64.mak
make -j"$JOBS" -f ../../cmpl_mac_x64.mak

OUT=b/m_universal
APP="$OUT/7-Zip.app"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R b/m_arm64/7-Zip.app "$APP"
lipo -create b/m_arm64/7zFM b/m_x64/7zFM -output "$APP/Contents/MacOS/7zFM"

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  # hardened runtime is required for notarization
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

lipo -info "$APP/Contents/MacOS/7zFM"
echo "Created: $APP"

if [ "$1" = "dmg" ]; then
  VERSION=$(sed -n 's/^#define MY_VERSION_NUMBERS "\(.*\)"/\1/p' ../../../../C/7zVersion.h)
  DMG="b/7-Zip-$VERSION-mac.dmg"
  STAGE="$OUT/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "7-Zip $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" "$DMG"
  fi
  echo "Created: $DMG"
fi
