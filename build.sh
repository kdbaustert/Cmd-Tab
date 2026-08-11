#!/bin/bash
# Builds Cmd-Tab.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG=release
APP="build/Cmd-Tab.app"
ENTITLEMENTS="Resources/CmdTab.entitlements"

# A local build targets this machine; a release targets everyone's. `swift build` produces a binary
# for the host architecture only, which for a notarised download means an Apple Silicon build that
# an Intel Mac cannot launch at all — and now that Sparkle is here, `generate_appcast` reads the
# slices out of the bundle and writes `<sparkle:hardwareRequirements>arm64` into the feed, so the
# exclusion becomes something the updater enforces rather than merely something that happens.
# `release.sh` sets this; a local build skips it, since the second slice costs ~10s and runs nowhere
# this machine can see.
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    echo "==> Compiling (universal: arm64 + x86_64)"
else
    echo "==> Compiling"
fi
# `${a[@]+"${a[@]}"}` rather than `"${a[@]}"`: macOS ships bash 3.2, where expanding an empty array
# under `set -u` is an unbound-variable error rather than nothing at all.
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/CmdTab"

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

# ---------------------------------------------------------------- localization
#
# SwiftPM does not compile String Catalogs: declared as a resource, `Localizable.xcstrings` is
# copied verbatim into a `CmdTab_CmdTab.bundle` where nothing can read it — `LocalizedStringKey`
# resolves against `Bundle.main`, and an uncompiled catalogue is not a strings table in any case.
# So the compile happens here, and the output goes straight where `Bundle.main` looks.
CATALOG="Sources/CmdTab/Resources/Localizable.xcstrings"
if [[ -f "$CATALOG" ]]; then
    echo "==> Compiling strings"
    xcrun xcstringstool compile "$CATALOG" --output-directory "$APP/Contents/Resources"
    # Named here rather than left implicit: without CFBundleDevelopmentRegion matching a shipped
    # .lproj, a system in an unlisted language falls back to the raw keys rather than to English.
    # They happen to be the English text, so the failure is invisible until a translation exists.
    LOCALES=$(find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' -exec basename {} .lproj \; | sort | tr '\n' ' ')
    echo "    locales: ${LOCALES:-none}"
fi

# ---------------------------------------------------------------- Sparkle
#
# The first dependency that is not just code. Sparkle ships as a binary XCFramework, and SwiftPM
# will happily *link* against it while doing nothing to put it inside the bundle we assemble by
# hand here — so a build with no embedding step compiles, signs, launches, and then dies on the
# first line that touches Sparkle with a dyld "Library not loaded" that names a path under .build.
#
# Three things have to happen, and all three are load-bearing:
#
#   1. Copy the macOS slice of the XCFramework into Contents/Frameworks.
#   2. Add an rpath so the executable looks there. SwiftPM links Sparkle as @rpath/Sparkle.framework
#      and bakes in an rpath pointing at .build, which is right for `swift run` and wrong for
#      everything a user will ever do.
#   3. Sign the framework *before* the app. Signatures nest: the app's seal covers the framework's,
#      so signing them the other way round produces a bundle that verifies until someone runs
#      `codesign --verify --deep --strict`, which is to say until notarisation.
SPARKLE_XC="$(find .build/artifacts -type d -name 'Sparkle.xcframework' -print -quit)"
if [[ -z "$SPARKLE_XC" ]]; then
    echo "==> ERROR: Sparkle.xcframework not found — run 'swift package resolve' first" >&2
    exit 1
fi
# The slice name carries its architectures (macos-arm64_x86_64), which is exactly the sort of thing
# that changes in a dependency bump and breaks a hardcoded path months later.
SPARKLE_FW="$(find "$SPARKLE_XC" -maxdepth 2 -type d -name 'Sparkle.framework' -path '*macos*' -print -quit)"
if [[ -z "$SPARKLE_FW" ]]; then
    echo "==> ERROR: no macOS slice inside $SPARKLE_XC" >&2
    exit 1
fi

echo "==> Embedding Sparkle"
mkdir -p "$APP/Contents/Frameworks"
# -R preserves the version symlinks a framework bundle is made of; cp -r would flatten Versions/A
# into a duplicate tree and the signature would not validate.
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# @executable_path/../Frameworks — the standard place, and the reason this works from /Applications
# as readily as from build/.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CmdTab" 2>/dev/null || true
# install_name_tool invalidates whatever ad-hoc signature the linker left behind. Harmless, since
# the real signing happens below, but it means the binary is unsigned between here and there.

# Version stamping, for a release that wants something other than what is in Info.plist. Applied to
# the built copy only — the source plist stays the tracked default, so a release build never leaves
# the working tree dirty.
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

# A local build must not update itself. The tracked Info.plist carries the release feed, and without
# this a `./build.sh --install` bundle would cheerfully notice that the published version is newer
# than the working tree, download it, and replace the developer's build with it — losing whatever
# was being tested. Releases keep the feed; everything else has it stripped, which is what
# `Updater.isConfigured` reads to grey out the update controls and say why.
if [[ "${HARDENED:-0}" != "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
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
fi
# `--deep` is gone from both paths. It used to be here because there was nothing nested for it to
# reach; now that there is, it is the wrong tool — Apple advises against it for distribution, and it
# re-signs nested code with the *outer* signature's options, which for Sparkle's XPC services and
# Updater.app means quietly replacing signatures that were built correctly with ones that were not.
# The explicit inside-out walk below is what replaces it.

# Everything inside Contents/Frameworks that carries its own signature, deepest first. Sparkle is
# not one binary: the framework wraps Autoupdate, Updater.app and two XPC services, each a separate
# signable item. Order matters — an inner signature invalidates every seal that already covered it,
# so signing outside-in produces a bundle that passes a plain `codesign --verify` and fails
# `--deep --strict`, which is to say it passes locally and fails notarisation.
sign_nested() {
    local identity_args=("$@")
    [[ -d "$APP/Contents/Frameworks" ]] || return 0
    # -depth walks children before parents, which is exactly the order signatures have to be applied.
    while IFS= read -r item; do
        codesign "${SIGN_ARGS[@]}" "${identity_args[@]}" "$item"
    # `! -type l` matters: a framework's root is a facade of symlinks into Versions/B, so
    # Updater.app matches twice — once as itself and once through the link — and signing the same
    # file by two paths is at best redundant noise.
    done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) ! -type l -print)
    # Loose Mach-O helpers that live outside a bundle wrapper — Sparkle's Autoupdate is one.
    while IFS= read -r item; do
        # A framework's versioned symlink resolves to a binary that has already been signed as part
        # of the framework; signing it again by path is harmless but noisy, so skip anything already
        # sealed by the walk above.
        codesign --verify "$item" 2>/dev/null && continue
        codesign "${SIGN_ARGS[@]}" "${identity_args[@]}" "$item"
    done < <(find "$APP/Contents/Frameworks" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q "Mach-O.*executable"' _ {} \; -print)
}

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "==> Signing as \"$IDENTITY\""
    sign_nested --sign "$IDENTITY"
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
elif [[ "${HARDENED:-0}" == "1" ]]; then
    # A release must never fall back to ad-hoc: it would notarise nothing and install nowhere.
    echo "==> ERROR: signing identity \"$IDENTITY\" not found in the keychain" >&2
    exit 1
else
    echo "==> Signing (ad-hoc — \"$IDENTITY\" not found; Accessibility resets on each build)"
    sign_nested --sign -
    codesign "${SIGN_ARGS[@]}" --sign - "$APP"
fi

# The check that would have caught the outside-in mistake. Cheap, and the failure it catches
# otherwise surfaces as a notarisation rejection several minutes into a release.
codesign --verify --deep --strict "$APP"

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
