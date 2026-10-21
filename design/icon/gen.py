"""SVG generator for the PicaMD app icon ("Caret line").

Motif: rendered text lines on paper. The middle line is the caret line and shows its raw
Markdown: a blue "#", a short text run that fades from blue into paper, and the blue caret.

Usage:  python3 gen.py spec.json <output-dir>
Writes into <output-dir>:
  icon.svg               flat master: squircle (superellipse n = 5) on the 824 px grid
                         (100 px margin on the 1024 canvas) plus glyph; previews only
  icon-32.svg, icon-16.svg  pixel-grid masters for 32 and 16 px (same 1024 canvas); reference
                         for the small sizes, Icon Composer has no per-size images
  layers/1-paper.svg     .icon layer: the paper lines, transparent, full 1024 canvas
  layers/2-markup.svg    .icon layer: "#" and caret

Coordinates in spec.json are on the 1024 canvas WITH the 100 px margin. The .icon layers get
the glyph scaled by 1024/824 around the centre, because Icon Composer maps the whole layer
canvas onto the squircle body. The squircle itself is never part of a layer: the background
is a fill in icon.json (make_icon.py), otherwise it renders as a smaller square inside the
system mask.
"""
import json, math, os, sys

S = json.load(open(sys.argv[1])); OUT = sys.argv[2]
os.makedirs(os.path.join(OUT, "layers"), exist_ok=True)
HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'


def squircle(x0=100, y0=100, s=824, n=5.0, N=360):
    c = s / 2; cx, cy = x0 + c, y0 + c; pts = []
    for i in range(N):
        t = 2 * math.pi * i / N; ct, st = math.cos(t), math.sin(t)
        x = cx + c * math.copysign(abs(ct) ** (2 / n), ct); y = cy + c * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


def seg(d, col, w):
    return (f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{w:.2f}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def hline(x0, x1, y, col, w):          # x0/x1 = stroke extent including the round caps
    return seg(f"M{x0 + w/2:.2f},{y:.2f} H{x1 - w/2:.2f}", col, w)


def vline(x, y0, y1, col, w, dx=0.0):   # y0/y1 = stroke extent; dx = slant (top leans right)
    return seg(f"M{x + dx/2:.2f},{y0 + w/2:.2f} L{x - dx/2:.2f},{y1 - w/2:.2f}", col, w)


def glyph(P, k=1.0):
    """P = geometry in spec units, k = factor to the 1024 canvas. Returns (paper, markup, defs)."""
    u = lambda v: v * k
    paper, markup, defs = [], [], ""
    w = u(P["w"])
    for x0, x1, y in P["lines"]:
        paper.append(hline(u(x0), u(x1), u(y), S["paper"], w))
    t = P["text"]; tcol = S["paper"]
    if t.get("grad"):
        g0, g1 = t["grad"]
        defs += (f'<linearGradient id="tg" gradientUnits="userSpaceOnUse" x1="{u(g0):.2f}" y1="0" x2="{u(g1):.2f}" y2="0">'
                 f'<stop offset="0" stop-color="{S["blue2"]}"/><stop offset="1" stop-color="{S["paper"]}"/></linearGradient>')
        tcol = "url(#tg)"
    paper.append(hline(u(t["x0"]), u(t["x1"]), u(t["y"]), tcol, w))
    h = P["hash"]; hw = u(h.get("w", P["w"])); hx, hy, sx, sy = u(h["x"]), u(h["y"]), u(h["sx"]), u(h["sy"])
    dx = u(h.get("slant", 0))
    for a in h["v"]:   # vertical bars, centre as a fraction of the width
        markup.append(vline(hx + sx * a, hy, hy + sy, S["blue"], hw, dx))
    for a in h["h"]:   # horizontal bars, centre as a fraction of the height
        markup.append(hline(hx, hx + sx, hy + sy * a, S["blue"], hw))
    c = P["caret"]; cw = u(c.get("w", P["w"]))
    markup.append(vline(u(c["x"]), u(c["y0"]), u(c["y1"]), S["caret"], cw))
    return paper, markup, defs


def bgdefs():
    return (f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{S["bg"][0]}"/>'
            f'<stop offset="1" stop-color="{S["bg"][1]}"/></linearGradient>')


def full(P, k):
    paper, markup, defs = glyph(P, k)
    sc = P.get("scale", 1.0)   # optical size of the whole glyph, scaled around the centre
    g0 = f'<g transform="translate(512 512) scale({sc}) translate(-512 -512)">' if sc != 1.0 else "<g>"
    return (HEAD + f"<defs>{bgdefs()}{defs}</defs>" + f'<path d="{squircle()}" fill="url(#bg)"/>'
            + g0 + "".join(paper) + "".join(markup) + "</g></svg>\n")


def write(name, txt):
    open(os.path.join(OUT, name), "w").write(txt)


# Large master
write("icon.svg", full(S["big"], 1.0))
# Pixel-grid masters (one unit = one target pixel)
for name, P in S.get("small", {}).items():
    write(f"icon-{name}.svg", full(P, 1024 / P["size"]))
# .icon layers: body (824) -> whole canvas (1024)
f = 1024 / 824 * S["big"].get("scale", 1.0)
T = f'<g transform="translate(512 512) scale({f:.6f}) translate(-512 -512)">'
paper, markup, defs = glyph(S["big"], 1.0)
write("layers/1-paper.svg", HEAD + (f"<defs>{defs}</defs>" if defs else "") + T + "".join(paper) + "</g></svg>\n")
write("layers/2-markup.svg", HEAD + T + "".join(markup) + "</g></svg>\n")
print("ok", OUT)
