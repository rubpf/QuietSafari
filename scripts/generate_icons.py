#!/usr/bin/env python3
"""Draw the QuietSafari icon. Output is deterministic so it can be checked in."""

from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPICON = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"
ACCENT = ROOT / "App" / "Assets.xcassets" / "AccentColor.colorset"
IMAGES = ROOT / "Extension" / "Resources" / "images"

GREEN = (18, 110, 68)
WHITE = (255, 255, 255)

APP_ICONS = [
    ("icon_16x16.png", "16x16", "1x", 16),
    ("icon_16x16@2x.png", "16x16", "2x", 32),
    ("icon_32x32.png", "32x32", "1x", 32),
    ("icon_32x32@2x.png", "32x32", "2x", 64),
    ("icon_128x128.png", "128x128", "1x", 128),
    ("icon_128x128@2x.png", "128x128", "2x", 256),
    ("icon_256x256.png", "256x256", "1x", 256),
    ("icon_256x256@2x.png", "256x256", "2x", 512),
    ("icon_512x512.png", "512x512", "1x", 512),
    ("icon_512x512@2x.png", "512x512", "2x", 1024),
]


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def coverage(signed_distance: float) -> float:
    return clamp01(0.5 - signed_distance / 1.4)


def sd_round_rect(px: float, py: float, size: float, radius: float) -> float:
    half = size / 2
    dx = abs(px - half) - (half - radius)
    dy = abs(py - half) - (half - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    return outside + inside - radius


def ellipse_coverage(px: float, py: float, cx: float, cy: float, rx: float, ry: float, angle: float) -> float:
    """Coverage of a filled rotated ellipse. 1 is inside."""
    dx = px - cx
    dy = py - cy
    cosine = math.cos(-angle)
    sine = math.sin(-angle)
    local_x = dx * cosine - dy * sine
    local_y = dx * sine + dy * cosine
    value = (local_x / rx) ** 2 + (local_y / ry) ** 2
    gradient = math.hypot(2 * local_x / (rx * rx), 2 * local_y / (ry * ry))
    if gradient == 0:
        return 1.0
    return coverage((value - 1.0) / gradient)


def composite(dst, src_rgb, src_a: float):
    """Straight-alpha overlay. src_a is 0..1."""
    if src_a <= 0:
        return dst
    dst_a = dst[3] / 255
    out_a = src_a + dst_a * (1 - src_a)
    if out_a <= 0:
        return (0, 0, 0, 0)
    out = []
    for index in range(3):
        mixed = (src_rgb[index] * src_a + dst[index] * dst_a * (1 - src_a)) / out_a
        out.append(int(round(mixed)))
    out.append(int(round(out_a * 255)))
    return (out[0], out[1], out[2], out[3])


def render(size: int) -> list[list[tuple[int, int, int, int]]]:
    radius = size * 0.22
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            px = x + 0.5
            py = y + 0.5
            pixel = (0, 0, 0, 0)
            pixel = composite(pixel, GREEN, coverage(sd_round_rect(px, py, size, radius)))
            # A solid leaf. A same-color vein hollowed this out into a ring at small sizes.
            leaf = ellipse_coverage(px, py, size * 0.48, size * 0.50, size * 0.20, size * 0.30, -0.65)
            pixel = composite(pixel, WHITE, leaf)
            row.append(pixel)
        rows.append(row)
    return rows


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def png_bytes(rows: list[list[tuple[int, int, int, int]]]) -> bytes:
    height = len(rows)
    width = len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for red, green, blue, alpha in row:
            raw.extend((red, green, blue, alpha))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def outputs() -> dict[Path, bytes]:
    files: dict[Path, bytes] = {}
    cache: dict[int, bytes] = {}

    def png(size: int) -> bytes:
        if size not in cache:
            cache[size] = png_bytes(render(size))
        return cache[size]

    files[ROOT / "App" / "Assets.xcassets" / "Contents.json"] = contents_json({"info": {"author": "xcode", "version": 1}})
    images = []
    for filename, size_name, scale, pixels in APP_ICONS:
        files[APPICON / filename] = png(pixels)
        images.append(
            {
                "filename": filename,
                "idiom": "mac",
                "scale": scale,
                "size": size_name,
            }
        )
    files[APPICON / "Contents.json"] = contents_json({"images": images, "info": {"author": "xcode", "version": 1}})
    files[ACCENT / "Contents.json"] = contents_json(
        {
            "colors": [
                {
                    "color": {
                        "color-space": "srgb",
                        "components": {
                            "alpha": "1.000",
                            "blue": "0.267",
                            "green": "0.431",
                            "red": "0.071",
                        },
                    },
                    "idiom": "universal",
                }
            ],
            "info": {"author": "xcode", "version": 1},
        }
    )
    for pixels in (16, 32, 48, 128):
        files[IMAGES / f"icon-{pixels}.png"] = png(pixels)
    return files


def contents_json(payload: dict) -> bytes:
    return (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def main() -> None:
    import sys

    rendered = outputs()
    if "--check" in sys.argv:
        mismatches = []
        for path, data in sorted(rendered.items()):
            if not path.exists() or path.read_bytes() != data:
                mismatches.append(str(path.relative_to(ROOT)))
        if mismatches:
            raise SystemExit("icon outputs are stale:\n" + "\n".join(mismatches))
        print("icons match")
        return
    for path, data in rendered.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print(f"wrote {len(rendered)} icon files")


if __name__ == "__main__":
    main()
