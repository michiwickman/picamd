#!/bin/bash
# Regenerates the PicaMD app icon from spec.json:
#   1. gen.py writes the SVG masters and the two .icon layers into this folder,
#   2. make_icon.py assembles PicaMD/AppIcon.icon (the file the app target ships),
#   3. ictool renders all six system renditions into renders/ (not committed) and
#      the committed preview.png (Default, Dark, Tinted dark, Clear light).
# Usage: design/icon/build.sh [spec.json]
# ICTOOL overrides the renderer path; without it the Icon Composer that ships with the
# selected Xcode is used. Step 3 is skipped when ictool is missing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SPEC="${1:-$HERE/spec.json}"
ICON="$REPO/PicaMD/AppIcon.icon"
ICTOOL="${ICTOOL:-$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool}"

python3 "$HERE/gen.py" "$SPEC" "$HERE"
python3 "$HERE/make_icon.py" "$SPEC" "$HERE/layers" "$ICON"

if [ ! -x "$ICTOOL" ]; then
    echo "ictool not found at $ICTOOL - skipped renders and preview.png"
    exit 0
fi
mkdir -p "$HERE/renders"
for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    "$ICTOOL" "$ICON" --export-image --output-file "$HERE/renders/$r.png" --platform macOS \
        --rendition "$r" --width 1024 --height 1024 --scale 1 --design-generation 27 >/dev/null
done
xcrun swift "$HERE/montage.swift" "$HERE/preview.png" 808080 24 256 \
    "$HERE/renders/Default.png" "$HERE/renders/Dark.png" \
    "$HERE/renders/TintedDark.png" "$HERE/renders/ClearLight.png"
echo "done: $ICON, renders in $HERE/renders, preview $HERE/preview.png"
