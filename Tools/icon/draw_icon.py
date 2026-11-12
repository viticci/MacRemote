#!/usr/bin/env python3
"""Draws Resources/AppIcon.icon, the Icon Composer document for MacRemote's icon.

The picture: your Mac, lit, at the far end of a glass tunnel. The screen is the
light source; four rings recede toward it from violet night to cyan.

Every size and colour is a number in this file. Running it rewrites the whole
document, so it overwrites edits made by hand in Icon Composer. Afterwards run
Tools/icon/build_assets.py to rebuild the files the app ships.

Needs Pillow (for the three soft light layers).
"""
import io
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
DOCUMENT = ROOT / "Resources" / "AppIcon.icon"
CANVAS = 1024
CX = 512
MAC_CY = 546  # centre of the display, and the point every ring is centred on
DISPLAY = (384, 258, 58)  # width, height, corner radius
STAND = (64, 58, 224, 32, 26)  # neck width, neck height, foot width, foot height, join radius
DOWN = ((0.5, 0.0), (0.5, 1.0))  # gradients run top to bottom of each shape

# Rings, outermost first. Each has a top and bottom colour per appearance;
# "tint" is the gray pair the system recolours in the Tinted appearances.
RINGS = [
    dict(half=444, light=((0.26, 0.21, 0.98), (0.12, 0.08, 0.62)), dark=((0.17, 0.13, 0.72), (0.07, 0.05, 0.40)), tint=(0.13, 0.07)),
    dict(half=364, light=((0.15, 0.37, 1.00), (0.07, 0.19, 0.84)), dark=((0.11, 0.27, 0.88), (0.05, 0.13, 0.62)), tint=(0.20, 0.12)),
    dict(half=305, light=((0.10, 0.57, 1.00), (0.04, 0.33, 0.94)), dark=((0.08, 0.46, 0.96), (0.03, 0.25, 0.80)), tint=(0.29, 0.18)),
    dict(half=260, light=((0.12, 0.78, 1.00), (0.02, 0.50, 0.98)), dark=((0.10, 0.70, 1.00), (0.02, 0.42, 0.92)), tint=(0.40, 0.26)),
]


# Colours and fills, in Icon Composer's notation.

def p3(r, g, b, a=1.0):
    return f"display-p3:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def gray(v, a=1.0):
    return f"gray:{v:.5f},{a:.5f}"


WHITE = "srgb:1.00000,1.00000,1.00000,1.00000"


def solid(color):
    return {"solid": color}


def gradient(top, bottom, start=DOWN[0], stop=DOWN[1]):
    """A two-colour gradient. Start and stop are fractions of the shape's own bounds."""
    return {
        "linear-gradient": [top, bottom],
        "orientation": {"start": {"x": start[0], "y": start[1]}, "stop": {"x": stop[0], "y": stop[1]}},
    }


def by_appearance(default, dark=None, tinted=None):
    """A value that changes with the system appearance."""
    out = [{"value": default}]
    if dark is not None:
        out.append({"appearance": "dark", "value": dark})
    if tinted is not None:
        out.append({"appearance": "tinted", "value": tinted})
    return out


# Shapes, as SVG path data on the 1024 canvas.

def rounded_rect(x0, y0, x1, y1, r):
    """Rounded rectangle with continuous (squircle) corners, like Apple's shapes."""
    w, h = x1 - x0, y1 - y0
    r = min(r, w / 2 / 1.52866483, h / 2 / 1.52866483)
    a, b, c, d, e, f, g = 1.52866483, 1.08849296, 0.86840694, 0.63149399, 0.07491100, 0.37282392, 0.16905899

    def P(x, y):
        return f"{x0 + x:.2f},{y0 + y:.2f}"

    return " ".join([
        f"M{P(a*r, 0)}", f"L{P(w - a*r, 0)}",
        f"C{P(w - b*r, 0)} {P(w - c*r, 0)} {P(w - d*r, e*r)}",
        f"C{P(w - f*r, g*r)} {P(w - g*r, f*r)} {P(w - e*r, d*r)}",
        f"C{P(w, c*r)} {P(w, b*r)} {P(w, a*r)}",
        f"L{P(w, h - a*r)}",
        f"C{P(w, h - b*r)} {P(w, h - c*r)} {P(w - e*r, h - d*r)}",
        f"C{P(w - g*r, h - f*r)} {P(w - f*r, h - g*r)} {P(w - d*r, h - e*r)}",
        f"C{P(w - c*r, h)} {P(w - b*r, h)} {P(w - a*r, h)}",
        f"L{P(a*r, h)}",
        f"C{P(b*r, h)} {P(c*r, h)} {P(d*r, h - e*r)}",
        f"C{P(f*r, h - g*r)} {P(g*r, h - f*r)} {P(e*r, h - d*r)}",
        f"C{P(0, h - c*r)} {P(0, h - b*r)} {P(0, h - a*r)}",
        f"L{P(0, a*r)}",
        f"C{P(0, b*r)} {P(0, c*r)} {P(e*r, d*r)}",
        f"C{P(g*r, f*r)} {P(f*r, g*r)} {P(d*r, e*r)}",
        f"C{P(c*r, 0)} {P(b*r, 0)} {P(a*r, 0)}", "Z",
    ])


def tunnel_ring(half):
    """One ring of the tunnel: a semicircle centred on the Mac, legs running off the floor."""
    return (f"M{CX - half:.2f},1100.00 L{CX - half:.2f},{MAC_CY:.2f} "
            f"A{half:.2f},{half:.2f} 0 0 1 {CX + half:.2f},{MAC_CY:.2f} L{CX + half:.2f},1100.00 Z")


def mac_stand(top, neck, neck_h, foot, foot_h, q):
    """Neck and foot as one outline, with liquid joins."""
    fy0 = top + neck_h
    fy1 = fy0 + foot_h
    fr = foot_h / 2
    return (
        f"M{CX - neck / 2},{top - 10} L{CX + neck / 2},{top - 10} L{CX + neck / 2},{fy0 - q} "
        f"A{q},{q} 0 0 0 {CX + neck / 2 + q},{fy0} L{CX + foot / 2 - fr},{fy0} "
        f"A{fr},{fr} 0 0 1 {CX + foot / 2 - fr},{fy1} L{CX - foot / 2 + fr},{fy1} "
        f"A{fr},{fr} 0 0 1 {CX - foot / 2 + fr},{fy0} L{CX - neck / 2 - q},{fy0} "
        f"A{q},{q} 0 0 0 {CX - neck / 2},{fy0 - q} Z"
    )


def pointer(x, y, s):
    """The arrow pointer, tip at (x, y)."""
    pts = [(0, 0), (0, 0.86), (0.235, 0.655), (0.40, 1.0), (0.545, 0.93), (0.385, 0.60), (0.69, 0.60)]
    return "M" + " L".join(f"{x + px * s:.2f},{y + py * s:.2f}" for px, py in pts) + " Z"


def svg(path):
    """A full-canvas SVG holding one white shape; the document supplies the colour."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}"><path fill-rule="evenodd" d="{path}" fill="#ffffff"/></svg>')


# Soft lights. Icon Composer has no blur, so these three layers are PNGs with glass off.

def soft_png(draw, color, blur):
    """Draws a mask, blurs it, and returns it as a coloured transparent PNG."""
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw(ImageDraw.Draw(mask), mask)
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", (CANVAS, CANVAS), color + (0,))
    out.putalpha(mask)
    buf = io.BytesIO()
    out.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def halo_png(cy, rx, ry, color, strength, blur):
    """Light shaped like the display, spilling past its edges."""
    def draw(d, _):
        d.rounded_rectangle((CX - rx, cy - ry, CX + rx, cy + ry), radius=min(rx, ry) * 0.5, fill=int(255 * strength))
    return soft_png(draw, color, blur)


def floor_light_png(y_top, half_top, half_bottom, color, strength, blur):
    """Light the screen throws along the tunnel floor, widening toward the viewer."""
    def draw(_, mask):
        px = mask.load()
        for y in range(int(y_top), CANVAS):
            t = (y - y_top) / (CANVAS - y_top)
            half = half_top + (half_bottom - half_top) * t
            a = int(255 * strength * (1 - t) ** 1.5)
            for x in range(int(CX - half), int(CX + half)):
                px[x, y] = a
    return soft_png(draw, color, blur)


def document():
    """Returns the icon as (icon.json contents, {asset file name: bytes or text})."""
    assets = {}

    def layer(name, data, ext="svg", **props):
        assets[f"{name}.{ext}"] = data
        return {"image-name": f"{name}.{ext}", "name": name, **props}

    def group(name, layers, **props):
        return {"name": name, "hidden": False, "layers": layers, **props}

    w, h, r = DISPLAY
    top = MAC_CY - h / 2
    screen = gradient(WHITE, p3(0.80, 1.0, 0.98))
    metal = gradient(p3(0.72, 0.94, 1.0), p3(0.90, 1.0, 1.0))

    def ring(i):
        spec = RINGS[i]
        return layer(f"ring-{i + 1}", svg(tunnel_ring(spec["half"])), glass=True, **{
            "fill-specializations": by_appearance(
                gradient(p3(*spec["light"][0]), p3(*spec["light"][1])),
                dark=gradient(p3(*spec["dark"][0]), p3(*spec["dark"][1])),
                tinted=gradient(gray(spec["tint"][0]), gray(spec["tint"][1])))})

    ring_glass = dict(specular="outside", shadow={"kind": "neutral", "opacity": 0.5}, lighting="individual",
                      translucency={"enabled": True, "value": 0.1})
    light = {"glass": False, "blend-mode": "plus-lighter", "opacity-specializations": by_appearance(1, tinted=0.45)}

    # Groups and layers are listed front to back. Icon Composer allows four groups.
    groups = [
        group("Pointer", [
            layer("pointer", svg(pointer(CX + 6, MAC_CY - 46, 136)), glass=True, **{
                "fill-specializations": by_appearance(
                    gradient(p3(0.12, 0.40, 1.0), p3(0.07, 0.16, 0.78)), tinted=solid(gray(0.16)))}),
        ], specular="inside", shadow={"kind": "layer-color", "opacity": 0.5}, lighting="individual",
            translucency={"enabled": False, "value": 0}),
        group("Mac", [
            layer("display", svg(rounded_rect(CX - w / 2, top, CX + w / 2, top + h, r)), glass=True, **{
                "fill-specializations": by_appearance(screen, dark=screen, tinted=solid(WHITE))}),
            layer("stand", svg(mac_stand(top + h, *STAND)), glass=True, **{
                "fill-specializations": by_appearance(metal, dark=metal, tinted=solid(gray(0.86)))}),
        ], specular="outside", shadow={"kind": "neutral", "opacity": 0.5}, lighting="individual",
            translucency={"enabled": False, "value": 0}),
        group("Far End", [
            layer("halo", halo_png(MAC_CY, w / 2 + 2, h / 2 + 2, (200, 255, 250), 0.82, 30), ext="png", **light),
            layer("ambient", halo_png(MAC_CY + 10, 240, 180, (70, 190, 255), 0.42, 130), ext="png", **light),
            layer("floor-light", floor_light_png(top + h + STAND[1] + STAND[3] + 10, 88, 240, (170, 250, 255), 0.36, 20),
                  ext="png", **light),
            ring(3), ring(2),
        ], **ring_glass),
        group("Tunnel", [ring(1), ring(0)], **ring_glass),
    ]

    background = gradient(p3(0.15, 0.09, 0.56), p3(0.06, 0.03, 0.30))
    background_dark = gradient(p3(0.075, 0.06, 0.20), p3(0.02, 0.015, 0.07))
    icon = {
        "features": ["specular-location"],
        # Apple's own documents nest the background's variants inside "fill".
        "fill": {**background, "fill-specializations": by_appearance(background, dark=background_dark)},
        "groups": groups,
        "supported-platforms": {"squares": "shared", "circles": ["watchOS"]},
    }
    return icon, assets


def main():
    icon, assets = document()
    shutil.rmtree(DOCUMENT, ignore_errors=True)
    (DOCUMENT / "Assets").mkdir(parents=True)
    (DOCUMENT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
    for name, data in assets.items():
        path = DOCUMENT / "Assets" / name
        if isinstance(data, bytes):
            path.write_bytes(data)
        else:
            path.write_text(data)
    print(f"Wrote {DOCUMENT.relative_to(ROOT)}. Now run Tools/icon/build_assets.py.")


if __name__ == "__main__":
    main()
