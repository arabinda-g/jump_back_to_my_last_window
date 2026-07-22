#!/usr/bin/env python3
"""Generate the JumpBack app icon (.iconset) and menu-bar template images.

Design: a modern macOS "squircle" with an indigo->violet gradient and a bold,
rounded U-turn "jump back" arrow — the same idea as the app's SF Symbol, crafted.

Outputs (into --out dir):
  iconset/icon_{16,32,128,256,512}{,@2x}.png   -> for iconutil
  menubar.png, menubar@2x.png                  -> monochrome template glyph
"""
import argparse
import math
import os
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

def superellipse(cx, cy, rx, ry, n=5.0, steps=720):
    """Apple-style continuous-corner squircle as a polygon of points."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + rx * math.copysign(abs(ct) ** (2 / n), ct)
        y = cy + ry * math.copysign(abs(st) ** (2 / n), st)
        pts.append((x, y))
    return pts


def lerp(a, b, t):
    return a + (b - a) * t


def vgradient(size, top, bottom):
    """Vertical gradient image, with a subtle diagonal light sheen."""
    w = h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        r = int(lerp(top[0], bottom[0], t))
        g = int(lerp(top[1], bottom[1], t))
        b = int(lerp(top[2], bottom[2], t))
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def uturn_arrow_path(size):
    """Describe a bold circular 'jump back' arrow.

    A thick arc sweeps counter-clockwise most of the way round a circle and ends
    in a broad arrowhead — the universal 'go back / return' mark, here pointing
    back toward the start, reading as 'jump back to where you were'.
    """
    return {
        "cx": size * 0.500,
        "cy": size * 0.520,
        "r": size * 0.255,
        "stroke_w": size * 0.120,
        # Gap at the top-right; arc runs counter-clockwise down and around.
        "a_start": math.radians(-58),   # upper-right (open end / tail)
        "a_end": math.radians(212),      # upper-left (arrowhead)
        "head": size * 0.115,            # arrowhead half-length
        "wing": size * 0.135,            # arrowhead half-width
    }


def _arc_pts(cx, cy, rad, a0, a1, steps):
    return [(cx + rad * math.cos(lerp(a0, a1, i / steps)),
             cy + rad * math.sin(lerp(a0, a1, i / steps))) for i in range(steps + 1)]


def draw_arrow(draw, p, color):
    """Draw the arrow as a smooth filled band + round caps + arrowhead."""
    cx, cy, r, sw = p["cx"], p["cy"], p["r"], p["stroke_w"]
    a0, a1 = p["a_start"], p["a_end"]
    ro, ri = r + sw / 2, r - sw / 2
    steps = 400

    # Filled annulus segment: outer arc forward, inner arc back.
    band = _arc_pts(cx, cy, ro, a0, a1, steps) + _arc_pts(cx, cy, ri, a1, a0, steps)
    draw.polygon(band, fill=color)

    # Round the tail cap.
    tx, ty = cx + r * math.cos(a0), cy + r * math.sin(a0)
    cap = sw / 2
    draw.ellipse([tx - cap, ty - cap, tx + cap, ty + cap], fill=color)

    # Arrowhead at the a_end, pointing along the counter-clockwise tangent.
    ex, ey = cx + r * math.cos(a1), cy + r * math.sin(a1)
    tang = a1 + math.pi / 2
    fx, fy = math.cos(tang), math.sin(tang)          # forward
    nx, ny = -math.sin(tang), math.cos(tang)         # normal
    head, wing = p["head"] * 1.9, p["wing"]
    tip = (ex + fx * head, ey + fy * head)
    left = (ex + nx * wing, ey + ny * wing)
    right = (ex - nx * wing, ey - ny * wing)
    draw.polygon([tip, left, right], fill=color)


# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

# Modern indigo -> violet gradient (Apple-ish vivid).
GRAD_TOP = (99, 102, 241)     # indigo-500
GRAD_BOTTOM = (139, 92, 246)  # violet-500


def render_app_icon(px):
    """Render the full color app icon at `px` pixels (supersampled internally)."""
    ss = 4 if px <= 256 else 2
    S = px * ss
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Icon art fills the standard macOS safe area (~ 82% of the tile).
    pad = S * 0.086
    inner = S - 2 * pad
    cx = cy = S / 2
    rx = ry = inner / 2

    # Squircle mask.
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(superellipse(cx, cy, rx, ry), fill=255)

    # Gradient body.
    grad = vgradient(S, GRAD_TOP, GRAD_BOTTOM).convert("RGBA")

    # Soft top highlight sheen for depth.
    sheen = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([cx - rx * 1.1, cy - ry * 2.05, cx + rx * 1.1, cy + ry * 0.15], fill=70)
    sheen = sheen.filter(ImageFilter.GaussianBlur(S * 0.05))
    white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    grad = Image.composite(white, grad, sheen)

    canvas.paste(grad, (0, 0), mask)

    # Inner top edge light + bottom shade for a subtle bevel.
    bevel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bevel)
    ring = superellipse(cx, cy, rx, ry)
    bd.line(ring + [ring[0]], fill=(255, 255, 255, 60), width=max(1, int(S * 0.006)))
    bevel_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bevel_masked.paste(bevel, (0, 0), mask)
    canvas = Image.alpha_composite(canvas, bevel_masked)

    # Arrow: drop shadow then white glyph.
    p = uturn_arrow_path(S)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    off = S * 0.012
    ps = dict(p, cx=p["cx"] + off, cy=p["cy"] + off)
    draw_arrow(ImageDraw.Draw(shadow), ps, (28, 18, 66, 160))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.014))
    canvas = Image.alpha_composite(canvas, shadow)

    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_arrow(ImageDraw.Draw(glyph), p, (255, 255, 255, 255))
    canvas = Image.alpha_composite(canvas, glyph)

    return canvas.resize((px, px), Image.LANCZOS)


def render_menubar(px, color=(0, 0, 0, 255)):
    """Monochrome template glyph (arrow only) for the status bar."""
    ss = 8
    S = px * ss
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    p = uturn_arrow_path(S)
    # Slim the stroke a touch for legibility at menu-bar sizes.
    p["stroke_w"] = S * 0.105
    draw_arrow(ImageDraw.Draw(canvas), p, color)
    return canvas.resize((px, px), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = args.out
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    cache = {}
    for name, px in specs:
        if px not in cache:
            cache[px] = render_app_icon(px)
        cache[px].save(os.path.join(iconset, name))
        print("wrote", name)

    # Large preview.
    cache.get(1024, render_app_icon(1024)).save(os.path.join(out, "AppIcon-preview.png"))

    # Menu bar template glyph (18pt @1x/@2x/@3x).
    render_menubar(18).save(os.path.join(out, "menubarTemplate.png"))
    render_menubar(36).save(os.path.join(out, "menubarTemplate@2x.png"))
    print("done")


if __name__ == "__main__":
    main()
