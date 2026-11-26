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

# Sampled from the chosen logo, not an approximation.
GREEN = (200, 208, 181)
WHITE = (255, 255, 255)
INK = (20, 20, 20)
CORNER_RATIO = 0.1516
# Leaf outline traced from the reference image, normalized to the rounded square.
LEAF = [
    (0.72736, 0.25295), (0.72933, 0.25492), (0.72933, 0.36909), (0.72736, 0.37106),
    (0.72736, 0.38878), (0.72539, 0.39075), (0.72539, 0.41831), (0.72146, 0.42815),
    (0.72146, 0.44587), (0.71752, 0.45571), (0.71752, 0.46752), (0.71358, 0.47736),
    (0.71358, 0.4872), (0.70965, 0.49508), (0.70965, 0.50689), (0.70571, 0.5128),
    (0.70571, 0.5187), (0.70177, 0.52264), (0.70177, 0.53051), (0.69783, 0.53839),
    (0.69783, 0.54626), (0.68996, 0.55807), (0.68602, 0.57382), (0.67028, 0.60531),
    (0.67028, 0.60925), (0.66043, 0.62697), (0.6565, 0.63091), (0.65256, 0.64075),
    (0.63287, 0.66634), (0.63091, 0.67224), (0.62697, 0.67421), (0.62697, 0.67618),
    (0.61122, 0.69193), (0.61122, 0.6939), (0.59154, 0.71161), (0.58366, 0.72146),
    (0.57185, 0.72933), (0.56398, 0.73917), (0.54232, 0.75492), (0.49508, 0.78248),
    (0.4872, 0.78445), (0.47736, 0.79035), (0.43406, 0.80807), (0.36319, 0.82579),
    (0.3002, 0.8376), (0.28248, 0.8376), (0.28051, 0.81398), (0.27854, 0.81201),
    (0.27657, 0.77067), (0.27461, 0.7687), (0.27461, 0.72736), (0.27264, 0.72539),
    (0.27264, 0.71161), (0.27461, 0.70965), (0.27461, 0.67618), (0.27657, 0.67421),
    (0.27854, 0.64469), (0.28248, 0.63484), (0.28248, 0.62303), (0.28642, 0.61319),
    (0.28642, 0.60531), (0.29035, 0.59941), (0.29035, 0.58957), (0.29232, 0.5876),
    (0.29429, 0.57776), (0.29823, 0.57382), (0.29823, 0.56398), (0.31004, 0.54035),
    (0.31004, 0.53445), (0.31791, 0.52264), (0.32382, 0.50689), (0.32776, 0.50295),
    (0.34547, 0.46949), (0.35335, 0.46161), (0.35728, 0.45177), (0.36713, 0.44193),
    (0.375, 0.43012), (0.38681, 0.42028), (0.39665, 0.4065), (0.42028, 0.38484),
    (0.43799, 0.37303), (0.43996, 0.36909), (0.46358, 0.35138), (0.48917, 0.3376),
    (0.48917, 0.33563), (0.49508, 0.33169), (0.5502, 0.3061), (0.59547, 0.28839),
    (0.71949, 0.25295),
]

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


def point_in_leaf(px: float, py: float, size: float) -> bool:
    x = px / size
    y = py / size
    inside = False
    j = len(LEAF) - 1
    for i, point in enumerate(LEAF):
        xi, yi = point
        xj, yj = LEAF[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def render(size: int, kind: str = "color") -> list[list[tuple[int, int, int, int]]]:
    radius = size * CORNER_RATIO
    mask = [point_in_leaf(x + 0.5, y + 0.5, size) for y in range(size) for x in range(size)]
    stroke = max(1, int(round(size * 0.055)))
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            inside = mask[y * size + x]
            pixel = (0, 0, 0, 0)
            if kind == "outline":
                if inside:
                    edge = False
                    for dy in range(-stroke, stroke + 1):
                        for dx in range(-stroke, stroke + 1):
                            nx, ny = x + dx, y + dy
                            if nx < 0 or ny < 0 or nx >= size or ny >= size or not mask[ny * size + nx]:
                                edge = True
                                break
                        if edge:
                            break
                    if edge:
                        pixel = composite(pixel, INK, 1)
            elif kind == "filled":
                if inside:
                    pixel = composite(pixel, INK, 1)
            else:
                pixel = composite(pixel, GREEN, coverage(sd_round_rect(x + 0.5, y + 0.5, size, radius)))
                if inside:
                    pixel = composite(pixel, WHITE, 1)
            row.append(pixel)
        rows.append(row)
    return rows


def icon_svg() -> str:
    radius = round(1024 * CORNER_RATIO, 2)
    commands = []
    for index, (x, y) in enumerate(LEAF):
        px = round(x * 1024, 2)
        py = round(y * 1024, 2)
        commands.append(("M" if index == 0 else "L") + f"{px},{py}")
    commands.append("Z")
    path = " ".join(commands)
    red, green, blue = GREEN
    fill = f"#{red:02X}{green:02X}{blue:02X}"
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="QuietSafari">\n'
        f'  <rect width="1024" height="1024" rx="{radius}" fill="{fill}"/>\n'
        f'  <path fill="#ffffff" d="{path}"/>\n'
        "</svg>\n"
    )


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
    cache: dict[tuple[int, str], bytes] = {}

    def png(size: int, kind: str = "color") -> bytes:
        key = (size, kind)
        if key not in cache:
            cache[key] = png_bytes(render(size, kind))
        return cache[key]

    files[ROOT / "App" / "Assets.xcassets" / "Contents.json"] = contents_json({"info": {"author": "xcode", "version": 1}})
    svg = icon_svg().encode("utf-8")
    files[ROOT / "App" / "AppIcon.svg"] = svg
    files[ROOT / "site" / "icon.svg"] = svg
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
    def accent_entry(red: str, green: str, blue: str, luminosity: str) -> dict:
        return {
            "appearances": [{"appearance": "luminosity", "value": luminosity}],
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": blue, "green": green, "red": red},
            },
            "idiom": "universal",
        }

    files[ACCENT / "Contents.json"] = contents_json(
        {
            "colors": [
                accent_entry("0.455", "0.494", "0.376", "light"),
                accent_entry("0.784", "0.816", "0.710", "dark"),
            ],
            "info": {"author": "xcode", "version": 1},
        }
    )
    for pixels in (16, 32, 48, 128):
        files[IMAGES / f"icon-{pixels}.png"] = png(pixels, "filled")

    def template_set(folder: str, kind: str) -> None:
        directory = ROOT / "App" / "Assets.xcassets" / folder
        files[directory / "leaf.png"] = png(18, kind)
        files[directory / "leaf@2x.png"] = png(36, kind)
        files[directory / "Contents.json"] = contents_json(
            {
                "images": [
                    {"filename": "leaf.png", "idiom": "mac", "scale": "1x"},
                    {"filename": "leaf@2x.png", "idiom": "mac", "scale": "2x"},
                ],
                "info": {"author": "xcode", "version": 1},
                "properties": {"template-rendering-intent": "template"},
            }
        )

    template_set("MenuBarIcon.imageset", "filled")
    template_set("MenuBarIconOutline.imageset", "outline")
    mark = ROOT / "App" / "Assets.xcassets" / "QuietSafariMark.imageset"
    files[mark / "mark.png"] = png(40, "color")
    files[mark / "mark@2x.png"] = png(80, "color")
    files[mark / "Contents.json"] = contents_json(
        {
            "images": [
                {"filename": "mark.png", "idiom": "mac", "scale": "1x"},
                {"filename": "mark@2x.png", "idiom": "mac", "scale": "2x"},
            ],
            "info": {"author": "xcode", "version": 1},
        }
    )
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
