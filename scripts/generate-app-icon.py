#!/usr/bin/env python3
"""Write a minimal dark macOS app icon set (no third-party deps)."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path


def png(width: int, height: int, rgba: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b""
    stride = width * 4
    for y in range(height):
        raw += b"\x00" + rgba[y * stride : (y + 1) * stride]
    return b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
            chunk(b"IDAT", zlib.compress(raw, 9)),
            chunk(b"IEND", b""),
        ]
    )


def pixel(x: int, y: int, size: int) -> bytes:
    cx, cy = (size - 1) / 2.0, (size - 1) / 2.0
    dx, dy = x - cx, y - cy
    rx, ry = size * 0.36, size * 0.16
    inside = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) <= 1.0
    if inside:
        return bytes((250, 208, 110, 255))
    return bytes((18, 18, 20, 255))


def render(size: int) -> bytes:
    buf = bytearray()
    for y in range(size):
        for x in range(size):
            buf.extend(pixel(x, y, size))
    return png(size, size, bytes(buf))


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "GrokIsland" / "Assets.xcassets" / "AppIcon.appiconset"
    root.mkdir(parents=True, exist_ok=True)
    for name, size in {
        "icon_16.png": 16,
        "icon_16@2x.png": 32,
        "icon_32.png": 32,
        "icon_32@2x.png": 64,
        "icon_128.png": 128,
        "icon_128@2x.png": 256,
        "icon_256.png": 256,
        "icon_256@2x.png": 512,
        "icon_512.png": 512,
        "icon_512@2x.png": 1024,
    }.items():
        (root / name).write_bytes(render(size))
        print(f"wrote {name} ({size}px)")


if __name__ == "__main__":
    main()
