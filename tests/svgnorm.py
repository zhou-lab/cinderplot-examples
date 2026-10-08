#!/usr/bin/env python3
"""Normalise cairo's two SVG paint spellings, in place.

cairo 1.18 writes paint as attributes:

    <path fill-rule="nonzero" fill="rgb(34.9%, 34.9%, 34.9%)" .../>

cairo 1.17 writes the same thing as a style property, without the spaces:

    <path style=" stroke:none;fill-rule:nonzero;fill:rgb(34.9%,34.9%,34.9%);..." .../>

Which one you get depends on the cairo the binary was linked against, so an
assertion that greps for one form passes against the conda dev build and fails
against the lab binary (system cairo) for no reason to do with the figure.
Rewriting the older form into the newer one lets every case assume one shape.

It also drops the white canvas rect cinderplot paints first (0.27.1+), so the
cases that count fills count marks, not the page. `--keep-canvas` leaves it,
for the case that checks the canvas itself.
"""
import re
import sys


def prop(style, name):
    m = re.search(r'(?:^|[;\s])' + name + r':([^;]+)', style)
    return m.group(1).strip() if m else None


def colour(v):
    m = re.match(r'rgb\(([^)]*)\)', v)
    if not m:
        return v
    return 'rgb(%s)' % ', '.join(c.strip() for c in m.group(1).split(','))


def convert(m):
    style = m.group(1)
    out = []
    for name in ('fill-rule', 'fill', 'stroke', 'stroke-width',
                 'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit',
                 'fill-opacity', 'stroke-opacity'):
        v = prop(style, name)
        if v is None:
            continue
        if name in ('fill', 'stroke'):
            v = colour(v)
        out.append('%s="%s"' % (name, v))
    return ' '.join(out)


def drop_canvas(s):
    """Remove the first drawn element when it is a white rect covering the
    whole <svg> viewport -- the canvas, not a mark."""
    root = re.search(r'<svg[^>]*\bwidth="([0-9.]+)"[^>]*\bheight="([0-9.]+)"', s)
    if not root:
        return s
    W, H = float(root.group(1)), float(root.group(2))
    start = s.find('</defs>')
    start = start + 7 if start >= 0 else root.end()
    m = re.compile(r'<(rect|path|image|use|text|g)\b[^>]*>\n?').search(s, start)
    if not m or m.group(1) != 'rect' or 'fill="rgb(100%, 100%, 100%)"' not in m.group(0):
        return s
    try:
        x, y, w, h = (float(re.search(r'\b' + k + r'="([-0-9.]+)"', m.group(0)).group(1))
                      for k in ('x', 'y', 'width', 'height'))
    except AttributeError:
        return s
    if x <= 0 and y <= 0 and x + w >= W - 0.01 and y + h >= H - 0.01:
        return s[:m.start()] + s[m.end():]
    return s


def main(args):
    keep = '--keep-canvas' in args
    for p in (a for a in args if a != '--keep-canvas'):
        s0 = s = open(p).read()
        if 'style="' in s:                # the older, style-property form
            s = re.sub(r'style="([^"]*)"', convert, s)
        if not keep:
            s = drop_canvas(s)
        if s != s0:
            open(p, 'w').write(s)


if __name__ == '__main__':
    main(sys.argv[1:])
