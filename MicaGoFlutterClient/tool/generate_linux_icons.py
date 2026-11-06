#!/usr/bin/env python3
"""Export the shared default artwork for Linux (requires rsvg-convert)."""

from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.micago.message.mica_go"
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def main():
    source = ET.parse(ROOT / "tool/launcher_icons/default-foreground.svg").getroot()
    icon = ET.Element(f"{{{SVG}}}svg", {
        "width": "512", "height": "512", "viewBox": "18 18 72 72",
    })
    ET.SubElement(icon, f"{{{SVG}}}rect", {
        "x": "18", "y": "18", "width": "72", "height": "72",
        "rx": "16", "fill": "#FFFFFF",
    })
    artwork = ET.SubElement(icon, f"{{{SVG}}}g", {
        "transform": "translate(54 54) scale(.82) translate(-54 -54)",
    })
    artwork.extend(list(source))
    icons = ROOT / "linux/icons/hicolor"
    vector = icons / "scalable/apps" / f"{APP_ID}.svg"
    vector.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(icon)
    ET.ElementTree(icon).write(vector, encoding="utf-8", xml_declaration=True)
    for size in (16, 24, 32, 48, 64, 128, 256, 512):
        output = icons / f"{size}x{size}/apps" / f"{APP_ID}.png"
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([
            "rsvg-convert", "--width", str(size), "--height", str(size),
            "--output", str(output), str(vector),
        ], check=True)


if __name__ == "__main__":
    main()
