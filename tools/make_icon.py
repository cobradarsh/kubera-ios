"""Draws Kubera's app icon and splash emblem: a gold lotus in a coin ring on true black.

python tools/make_icon.py            -> App/Assets.xcassets/{AppIcon.appiconset,Emblem.imageset}/... and shots/icon-preview.png
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "App", "Assets.xcassets")

GOLD_LIGHT = (250, 226, 140)
GOLD = (212, 175, 55)
GOLD_DEEP = (140, 104, 24)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top, bottom):
    """Vertical gradient image."""
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        g.putpixel((0, y), lerp(top, bottom, y / max(1, h - 1)))
    return g.resize((w, h))


def bezier(p0, p1, p2, p3, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t ** 2
        d = t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def petal(cx, cy, angle_deg, length, width):
    """An almond petal from (cx, cy) pointing at angle (0 = up), as a polygon."""
    a = math.radians(angle_deg)
    ux, uy = math.sin(a), -math.cos(a)          # along the petal
    px, py = -uy, ux                             # across
    tip = (cx + ux * length, cy + uy * length)
    def at(f, side):
        return (cx + ux * length * f + px * width * side, cy + uy * length * f + py * width * side)
    right = bezier((cx, cy), at(0.18, 0.95), at(0.72, 0.62), tip)
    left = bezier(tip, at(0.72, -0.62), at(0.18, -0.95), (cx, cy))
    return right + left[1:]


def draw_lotus(size, transparent=False, ring=True):
    S = size * 2  # supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0 if transparent else 255))
    if not transparent:
        glow = Image.new("L", (S, S), 0)
        gd = ImageDraw.Draw(glow)
        for r in range(int(S * 0.55), 0, -6):
            v = int(70 * (1 - r / (S * 0.55)) ** 1.6)
            gd.ellipse((S / 2 - r, S * 0.52 - r, S / 2 + r, S * 0.52 + r), fill=v)
        tint = Image.new("RGBA", (S, S), (60, 44, 8, 255))
        img = Image.composite(tint, img, glow)

    d = ImageDraw.Draw(img)
    cx, cy = S / 2, S * 0.60

    if ring:
        for rr, wdt, col in [(0.435, 0.014, GOLD), (0.405, 0.005, GOLD_DEEP)]:
            r = S * rr
            d.ellipse((S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r), outline=col, width=int(S * wdt))

    layers = [
        # (angle, length, width, top colour, bottom colour)
        [(-78, 0.27, 0.075, GOLD, GOLD_DEEP), (78, 0.27, 0.075, GOLD, GOLD_DEEP)],
        [(-48, 0.31, 0.085, GOLD_LIGHT, GOLD_DEEP), (48, 0.31, 0.085, GOLD_LIGHT, GOLD_DEEP)],
        [(-22, 0.33, 0.09, GOLD_LIGHT, GOLD), (22, 0.33, 0.09, GOLD_LIGHT, GOLD)],
        [(0, 0.37, 0.1, (255, 240, 180), GOLD)],
    ]
    for layer in layers:
        for ang, ln, wd, c1, c2 in layer:
            poly = petal(cx, cy, ang, S * ln, S * wd)
            mask = Image.new("L", (S, S), 0)
            ImageDraw.Draw(mask).polygon(poly, fill=255)
            xs = [p[0] for p in poly]
            ys = [p[1] for p in poly]
            box = (int(min(xs)), int(min(ys)), int(max(xs)) + 1, int(max(ys)) + 1)
            grad = gradient((box[2] - box[0], box[3] - box[1]), c1, c2)
            layer_img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            layer_img.paste(grad, box)
            img = Image.composite(layer_img, img, mask)
            d = ImageDraw.Draw(img)
            d.line(poly + [poly[0]], fill=(70, 50, 8, 255), width=max(2, int(S * 0.004)))
            # centre vein
            a = math.radians(ang)
            d.line([(cx, cy), (cx + math.sin(a) * S * ln * 0.78, cy - math.cos(a) * S * ln * 0.78)], fill=(120, 90, 20, 255), width=max(1, int(S * 0.0025)))

    # Water line under the lotus.
    base = bezier((cx - S * 0.30, cy + S * 0.02), (cx - S * 0.12, cy + S * 0.09), (cx + S * 0.12, cy + S * 0.09), (cx + S * 0.30, cy + S * 0.02))
    d.line(base, fill=GOLD + (255,), width=int(S * 0.012))
    # Bindu with rays above the centre petal.
    bx, by = cx, cy - S * 0.42
    for i in range(12):
        a = math.radians(i * 30)
        r0, r1 = S * 0.04, S * (0.065 if i % 2 == 0 else 0.055)
        d.line([(bx + math.cos(a) * r0, by + math.sin(a) * r0), (bx + math.cos(a) * r1, by + math.sin(a) * r1)], fill=GOLD + (255,), width=max(2, int(S * 0.006)))
    r = S * 0.028
    d.ellipse((bx - r, by - r, bx + r, by + r), fill=(255, 236, 170, 255))

    out = img.resize((size, size), Image.LANCZOS)
    if not transparent:
        out = out.convert("RGB")
    return out


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main():
    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    emblem_dir = os.path.join(ASSETS, "Emblem.imageset")
    launch_dir = os.path.join(ASSETS, "LaunchBackground.colorset")
    for p in (icon_dir, emblem_dir, launch_dir):
        os.makedirs(p, exist_ok=True)
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    icon = draw_lotus(1024)
    icon.save(os.path.join(icon_dir, "AppIcon-1024.png"))
    write_json(os.path.join(icon_dir, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })

    emblem = draw_lotus(600, transparent=True, ring=False)
    emblem.save(os.path.join(emblem_dir, "Emblem.png"))
    write_json(os.path.join(emblem_dir, "Contents.json"), {
        "images": [{"filename": "Emblem.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    })

    write_json(os.path.join(launch_dir, "Contents.json"), {
        "colors": [{"color": {"color-space": "srgb", "components": {"alpha": "1.000", "blue": "0.000", "green": "0.000", "red": "0.000"}}, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    })

    shots = os.path.join(ROOT, "shots")
    os.makedirs(shots, exist_ok=True)
    preview = Image.new("RGB", (1024 + 600 + 60, 1024), (20, 20, 20))
    preview.paste(icon, (0, 0))
    bg = Image.new("RGBA", (600, 600), (0, 0, 0, 255))
    bg.alpha_composite(emblem)
    preview.paste(bg.convert("RGB"), (1084, 212))
    preview.save(os.path.join(shots, "icon-preview.png"))
    print("icon, emblem and preview written")


if __name__ == "__main__":
    main()
