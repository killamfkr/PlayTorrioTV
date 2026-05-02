#!/usr/bin/env python3
"""Generate ic_launcher.png for each mipmap density (stdlib only)."""
import struct
import zlib
from pathlib import Path

PROJ = Path(__file__).resolve().parents[1]
ROOT = PROJ / "android/app/src/main/res"
ASSETS_IMG = PROJ / "assets/images"


def png_chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, w: int, h: int, rgba_fn):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(rgba_fn(x, y))
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    out = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", compressed)
        + png_chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out)


def in_triangle(px: float, py: float, ax: float, ay: float, bx: float, by: float, cx: float, cy: float) -> bool:
    def sign(px_, py_, x1, y1, x2, y2):
        return (px_ - x2) * (y1 - y2) - (x1 - x2) * (py_ - y2)

    d1 = sign(px, py, ax, ay, bx, by)
    d2 = sign(px, py, bx, by, cx, cy)
    d3 = sign(px, py, cx, cy, ax, ay)
    neg = d1 < 0 or d2 < 0 or d3 < 0
    pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)


def launcher_rgba(px: float, py: float, dim: float):
    m = 0.11 * dim
    stroke = max(1.5, dim / 24)
    ix0, iy0 = m, m
    ix1, iy1 = dim - m, dim - m
    outer = (
        ix0 <= px <= ix1 and (abs(py - iy0) < stroke / 2 or abs(py - iy1) < stroke / 2)
    ) or (
        iy0 <= py <= iy1 and (abs(px - ix0) < stroke / 2 or abs(px - ix1) < stroke / 2)
    )
    inner = ix0 + stroke < px < ix1 - stroke and iy0 + stroke < py < iy1 - stroke
    if outer and not inner:
        return (255, 255, 255, 255)
    ax, ay = 0.39 * dim, 0.33 * dim
    bx, by = 0.39 * dim, 0.67 * dim
    cx, cy = 0.62 * dim, 0.50 * dim
    if in_triangle(px, py, ax, ay, bx, by, cx, cy):
        return (255, 255, 255, 255)
    return (0, 0, 0, 255)


def main():
    densities = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, dim in densities.items():
        out = ROOT / folder / "ic_launcher.png"

        def rgba(x: int, y: int, d=dim):
            return launcher_rgba(x + 0.5, y + 0.5, float(d))

        write_png(out, dim, dim, rgba)
        print("Wrote", out)

    # Android TV leanback banner (320×180)
    bw, bh = 320, 180
    icon = 130.0
    ox = 36.0
    oy = (bh - icon) / 2

    def banner_rgba(x: int, y: int):
        px, py = x + 0.5, y + 0.5
        if ox <= px < ox + icon and oy <= py < oy + icon:
            lx = (px - ox) / icon
            ly = (py - oy) / icon
            return launcher_rgba(lx * 256, ly * 256, 256.0)
        return (0, 0, 0, 255)

    banner_path = ROOT / "drawable" / "banner.png"
    write_png(banner_path, bw, bh, banner_rgba)
    print("Wrote", banner_path)

    # Flutter splash / about (single high-res asset)
    mark = ASSETS_IMG / "playtorrio_mark.png"
    mark_dim = 256

    def mark_rgba(x: int, y: int):
        return launcher_rgba(x + 0.5, y + 0.5, float(mark_dim))

    ASSETS_IMG.mkdir(parents=True, exist_ok=True)
    write_png(mark, mark_dim, mark_dim, mark_rgba)
    print("Wrote", mark)


if __name__ == "__main__":
    main()
