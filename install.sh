#!/bin/sh
# ack05d installer — build, sign, install as a login agent. One command:
#
#     ./install.sh
#
# Signs ad-hoc by default (macOS re-asks for Accessibility after each rebuild).
# To keep the Accessibility grant across rebuilds, export a code-signing identity:
#
#     ACK05D_SIGN_IDENTITY="my-cert-name" ./install.sh
#
# Accessibility is ONLY needed for the optional "mediaKey" action (native volume /
# brightness HUD). Everything else — launching apps, shell commands, the wheel —
# works with no permission at all.
set -eu

APP_DIR="$HOME/Applications/ACK05 Remote.app"
BIN_DST="$APP_DIR/Contents/MacOS/ack05d"
PLIST="$HOME/Library/LaunchAgents/io.github.livenl.ack05d.plist"
LABEL="io.github.livenl.ack05d"
IDENTITY="${ACK05D_SIGN_IDENTITY:--}"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> building (release)"
swift build -c release --package-path "$REPO"
BIN_SRC="$(swift build -c release --package-path "$REPO" --show-bin-path)/ack05d"

echo "==> assembling $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_SRC" "$BIN_DST"
cp "$REPO/app/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$REPO/app/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> signing (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$APP_DIR"

echo "==> building overlay helper (hud)"
# Optional on-screen HUD used by the example config's overlayCommand. Standalone,
# needs no permissions. Installed to ~/.local/bin if that dir is on PATH.
BIN_HOME="$HOME/.local/bin"
if [ -d "$BIN_HOME" ]; then
    swiftc -O -o "$BIN_HOME/hud" "$REPO/overlay/hud.swift"
    pkill -f "hud --server" 2>/dev/null || true
    echo "    installed $BIN_HOME/hud"
else
    echo "    skipped: $BIN_HOME does not exist (add it to PATH to use the overlay)"
fi

echo "==> installing login agent"
sed "s#@BIN@#$BIN_DST#" "$REPO/launchd/io.github.livenl.ack05d.plist.template" > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "ack05d installed and running."
echo "Config: ${XDG_CONFIG_HOME:-$HOME/.config}/ack05d/config.json"
echo "Run './.build/release/ack05d --identify' to learn your button names."
echo
echo "For the native volume/brightness HUD (optional 'mediaKey' actions), add"
echo "$APP_DIR to System Settings > Privacy & Security > Accessibility."
