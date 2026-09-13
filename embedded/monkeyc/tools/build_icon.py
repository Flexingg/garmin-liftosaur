"""Build the watch launcher icon from the Liftosaur SVG.

Deterministic rather than by-eye: the artwork sits on a flat purple (#8356F6)
background, so the content mask is "pixels that differ from purple". That gives
the true bounding box, and the empty row band between the dino and the barbell
gives a clean place to split them - which matters because the barbell is
unreadable at 61px and would be sliced by the watch's round icon mask.

Usage: build_icon.py <source.svg> <out_dir>
"""
import sys
from pathlib import Path

import cairosvg
from PIL import Image

BG = (0x83, 0x56, 0xF6)
TOL = 40          # per-channel distance from the background to count as content
RENDER = 512      # work large, downscale once at the end
LAUNCHER = 61     # what venu2s wants (compiler.json: launcherIcon 61x61)
COMPLICATION = 39
MARGIN = 0.10     # fraction of the frame kept clear so a round mask cannot clip


def content_mask(im: Image.Image):
    """Rows where the artwork is, as a list of (y, count) plus the bbox."""
    px = im.load()
    w, h = im.size
    rows = []
    minx, maxx, miny, maxy = w, -1, h, -1
    for y in range(h):
        count = 0
        for x in range(w):
            r, g, b = px[x, y][:3]
            if (abs(r - BG[0]) + abs(g - BG[1]) + abs(b - BG[2])) > TOL:
                count += 1
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
        rows.append((y, count))
    return rows, (minx, miny, maxx, maxy)


_PX = None


def split_head(rows, bbox, width):
    """Row where the barbell starts, found by the sudden jump in row width.

    There is no empty gap to exploit (the dino's neck meets the bar), but the
    barbell plates span nearly the full canvas while the head is much narrower,
    so the first row whose content covers most of the width IS the barbell.
    """
    _, miny, _, maxy = bbox
    # Only the barbell plates reach the canvas edges; the head never does.
    edge = int(width * 0.05)
    px = _PX
    for y in range(miny, maxy + 1):
        if px[edge, y][:3] != BG[:3] or px[width - edge, y][:3] != BG[:3]:
            return y
    return None


def square_crop(im: Image.Image, bbox, cut_bottom=None):
    """A square around the content, padded so a round mask stays clear."""
    minx, miny, maxx, maxy = bbox
    if cut_bottom is not None:
        maxy = min(maxy, cut_bottom)
    cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
    side = max(maxx - minx, maxy - miny) / (1.0 - 2 * MARGIN)
    half = side / 2
    box = (int(cx - half), int(cy - half), int(cx + half), int(cy + half))
    # keep inside the canvas by shifting, then pad if it still does not fit
    canvas = Image.new("RGB", (int(side), int(side)), BG)
    src = im.crop((max(0, box[0]), max(0, box[1]),
                   min(im.size[0], box[2]), min(im.size[1], box[3])))
    canvas.paste(src, (max(0, -box[0]), max(0, -box[1])))
    return canvas


def main() -> int:
    src, out_dir = sys.argv[1], Path(sys.argv[2])
    png = "/tmp/_icon_render.png"
    cairosvg.svg2png(url=src, write_to=png, output_width=RENDER, output_height=RENDER)
    im = Image.open(png).convert("RGB")

    global _PX
    rows, bbox = content_mask(im)
    _PX = im.load()
    print(f"content bbox: {bbox}")
    cut = split_head(rows, bbox, RENDER)
    print(f"head/barbell split at y={cut}")

    (out_dir).mkdir(parents=True, exist_ok=True)
    if cut is not None:
        head_bbox = (bbox[0], bbox[1], bbox[2], cut - 1)
        # narrower x extent: within the head rows only
        minx, maxx = RENDER, -1
        px = im.load()
        for y in range(bbox[1], cut):
            for x in range(RENDER):
                r, g, b = px[x, y][:3]
                if (abs(r-BG[0]) + abs(g-BG[1]) + abs(b-BG[2])) > TOL:
                    if x < minx: minx = x
                    if x > maxx: maxx = x
        if maxx > minx:
            head_bbox = (minx, bbox[1], maxx, cut - 1)
        print(f"head bbox: {head_bbox}")
    else:
        head_bbox = bbox
    head = square_crop(im, head_bbox)
    head.resize((LAUNCHER, LAUNCHER), Image.LANCZOS).save(
        out_dir / "images" / "icon.png")
    head.resize((COMPLICATION, COMPLICATION), Image.LANCZOS).save(
        "/tmp/icon-complication.png")
    head.resize((244, 244), Image.NEAREST).save("/tmp/icon-preview.png")
    print(f"wrote {out_dir}/images/icon.png ({LAUNCHER}x{LAUNCHER})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
