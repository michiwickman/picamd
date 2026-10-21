"""Assembles the Icon Composer bundle from the layers that gen.py wrote.

Usage:  python3 make_icon.py spec.json <layers-dir> <target.icon>
Overwrites icon.json and Assets/*.svg in <target.icon>; the file names are fixed, so nothing
stale is left behind.

The background is a fill in icon.json, not a layer: a squircle drawn into a layer renders as a
smaller square inside the system mask. Specializations:
  dark    deeper black background (spec "bgDark"), glyph unchanged
  tinted  markup turns white (becomes the brightest tint step), paper lines at 75 % opacity
"""
import json, os, shutil, sys

S = json.load(open(sys.argv[1])); src, dst = sys.argv[2], sys.argv[3]
os.makedirs(os.path.join(dst, "Assets"), exist_ok=True)
for f in ("1-paper.svg", "2-markup.svg"):
    shutil.copyfile(os.path.join(src, f), os.path.join(dst, "Assets", f))


def rgb(h):
    h = h.lstrip("#"); return "srgb:" + ",".join(f"{int(h[i:i+2],16)/255:.5f}" for i in (0, 2, 4)) + ",1.00000"


def grad(a, b):
    return {"linear-gradient": [rgb(a), rgb(b)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


icon = {
  "fill-specializations": [
    {"value": grad(*S["bg"])},
    {"appearance": "dark", "value": grad(*S["bgDark"])},
  ],
  "groups": [
    {"name": "markup",
     "layers": [{"image-name": "2-markup.svg", "name": "markup",
                 "fill-specializations": [{"appearance": "tinted", "value": {"solid": rgb("#FFFFFF")}}]}],
     "shadow": {"kind": "neutral", "opacity": 0.5},
     "translucency": {"enabled": False, "value": 0},
     "specular": True},
    {"name": "paper",
     "layers": [{"image-name": "1-paper.svg", "name": "paper",
                 "opacity-specializations": [{"value": 1}, {"appearance": "tinted", "value": 0.75}]}],
     "shadow": {"kind": "neutral", "opacity": 0.5},
     "translucency": {"enabled": False, "value": 0},
     "specular": True},
  ],
  "supported-platforms": {"squares": ["macOS"]},
}
json.dump(icon, open(os.path.join(dst, "icon.json"), "w"), indent=2)
print("ok", dst)
