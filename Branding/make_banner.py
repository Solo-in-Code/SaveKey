#!/usr/bin/env python3
# Copyright (C) 2026 the SaveKey project. All rights reserved.
# SPDX-License-Identifier: LicenseRef-SaveKey-Logo
# The SaveKey logo, the SaveKey lettering and this script that draws them are NOT covered by the GNU AGPL.
# See Branding/README.md for what you may do with them.
"""Draws SaveKey's banners: the logo (make_logo.py) next to the word SaveKey in IBM Plex Sans Bold, "Save" in ivory
(#fffff0) and "Key" in orange (#f15a30), on the logo's slate (#283438). Where a banner has a line of text under the
logo, it is in IBM Plex Mono.

The letters are written as outlines, not as text: GitHub shows a README's SVG as an image, and an image cannot load
a font, so live text would fall back to whatever font the viewer has.

Writes, in Branding/:
  savekey-banner.svg                   the banner at the top of the README
  savekey-social-preview.svg and .png  GitHub's social preview, 1280 x 640 (Settings > General > Social preview)
With --kit FOLDER it also writes every logo and banner file, as SVG and PNG, into FOLDER/Logo and FOLDER/Banners.

Needs: pip install fonttools uharfbuzz pillow; the fonts IBM Plex Sans and IBM Plex Mono (SIL Open Font License,
https://github.com/IBM/plex; on a Mac, install them with Font Book; on Debian or Ubuntu: sudo apt install
fonts-ibm-plex); rsvg-convert for the PNG files (brew install librsvg, or sudo apt install librsvg2-bin).
Run:   python3 Branding/make_banner.py [--fonts FOLDER] [--kit FOLDER]
"""
import argparse
import os
import shutil
import subprocess
import sys
import zlib

sys.dont_write_bytecode = True  # no __pycache__ folder in Branding/
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_logo as logo  # noqa: E402  (the fingerprint, the keyhole and the colours)

try:
    import uharfbuzz as hb
    from fontTools.pens.boundsPen import BoundsPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("make_banner.py needs fonttools and uharfbuzz: pip install fonttools uharfbuzz")

IVORY, ORANGE, SLATE = logo.IVORY, logo.ORANGE, logo.BACKGROUND
BRANDING = os.path.dirname(os.path.abspath(__file__))
SANS, MONO = "IBMPlexSans-Bold", "IBMPlexMono-Regular"
FONT_FOLDERS = ["/usr/share/fonts/truetype/ibm-plex", "/usr/share/fonts/opentype/ibm-plex",
                os.path.expanduser("~/Library/Fonts"), "/Library/Fonts", os.path.expanduser("~/.local/share/fonts"),
                "/usr/share/fonts"]
TAGLINE = "KeePass password manager for iPhone"

# Proportions, as shares of the fingerprint's height.
WORD_SIZE = 0.58     # the word's font size
WORD_GAP = 0.15      # from the fingerprint to the word
CARD_MARGIN = 0.18   # the README banner's margin, the same all round
CARD_RADIUS = 0.147  # the README banner's rounded corners
LINE_SIZE = 0.136    # the font size of the line under the logo
LINE_GAP = 0.2       # from the bottom of the fingerprint to the top of the capitals in that line

RIGHTS = ("SaveKey logo. Copyright (C) 2026 the SaveKey project. All rights reserved. Not covered by the GNU AGPL; "
          "see Branding/README.md at https://github.com/Solo-in-Code/SaveKey")


def num(x, places=2):
    return f"{x:.{places}f}".rstrip("0").rstrip(".")


class Lettering:
    """One font, used to write text as outlines with the font's own spacing (kerning included)."""

    def __init__(self, path):
        tt = TTFont(path)
        self.glyphs, self.order, self.upem = tt.getGlyphSet(), tt.getGlyphOrder(), tt["head"].unitsPerEm
        self.cap_height = tt["OS/2"].sCapHeight / self.upem  # as a share of the font size
        self.font = hb.Font(hb.Face(hb.Blob.from_file_path(path)))

    def write(self, parts, size):
        """Writes `parts`, a list of (text, colour), as one line at `size` px, starting at x = 0 on the baseline
        (y = 0). Returns (svg, box), where box is (left, top, right, bottom) of the letters themselves, y down."""
        text = "".join(t for t, _ in parts)
        colour_of = [colour for t, colour in parts for _ in t]
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.font, buf, {"kern": True, "liga": True})
        scale = size / self.upem
        paths, pen_x, box = {}, 0, None
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            name = self.order[info.codepoint]
            dx, dy = (pen_x + pos.x_offset) * scale, -pos.y_offset * scale
            pen = SVGPathPen(self.glyphs, ntos=num)
            self.glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, dx, dy)))
            paths.setdefault(colour_of[info.cluster], []).append(pen.getCommands())
            bounds = BoundsPen(self.glyphs)
            self.glyphs[name].draw(bounds)
            if bounds.bounds:
                x0, y0, x1, y1 = bounds.bounds
                edges = (dx + x0 * scale, dy - y1 * scale, dx + x1 * scale, dy - y0 * scale)
                box = edges if box is None else (min(box[0], edges[0]), min(box[1], edges[1]),
                                                 max(box[2], edges[2]), max(box[3], edges[3]))
            pen_x += pos.x_advance
        svg = "\n".join(f'<path d="{"".join(d)}" fill="{colour}"/>' for colour, d in paths.items())
        return svg, box


def mark(height):
    """The fingerprint with its keyhole, `height` px tall, with its top left corner at (0, 0): (svg, width, scale)."""
    x0, y0, x1, y1 = logo.mark_bounds()
    s = height / (y1 - y0)
    svg = (f'<g transform="scale({num(s, 5)}) translate({num(-x0)} {num(-y0)})">\n'
           + "\n".join(logo.mark_elements()) + "\n</g>")
    return svg, (x1 - x0) * s, s


def lockup(sans, height):
    """The fingerprint and the word side by side, the fingerprint `height` px tall: (svg, width, height), with the
    origin at the top left. The middle of the capitals is level with the middle of the keyhole's round head."""
    art, mark_width, s = mark(height)
    size = height * WORD_SIZE
    word, box = sans.write([("Save", IVORY), ("Key", ORANGE)], size)
    left = mark_width + height * WORD_GAP
    baseline = (logo.HEAD_Y - logo.mark_bounds()[1]) * s + sans.cap_height * size / 2
    assert baseline + box[3] <= height, "the word reaches below the fingerprint"
    svg = f'{art}\n<g transform="translate({num(left - box[0])} {num(baseline)})">\n{word}\n</g>'
    return svg, left + box[2] - box[0], height


def wordmark(sans, size):
    """The word alone at `size` px, cropped to its letters: (svg, width, height)."""
    word, box = sans.write([("Save", IVORY), ("Key", ORANGE)], size)
    return (f'<g transform="translate({num(-box[0])} {num(-box[1])})">\n{word}\n</g>',
            box[2] - box[0], box[3] - box[1])


def document(width, height, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{num(width)}" height="{num(height)}" '
            f'viewBox="0 0 {num(width)} {num(height)}" role="img" aria-label="SaveKey">\n'
            f'{logo.SVG_NOTICE}\n<title>SaveKey</title>\n{body}\n</svg>\n')


def readme_banner(sans, height=300):
    """The banner at the top of the README: the lockup on a rounded slate card, so that it shows the same on GitHub's
    light and dark pages."""
    art, w, h = lockup(sans, height)
    margin = height * CARD_MARGIN
    width, full_height = w + 2 * margin, h + 2 * margin
    return document(width, full_height,
                    f'<rect width="{num(width)}" height="{num(full_height)}" rx="{num(height * CARD_RADIUS)}" '
                    f'fill="{SLATE}"/>\n<g transform="translate({num(margin)} {num(margin)})">\n{art}\n</g>')


def banner(sans, mono, width, height, mark_height, line=TAGLINE):
    """A slate banner `width` x `height` px: the lockup in the middle, the fingerprint `mark_height` px tall, with
    `line` centred under it in IBM Plex Mono."""
    art, w, h = lockup(sans, mark_height)
    size = mark_height * LINE_SIZE
    text, box = mono.write([(line, IVORY)], size)
    gap = mark_height * LINE_GAP
    top = (height - (h + gap + mono.cap_height * size)) / 2
    return document(width, height, "\n".join([
        f'<rect width="{width}" height="{height}" fill="{SLATE}"/>',
        f'<g transform="translate({num((width - w) / 2)} {num(top)})">\n{art}\n</g>',
        f'<g transform="translate({num((width - (box[2] - box[0])) / 2 - box[0])} '
        f'{num(top + h + gap + mono.cap_height * size)})">\n{text}\n</g>']))


def rounded_icon():
    """The icon with rounded corners and transparent outside them, like the logo inside the app."""
    return document(1024, 1024, f'<rect width="1024" height="1024" rx="{num(1024 * 0.225)}" fill="{SLATE}"/>\n'
                    + "\n".join(logo.mark_elements()))


def find_font(name, folders):
    for folder in folders:
        for root, _, files in os.walk(folder):
            for ext in (".ttf", ".otf"):
                if name + ext in files:
                    return os.path.join(root, name + ext)
    return None


def add_png_copyright(path):
    """Writes the rights notice into a PNG file as its standard "Copyright" text field (a tEXt chunk after IHDR)."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", "not a PNG file"
    ihdr_end = 8 + 12 + int.from_bytes(data[8:12], "big")
    text = b"Copyright\0" + RIGHTS.encode("latin-1")
    chunk = len(text).to_bytes(4, "big") + b"tEXt" + text + zlib.crc32(b"tEXt" + text).to_bytes(4, "big")
    with open(path, "wb") as f:
        f.write(data[:ihdr_end] + chunk + data[ihdr_end:])


class Writer:
    def __init__(self, rsvg):
        self.rsvg = rsvg
        self.written = []

    def svg(self, path, text):
        with open(path, "w") as f:
            f.write(text)
        self.written.append(path)
        return path

    def png(self, svg_path, png_path, size=None, zoom=None):
        """Renders `svg_path` at its own size, at `size` (w, h) or at `zoom` times its size."""
        args = [self.rsvg]
        if size:
            args += ["-w", str(size[0]), "-h", str(size[1])]
        if zoom:
            args += ["--zoom", str(zoom)]
        subprocess.run(args + [svg_path, "-o", png_path], check=True)
        add_png_copyright(png_path)
        self.written.append(png_path)


def write_kit(out, folder, sans, mono):
    logo_dir, banner_dir = os.path.join(folder, "Logo"), os.path.join(folder, "Banners")
    os.makedirs(logo_dir, exist_ok=True)
    os.makedirs(banner_dir, exist_ok=True)

    def put(directory, name, svg, pngs):
        path = out.svg(os.path.join(directory, name + ".svg"), svg)
        for suffix, kwargs in pngs:
            out.png(path, os.path.join(directory, name + suffix + ".png"), **kwargs)

    put(logo_dir, "savekey-icon", logo.svg(True), [(f"-{s}", {"size": (s, s)}) for s in (1024, 512, 256)])
    put(logo_dir, "savekey-icon-rounded", rounded_icon(), [(f"-{s}", {"size": (s, s)}) for s in (1024, 512)])
    put(logo_dir, "savekey-mark", logo.svg(False), [("-1024", {"size": (1024, 1024)})])
    art, w, h = lockup(sans, 300)
    put(logo_dir, "savekey-logo", document(w, h, art), [("", {"zoom": 2})])
    art, w, h = wordmark(sans, 300 * WORD_SIZE)
    put(logo_dir, "savekey-wordmark", document(w, h, art), [("", {"zoom": 2})])

    put(banner_dir, "savekey-banner", readme_banner(sans), [("", {"zoom": 2})])
    put(banner_dir, "savekey-social-preview", banner(sans, mono, 1280, 640, 250), [("", {})])
    put(banner_dir, "savekey-header-1500x500", banner(sans, mono, 1500, 500, 200), [("", {})])
    put(banner_dir, "savekey-linkedin-1584x396", banner(sans, mono, 1584, 396, 160), [("", {})])


def main():
    ap = argparse.ArgumentParser(description="Draws SaveKey's banners (see the top of this file).")
    ap.add_argument("--fonts", help=f"a folder that holds {SANS} and {MONO} (.ttf or .otf)")
    ap.add_argument("--kit", metavar="FOLDER", help="also write every logo and banner file into FOLDER")
    a = ap.parse_args()
    folders = ([a.fonts] if a.fonts else []) + FONT_FOLDERS
    found = {name: find_font(name, folders) for name in (SANS, MONO)}
    missing = [name for name, path in found.items() if not path]
    if missing:
        sys.exit(f"Not found: {', '.join(missing)}. Install IBM Plex Sans and IBM Plex Mono, or give their folder "
                 "with --fonts")
    rsvg = shutil.which("rsvg-convert")
    if not rsvg:
        sys.exit("rsvg-convert was not found: brew install librsvg (Mac) or sudo apt install librsvg2-bin")
    sans, mono = Lettering(found[SANS]), Lettering(found[MONO])

    out = Writer(rsvg)
    out.svg(os.path.join(BRANDING, "savekey-banner.svg"), readme_banner(sans))
    social = out.svg(os.path.join(BRANDING, "savekey-social-preview.svg"), banner(sans, mono, 1280, 640, 250))
    out.png(social, os.path.join(BRANDING, "savekey-social-preview.png"))
    if a.kit:
        write_kit(out, a.kit, sans, mono)
    for path in out.written:
        shown = os.path.relpath(path)
        print("wrote", path if shown.startswith("..") else shown)


if __name__ == "__main__":
    main()
