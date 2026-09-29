#!/usr/bin/env python3
"""Normalise a piece set into the simple shape the app's parser reads.

The upstream files are editor output: some put shapes in a group carrying a
`transform`, some use `<ellipse>`, and many write their colours in a `style`
attribute instead of the presentation attributes. The app's piece parser reads
plain paths with their own coordinates, so all of that is resolved here rather
than taught to the parser, which keeps the bundled artwork as simple as it
claims to be.

Usage: tool/prepare_pieces.py <source-dir> <assets/pieces>
"""
import re
import sys
from pathlib import Path

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
CMD = re.compile(r'([MmZzLlHhVvCcSsQqTtAa])')
PARAMS = {
    'M': 2, 'L': 2, 'T': 2, 'Z': 0, 'm': 2, 'l': 2, 't': 2, 'z': 0,
    'H': 1, 'V': 1, 'h': 1, 'v': 1,
    'C': 6, 'S': 4, 'Q': 4, 'c': 6, 's': 4, 'q': 4,
    'A': 7, 'a': 7,
}


def tokenize(d):
    """Splits path data into (command, [numbers]) pairs, as SVG defines them."""
    out = []
    parts = CMD.split(d)
    i = 0
    while i < len(parts):
        cmd = parts[i].strip()
        if not cmd:
            i += 1
            continue
        nums = [float(n) for n in NUM.findall(parts[i + 1])]
        step = PARAMS[cmd]
        if step == 0:
            out.append((cmd, []))
        else:
            for k in range(0, len(nums), step):
                out.append((cmd, nums[k:k + step]))
        i += 2
    return out


def detokenize(tokens):
    """Rebuilds path data, rounding so the files stay small.

    Every number is space separated: written back to back, `M200 88` would
    become `M20088` and the parser would read a completely different point.
    """
    parts = []
    for cmd, nums in tokens:
        parts.append(cmd)
        parts.extend(f'{round(n, 3):g}' for n in nums)
    return ' '.join(parts)


def to_absolute(d):
    """Rewrites path data in absolute commands, tracking the current point.

    SVG allows a command to name only one coordinate (H, V) or to be relative to
    where the pen currently is. Resolving all of that first means the affine
    transform below only ever has to look at whole points.
    """
    out = []
    cur = [0.0, 0.0]
    start = [0.0, 0.0]
    for cmd, nums in tokenize(d):
        up = cmd.upper()
        relative = cmd.islower()
        if up == 'Z':
            out.append(('Z', []))
            cur = list(start)
            continue
        if up == 'H':
            x = nums[0] + cur[0] if relative else nums[0]
            out.append(('L', [x, cur[1]]))
            cur[0] = x
        elif up == 'V':
            y = nums[0] + cur[1] if relative else nums[0]
            out.append(('L', [cur[0], y]))
            cur[1] = y
        else:
            if up == 'A':
                # An arc names its radii, a rotation and two flags before the
                # end point, so its last pair is the only coordinate pair.
                x = nums[5] + cur[0] if relative else nums[5]
                y = nums[6] + cur[1] if relative else nums[6]
                out.append(('A', [nums[0], nums[1], nums[2], nums[3],
                                  nums[4], x, y]))
                cur = [x, y]
                continue
            points = [
                (nums[i] + cur[0] if relative else nums[i],
                 nums[i + 1] + cur[1] if relative else nums[i + 1])
                for i in range(0, len(nums), 2)
            ]
            out.append((up, [v for point in points for v in point]))
            if up == 'M':
                start = points[0]
            cur = list(points[-1])
    return out


def scale_path(d, a, b, c, dd, e, f):
    """Applies `matrix(a b c d e f)` to every coordinate in [d]."""
    out = []
    for cmd, nums in to_absolute(d):
        if cmd == 'Z':
            out.append((cmd, []))
            continue
        if cmd == 'A':
            # Radii scale, the rotation and the two flags do not.
            rx, ry, rot, laf, sf, x, y = nums
            nums = [
                rx * (a * a + c * c) ** 0.5,
                ry * (b * b + dd * dd) ** 0.5,
                rot,
                laf,
                sf,
                a * x + c * y + e,
                b * x + dd * y + f,
            ]
        else:
            nums = [
                n
                for i in range(0, len(nums), 2)
                for n in (a * nums[i] + c * nums[i + 1] + e,
                          b * nums[i] + dd * nums[i + 1] + f)
            ]
        out.append((cmd, nums))
    return detokenize(out)


def ellipse_to_path(cx, cy, rx, ry):
    """An ellipse is two half arcs, which is all the parser needs."""
    return (
        f'M{round(cx - rx, 3):g} {round(cy, 3):g}'
        f'A{round(rx, 3):g} {round(ry, 3):g} 0 1 0 {round(cx + rx, 3):g} '
        f'{round(cy, 3):g}'
        f'A{round(rx, 3):g} {round(ry, 3):g} 0 1 0 {round(cx - rx, 3):g} '
        f'{round(cy, 3):g}Z'
    )


ATTR = re.compile(r'([\w-]+)="([^"]*)"')
DECL = re.compile(r'([\w-]+)\s*:\s*([^;]+)')

#: The only paint properties the app's parser reads.
KEPT = ('fill', 'stroke', 'stroke-width', 'fill-rule')


def paints(attrs):
    """The paint properties of a shape.

    SVG lets these be written either as attributes or inside `style`, with the
    attribute winning when both are present.
    """
    found = {}
    style = attrs.get('style')
    if style:
        found.update({k.strip(): v.strip() for k, v in DECL.findall(style)})
    for name in KEPT:
        if name in attrs:
            found[name] = attrs[name]
    return {k: v for k, v in found.items() if k in KEPT}
SHAPE = re.compile(r'<(path|ellipse)\b([^>]*?)/?>')
MATRIX = re.compile(r'matrix\(([^)]*)\)')


def convert(source):
    # Every transform in the set is a single matrix, applied to one group.
    matrix = None
    found = MATRIX.search(source)
    if found:
        matrix = [float(v) for v in found.group(1).split()]
        source = MATRIX.sub('', source)

    # A viewBox is kept as it stands: the set chooses its own units and nothing
    # in the app assumes a particular one.
    view_box = re.search(r'viewBox="([^"]*)"', source)
    view_box = view_box.group(1) if view_box else '0 0 45 45'

    # Properties on the root element are inherited by every shape in it, which
    # is where these sets put `fill-rule`.
    root = paints(dict(ATTR.findall(re.match(r'<svg\b([^>]*)>', source).group(1)))) \
        if re.match(r'<svg\b([^>]*)>', source) else {}

    shapes = []
    for match in SHAPE.finditer(source):
        tag, attr_text = match.group(1), match.group(2)
        attrs = dict(ATTR.findall(attr_text))
        if tag == 'ellipse':
            d = ellipse_to_path(
                float(attrs['cx']), float(attrs['cy']),
                float(attrs['rx']), float(attrs['ry']),
            )
        else:
            d = attrs['d']
        kept = paints(attrs)
        if matrix:
            d = scale_path(d, *matrix)
            scale = (matrix[0] * matrix[0] + matrix[2] * matrix[2]) ** 0.5
            if 'stroke-width' in kept:
                kept['stroke-width'] = f'{round(float(kept["stroke-width"]) * scale, 3):g}'
        shapes.append((d, kept))

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}"'
        f'{" " + " ".join(f"{k}=\"{v}\"" for k, v in root.items()) if root else ""}>'
    ]
    for d, attrs in shapes:
        parts = ' '.join(f'{k}="{v}"' for k, v in attrs.items())
        lines.append(f'  <path d="{d}"{(" " + parts) if parts else ""}/>')
    lines.append('</svg>')
    return '\n'.join(lines) + '\n'


#: Source file name to the app's name, which is the FEN letter after the colour.
NAMES = {
    'white_pawn': 'wP', 'white_knight': 'wN', 'white_bishop': 'wB',
    'white_rook': 'wR', 'white_queen': 'wQ', 'white_king': 'wK',
    'black_pawn': 'bP', 'black_knight': 'bN', 'black_bishop': 'bB',
    'black_rook': 'bR', 'black_queen': 'bQ', 'black_king': 'bK',
}

#: Sets that already use the app's names, so they are read in place.
AS_IS = {f'{colour}{piece}': f'{colour}{piece}'
         for colour in 'wb' for piece in 'KQRBNP'}


def main():
    source_dir, target_dir = Path(sys.argv[1]), Path(sys.argv[2])
    target_dir.mkdir(parents=True, exist_ok=True)
    for target_name in AS_IS:
        source = source_dir / f'{target_name}.svg'
        text = source.read_text()
        (target_dir / f'{target_name}.svg').write_text(convert(text))
        print(f'{target_name}.svg')


if __name__ == '__main__':
    main()
