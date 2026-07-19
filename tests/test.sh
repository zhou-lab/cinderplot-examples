#!/bin/sh
set -eu

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cinderplot-test.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# Locate the cinderplot binary. Override with CINDERPLOT=/path/to/cinderplot.
# Default assumes the code repo is a sibling checkout: ../cinderplot/cinderplot.
here=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CINDERPLOT=${CINDERPLOT:-"$here/../cinderplot/cinderplot"}
if [ ! -x "$CINDERPLOT" ]; then
    echo "cinderplot binary not found at $CINDERPLOT" >&2
    echo "build it in the code repo, or set CINDERPLOT=/path/to/cinderplot" >&2
    exit 2
fi
data="$here/data"

"$CINDERPLOT" "$data/mtcars.csv" -x hp -y mpg -m col -o "$tmpdir/col.pdf"
test -s "$tmpdir/col.pdf"

"$CINDERPLOT" "$data/mtcars.csv" -x hp -m histogram --log y -o "$tmpdir/hist-log.pdf"
test -s "$tmpdir/hist-log.pdf"

"$CINDERPLOT" "$data/mtcars.csv" -x hp -y mpg -t 'quoted "title" \\ ok' \
    --dump-spec -o "$tmpdir/title.pdf" >"$tmpdir/spec"
grep -F 'labs(title="quoted \"title\" \\\\ ok")' "$tmpdir/spec" >/dev/null
test -s "$tmpdir/title.pdf"

if "$CINDERPLOT" "$data/mtcars.csv" -x hp -y mpg --size -1x2 -o "$tmpdir/bad.pdf" \
    >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "negative --size unexpectedly succeeded" >&2
    exit 1
fi
grep 'bad --size' "$tmpdir/err" >/dev/null

printf 'x,y\n"1"junk,2\n' >"$tmpdir/bad.csv"
if "$CINDERPLOT" "$tmpdir/bad.csv" -x x -y y -o "$tmpdir/bad-csv.pdf" \
    >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "malformed CSV unexpectedly succeeded" >&2
    exit 1
fi
grep 'malformed quoted field' "$tmpdir/err" >/dev/null

# geom_density (1-D KDE) on the GM12878 methylation betas -> SVG
"$CINDERPLOT" "$data/gm12878_betas.tsv + aes(beta) + geom_density()" -o "$tmpdir/density.svg"
test -s "$tmpdir/density.svg"
grep -q '<svg' "$tmpdir/density.svg"

echo "all tests passed"
