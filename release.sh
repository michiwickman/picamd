#!/usr/bin/env bash
# PicaMD release script — produces a distributable .zip for a given
# version tag. Works in two modes:
#
#   1. **Ad-hoc signed (default)** — what you get without an Apple
#      Developer Program subscription. Build, ad-hoc-sign, zip.
#      Users will see Gatekeeper's "can't be opened" dialog on first
#      launch and need to right-click → Open. README explains.
#
#   2. **Notarized** — when `NOTARIZE_API_KEY_ID` and
#      `NOTARIZE_API_KEY_PATH` and `NOTARIZE_TEAM_ID` are set in the
#      environment, additionally:
#        - Re-sign with Developer ID Application identity (must be
#          in the keychain — `security find-identity -v -p codesigning`)
#        - Submit to Apple's notary service via `xcrun notarytool`
#        - Staple the ticket so the .app passes Gatekeeper offline
#      This path requires a paid Apple Developer membership.
#
# Usage:
#   ./release.sh                 # builds version from project.yml
#   ./release.sh 0.8.0           # bumps project.yml to 0.8.0 first
#   NOTARIZE_API_KEY_ID=… ./release.sh 1.0.0   # full notarized release
#
# Output: ./dist/PicaMD-<version>.zip + ./dist/PicaMD-<version>.zip.sig
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
NOTARIZE="${NOTARIZE_API_KEY_ID:+1}"

# ---------------------------------------------------------------- prep

if [ -n "$VERSION" ]; then
    echo "==> Bumping MARKETING_VERSION to $VERSION in project.yml"
    /usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
fi

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] || { echo "Could not read MARKETING_VERSION from project.yml"; exit 1; }

# Sparkle compares the appcast's <sparkle:version> with CFBundleVersion,
# which used to stay "1" forever — so an update was never "newer". Use
# a monotonic build number (commit count) and put the SAME number into
# <sparkle:version> for this release.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
echo "==> Building PicaMD $VERSION (build $BUILD_NUMBER)"

mkdir -p dist
rm -rf dist/PicaMD-*

# ------------------------------------------------------------- build

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild \
    -project PicaMD.xcodeproj \
    -scheme PicaMD \
    -configuration Release \
    -destination 'platform=macOS' \
    build | tail -5

BUILT_APP="$(
    xcodebuild -project PicaMD.xcodeproj \
        -scheme PicaMD -configuration Release \
        -showBuildSettings 2>/dev/null \
        | awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR /{print $2}'
)/PicaMD.app"

[ -d "$BUILT_APP" ] || { echo "Build did not produce $BUILT_APP"; exit 1; }

# ------------------------------------------------------------- sign

if [ "$NOTARIZE" = "1" ]; then
    : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the keychain identity name (e.g. 'Developer ID Application: …')}"
    echo "==> Signing with Developer ID: $DEVELOPER_ID_APPLICATION"
    /usr/bin/codesign --force --deep --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$BUILT_APP"
else
    echo "==> Ad-hoc signing (no Developer ID)"
    /usr/bin/codesign --force --deep --sign - "$BUILT_APP"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

# ----------------------------------------------------------- package

DEST="dist/PicaMD-$VERSION.zip"
echo "==> Zipping to $DEST"
# `-y` keeps symlinks (some Sparkle setups care). `--keepParent` puts
# PicaMD.app at the top level of the archive instead of unpacking
# loose Contents/.
/usr/bin/ditto -c -k --keepParent "$BUILT_APP" "$DEST"

# --------------------------------------------------------- notarize

if [ "$NOTARIZE" = "1" ]; then
    : "${NOTARIZE_API_KEY_PATH:?Set NOTARIZE_API_KEY_PATH to the .p8 key file path}"
    : "${NOTARIZE_TEAM_ID:?Set NOTARIZE_TEAM_ID to your Apple Team ID}"
    echo "==> Submitting to Apple notary service (this can take 1-5 min)"
    /usr/bin/xcrun notarytool submit "$DEST" \
        --key "$NOTARIZE_API_KEY_PATH" \
        --key-id "$NOTARIZE_API_KEY_ID" \
        --team-id "$NOTARIZE_TEAM_ID" \
        --wait

    echo "==> Stapling notarization ticket"
    /usr/bin/xcrun stapler staple "$BUILT_APP"

    # Re-zip with the stapled ticket included.
    rm -f "$DEST"
    /usr/bin/ditto -c -k --keepParent "$BUILT_APP" "$DEST"
fi

# ----------------------------------------------------------- output

SIZE_MB=$(du -sh "$DEST" | awk '{print $1}')
SHA=$(/usr/bin/shasum -a 256 "$DEST" | awk '{print $1}')

echo
echo "============================================================"
echo "PicaMD $VERSION packaged"
echo "  Build:   $BUILD_NUMBER  (use as <sparkle:version> in appcast.xml)"
echo "  File:    $DEST"
echo "  Size:    $SIZE_MB"
echo "  SHA-256: $SHA"
if [ "$NOTARIZE" = "1" ]; then
    echo "  Status:  Notarized (passes Gatekeeper offline)"
else
    echo "  Status:  Ad-hoc signed (Gatekeeper warning on first open)"
    echo
    echo "Tell users:"
    echo "  1. Right-click PicaMD.app → Open → Open (in dialog)"
    echo "  2. OR: xattr -dr com.apple.quarantine /Applications/PicaMD.app"
fi
echo "============================================================"
