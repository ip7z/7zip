#!/bin/sh

# Builds and installs 7-Zip.app for macOS.
#
#   ./install_app.sh                 build for current CPU and install to /Applications
#   ./install_app.sh --universal     build universal application (arm64 + x86_64)
#   ./install_app.sh --user          install to ~/Applications (no admin rights required)
#   ./install_app.sh --dest DIR      install to DIR
#   ./install_app.sh --no-build      install already built application
#   ./install_app.sh --uninstall     remove installed 7-Zip.app
#   ./install_app.sh --help
#
# Environment variables:
#   LANG_DIR          : folder with lang files (Lang/*.txt from 7-Zip for Windows)
#   CODESIGN_IDENTITY : identity for codesign (used with --universal), default is ad-hoc

set -e

cd "$(dirname "$0")"

APP_NAME="7-Zip.app"
DEST="/Applications"
UNIVERSAL=0
BUILD=1
UNINSTALL=0

usage()
{
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --user)      DEST="$HOME/Applications" ;;
    --dest)      shift; DEST="$1" ;;
    --no-build)  BUILD=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$DEST" ]; then
  echo "Destination folder is not specified" >&2
  exit 1
fi

TARGET="$DEST/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# runs command with sudo, if the destination folder is not writable
run()
{
  if [ -w "$DEST" ] || { [ ! -e "$DEST" ] && [ -w "$(dirname "$DEST")" ]; }; then
    "$@"
  else
    echo "Administrator rights are required to write to $DEST"
    sudo "$@"
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  if [ ! -d "$TARGET" ]; then
    echo "$TARGET is not installed"
    exit 0
  fi
  pkill -x 7zFM 2>/dev/null || true
  "$LSREGISTER" -u "$TARGET" 2>/dev/null || true
  run rm -rf "$TARGET"
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  echo "Removed: $TARGET"
  exit 0
fi

# ---------- build ----------

if [ "$UNIVERSAL" = 1 ]; then
  SRC="b/m_universal/$APP_NAME"
  [ "$BUILD" = 1 ] && ./build_app.sh
else
  case "$(uname -m)" in
    arm64)  MAK=../../cmpl_mac_arm64.mak; SRC="b/m_arm64/$APP_NAME" ;;
    x86_64) MAK=../../cmpl_mac_x64.mak;   SRC="b/m_x64/$APP_NAME" ;;
    *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
  esac
  if [ "$BUILD" = 1 ]; then
    JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    make -j"$JOBS" -f "$MAK"
  fi
fi

if [ ! -d "$SRC" ]; then
  echo "The application was not built: $SRC" >&2
  exit 1
fi

# ---------- install ----------

# the running copy must be closed before replacing
if pgrep -x 7zFM >/dev/null 2>&1; then
  echo "Closing running 7-Zip..."
  osascript -e 'tell application id "org.7-zip.7-Zip" to quit' 2>/dev/null || pkill -x 7zFM || true
  sleep 1
fi

run mkdir -p "$DEST"
run rm -rf "$TARGET"
run ditto "$SRC" "$TARGET"
run xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# register the application (document types, icons) and Finder services
"$LSREGISTER" -f "$TARGET"
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo "Installed: $TARGET"
echo "Finder services: right-click files > Quick Actions / Services > 7-Zip: ..."
echo "If services are not shown, enable them in System Settings > Keyboard > Keyboard Shortcuts > Services."
