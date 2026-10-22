#!/usr/bin/env bash
# PicaMD build script — generates the Xcode project, builds Release,
# ad-hoc signs, and (optionally) installs into /Applications/.
#
# Requires: Xcode, xcodegen (`brew install xcodegen`).
#
# Why no custom `-derivedDataPath` and no `lsregister`?
#   Earlier versions wrote into `./build-release/` AND explicitly
#   registered that path with LaunchServices. The combination meant
#   Spotlight ended up with multiple PicaMD entries — the project
#   build, the Xcode-DerivedData build, and the /Applications copy.
#   Now we use the standard Xcode DerivedData path (Spotlight already
#   ignores it under most macOS configs) and only register the
#   /Applications copy via the standard `cp -R` install.
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_TO_APPLICATIONS="${INSTALL:-1}"   # set INSTALL=0 to skip the cp

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release (Xcode-DerivedData, no custom path)"
xcodebuild \
    -project PicaMD.xcodeproj \
    -scheme PicaMD \
    -configuration Release \
    -destination 'platform=macOS' \
    build | tail -3

# Locate the just-built .app — `xcodebuild -showBuildSettings` is the
# Apple-blessed way to find it without hard-coding the DerivedData hash.
BUILT_APP="$(
    xcodebuild -project PicaMD.xcodeproj \
        -scheme PicaMD -configuration Release \
        -showBuildSettings 2>/dev/null \
        | awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR /{print $2}'
)/PicaMD.app"

[ -d "$BUILT_APP" ] || { echo "Build did not produce $BUILT_APP"; exit 1; }

echo "==> Re-signing ad-hoc (deep)"
codesign --force --deep --sign - "$BUILT_APP"

echo "==> Verifying signature"
codesign --verify --verbose=2 "$BUILT_APP"

echo "==> Bundle stats"
echo "Size:    $(du -sh "$BUILT_APP" | awk '{print $1}')"
echo "Linked:  $(otool -L "$BUILT_APP/Contents/MacOS/PicaMD" | tail -n +2 | wc -l | tr -d ' ') libraries"

if [ "$INSTALL_TO_APPLICATIONS" = "1" ]; then
    echo "==> Installing to /Applications"
    # Never `rm` — the previous copy goes to the Trash so an install can
    # always be undone from the Finder. `trash` exits non-zero when the
    # target is absent, which is fine on a first install.
    [ -d "/Applications/PicaMD.app" ] && /usr/bin/trash "/Applications/PicaMD.app"
    cp -R "$BUILT_APP" "/Applications/"
    # `cp` triggers a Finder re-scan on /Applications which registers
    # the copy automatically — no explicit `lsregister` needed.
    echo "Installed: /Applications/PicaMD.app"
else
    echo "==> Skipping install (INSTALL=0)"
    echo "Built: $BUILT_APP"
fi

echo
echo "First-launch tip (no Developer ID, after fresh install):"
echo "  xattr -dr com.apple.quarantine /Applications/PicaMD.app"
