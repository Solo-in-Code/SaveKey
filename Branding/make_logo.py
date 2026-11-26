# Copyright (C) 2026 the SaveKey project. All rights reserved.
# SPDX-License-Identifier: LicenseRef-SaveKey-Logo
# The SaveKey logo, and this script that draws it, are NOT covered by the GNU AGPL.
# See Branding/README.md for what you may do with them.
"""Draws the SaveKey logo: a fingerprint with a keyhole in the centre.

  ridges and keyhole  #fffff0 (ivory)
  two half-lines      #f15a30 (orange): left half of the middle ridge, right half of the outermost ridge
  background          #283438

Outputs:
  Branding/savekey-icon.svg                          icon with background (vector master)
  Branding/savekey-mark.svg                          fingerprint + keyhole only, transparent (for dark backgrounds)
  App/Assets.xcassets/AppIcon.appiconset/AppIcon.png  1024x1024, opaque (App Store icon)
  App/Assets.xcassets/Logo.imageset/Logo.png          512x512 rounded icon for use inside the app

Requires rsvg-convert (librsvg) to render the PNGs. Usage: python3 Branding/make_logo.py
"""
import math
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

IVORY = "#fffff0"
ORANGE = "#f15a30"
BACKGROUND = "#283438"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG_NOTICE = ("<!-- SaveKey logo. Copyright (C) 2026 the SaveKey project. All rights reserved. "
              "Not covered by the GNU AGPL; see Branding/README.md. -->")

STROKE = 28
CX, CY = 512, 595
GAP_PX = 26  # gap between the orange and ivory halves of one ridge

# Ridges as elliptical arcs open at the bottom: (rx, ry, start angle, end angle, breaks), angles in degrees.
RIDGES = [
    (104, 146, 212, -30, [(148, 160)]),
    (164, 218, 220, -38, [(34, 44)]),
    (224, 290, 222, -36, [(122, 130)]),
    (284, 360, 196, -14, [(64, 72)]),
]
ORANGE_HALVES = {1: "left", 3: "right"}  # middle ridge: left half; outermost ridge: right half

# Keyhole, centred inside the innermost ridge.
HEAD_R, HEAD_Y = 38, 533
STEM_TOP_HALF, STEM_BOTTOM_HALF, STEM_BOTTOM_Y = 15, 33, 668


def arc_points(rx, ry, a0, a1, step=1.0):
    n = max(2, int(abs(a1 - a0) / step))
    return [(CX + rx * math.cos(math.radians(a0 + (a1 - a0) * k / n)),
             CY - ry * math.sin(math.radians(a0 + (a1 - a0) * k / n))) for k in range(n + 1)]


def ridge_segments():
    segments = []
    for i, (rx, ry, a0, a1, breaks) in enumerate(RIDGES):
        side = ORANGE_HALVES.get(i)
        if side:
            # Keep each orange half in one piece: move breaks to the ivory side.
            breaks = [((180 - b1, 180 - b0) if ((side == "left") == (b0 > 90)) else (b0, b1)) for b0, b1 in breaks]
        cuts = [a0] + [v for b in breaks for v in (b[1], b[0])] + [a1]
        pieces = [(cuts[k], cuts[k + 1]) for k in range(0, len(cuts), 2)]
        gap = math.degrees(GAP_PX / ((rx + ry) / 2))
        for p0, p1 in pieces:
            if side is None:
                segments.append((arc_points(rx, ry, p0, p1), IVORY))
            elif p0 > 90 > p1:
                segments.append((arc_points(rx, ry, p0, 90 + gap / 2), ORANGE if side == "left" else IVORY))
                segments.append((arc_points(rx, ry, 90 - gap / 2, p1), ORANGE if side == "right" else IVORY))
            else:
                is_left = p1 >= 90
                segments.append((arc_points(rx, ry, p0, p1), ORANGE if (side == "left") == is_left else IVORY))
    return segments


def mark_elements():
    """The fingerprint and the keyhole as SVG elements, in the coordinates of the 1024 x 1024 icon."""
    out = []
    for pts, colour in ridge_segments():
        d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts)
        out.append(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{STROKE}" '
                   f'stroke-linecap="round" stroke-linejoin="round"/>')
    stem = [(CX - STEM_TOP_HALF, HEAD_Y), (CX + STEM_TOP_HALF, HEAD_Y),
            (CX + STEM_BOTTOM_HALF, STEM_BOTTOM_Y), (CX - STEM_BOTTOM_HALF, STEM_BOTTOM_Y)]
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in stem) + " Z"
    out.append(f'<circle cx="{CX}" cy="{HEAD_Y}" r="{HEAD_R}" fill="{IVORY}"/>')
    out.append(f'<path d="{d}" fill="{IVORY}" stroke="{IVORY}" stroke-width="12" stroke-linejoin="round"/>')
    return out


def mark_bounds():
    """The box the fingerprint covers, its round line ends included: (left, top, right, bottom) in the icon's
    coordinates. The keyhole lies inside it."""
    points = [p for pts, _ in ridge_segments() for p in pts]
    half = STROKE / 2
    return (min(x for x, _ in points) - half, min(y for _, y in points) - half,
            max(x for x, _ in points) + half, max(y for _, y in points) + half)


def svg(background):
    out = [SVG_NOTICE,
           '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">']
    if background:
        out.append(f'<rect width="1024" height="1024" fill="{BACKGROUND}"/>')
    out += mark_elements()
    out.append("</svg>")
    return "\n".join(out) + "\n"


def render(svg_path, size):
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        out = tmp.name
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", out], check=True)
    img = Image.open(out).convert("RGBA")
    os.unlink(out)
    return img


def main():
    branding = os.path.join(ROOT, "Branding")
    os.makedirs(branding, exist_ok=True)
    icon_svg = os.path.join(branding, "savekey-icon.svg")
    with open(icon_svg, "w") as f:
        f.write(svg(background=True))
    with open(os.path.join(branding, "savekey-mark.svg"), "w") as f:
        f.write(svg(background=False))

    icon = render(icon_svg, 1024).convert("RGB")
    icon.save(os.path.join(ROOT, "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))

    # In-app logo: the icon with rounded corners, so it works on light and dark screens.
    mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 4095, 4095), radius=int(4096 * 0.225), fill=255)
    logo = icon.convert("RGBA")
    logo.putalpha(mask.resize((1024, 1024), Image.LANCZOS))
    os.makedirs(os.path.join(ROOT, "App/Assets.xcassets/Logo.imageset"), exist_ok=True)
    logo.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, "App/Assets.xcassets/Logo.imageset/Logo.png"))


if __name__ == "__main__":
    main()
