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


def main(paths):
    for p in paths:
        s = open(p).read()
        if 'style="' not in s:
            continue                      # already the attribute form
        open(p, 'w').write(re.sub(r'style="([^"]*)"', convert, s))


if __name__ == '__main__':
    main(sys.argv[1:])
