# App icon ("Caret line")

![Default, Dark, Tinted dark, Clear light](preview.png)

Three paper lines on a near-black ground. The middle line is the line with
the caret and shows its raw Markdown: a blue `#`, a short text run that fades
from blue into paper, and the blue caret.

The app ships `PicaMD/AppIcon.icon`, an Icon Composer bundle (`icon.json`
plus two SVG layers). Everything in this folder exists to regenerate it.

| File | Purpose |
|---|---|
| `spec.json` | All geometry and colours. Coordinates are on a 1024 px canvas with a 100 px margin (icon body 824 px). `bg` / `bgDark` are the background gradients (top, bottom) for the light and dark appearance. |
| `gen.py` | Writes the SVGs below from `spec.json`. |
| `make_icon.py` | Assembles `PicaMD/AppIcon.icon` from the layers: background as a gradient fill in `icon.json`, dark and tinted specializations. |
| `build.sh` | Runs both scripts, then renders previews with `ictool`. |
| `layers/1-paper.svg`, `layers/2-markup.svg` | The two `.icon` layers (copied into `AppIcon.icon/Assets/`). |
| `icon.svg` | Flat master with the squircle, for previews outside Icon Composer. |
| `icon-16.svg`, `icon-32.svg` | Pixel-grid masters for 16 and 32 px. Reference only: an `.icon` has no per-size images, so the system scales the large layers down. |
| `montage.swift` | Lays renders side by side for `preview.png`. |
| `preview.png` | The one committed render. |

## Regenerate

```sh
design/icon/build.sh            # or: design/icon/build.sh path/to/other-spec.json
xcodegen generate               # only needed if the project does not exist yet
```

`build.sh` needs `python3` and Xcode 27. It overwrites
`PicaMD/AppIcon.icon` and `preview.png`, and writes all six system renditions
to `design/icon/renders/` (git-ignored). Check the result in the built app's
Dock and Finder, not only in the renders: the system adds the margin and the
glass edge itself.

Two rules that the scripts already follow:

- The squircle is never part of a layer. A squircle drawn into a layer shows
  up as a smaller square inside the system mask. The background is a fill in
  `icon.json`, and the layers are transparent and cover the whole canvas.
- Icon Composer maps the whole layer canvas onto the icon body, so `gen.py`
  scales the glyph by 1024/824 (times `big.scale`) around the centre.

## Render previews by hand

The renderer is not `xcrun ictool` (that one rejects `--export-image`) but
the binary inside Icon Composer:

```sh
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" PicaMD/AppIcon.icon --export-image --output-file out.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 \
    --design-generation 27
```

Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`,
`ClearDark`. Tinted renders take `--tint-color <0..1>` (hue) and
`--tint-strength <0..1>`. `ictool` renders the icon full-bleed; the system
draws it inside the standard margin.

## How the build uses it

`project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. xcodegen
picks up `PicaMD/AppIcon.icon` as a resource (`wrapper.icon`), and actool
compiles it into `Contents/Resources/Assets.car` (all sizes and appearances)
plus a small `AppIcon.icns`, and writes `CFBundleIconFile` and
`CFBundleIconName` into `Info.plist`. `NSImage(named: "AppIcon")`, which the
Welcome window uses, resolves from `Assets.car`; `PicaMDTests/AppIconTests`
checks that.
