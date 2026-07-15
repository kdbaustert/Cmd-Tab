#!/bin/bash
# Builds Overtab.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG=release
APP="build/Overtab.app"

echo "==> Compiling"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Overtab"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Overtab"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable self-signed identity when one is present. macOS keys Accessibility to the
# app's designated requirement; signed with the same certificate every time, that requirement
# stays put and the permission survives a rebuild. Ad-hoc signing has no certificate, so the
# requirement falls back to the code hash, which changes on every build — hence the re-granting.
# See README for how to create the identity.
IDENTITY="Overtab Local"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "==> Signing as \"$IDENTITY\""
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad-hoc — \"$IDENTITY\" not found; Accessibility resets on each build)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # Kill the running copy first; a replaced binary keeps running off the old inode otherwise.
    osascript -e 'quit app "Overtab"' 2>/dev/null || true
    pkill -x Overtab 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Overtab.app
    cp -R "$APP" /Applications/Overtab.app
    open /Applications/Overtab.app
    echo "==> Launched. Look for the stacked-squares icon in the menu bar."
fi
