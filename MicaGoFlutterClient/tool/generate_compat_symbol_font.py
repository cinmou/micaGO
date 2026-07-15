"""Generate micaGO's tiny PUA compatibility font from sourced SVG logos."""

from pathlib import Path
from xml.etree import ElementTree

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path


ROOT = Path(__file__).parent
SOURCE_DIR = ROOT / "compat_symbols"


def _empty():
    return TTGlyphPen(None).glyph()


def _path_data(source: Path) -> list[str]:
    root = ElementTree.parse(source).getroot()
    paths = [
        element.get("d")
        for element in root.iter()
        if element.tag.endswith("path")
    ]
    return [path for path in paths if path]


def _svg_glyph(filename: str):
    """Normalize SVG path bounds into a large, vertically centered em glyph."""
    paths = _path_data(SOURCE_DIR / filename)
    bounds_pen = BoundsPen(None)
    for path in paths:
        parse_path(path, bounds_pen)
    if bounds_pen.bounds is None:
        raise ValueError(f"No drawable path in {filename}")

    min_x, min_y, max_x, max_y = bounds_pen.bounds
    width = max_x - min_x
    height = max_y - min_y
    scale = min(900 / width, 900 / height)
    rendered_width = width * scale
    rendered_height = height * scale
    left = (1000 - rendered_width) / 2
    bottom = (900 - rendered_height) / 2

    glyph_pen = TTGlyphPen(None)
    # SVG coordinates grow downward; TrueType coordinates grow upward.
    transformed = TransformPen(
        Cu2QuPen(glyph_pen, max_err=1.0, reverse_direction=False),
        (
            scale,
            0,
            0,
            -scale,
            left - min_x * scale,
            bottom + max_y * scale,
        ),
    )
    for path in paths:
        parse_path(path, transformed)
    return glyph_pen.glyph()


def main():
    glyphs = {
        ".notdef": _empty(),
        "uniEEEE": _svg_glyph("xiaomi.svg"),
        "uniF8FF": _svg_glyph("apple.svg"),
        "uniEA00": _svg_glyph("twitter-2012.svg"),
    }
    cmap = {
        0xEEEE: "uniEEEE",
        0xF8FF: "uniF8FF",
        0xEA00: "uniEA00",
    }
    order = list(glyphs)
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap(cmap)
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (1000, 0) for name in order})
    builder.setupHorizontalHeader(ascent=900, descent=0)
    builder.setupNameTable(
        {
            "familyName": "MicaGo Compat Symbols",
            "styleName": "Regular",
            "uniqueFontIdentifier": "micaGO:MicaGoCompatSymbols:2.0",
            "fullName": "MicaGo Compat Symbols Regular",
            "psName": "MicaGoCompatSymbols-Regular",
            "version": "Version 2.0",
        }
    )
    builder.setupOS2(
        sTypoAscender=900,
        sTypoDescender=0,
        usWinAscent=900,
        usWinDescent=0,
    )
    builder.setupPost()
    builder.setupMaxp()
    output = ROOT.parent / "lib/Assets/fonts/MicaGoCompatSymbols.ttf"
    output.parent.mkdir(parents=True, exist_ok=True)
    builder.save(output)
    print(output)


if __name__ == "__main__":
    main()
