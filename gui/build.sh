#!/bin/bash
# Build BatteryKeeper.app from the SwiftPM package, optionally wrap it in a DMG
# and/or install it.
#
# Usage:
#   ./build.sh                 build the .app into ./build
#   ./build.sh --dmg           also build BatteryKeeper-<version>-arm64.dmg
#   ./build.sh --install       install the built .app (relaunching it if it was running)
#   ./build.sh --dmg --install build, package and install
#   ./build.sh --all           --dmg --install, then reopen the installed app
#   ./build.sh --dry-run       with --install: report the target, change nothing
#
# Options:
#   --out DIR            output directory (default: ./build)
#   --sign-identity ID   codesign identity (default: ad-hoc "-")
#   --help               this text
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BatteryKeeper"
HELPER_NAME="battery-keeper-helper"
BUNDLE_ID="co.palokaj.batterykeeper"
MIN_MACOS="14.0"
ARCH="arm64"

# Version reported in Info.plist and used in the DMG filename. Override with
# APP_VERSION=1.2.3 ./build.sh — the old script had this hardcoded in the
# heredoc, where it was easy to ship a stale number.
APP_VERSION="${APP_VERSION:-0.1.0}"

OUT_DIR="build"
MAKE_DMG=false
DO_INSTALL=false
DO_REOPEN=false
DRY_RUN=false
SIGN_IDENTITY="-"

# Print the header comment block (everything above the shebang's sibling block),
# stopping at the last help line so a future code edit cannot leak into --help.
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) MAKE_DMG=true ;;
    --install) DO_INSTALL=true ;;
    --all) MAKE_DMG=true; DO_INSTALL=true; DO_REOPEN=true ;;
    --dry-run) DRY_RUN=true ;;
    --out) OUT_DIR="${2:?--out needs a directory}"; shift ;;
    --sign-identity) SIGN_IDENTITY="${2:?--sign-identity needs a value}"; shift ;;
    --help|-h) usage; exit 0 ;;
    # Bare path stays supported as the output directory, like the old script.
    *) OUT_DIR="$1" ;;
  esac
  shift
done

APP_DIR="$OUT_DIR/$APP_NAME.app"
DMG_PATH="$OUT_DIR/$APP_NAME-$APP_VERSION-$ARCH.dmg"

# ---------------------------------------------------------------- build ----

echo "🔨 Building release binaries…"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

echo "📦 Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# The helper travels inside the bundle: SchedulesView.swift locates it via
# Bundle.main, and every launchd plist hardcodes that absolute path.
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$HELPER_NAME" "$APP_DIR/Contents/MacOS/$HELPER_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc sign so launchd and Gatekeeper treat it consistently. A real identity
# passed via --sign-identity makes the bundle distributable.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "✍️  Ad-hoc signing…"
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
else
  echo "✍️  Signing with \"$SIGN_IDENTITY\"…"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

echo "✅ Built: $APP_DIR"

# ------------------------------------------------------------------ dmg ----

if $MAKE_DMG; then
  echo "💿 Building DMG…"
  STAGE="$OUT_DIR/dmg-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  # Stage via a copy so the DMG is built from a clean bundle rather than
  # whatever extended attributes the freshly assembled app happens to carry.
  ditto "$APP_DIR" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  # Sign the staged copy too — that is the one that actually ships.
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$STAGE/$APP_NAME.app" 2>/dev/null || true
  else
    codesign --force --deep --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$STAGE/$APP_NAME.app"
  fi

  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  echo "✅ DMG: $DMG_PATH"
fi

# -------------------------------------------------------------- install ----

# Pick the directory to install into. An existing copy wins over the default so
# that re-installing updates the copy the user's login item actually points at
# rather than leaving a stale one behind somewhere else.
detect_install_dir() {
  for dir in "/Applications" "$HOME/Applications"; do
    if [[ -d "$dir/$APP_NAME.app" ]]; then
      echo "$dir"
      return
    fi
  done
  # Never installed: ~/Applications needs no elevation, so prefer it.
  echo "$HOME/Applications"
}

# Echo the other candidate directory when it also holds a copy of the app, or
# "none". Used only to decide whether the stale-login-item warning is relevant.
other_install_dir() {
  for dir in "/Applications" "$HOME/Applications"; do
    if [[ "$dir" != "$1" && -d "$dir/$APP_NAME.app" ]]; then
      echo "$dir"
      return
    fi
  done
  echo "none"
}

# Set to true by quit_running_app when it actually terminated a live copy, so
# the caller knows whether restoring the previous state means relaunching.
APP_WAS_RUNNING=false

# Quiesce the running copy so we never swap files underneath a live process.
# Returns 0 whether or not anything was running.
quit_running_app() {
  APP_WAS_RUNNING=false
  if ! pgrep -qx "$APP_NAME"; then
    return 0
  fi
  if $DRY_RUN; then
    echo "   (dry run) would quit the running $APP_NAME"
    APP_WAS_RUNNING=true
    return 0
  fi
  echo "🛑 Quitting running ${APP_NAME}…"
  APP_WAS_RUNNING=true
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -qx "$APP_NAME" || return 0
    sleep 0.2
  done
  pkill -x "$APP_NAME" 2>/dev/null || true
  # pkill is async: give it a moment, and confirm it actually took effect so we
  # never claim to have quit something still holding the old bundle open.
  for _ in {1..20}; do
    pgrep -qx "$APP_NAME" || break
    sleep 0.1
  done
  if pgrep -qx "$APP_NAME"; then
    echo "❌ $APP_NAME is still running and holds the old copy open."
    echo "   Quit it from the menu bar, then re-run this script."
    exit 1
  fi
}

# SMAppService registers the app by absolute path, so moving the app leaves the
# old login item pointing at a path that no longer exists. Only warn when we
# actually changed directories — installing over an existing copy in place
# leaves the registration valid. Deliberately does not shell out to sfltool:
# `sfltool dumpbtm` demands admin rights and pops an authorization sheet even
# for a plain read.
warn_if_login_item_stale() {
  local new_target="$1" other_dir="$2"
  [[ "$other_dir" == "none" ]] && return 0
  echo "⚠️  Another copy of $APP_NAME exists at $other_dir/$APP_NAME.app"
  echo "   If \"Launch at login\" was registered against that copy, toggle it off"
  echo "   and on again in BatteryKeeper, then remove the leftover copy."
}

if $DO_INSTALL; then
  INSTALL_DIR="$(detect_install_dir)"
  echo "📥 Installing to $INSTALL_DIR"
  if $DRY_RUN; then
    quit_running_app
    echo "🧪 Dry run — nothing written."
    exit 0
  fi

  # /Applications is root:wheel on most Macs and only root:admin-writable on
  # some, so fail with an actionable message rather than letting ditto die
  # halfway through with a bare "Permission denied".
  if ! mkdir -p "$INSTALL_DIR" 2>/dev/null || [[ ! -w "$INSTALL_DIR" ]]; then
    echo "❌ $INSTALL_DIR is not writable by $(id -un)."
    echo "   Either pick a different target, or re-run just the install with:"
    echo "     sudo ./build.sh --install"
    echo "   (build and dmg steps already ran, so nothing is lost)"
    exit 1
  fi

  quit_running_app

  TARGET="$INSTALL_DIR/$APP_NAME.app"
  if [[ -d "$TARGET" ]]; then
    # Copy alongside, then swap: a failed ditto leaves the old app intact
    # instead of a half-overwritten bundle.
    TMP_TARGET="$INSTALL_DIR/.$APP_NAME.app.new"
    rm -rf "$TMP_TARGET"
    ditto "$APP_DIR" "$TMP_TARGET"
    rm -rf "$TARGET"
    mv "$TMP_TARGET" "$TARGET"
  else
    ditto "$APP_DIR" "$TARGET"
  fi

  warn_if_login_item_stale "$TARGET" "$(other_install_dir "$INSTALL_DIR")"
  echo "✅ Installed: $TARGET"

  # Restore the state we found: if the app was running, it should be running
  # again, now against the new bundle. --all forces it on regardless.
  if $DO_REOPEN || $APP_WAS_RUNNING; then
    echo "🚀 Relaunching $TARGET"
    open "$TARGET"
  fi
fi

if $DO_REOPEN && ! $DO_INSTALL; then
  INSTALL_DIR="$(detect_install_dir)"
  echo "🚀 Launching $INSTALL_DIR/$APP_NAME.app"
  open "$INSTALL_DIR/$APP_NAME.app"
fi
