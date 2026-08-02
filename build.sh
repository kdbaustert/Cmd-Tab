#!/bin/bash
# Builds Cmd-Tab.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG=release
APP="build/Cmd-Tab.app"
ENTITLEMENTS="Resources/CmdTab.entitlements"

echo "==> Compiling"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CmdTab"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CmdTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon (CFBundleIconFile=AppIcon) and the menu-bar template PNGs, looked up by NSImage(named:).
# One template set per MenuBarIcon case — all of them ship, since the choice is made at runtime.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Flattened out of Resources/MenuBar: NSImage(named:) only searches the top level of the bundle's
# resource directory, so the subfolder is a repo-tidiness measure that must not survive the copy.
cp Resources/MenuBar/*.png "$APP/Contents/Resources/"

# Version stamping, for a release that wants something other than what is in Info.plist. Applied to
# the built copy only — the source plist stays the tracked default, so a release build never leaves
# the working tree dirty.
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

# Sign with a stable identity when one is present. macOS keys Accessibility to the app's designated
# requirement; signed with the same certificate every time, that requirement stays put and the
# permission survives a rebuild. Ad-hoc signing has no certificate, so the requirement falls back to
# the code hash, which changes on every build — hence the re-granting.
#
# The default identity is still called "Overtab Local" from before the rename: it is only a keychain
# label, and replacing it would change the requirement and cost another re-grant for nothing. See
# README for how to create it. `release.sh` overrides it with a Developer ID.
IDENTITY="${CODESIGN_IDENTITY:-Overtab Local}"
SIGN_ARGS=(--force)
if [[ "${HARDENED:-0}" == "1" ]]; then
    # Both are notarisation requirements, not nice-to-haves: the Notary Service rejects a submission
    # that is not hardened, and a signature without a secure timestamp stops validating the moment
    # the signing certificate expires.
    SIGN_ARGS+=(--options runtime --timestamp)
    # None are needed today — the app is unsandboxed, loads no third-party code, and reaches
    # Accessibility and ScreenCaptureKit through TCC rather than entitlements — so the file is
    # optional and only picked up if it exists.
    if [[ -f "$ENTITLEMENTS" ]]; then
        echo "==> Entitlements: $ENTITLEMENTS"
        SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
else
    # Local builds keep --deep, which is what this script has always done. Release builds do not:
    # Apple explicitly advises against it for distribution, and there is no nested code here to
    # need it — one executable, no frameworks, no helpers.
    SIGN_ARGS+=(--deep)
fi

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "==> Signing as \"$IDENTITY\""
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
elif [[ "${HARDENED:-0}" == "1" ]]; then
    # A release must never fall back to ad-hoc: it would notarise nothing and install nowhere.
    echo "==> ERROR: signing identity \"$IDENTITY\" not found in the keychain" >&2
    exit 1
else
    echo "==> Signing (ad-hoc — \"$IDENTITY\" not found; Accessibility resets on each build)"
    codesign "${SIGN_ARGS[@]}" --sign - "$APP"
fi

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    # Kill the running copy first; a replaced binary keeps running off the old inode otherwise.
    osascript -e 'quit app "Cmd-Tab"' 2>/dev/null || true
    pkill -x CmdTab 2>/dev/null || true
    # The pre-rename app, if it is still around. It disabled the system ⌘-Tab on the way in and
    # only restores it on a clean quit, so it has to go down properly rather than be deleted.
    osascript -e 'quit app "Overtab"' 2>/dev/null || true
    pkill -x Overtab 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Cmd-Tab.app /Applications/Overtab.app
    cp -R "$APP" /Applications/Cmd-Tab.app
    open /Applications/Cmd-Tab.app
    echo "==> Launched. Look for the stacked-squares icon in the menu bar."
fi
