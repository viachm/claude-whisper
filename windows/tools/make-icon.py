"""Packs the macOS app icon (macos/Resources/AppIcon.icns, drawn by macos/tools/make-icon.swift)
into windows/Resources/AppIcon.ico, so both apps share one icon. Needs macOS for iconutil.
Run with: python3 -I windows/tools/make-icon.py"""
import pathlib, struct, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parent.parent.parent
icns = root / "macos/Resources/AppIcon.icns"
ico = root / "windows/Resources/AppIcon.ico"

with tempfile.TemporaryDirectory() as tmp:
    iconset = pathlib.Path(tmp) / "AppIcon.iconset"
    subprocess.run(["iconutil", "-c", "iconset", str(icns), "-o", str(iconset)], check=True)
    # Windows reads PNG-compressed entries since Vista; 256 is the largest size an .ico allows.
    sizes = [(16, "icon_16x16.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
             (128, "icon_128x128.png"), (256, "icon_256x256.png")]
    images = [(size, (iconset / name).read_bytes()) for size, name in sizes]

header = struct.pack("<HHH", 0, 1, len(images))
offset = len(header) + 16 * len(images)
entries, data = b"", b""
for size, png in images:
    entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
    data += png
ico.write_bytes(header + entries + data)
print(f"wrote {ico} ({len(images)} sizes)")
