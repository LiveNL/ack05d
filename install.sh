#!/bin/sh
# ack05d installer — build, sign, install as a login agent. One command:
#
#     ./install.sh
#
# Signs with the "ack05d-signing" identity when it exists (create it once with
# ./make-signing-cert.sh — keeps Accessibility/login-item/keychain grants across
# rebuilds), else ad-hoc (macOS re-asks for Accessibility after each rebuild).
# Override with:
#
#     ACK05D_SIGN_IDENTITY="my-cert-name" ./install.sh
#
# Accessibility is only needed for actions that synthesize input: "mediaKey" (native
# volume/brightness HUD) and "keystroke". Launching apps, shell commands and the wheel
# itself work with no permission at all.
set -eu

APP_NAME="ACK05 Remote Community Driver"
APP_DIR="$HOME/Applications/$APP_NAME.app"
BIN_DST="$APP_DIR/Contents/MacOS/ack05d"
PLIST="$HOME/Library/LaunchAgents/io.github.livenl.ack05d.plist"
LABEL="io.github.livenl.ack05d"
LOG="$HOME/Library/Logs/ack05d.log"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ack05d"
if [ -z "${ACK05D_SIGN_IDENTITY:-}" ] \
    && security find-identity -p codesigning -v 2>/dev/null | grep -q "ack05d-signing"; then
    ACK05D_SIGN_IDENTITY="ack05d-signing"
fi
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
# needs no permissions. Installed to ~/.local/bin (created if missing).
BIN_HOME="$HOME/.local/bin"
mkdir -p "$BIN_HOME"
swiftc -O -o "$BIN_HOME/hud" "$REPO/overlay/hud.swift"
pkill -f "hud --server" 2>/dev/null || true
echo "    installed $BIN_HOME/hud"
case ":$PATH:" in
    *":$BIN_HOME:"*) ;;
    *) echo "    note: $BIN_HOME is not on your PATH; the config references it by full path, so that's fine" ;;
esac

echo "==> config"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    # Seed from the example, pointing overlayCommand at the hud just built.
    cp "$REPO/config.example.json" "$CONFIG_DIR/config.json"
    echo "    created $CONFIG_DIR/config.json from config.example.json"
else
    echo "    keeping existing $CONFIG_DIR/config.json"
fi

echo "==> installing login agent"
mkdir -p "$(dirname "$LOG")"
NEW_PLIST="$(sed -e "s#@BIN@#$BIN_DST#" -e "s#@LOG@#$LOG#" "$REPO/launchd/io.github.livenl.ack05d.plist.template")"
if [ -f "$PLIST" ] && [ "$NEW_PLIST" = "$(cat "$PLIST")" ] \
    && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    # Unchanged and loaded: restart in place. Re-bootstrapping re-registers the
    # login item and triggers the "added to Login Items" notification every build.
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
    printf '%s\n' "$NEW_PLIST" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

echo
echo "ack05d installed and running."
echo "  config : $CONFIG_DIR/config.json  (edits hot-reload)"
echo "  log    : $LOG"
echo
echo "Next:"
echo "  1. If the remote is not paired yet: System Settings > Bluetooth > pair 'Shortcut Remote'."
echo "  2. Learn your button names: stop the agent first, then run identify:"
echo "       launchctl bootout gui/\$(id -u)/$LABEL"
echo "       $REPO/.build/release/ack05d --identify"
echo "       ./install.sh    # restarts the agent"
echo "  3. For mediaKey / keystroke actions, add \"$APP_NAME\" under"
echo "     System Settings > Privacy & Security > Accessibility."
echo "     Run ./make-signing-cert.sh once so that grant survives future rebuilds."
