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

# Discrete y supports its documented maximum of 40 categories without
# overflowing the axis-label or minor-grid buffers.
printf 'x\ty\tz\n' >"$tmpdir/tile40.tsv"
i=1
while [ "$i" -le 40 ]; do
    printf 'x\ty%s\t%s\n' "$i" "$i" >>"$tmpdir/tile40.tsv"
    i=$((i + 1))
done
"$CINDERPLOT" \
    "$tmpdir/tile40.tsv + aes(x,y,fill=z) + geom_tile()" \
    -o "$tmpdir/tile40.pdf"
test -s "$tmpdir/tile40.pdf"

# Missing and infinite continuous-colour values are dropped before palette
# interpolation instead of becoming invalid palette indices.
printf 'x,y,c\n1,1,0.2\n2,2,NA\n3,3,Inf\n' >"$tmpdir/colour-na.csv"
"$CINDERPLOT" \
    "$tmpdir/colour-na.csv + aes(x,y,colour=c) + geom_point()" \
    -o "$tmpdir/colour-na.pdf" 2>"$tmpdir/colour-na.err"
test -s "$tmpdir/colour-na.pdf"
grep 'removed 2 rows with missing values' "$tmpdir/colour-na.err" >/dev/null

# Text geoms report a missing label column instead of dereferencing NULL.
printf 'x,y\n1,1\n2,2\n' >"$tmpdir/missing-label.csv"
if "$CINDERPLOT" \
    "$tmpdir/missing-label.csv + aes(x,y,label=nope) + geom_text()" \
    -o "$tmpdir/missing-label.pdf" 2>"$tmpdir/missing-label.err"; then
    echo "missing label column unexpectedly succeeded" >&2
    exit 1
fi
grep 'column `nope` not found' "$tmpdir/missing-label.err" >/dev/null

# Segment endpoints must be numeric; text endpoints produce a controlled error.
printf 'x,y,xend,yend\n1,1,right,2\n' >"$tmpdir/string-xend.csv"
if "$CINDERPLOT" \
    "$tmpdir/string-xend.csv + aes(x,y,xend=xend,yend=yend) + geom_segment()" \
    -o "$tmpdir/string-xend.pdf" 2>"$tmpdir/string-xend.err"; then
    echo "string xend unexpectedly succeeded" >&2
    exit 1
fi
grep 'xend column `xend` must be numeric' "$tmpdir/string-xend.err" >/dev/null
printf 'x,y,xend,yend\n1,1,2,top\n' >"$tmpdir/string-yend.csv"
if "$CINDERPLOT" \
    "$tmpdir/string-yend.csv + aes(x,y,xend=xend,yend=yend) + geom_segment()" \
    -o "$tmpdir/string-yend.pdf" 2>"$tmpdir/string-yend.err"; then
    echo "string yend unexpectedly succeeded" >&2
    exit 1
fi
grep 'yend column `yend` must be numeric' "$tmpdir/string-yend.err" >/dev/null

# A continuous colour mapped to stat-count bars is rejected rather than
# producing a legend whose colours are ignored by the bars.
printf 'x,c\na,1\na,2\nb,3\n' >"$tmpdir/bar-continuous.csv"
if "$CINDERPLOT" \
    "$tmpdir/bar-continuous.csv + aes(factor(x),colour=c) + geom_bar()" \
    -o "$tmpdir/bar-continuous.pdf" 2>"$tmpdir/bar-continuous.err"; then
    echo "continuous-colour geom_bar unexpectedly succeeded" >&2
    exit 1
fi
grep 'continuous colour/fill on geom_bar() is not implemented' \
    "$tmpdir/bar-continuous.err" >/dev/null

# Hex colours parse through correctly typed sscanf destinations.
"$CINDERPLOT" \
    "$data/mtcars.csv + aes(hp,mpg) + geom_point(colour=\"#123abc\")" \
    -o "$tmpdir/hex-colour.pdf"
test -s "$tmpdir/hex-colour.pdf"

# Numeric chromosome columns in long matrix data are formatted for matching
# rather than dereferenced as strings or mistaken for the value column.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' \
    >"$tmpdir/numeric-chrom.tsv"
printf '1\t110\t111\tp1\t0.1\ts1\n1\t110\t111\tp1\t0.2\ts2\n' \
    >>"$tmpdir/numeric-chrom.tsv"
"$CINDERPLOT" \
    "region(\"1:100-200\") + matrix(\"$tmpdir/numeric-chrom.tsv\")" \
    -o "$tmpdir/numeric-chrom.pdf"
test -s "$tmpdir/numeric-chrom.pdf"

# BED12 genes with name `.` remain as unlabeled models instead of crashing
# symbol-based canonical-transcript selection.
printf 'chr1\t100\t200\t.\t0\t+\t120\t180\t0\t1\t100,\t0,\n' \
    >"$tmpdir/unnamed-gene.bed"
"$CINDERPLOT" \
    "region(\"chr1:50-250\") + genes(\"$tmpdir/unnamed-gene.bed\")" \
    -o "$tmpdir/unnamed-gene.pdf"
test -s "$tmpdir/unnamed-gene.pdf"

# Wide matrices retain only probes overlapping the requested window.
printf 'chrom\tstart\tend\tProbe_ID\ts1\ts2\n' >"$tmpdir/wide-window.tsv"
printf 'chr1\t110\t111\tin\t0.1\t0.2\nchr1\t900\t901\tout\t0.8\t0.9\n' \
    >>"$tmpdir/wide-window.tsv"
"$CINDERPLOT" \
    "region(\"chr1:100-200\") + matrix(\"$tmpdir/wide-window.tsv\")" \
    -o "$tmpdir/wide-window.pdf"
test -s "$tmpdir/wide-window.pdf"
if "$CINDERPLOT" \
    "region(\"chr1:700-800\") + matrix(\"$tmpdir/wide-window.tsv\")" \
    -o "$tmpdir/wide-empty.pdf" 2>"$tmpdir/wide-empty.err"; then
    echo "wide matrix outside the requested window unexpectedly succeeded" >&2
    exit 1
fi
grep 'matrix is empty in the requested window' "$tmpdir/wide-empty.err" >/dev/null

# Independently loaded matrix windows follow the shared all-data sample order,
# even when samples first occur in a different order within each window.
printf 'chr1\t100\t200\tleft\nchr1\t300\t400\tright\n' \
    >"$tmpdir/matrix-windows.bed"
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' \
    >"$tmpdir/matrix-row-order.tsv"
printf 'chr1\t120\t121\tp1\t0.1\ts1\nchr1\t120\t121\tp1\t0.9\ts2\n' \
    >>"$tmpdir/matrix-row-order.tsv"
printf 'chr1\t320\t321\tp2\t0.8\ts2\nchr1\t320\t321\tp2\t0.2\ts1\n' \
    >>"$tmpdir/matrix-row-order.tsv"
"$CINDERPLOT" \
    "regions(\"$tmpdir/matrix-windows.bed\") + matrix(\"$tmpdir/matrix-row-order.tsv\")" \
    -o "$tmpdir/matrix-row-order.pdf"
test -s "$tmpdir/matrix-row-order.pdf"

# A sample absent from one window keeps its band there rather than letting the
# remaining rows spread over the full height under the other window's labels.
# Every window's heatmap image must therefore be as tall as the sample count:
# here s2 has no probe in the right window, so both images stay 2 rows.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' \
    >"$tmpdir/matrix-row-gap.tsv"
printf 'chr1\t120\t121\tp1\t0.1\ts1\nchr1\t120\t121\tp1\t0.9\ts2\n' \
    >>"$tmpdir/matrix-row-gap.tsv"
printf 'chr1\t320\t321\tp2\t0.8\ts1\n' >>"$tmpdir/matrix-row-gap.tsv"
"$CINDERPLOT" \
    "regions(\"$tmpdir/matrix-windows.bed\") + matrix(\"$tmpdir/matrix-row-gap.tsv\")" \
    -o "$tmpdir/matrix-row-gap.pdf"
test "$(strings "$tmpdir/matrix-row-gap.pdf" | grep -c '/Height 2')" -eq 2
test "$(strings "$tmpdir/matrix-row-gap.pdf" | grep -c '/Height 1')" -eq 0

# region() and regions() both name the window, so giving both is an error rather
# than a silent choice between them.
if "$CINDERPLOT" \
    "region(\"chr1:1-999\") + regions(\"$tmpdir/matrix-windows.bed\") + matrix(\"$tmpdir/matrix-row-order.tsv\")" \
    -o "$tmpdir/both-windows.pdf" 2>"$tmpdir/both-windows.err"; then
    echo "region() plus regions() unexpectedly succeeded" >&2
    exit 1
fi
grep 'both give the window' "$tmpdir/both-windows.err" >/dev/null

# regions() tolerates a BED header and filters interval() into each window.
printf 'chrom\tstart\tend\tname\nchr20\t100\t200\tleft\nchr20\t300\t400\tright\n' \
    >"$tmpdir/windows.bed"
printf 'chr20\t120\t150\ta\nchr20\t320\t350\tb\n' >"$tmpdir/spans.bed"
"$CINDERPLOT" \
    "regions(\"$tmpdir/windows.bed\") + interval(\"$tmpdir/spans.bed\")" \
    -o "$tmpdir/regions.pdf"
test -s "$tmpdir/regions.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    test "$(pdftotext "$tmpdir/regions.pdf" - | grep -o 'bp' | wc -l)" -eq 2
fi

echo "all tests passed"
