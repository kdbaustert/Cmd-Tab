#!/bin/bash
# Builds, signs and (optionally) notarises Cmd-Tab.app for distribution.
#
# `build.sh` signs with a self-signed certificate, which is right for this machine and useless
# anywhere else: Gatekeeper refuses it, and the first launch on someone else's Mac is a dialog
# saying the app is damaged. A release needs a Developer ID Application certificate, the hardened
# runtime, a secure timestamp, and a trip through Apple's Notary Service.
#
# Usage:
#   ./release.sh                          build + sign
#   ./release.sh --notarize               ... and submit to Apple, then staple
#   VERSION=1.2.0 BUILD=34 ./release.sh   stamp a version into the built bundle
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity. Defaults to the sole "Developer ID Application" in the
#                      keychain; set this when several teams' certificates are installed.
#   NOTARY_PROFILE     Name of a stored notarytool credential profile. Create once with:
#                        xcrun notarytool store-credentials "Cmd-Tab" \
#                          --apple-id you@example.com --team-id TEAMID --password <app-specific>
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Cmd-Tab.app"
ZIP="build/Cmd-Tab.zip"
NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

# ---------------------------------------------------------------- identity

# Matched on the certificate's common name rather than a hash, so the script keeps working when the
# certificate is renewed — the name is stable, the hash is not.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    FOUND=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | sed -E 's/.*"(.*)".*/\1/' || true)
    COUNT=$(printf '%s' "$FOUND" | grep -c . || true)
    if [[ "$COUNT" -gt 1 ]]; then
        echo "==> ERROR: several Developer ID certificates found; pick one with CODESIGN_IDENTITY:" >&2
        printf '      %s\n' $FOUND >&2
        exit 1
    fi
    IDENTITY="$FOUND"
fi

if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'EOF'
==> ERROR: no "Developer ID Application" certificate in the keychain.

    This is the only certificate Gatekeeper accepts for an app distributed outside the App Store,
    and it requires a paid Apple Developer Program membership. To get one:

      1. developer.apple.com/account → Certificates, Identifiers & Profiles → Certificates → +
      2. Choose "Developer ID Application", upload a CSR from Keychain Access
         (Keychain Access → Certificate Assistant → Request a Certificate From a Certificate
          Authority → "Saved to disk"), download the .cer and double-click it.
      3. Confirm it landed:  security find-identity -v -p codesigning

    Until then, ./build.sh --install is the way to run this app on this machine: it signs with the
    local "Overtab Local" certificate, which keeps the Accessibility grant stable across rebuilds
    but is trusted by nothing else.
EOF
    exit 1
fi

echo "==> Release identity: $IDENTITY"

# ---------------------------------------------------------------- build + sign

# Hardened runtime and timestamp come from HARDENED=1; see build.sh.
CODESIGN_IDENTITY="$IDENTITY" HARDENED=1 ./build.sh

# ---------------------------------------------------------------- verify

echo "==> Verifying signature"
# --strict is what catches the mistakes that pass a plain verify and fail notarisation: a nested
# item signed by someone else, a resource added after signing, a broken seal.
codesign --verify --strict --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 \
    | grep -E "Authority|TeamIdentifier|Timestamp|Runtime Version|Identifier" || true

# The requirement Accessibility and Screen Recording grants are keyed to. Worth printing on every
# release: change the certificate and every user re-grants both permissions, with no warning from
# anywhere else that it is about to happen.
echo "==> Designated requirement"
codesign --display --requirements - "$APP" 2>&1 | tail -n +2

# ---------------------------------------------------------------- notarise

if [[ "$NOTARIZE" != "1" ]]; then
    echo "==> Built and signed: $APP"
    echo "    Not notarised. Gatekeeper will refuse it on another Mac until it is —"
    echo "    re-run as: ./release.sh --notarize   (needs NOTARY_PROFILE)"
    exit 0
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "==> ERROR: NOTARY_PROFILE is not set; store credentials once with:" >&2
    echo "      xcrun notarytool store-credentials \"Cmd-Tab\" \\" >&2
    echo "        --apple-id you@example.com --team-id TEAMID --password <app-specific-password>" >&2
    exit 1
fi

# ditto, not zip: the Notary Service needs the bundle's symlinks and extended attributes intact, and
# a plain `zip` flattens both, which fails the submission with an unhelpful error.
echo "==> Packaging for notarisation"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple (this takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# Stapling puts the ticket inside the bundle, so the app launches on a Mac that is offline or
# cannot reach Apple. Without it Gatekeeper has to phone home on first launch.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The real test: what Gatekeeper says about the bundle as a user would receive it.
echo "==> Gatekeeper assessment"
spctl --assess --type exec --verbose=4 "$APP"

# Re-zipped after stapling — the ticket lives in the bundle, so a zip made before stapling does not
# carry it and the download would still phone home.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Notarised and stapled: $ZIP"
