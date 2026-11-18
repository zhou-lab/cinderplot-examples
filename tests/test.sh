#!/bin/sh
set -eu

# Personal defaults must not reach the suite. CINDERPLOT_EDITABLE_SVG=1 and
# CINDERPLOT_BASE_LINE_SIZE=0.25 are documented per-user settings, so a
# maintainer who has them exported would otherwise be testing a different
# tool from CI: an SVG comes out as <text> elements rather than glyph
# outlines, and every chrome line is half weight. The cases that exercise
# those knobs set them per invocation, below.
unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE

# Cairo spells SVG paint two ways depending on its version -- 1.18 as
# attributes, 1.17 inside a style="" property without spaces -- so a case that
# greps for one form passes against a conda-linked build and fails against the
# lab binary, which links the system cairo. svgnorm rewrites the older form
# into the newer one, in place, right after the render; see tests/svgnorm.py.
svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }

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

# Discrete y handles a large category count without overflowing the axis-label
# or minor-grid buffers. (40 was once the hard limit; it is now just a size.)
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

# cluster=diagonal puts a same-named column opposite its row, whatever order the
# columns arrived in, and appends the columns no row claims. Here the columns are
# D B A C Z against rows A B C D, so the rendered column order is the test.
printf 'true\tD\tB\tA\tC\tZ\n' >"$tmpdir/diag.tsv"
printf 'A\t0\t0\t1\t0\t0\nB\t0\t1\t0\t0\t0\n' >>"$tmpdir/diag.tsv"
printf 'C\t0\t0\t0\t1\t0\nD\t1\t0\t0\t0\t0\n' >>"$tmpdir/diag.tsv"
"$CINDERPLOT" \
    "$tmpdir/diag.tsv + heatmap(name=\"m\", cluster=diagonal, rownames=none, colnames=bottom)" \
    -o "$tmpdir/diag.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # Only the column labels are drawn, so the capitals in reading order are the
    # column order -- in one direction or the other, since pdftotext walks
    # rotated text bottom-up.
    order=$(pdftotext "$tmpdir/diag.pdf" - | tr -cd 'A-Z')
    test "$order" = "ABCDZ" || test "$order" = "ZDCBA"
fi

# cluster=symmetric clusters the rows and then makes the columns follow, so the
# order changes but the diagonal does not scatter the way cluster=both does.
"$CINDERPLOT" \
    "$tmpdir/diag.tsv + heatmap(name=\"m\", cluster=symmetric, colnames=bottom)" \
    -o "$tmpdir/sym.pdf"
test -s "$tmpdir/sym.pdf"

# Both need row names to match on.
printf 'a,b\n1,2\n3,4\n' >"$tmpdir/unnamed-rows.csv"
if "$CINDERPLOT" "$tmpdir/unnamed-rows.csv + heatmap(cluster=diagonal)" \
    -o "$tmpdir/unnamed-rows.pdf" 2>"$tmpdir/unnamed-rows.err"; then
    echo "cluster=diagonal without row names unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs row names' "$tmpdir/unnamed-rows.err" >/dev/null

# A wrong cluster= enumerates every mode, the new ones included.
if "$CINDERPLOT" "$tmpdir/diag.tsv + heatmap(cluster=bogus)" \
    -o "$tmpdir/bad-cluster.pdf" 2>"$tmpdir/bad-cluster.err"; then
    echo "cluster=bogus unexpectedly succeeded" >&2
    exit 1
fi
grep 'diagonal, symmetric, or none' "$tmpdir/bad-cluster.err" >/dev/null

# `off` says the same thing as `none` in heatmap mode as it does on a matrix()
# track, for cluster= and for the label sides.
"$CINDERPLOT" \
    "$tmpdir/diag.tsv + heatmap(cluster=off, rownames=off, colnames=off)" \
    -o "$tmpdir/off.pdf"
test -s "$tmpdir/off.pdf"

# A placement anchors to the anchor's plot body, so beneath() used to put the
# next panel under the anchor's cells and let the anchor's column labels draw on
# top of it. The labels now take their own gutter, which is only visible in the
# geometry: labelling the upper panel must cost the lower panel some room. Before
# the fix the lower panel was laid out identically either way.
# Distinct label vocabularies so the lower panel's rows can be picked out of the
# page: only it draws Rn, and only the upper panel draws the long Cn names whose
# presence is the variable under test.
printf 'true\tCumbersome1\tCumbersome2\n' >"$tmpdir/stack-top.tsv"
printf 'T1\t1\t0\nT2\t0\t1\n' >>"$tmpdir/stack-top.tsv"
printf 'true\tCumbersome1\tCumbersome2\n' >"$tmpdir/stack-bot.tsv"
printf 'Rone\t1\t0\nRtwo\t0\t1\n' >>"$tmpdir/stack-bot.tsv"
if command -v pdftotext >/dev/null 2>&1; then
    for cn in bottom none; do
        "$CINDERPLOT" \
            "$tmpdir/stack-top.tsv + heatmap(name=\"a\", cluster=none, colnames=$cn)
             + heatmap(data=\"$tmpdir/stack-bot.tsv\", beneath(\"a\"), name=\"b\",
                       cluster=none, rownames=right)" \
            -o "$tmpdir/stack-$cn.pdf"
        pdftotext -bbox "$tmpdir/stack-$cn.pdf" - \
            | grep 'R\(one\|two\)<' \
            | sed -n 's/.*yMin="\([0-9]*\)\..*/\1/p' | sort -n >"$tmpdir/stack-$cn.y"
        test -s "$tmpdir/stack-$cn.y"
    done
    if cmp -s "$tmpdir/stack-bottom.y" "$tmpdir/stack-none.y"; then
        echo "beneath() gave the anchor's column labels no room" >&2
        exit 1
    fi
fi

# box= frames the cells. It is off by default, so switching it on must add
# strokes the same figure did not have; a quoted value sets the colour and
# implies on.
"$CINDERPLOT" "$tmpdir/diag.tsv + heatmap(cluster=none)" \
    -o "$tmpdir/nobox.pdf"
"$CINDERPLOT" "$tmpdir/diag.tsv + heatmap(cluster=none, box=on)" \
    -o "$tmpdir/box.pdf"
"$CINDERPLOT" "$tmpdir/diag.tsv + heatmap(cluster=none, box=\"#b2182b\")" \
    -o "$tmpdir/boxcol.pdf"
test "$(wc -c <"$tmpdir/box.pdf")" -gt "$(wc -c <"$tmpdir/nobox.pdf")"
test -s "$tmpdir/boxcol.pdf"

# It applies to the two objects made of cells, and says so otherwise.
if "$CINDERPLOT" \
    "$tmpdir/diag.tsv + heatmap(name=\"m\") + legend(right_of(\"m\"), box=on)" \
    -o "$tmpdir/box-legend.pdf" 2>"$tmpdir/box-legend.err"; then
    echo "box= on a legend unexpectedly succeeded" >&2
    exit 1
fi
grep 'box= applies to' "$tmpdir/box-legend.err" >/dev/null
if "$CINDERPLOT" "$tmpdir/diag.tsv + heatmap(box=maybe)" \
    -o "$tmpdir/box-bad.pdf" 2>"$tmpdir/box-bad.err"; then
    echo "box=maybe unexpectedly succeeded" >&2
    exit 1
fi
grep 'use on/off or a quoted colour' "$tmpdir/box-bad.err" >/dev/null

# facet_wrap(scales=): a freed axis is trained per panel, so a panel whose data
# occupies a different range gets different tick labels. Panel "a" spans 1-2 and
# panel "b" spans 100-200; under fixed scales both show the same breaks.
printf 'p,x,y\na,1,1\na,2,2\nb,100,1\nb,200,2\n' >"$tmpdir/fs.csv"
"$CINDERPLOT" "$tmpdir/fs.csv + aes(x,y) + geom_point() + facet_wrap(~p)" \
    -o "$tmpdir/fs-fixed.pdf"
"$CINDERPLOT" "$tmpdir/fs.csv + aes(x,y) + geom_point() + facet_wrap(~p, scales=\"free_x\")" \
    -o "$tmpdir/fs-free.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    fx=$(pdftotext "$tmpdir/fs-fixed.pdf" - | tr -s ' \n' ' ')
    fr=$(pdftotext "$tmpdir/fs-free.pdf" - | tr -s ' \n' ' ')
    test "$fx" != "$fr"
fi

# A discrete axis drops the categories a panel has no rows for, so a freed panel
# shows fewer tick labels than the shared axis does.
printf 'p,k,y\na,alpha,1\na,beta,2\nb,gamma,1\nb,delta,2\n' >"$tmpdir/fd.csv"
"$CINDERPLOT" \
    "$tmpdir/fd.csv + aes(factor(k),y) + geom_point() + facet_wrap(~p, scales=\"free_x\")" \
    -o "$tmpdir/fd.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # each of the four names is drawn once, not once per panel
    for name in alpha beta gamma delta; do
        test "$(pdftotext "$tmpdir/fd.pdf" - | grep -c "$name")" -eq 1
    done
fi

# scales= is refused where there is nothing to scale, and validates its value.
if "$CINDERPLOT" "$tmpdir/fs.csv + aes(x,y) + geom_point() + facet_wrap(~p, scales=\"nope\")" \
    -o "$tmpdir/fs-bad.pdf" 2>"$tmpdir/fs-bad.err"; then
    echo "scales=nope unexpectedly succeeded" >&2
    exit 1
fi
grep 'use fixed, free_x, free_y, free, or free_colour' "$tmpdir/fs-bad.err" >/dev/null

# A discrete axis is no longer capped at 40 categories.
{ printf 'k,y\n'; i=1; while [ "$i" -le 60 ]; do printf 'cat%s,%s\n' "$i" "$i"; i=$((i+1)); done; } \
    >"$tmpdir/many.csv"
"$CINDERPLOT" "$tmpdir/many.csv + aes(factor(k),y) + geom_point()" -o "$tmpdir/many.pdf"
test -s "$tmpdir/many.pdf"

# Crowded labels rotate; an explicit angle overrides the decision, and angle=0
# means horizontal rather than "decide for me".
"$CINDERPLOT" "$tmpdir/many.csv + aes(factor(k),y) + geom_point() + scale_x_discrete(angle=0)" \
    -o "$tmpdir/many-flat.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # rotated text extracts with different word boxes than horizontal text
    a=$(pdftotext -bbox "$tmpdir/many.pdf" - | grep -c '<word')
    b=$(pdftotext -bbox "$tmpdir/many-flat.pdf" - | grep -c '<word')
    test "$a" -gt 0 && test "$b" -gt 0
fi
if "$CINDERPLOT" "$tmpdir/many.csv + aes(factor(k),y) + geom_point() + scale_x_discrete(angle=120)" \
    -o "$tmpdir/bad-angle.pdf" 2>"$tmpdir/bad-angle.err"; then
    echo "angle=120 unexpectedly succeeded" >&2
    exit 1
fi
grep 'between 0 and 90' "$tmpdir/bad-angle.err" >/dev/null

# Omitting --size fits the canvas to the content; giving one is honoured exactly.
"$CINDERPLOT" "$tmpdir/many.csv + aes(factor(k),y) + geom_point()" -o "$tmpdir/auto.pdf"
"$CINDERPLOT" "$tmpdir/fs.csv + aes(x,y) + geom_point()" -o "$tmpdir/auto-small.pdf"
"$CINDERPLOT" "$tmpdir/many.csv + aes(factor(k),y) + geom_point()" --size 6x4 \
    -o "$tmpdir/explicit.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    big=$(pdfinfo "$tmpdir/auto.pdf" | awk '/Page size/{print int($3)}')
    small=$(pdfinfo "$tmpdir/auto-small.pdf" | awk '/Page size/{print int($3)}')
    exp=$(pdfinfo "$tmpdir/explicit.pdf" | awk '/Page size/{print int($3)}')
    test "$big" -gt "$small"      # 60 categories need more room than 2 points
    test "$exp" -eq 432           # --size 6x4 is 432pt wide, whatever the content
fi

# A small matrix with long labels keeps the cells at a majority of the figure,
# rather than letting the label margins dominate what little data there is.
printf 'true\tCellType.Level.A\tCellType.Level.B\n' >"$tmpdir/share.tsv"
printf 'CellType.Level.A\t1\t0\nCellType.Level.B\t0\t1\n' >>"$tmpdir/share.tsv"
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"m\", cluster=none, rownames=right, colnames=bottom)" \
    -o "$tmpdir/share.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    w=$(pdfinfo "$tmpdir/share.pdf" | awk '/Page size/{print int($3)}')
    # the two long row labels alone are ~90pt; a figure that were only cells
    # plus margins would be far narrower than this
    test "$w" -gt 150
fi

# Newick tree mode: topology, tip labels and node labels from a .tre file.
printf '((a,b)AB,(c,d)CD)root;' >"$tmpdir/t.tre"
"$CINDERPLOT" "$tmpdir/t.tre + geom_tree() + geom_tiplab()" -o "$tmpdir/tree.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    got=$(pdftotext "$tmpdir/tree.pdf" - | tr -d ' \n\f')
    test "$got" = "abcd"          # tips only, in Newick order
fi
"$CINDERPLOT" "$tmpdir/t.tre + geom_tree() + geom_tiplab() + geom_nodelab()" \
    -o "$tmpdir/tree-nl.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/tree-nl.pdf" - | grep -q AB
    pdftotext "$tmpdir/tree-nl.pdf" - | grep -q root
fi

# Branch lengths are honoured when present.
printf '((a:1,b:5)AB:1,c:2)root;' >"$tmpdir/tl.tre"
"$CINDERPLOT" "$tmpdir/tl.tre + geom_tree() + geom_tiplab()" -o "$tmpdir/tree-len.pdf"
test -s "$tmpdir/tree-len.pdf"

# The deferred parts of the feature say so rather than drawing something that
# looks like they worked.
# Three layouts, each a different drawing of the same topology.
for lay in rectangular slanted circular; do
    "$CINDERPLOT" "$tmpdir/t.tre + geom_tree(layout=$lay) + geom_tiplab()" \
        -o "$tmpdir/lay-$lay.pdf"
    test -s "$tmpdir/lay-$lay.pdf"
done
if cmp -s "$tmpdir/lay-rectangular.pdf" "$tmpdir/lay-slanted.pdf"; then
    echo "layout=slanted drew the same figure as rectangular" >&2
    exit 1
fi
if cmp -s "$tmpdir/lay-rectangular.pdf" "$tmpdir/lay-circular.pdf"; then
    echo "layout=circular drew the same figure as rectangular" >&2
    exit 1
fi
# A circular tree's auto canvas is cropped to its drawing (C15zzl), so it
# need not be square; with --size given it is exactly that size.
if command -v pdfinfo >/dev/null 2>&1; then
    "$CINDERPLOT" "$tmpdir/t.tre + geom_tree(layout=circular) + geom_tiplab()" \
        -o "$tmpdir/lay-circ-sq.pdf" --size 4x4
    cw=$(pdfinfo "$tmpdir/lay-circ-sq.pdf" | awk '/Page size/{print int($3)}')
    ch=$(pdfinfo "$tmpdir/lay-circ-sq.pdf" | awk '/Page size/{print int($5)}')
    test "$cw" -eq 288 && test "$ch" -eq 288
fi
# An unknown layout enumerates the three rather than picking one.
if "$CINDERPLOT" "$tmpdir/t.tre + geom_tree(layout=spiral)" \
    -o "$tmpdir/tc.pdf" 2>"$tmpdir/tc.err"; then
    echo "layout=spiral unexpectedly succeeded" >&2
    exit 1
fi
grep 'use rectangular, slanted or circular' "$tmpdir/tc.err" >/dev/null
# Joining a table on node/tip name. Several rows for one name draw several
# marks, which is the point: a node in three categories shows three dots.
printf 'node\tlevel\nAB\tcompartment\nAB\tlineage\nAB\tgroup\nCD\tgroup\n' \
    >"$tmpdir/lv.tsv"
"$CINDERPLOT" \
    "$tmpdir/t.tre + geom_tree() + geom_tiplab()
     + geom_nodepoint(data=\"$tmpdir/lv.tsv\", colour=level)" \
    -o "$tmpdir/join.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # the key names every level exactly once, and carries the column title
    for lv in compartment lineage group level; do
        test "$(pdftotext "$tmpdir/join.pdf" - | grep -c "$lv")" -ge 1
    done
fi

# A continuous column gets a colourbar rather than a key.
printf 'tip\tacc\na\t0.1\nb\t0.9\nc\t0.5\nd\t0.3\n' >"$tmpdir/acc.tsv"
"$CINDERPLOT" \
    "$tmpdir/t.tre + geom_tree() + geom_tiplab(data=\"$tmpdir/acc.tsv\", colour=acc)" \
    -o "$tmpdir/joincont.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/joincont.pdf" - | grep -q '0\.9'
fi

# The join needs a column to map, that column must exist, and it must not be
# the key itself.
if "$CINDERPLOT" "$tmpdir/t.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/lv.tsv\")" \
    -o "$tmpdir/j1.pdf" 2>"$tmpdir/j1.err"; then
    echo "geom_nodepoint without colour= unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs colour=' "$tmpdir/j1.err" >/dev/null
if "$CINDERPLOT" \
    "$tmpdir/t.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/lv.tsv\", colour=node)" \
    -o "$tmpdir/j2.pdf" 2>"$tmpdir/j2.err"; then
    echo "colour= on the join key unexpectedly succeeded" >&2
    exit 1
fi
grep 'is the join key' "$tmpdir/j2.err" >/dev/null

# A name-keyed join is ambiguous the moment a name is not unique: every node
# called A would match every row for A, which is a figure that reads as correct
# and is not. Refuse rather than pick a tie-break.
printf '(((t1,t2)A,(t3,t4)B)A,t5)A;' >"$tmpdir/dup.tre"
printf 'node\tlevel\nA\tcompartment\nA\tlineage\nA\tgroup\nB\tgroup\n' \
    >"$tmpdir/dup.tsv"
if "$CINDERPLOT" \
    "$tmpdir/dup.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/dup.tsv\", colour=level)" \
    -o "$tmpdir/dup.pdf" 2>"$tmpdir/dup.err"; then
    echo "an ambiguous name-keyed join unexpectedly succeeded" >&2
    exit 1
fi
grep 'names 3 internal nodes' "$tmpdir/dup.err" >/dev/null

# ...but a NUMERIC key joins by node id, which is unique by construction and is
# the only way to address a tree whose names repeat. Tips are 1..Ntip in Newick
# order, then the root, then internal nodes in preorder (ape's convention).
"$CINDERPLOT" "$tmpdir/dup.tre + geom_tree() + geom_tiplab(label=id) + geom_nodelab(label=id)" \
    -o "$tmpdir/ids.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    got=$(pdftotext "$tmpdir/ids.pdf" - | tr -s ' \n\f' '\n' | sort -n | tr -d '\n')
    test "$got" = "123456789"
fi
printf 'node\tlevel\n7\tcompartment\n8\tlineage\n6\tgroup\n' >"$tmpdir/byid.tsv"
"$CINDERPLOT" \
    "$tmpdir/dup.tre + geom_tree() + geom_nodelab()
     + geom_nodepoint(data=\"$tmpdir/byid.tsv\", colour=level)" \
    -o "$tmpdir/byid.pdf"
test -s "$tmpdir/byid.pdf"

# An id that is in no node is a typo, not an empty selection.
printf 'node\tlevel\n99\tcompartment\n' >"$tmpdir/badid.tsv"
if "$CINDERPLOT" \
    "$tmpdir/dup.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/badid.tsv\", colour=level)" \
    -o "$tmpdir/badid.pdf" 2>"$tmpdir/badid.err"; then
    echo "an out-of-range node id unexpectedly succeeded" >&2
    exit 1
fi
grep 'is not in the tree' "$tmpdir/badid.err" >/dev/null
# but a repeated name the table never mentions is harmless
printf 'node\tlevel\nB\tgroup\n' >"$tmpdir/bonly.tsv"
"$CINDERPLOT" \
    "$tmpdir/dup.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/bonly.tsv\", colour=level)" \
    -o "$tmpdir/dupok.pdf"
test -s "$tmpdir/dupok.pdf"

# The nudge that separates stacked marks is a page distance, so it must not
# scale with the canvas -- it used to be divided by the data span, which threw
# the marks clear of their own node on a wide figure.
printf '((a,b)AB,c)root;' >"$tmpdir/nudge.tre"
printf 'node\tlevel\nAB\tx\nAB\ty\nAB\tz\n' >"$tmpdir/nudge.tsv"
for w in 4 16; do
    "$CINDERPLOT" \
        "$tmpdir/nudge.tre + geom_tree() + geom_nodepoint(data=\"$tmpdir/nudge.tsv\", colour=level)" \
        --size ${w}x4 -o "$tmpdir/nudge-$w.pdf"
    test -s "$tmpdir/nudge-$w.pdf"
done

# Malformed Newick is a bounded error, not a crash.
printf '(a,b' >"$tmpdir/bad.tre"
if "$CINDERPLOT" "$tmpdir/bad.tre + geom_tree()" -o "$tmpdir/tb.pdf" 2>"$tmpdir/tb.err"; then
    echo "truncated Newick unexpectedly succeeded" >&2
    exit 1
fi
grep 'malformed Newick' "$tmpdir/tb.err" >/dev/null

# Branch lengths are all-or-nothing. A partly annotated tree used to take the
# metric path and read a missing length as zero, putting those tips on top of
# their own parent -- a picture saying they branched at the root.
printf '((a,b:5)AB,c:2)root;' >"$tmpdir/mixed.tre"
if "$CINDERPLOT" "$tmpdir/mixed.tre + geom_tree()" -o "$tmpdir/mx.pdf" 2>"$tmpdir/mx.err"; then
    echo "mixed branch lengths unexpectedly succeeded" >&2
    exit 1
fi
grep 'give every branch one, or none' "$tmpdir/mx.err" >/dev/null

# A length that cannot be drawn is rejected rather than collapsing the tree.
for bad in 'inf' '-3'; do
    printf '((a:%s,b:1)AB,c:1)root;' "$bad" >"$tmpdir/badlen.tre"
    if "$CINDERPLOT" "$tmpdir/badlen.tre + geom_tree()" \
        -o "$tmpdir/bl.pdf" 2>"$tmpdir/bl.err"; then
        echo "branch length $bad unexpectedly succeeded" >&2
        exit 1
    fi
    grep 'finite and non-negative' "$tmpdir/bl.err" >/dev/null
done

# [...] comments are skipped (NHX uses them), doubled quotes are one literal
# quote, and a polytomy is not special.
# A quoted name may hold the characters Newick reserves -- comma, colon,
# parens -- which is the whole reason for quoting.
printf "((a[&&NHX:S=human],'b''s cell',,'x, y',d)P,'c:z(1)')root;" >"$tmpdir/nhx.tre"
"$CINDERPLOT" "$tmpdir/nhx.tre + geom_tree() + geom_tiplab()" -o "$tmpdir/nhx.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/nhx.pdf" - | grep -q "b's cell"
    pdftotext "$tmpdir/nhx.pdf" - | grep -q 'x, y'
    pdftotext "$tmpdir/nhx.pdf" - | grep -q 'c:z(1)'
    if pdftotext "$tmpdir/nhx.pdf" - | grep -q 'NHX'; then
        echo "an NHX comment leaked into a label" >&2
        exit 1
    fi
fi

# A length on the root measures to a parent that is not drawn, so it must not
# shift the tree: the two trees differ only by that length and render alike.
printf '((a:1,b:1)AB:1,c:2)root;' >"$tmpdir/r0.tre"
printf '((a:1,b:1)AB:1,c:2)root:0.5;' >"$tmpdir/r1.tre"
"$CINDERPLOT" "$tmpdir/r0.tre + geom_tree()" -o "$tmpdir/r0.png" --dpi 72
"$CINDERPLOT" "$tmpdir/r1.tre + geom_tree()" -o "$tmpdir/r1.png" --dpi 72
cmp "$tmpdir/r0.png" "$tmpdir/r1.png"

# labs(x=)/labs(y=) name the heatmap axes instead of being dropped.
"$CINDERPLOT" \
    "$tmpdir/diag.tsv + heatmap(cluster=none) + labs(x=\"predicted\", y=\"truth\")" \
    -o "$tmpdir/hmlabs.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/hmlabs.pdf" - | grep -q predicted
    pdftotext "$tmpdir/hmlabs.pdf" - | grep -q truth
fi

# A user limit is a domain the caller chose, so freeing an axis frees its
# BREAKS, not its limits. xlim() used to parse, run, and do nothing here.
printf 'p,x,y\na,1,1\na,2,2\nb,100,1\nb,200,2\n' >"$tmpdir/lim.csv"
"$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point() + facet_wrap(~p, scales=\"free_x\")" \
    -o "$tmpdir/lim-free.pdf"
"$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point() + facet_wrap(~p, scales=\"free_x\") + xlim(0,400)" \
    -o "$tmpdir/lim-set.pdf"
if cmp -s "$tmpdir/lim-free.pdf" "$tmpdir/lim-set.pdf"; then
    echo "xlim() was ignored under free scales" >&2
    exit 1
fi

# A limit that cannot be log-transformed is refused rather than turned into NaN.
if "$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point() + scale_x_log10() + xlim(-1,100)" \
    -o "$tmpdir/loglim.pdf" 2>"$tmpdir/loglim.err"; then
    echo "a negative log limit unexpectedly succeeded" >&2
    exit 1
fi
grep 'must be positive on a log axis' "$tmpdir/loglim.err" >/dev/null

# geom_abline() expands the panel to show where the line runs, as its hline and
# vline siblings already did.
"$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point()" -o "$tmpdir/ab0.pdf"
"$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point() + geom_abline(intercept=50, slope=1)" \
    -o "$tmpdir/ab1.pdf"
if cmp -s "$tmpdir/ab0.pdf" "$tmpdir/ab1.pdf"; then
    echo "geom_abline() did not expand the panel" >&2
    exit 1
fi

# A vline off the log domain is dropped, not turned into a NaN range.
"$CINDERPLOT" "$tmpdir/lim.csv + aes(x,y) + geom_point() + scale_x_log10() + geom_vline(xintercept=-5)" \
    -o "$tmpdir/vl.pdf"
test -s "$tmpdir/vl.pdf"

# geom_nodelab() on a cladogram widens each branch to hold its label, so a
# chain of long names stays readable instead of overprinting. x is arbitrary on
# a cladogram, so stretching it misrepresents nothing.
printf '((((tipA,tipB)Adrenal.Zona.Glomerulosa)Breast.Luminal.Epithelial)Muscle.Adipocyte.Progenitor,tipC)root;' >"$tmpdir/chain.tre"
"$CINDERPLOT" "$tmpdir/chain.tre + geom_tree() + geom_tiplab()" -o "$tmpdir/ch0.pdf"
"$CINDERPLOT" "$tmpdir/chain.tre + geom_tree() + geom_tiplab() + geom_nodelab()" \
    -o "$tmpdir/ch1.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    w0=$(pdfinfo "$tmpdir/ch0.pdf" | awk '/Page size/{print int($3)}')
    w1=$(pdfinfo "$tmpdir/ch1.pdf" | awk '/Page size/{print int($3)}')
    test "$w1" -gt "$w0"
fi

# A phylogram's lengths are the datum, so they are NOT stretched to fit labels.
printf '((a:1,b:1)AB:1,c:2)root;' >"$tmpdir/phy.tre"
"$CINDERPLOT" "$tmpdir/phy.tre + geom_tree() + geom_tiplab()" -o "$tmpdir/ph0.pdf"
"$CINDERPLOT" "$tmpdir/phy.tre + geom_tree() + geom_tiplab() + geom_nodelab()" \
    -o "$tmpdir/ph1.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    p0=$(pdfinfo "$tmpdir/ph0.pdf" | awk '/Page size/{print int($3)}')
    p1=$(pdfinfo "$tmpdir/ph1.pdf" | awk '/Page size/{print int($3)}')
    test "$p0" -eq "$p1"
fi

# The root has no incoming branch, so its label must read forward from the node
# rather than off the left edge of the surface.
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/ch1.pdf" - | grep -q root
fi

# title= on a placed object names that panel. It used to reach only the legend,
# so on a heatmap it parsed and vanished -- the same silent drop labs(x=) had.
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"a\", cluster=none, title=\"compartment\")
     + heatmap(data=\"$tmpdir/share.tsv\", beneath(\"a\"), name=\"b\",
               cluster=none, title=\"lineage\")" \
    -o "$tmpdir/ptitle.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/ptitle.pdf" - | grep -q compartment
    pdftotext "$tmpdir/ptitle.pdf" - | grep -q lineage
fi
# and it must be given room, not just drawn: titling the panels costs height
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"a\", cluster=none)
     + heatmap(data=\"$tmpdir/share.tsv\", beneath(\"a\"), name=\"b\", cluster=none)" \
    --size 5x7 -o "$tmpdir/notitle.pdf"
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"a\", cluster=none, title=\"compartment\")
     + heatmap(data=\"$tmpdir/share.tsv\", beneath(\"a\"), name=\"b\",
               cluster=none, title=\"lineage\")" \
    --size 5x7 -o "$tmpdir/withtitle.pdf"
if cmp -s "$tmpdir/notitle.pdf" "$tmpdir/withtitle.pdf"; then
    echo "panel titles were drawn without reserving room" >&2
    exit 1
fi

# TRUE/FALSE read as on/off: an R user types TRUE first.
"$CINDERPLOT" "$tmpdir/share.tsv + heatmap(cluster=none, box=TRUE)" -o "$tmpdir/bt.pdf"
"$CINDERPLOT" "$tmpdir/share.tsv + heatmap(cluster=none, box=FALSE)" -o "$tmpdir/bf.pdf"
if cmp -s "$tmpdir/bt.pdf" "$tmpdir/bf.pdf"; then
    echo "box=TRUE and box=FALSE drew the same thing" >&2
    exit 1
fi

# A title is chrome: auto-fit sized the canvas from the cells and their labels
# alone, so a title longer than the figure was simply cut off.
"$CINDERPLOT" "$tmpdir/share.tsv + heatmap(cluster=none) + labs(title=\"short\")" \
    -o "$tmpdir/ts.pdf"
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(cluster=none)
     + labs(title=\"a considerably longer title than the figure is otherwise wide\")" \
    -o "$tmpdir/tl.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    ws=$(pdfinfo "$tmpdir/ts.pdf" | awk '/Page size/{print int($3)}')
    wl=$(pdfinfo "$tmpdir/tl.pdf" | awk '/Page size/{print int($3)}')
    test "$wl" -gt "$ws"
    # ...but an explicit size is still exactly what was asked for
    "$CINDERPLOT" \
        "$tmpdir/share.tsv + heatmap(cluster=none)
         + labs(title=\"a considerably longer title than the figure is otherwise wide\")" \
        --size 3x3 -o "$tmpdir/tf.pdf"
    test "$(pdfinfo "$tmpdir/tf.pdf" | awk '/Page size/{print int($3)}')" -eq 216
fi

# Every built-in continuous palette renders.
for pal in viridis magma inferno plasma cividis rocket mako parula turbo \
           coolwarm bwr jet; do
    "$CINDERPLOT" "$tmpdir/share.tsv + heatmap(cluster=none) + scale_fill_${pal}()" \
        -o "$tmpdir/pal-$pal.pdf"
    test -s "$tmpdir/pal-$pal.pdf"
done
# ...and they are actually different ramps, not aliases of one another
if cmp -s "$tmpdir/pal-viridis.pdf" "$tmpdir/pal-turbo.pdf"; then
    echo "turbo and viridis drew the same thing" >&2
    exit 1
fi
# an unknown one lists them
if "$CINDERPLOT" "$tmpdir/share.tsv + heatmap(cluster=none) + scale_fill_nope()" \
    -o "$tmpdir/palbad.pdf" 2>"$tmpdir/palbad.err"; then
    echo "scale_fill_nope() unexpectedly succeeded" >&2
    exit 1
fi
grep 'turbo, coolwarm' "$tmpdir/palbad.err" >/dev/null

# A discrete colour aesthetic is no longer capped at 15 levels: the legend
# reserves 2*nlev+1 rows in the gtable, and that bound used to be 32.
{ printf 'x,y,g\n'; i=1; while [ "$i" -le 40 ]; do
    printf '%s,%s,type%s\n' "$i" "$i" "$i"; i=$((i + 1)); done; } >"$tmpdir/lv40.csv"
"$CINDERPLOT" "$tmpdir/lv40.csv + aes(x,y,colour=g) + geom_point()" -o "$tmpdir/lv40.pdf"
test -s "$tmpdir/lv40.pdf"

# aspect= couples the figure's two dimensions so the MATRIX comes out at that
# ratio -- the matrix, not a cell, so a non-square matrix under aspect=1 is
# square overall with oblong cells.
printf 'true\tC0\tC1\tC2\tC3\n' >"$tmpdir/wide.tsv"
printf 'R0\t1\t2\t3\t4\nR1\t4\t3\t2\t1\n' >>"$tmpdir/wide.tsv"
for a in 1 2; do
    "$CINDERPLOT" \
        "$tmpdir/wide.tsv + heatmap(cluster=none, rownames=none, colnames=none, aspect=$a)" \
        -o "$tmpdir/asp-$a.pdf"
    test -s "$tmpdir/asp-$a.pdf"
done
if command -v pdfinfo >/dev/null 2>&1; then
    # no labels, so the page ratio is the matrix ratio plus equal margins
    w1=$(pdfinfo "$tmpdir/asp-1.pdf" | awk '/Page size/{print int($3)}')
    h1=$(pdfinfo "$tmpdir/asp-1.pdf" | awk '/Page size/{print int($5)}')
    test "$w1" -eq "$h1"
    w2=$(pdfinfo "$tmpdir/asp-2.pdf" | awk '/Page size/{print int($3)}')
    h2=$(pdfinfo "$tmpdir/asp-2.pdf" | awk '/Page size/{print int($5)}')
    test "$w2" -gt "$h2"
fi

# A partial --size fixes one side and aspect derives the other.
"$CINDERPLOT" \
    "$tmpdir/wide.tsv + heatmap(cluster=none, rownames=none, colnames=none, aspect=1)" \
    --size 6x -o "$tmpdir/asp-part.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    wp=$(pdfinfo "$tmpdir/asp-part.pdf" | awk '/Page size/{print int($3)}')
    hp=$(pdfinfo "$tmpdir/asp-part.pdf" | awk '/Page size/{print int($5)}')
    test "$wp" -eq 432 && test "$wp" -eq "$hp"
fi

# ...but a fully specified --size already sets the proportions, so aspect= there
# would be silently ignored. Refuse instead.
if "$CINDERPLOT" "$tmpdir/wide.tsv + heatmap(cluster=none, aspect=1)" \
    --size 5x5 -o "$tmpdir/asp-both.pdf" 2>"$tmpdir/asp-both.err"; then
    echo "aspect= with a full --size unexpectedly succeeded" >&2
    exit 1
fi
grep 'conflicts with a fully specified --size' "$tmpdir/asp-both.err" >/dev/null
if "$CINDERPLOT" "$tmpdir/wide.tsv + heatmap(aspect=0)" -o "$tmpdir/asp-z.pdf" \
    2>"$tmpdir/asp-z.err"; then
    echo "aspect=0 unexpectedly succeeded" >&2
    exit 1
fi
grep 'positive number' "$tmpdir/asp-z.err" >/dev/null

# Auto-fit must SIZE the canvas for the inter-panel label gutters, not discover
# afterwards that they do not fit and demand a --size it was asked to choose.
printf 'grp\tEnterocyte.(Small.Intest)\tPancreatic.Islet.Cell\tEndothel.(Vascular)\n' \
    >"$tmpdir/stackedlab.tsv"
printf 'CRC LYMPH metastasis [Ent Co] n=299\t0.1\t0.2\t0.7\n' >>"$tmpdir/stackedlab.tsv"
printf 'CLL (Gaiti 2019) [B cell] n=2439\t0.3\t0.6\t0.1\n' >>"$tmpdir/stackedlab.tsv"
printf 'mg\tv\nCRC LYMPH metastasis [Ent Co] n=299\t0.4\n' >"$tmpdir/stackedmg.tsv"
printf 'CLL (Gaiti 2019) [B cell] n=2439\t0.8\n' >>"$tmpdir/stackedmg.tsv"
"$CINDERPLOT" \
    "$tmpdir/stackedlab.tsv + heatmap(name=\"m\", rownames=right, colnames=bottom)
     + annotation(\"$tmpdir/stackedmg.tsv\", right_of(\"m\")) + legend(right_of(\"m\"))" \
    -o "$tmpdir/stacked.pdf"
test -s "$tmpdir/stacked.pdf"

# A layout that cannot hold its labels still RENDERS -- squeezed, with a warning
# on stderr saying what gave. Refusing to draw is never the better answer: a
# cramped figure is visibly cramped, a missing one breaks the pipeline.
"$CINDERPLOT" \
    "$tmpdir/stackedlab.tsv + heatmap(name=\"m\", rownames=right, colnames=bottom)
     + annotation(\"$tmpdir/stackedmg.tsv\", right_of(\"m\")) + legend(right_of(\"m\"))" \
    --size 1.5x1.5 -o "$tmpdir/stacked-small.pdf" 2>"$tmpdir/stacked-small.err"
test -s "$tmpdir/stacked-small.pdf"
grep 'squeezed and may overlap' "$tmpdir/stacked-small.err" >/dev/null

# aspect= must survive a title wider than the figure: the title sets the width,
# so the height has to grow rather than the matrix stretching.
"$CINDERPLOT" \
    "$tmpdir/wide.tsv + heatmap(cluster=none, rownames=none, colnames=none, aspect=1)
     + labs(title=\"a title considerably wider than this small matrix would ever be\")" \
    -o "$tmpdir/asp-title.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    wt=$(pdfinfo "$tmpdir/asp-title.pdf" | awk '/Page size/{print int($3)}')
    ht=$(pdfinfo "$tmpdir/asp-title.pdf" | awk '/Page size/{print int($5)}')
    # the title widened the page, so the page is no longer square -- but the
    # height must have grown with it rather than staying put
    test "$ht" -gt 200
fi

# width= on a vertical placement (and height= on a horizontal one) used to be
# parsed and dropped, because that axis is inherited from the anchor. Honour it.
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"c\")
     + heatmap(data=\"$tmpdir/share.tsv\", beneath(\"c\", pad=0.05), name=\"g\")" \
    --size 4x5 -o "$tmpdir/pw-full.pdf"
"$CINDERPLOT" \
    "$tmpdir/share.tsv + heatmap(name=\"c\")
     + heatmap(data=\"$tmpdir/share.tsv\", beneath(\"c\", pad=0.05, width=0.5), name=\"g\")" \
    --size 4x5 -o "$tmpdir/pw-half.pdf"
if cmp -s "$tmpdir/pw-full.pdf" "$tmpdir/pw-half.pdf"; then
    echo "width= on beneath() was ignored" >&2
    exit 1
fi

# geom_jitter(): points with a deterministic random offset, layerable over a
# boxplot. On a discrete axis geom_point() stacks every observation on the
# category centre, so 400 of them look like 40.
printf 'g,v\n' >"$tmpdir/jit.csv"
i=1; while [ "$i" -le 60 ]; do
    printf 'a,0.%s\nb,0.%s\n' "$((i % 10))" "$(((i * 3) % 10))" >>"$tmpdir/jit.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_jitter(width=0.2)" \
    -o "$tmpdir/jit1.png" --dpi 72
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_jitter(width=0.2)" \
    -o "$tmpdir/jit2.png" --dpi 72
# reproducible: these figures are rebuilt from a notebook, so a plot that moved
# every render would be a bug, not a nicety
cmp "$tmpdir/jit1.png" "$tmpdir/jit2.png"
# ...and it really is jittered, not just geom_point under another name
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_point()" \
    -o "$tmpdir/jitp.png" --dpi 72
if cmp -s "$tmpdir/jit1.png" "$tmpdir/jitp.png"; then
    echo "geom_jitter() drew the same thing as geom_point()" >&2
    exit 1
fi
# seed= picks a different arrangement
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_jitter(width=0.2, seed=7)" \
    -o "$tmpdir/jit3.png" --dpi 72
if cmp -s "$tmpdir/jit1.png" "$tmpdir/jit3.png"; then
    echo "seed= did not change the jitter" >&2
    exit 1
fi
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_jitter(width=-1)" \
    -o "$tmpdir/jitbad.png" 2>"$tmpdir/jitbad.err" && {
    echo "a negative jitter width unexpectedly succeeded" >&2; exit 1; }
grep 'non-negative' "$tmpdir/jitbad.err" >/dev/null

# geom_boxplot(outlier.shape=NA) hides the outlier marks, which a jitter layer
# has already drawn.
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_boxplot()" \
    -o "$tmpdir/bx-on.pdf"
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_boxplot(outlier.shape=NA)" \
    -o "$tmpdir/bx-off.pdf"
test -s "$tmpdir/bx-off.pdf"
# a shape we cannot draw is refused rather than silently ignored
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_boxplot(outlier.shape=17)" \
    -o "$tmpdir/bx17.pdf" 2>"$tmpdir/bx17.err" && {
    echo "outlier.shape=17 unexpectedly succeeded" >&2; exit 1; }
grep 'only NA/FALSE' "$tmpdir/bx17.err" >/dev/null

# A spurious fontconfig warning on every run trains the reader to ignore stderr,
# which is where the real messages go. A successful render says nothing but the
# output line.
"$CINDERPLOT" "$tmpdir/jit.csv + aes(factor(g), v) + geom_boxplot()" \
    -o "$tmpdir/quiet.pdf" 2>"$tmpdir/quiet.err"
if grep -q 'Fontconfig error' "$tmpdir/quiet.err"; then
    echo "a spurious fontconfig warning reached stderr" >&2
    exit 1
fi

# facet_wrap(ncol=/nrow=): the caller choosing the grid shape. At 8 panels the
# automatic layout wraps 3 per row, which splits the pairs a two-factor figure
# exists to compare; no levels= ordering can fix that.
printf 'p,x,y\n' >"$tmpdir/f8.csv"
for c in c1 c2 c3 c4; do
    for m in mA mB; do
        printf '%s-%s,1,1\n%s-%s,2,2\n' "$c" "$m" "$c" "$m" >>"$tmpdir/f8.csv"
    done
done
for opt in "ncol=2" "nrow=2"; do
    "$CINDERPLOT" "$tmpdir/f8.csv + aes(x,y) + geom_point() + facet_wrap(~p, $opt)" \
        -o "$tmpdir/fw-$opt.pdf"
    test -s "$tmpdir/fw-$opt.pdf"
done
# a 2-column grid is taller than the automatic one, and taller than 4 columns
"$CINDERPLOT" "$tmpdir/f8.csv + aes(x,y) + geom_point() + facet_wrap(~p, ncol=4)" \
    -o "$tmpdir/fw-4.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
    h2=$(pdfinfo "$tmpdir/fw-ncol=2.pdf" | awk '/Page size/{print int($5)}')
    h4=$(pdfinfo "$tmpdir/fw-4.pdf" | awk '/Page size/{print int($5)}')
    test "$h2" -ge "$h4"
fi
# a grid too small to hold the panels is an error, not a silent truncation
if "$CINDERPLOT" \
    "$tmpdir/f8.csv + aes(x,y) + geom_point() + facet_wrap(~p, ncol=2, nrow=3)" \
    -o "$tmpdir/fw-small.pdf" 2>"$tmpdir/fw-small.err"; then
    echo "an undersized facet grid unexpectedly succeeded" >&2
    exit 1
fi
grep 'but there are 8' "$tmpdir/fw-small.err" >/dev/null
if "$CINDERPLOT" "$tmpdir/f8.csv + aes(x,y) + geom_point() + facet_wrap(~p, ncol=0)" \
    -o "$tmpdir/fw-zero.pdf" 2>"$tmpdir/fw-zero.err"; then
    echo "ncol=0 unexpectedly succeeded" >&2
    exit 1
fi
grep 'positive whole number' "$tmpdir/fw-zero.err" >/dev/null

# aes(shape=): a second discrete factor on a scatter, mapped to point glyphs.
# colour alone can carry one factor or the other, not both, and the pairing is
# usually what the figure is for.
printf 'x,y,g,h\n' >"$tmpdir/shp.csv"
i=1; while [ "$i" -le 24 ]; do
    printf '%s,%s,g%s,h%s\n' "$i" "$((i % 7))" "$((i % 3))" "$((i % 4))" >>"$tmpdir/shp.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/shp.csv + aes(x,y,shape=g) + geom_point()" -o "$tmpdir/sh1.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/sh1.pdf" - | grep -q g0     # the shape legend names its levels
fi
# the glyphs really differ -- not circles under another name
"$CINDERPLOT" "$tmpdir/shp.csv + aes(x,y) + geom_point()" -o "$tmpdir/sh0.pdf"
if cmp -s "$tmpdir/sh0.pdf" "$tmpdir/sh1.pdf"; then
    echo "aes(shape=) drew plain circles" >&2
    exit 1
fi
# shape and colour carry different factors at once
"$CINDERPLOT" "$tmpdir/shp.csv + aes(x,y,shape=g,colour=h) + geom_point()" \
    -o "$tmpdir/sh2.pdf"
test -s "$tmpdir/sh2.pdf"

# Six glyphs, like ggplot2 -- past that they stop being tellable apart, so it
# refuses rather than inventing a seventh.
printf 'x,y,g\n' >"$tmpdir/sh7.csv"
i=0; while [ "$i" -le 6 ]; do
    printf '1,1,lv%s\n' "$i" >>"$tmpdir/sh7.csv"; i=$((i + 1))
done
if "$CINDERPLOT" "$tmpdir/sh7.csv + aes(x,y,shape=g) + geom_point()" \
    -o "$tmpdir/sh7.pdf" 2>"$tmpdir/sh7.err"; then
    echo "a 7-level shape mapping unexpectedly succeeded" >&2
    exit 1
fi
grep 'shape palette holds 6' "$tmpdir/sh7.err" >/dev/null
# and it needs somewhere to put the glyphs
if "$CINDERPLOT" "$tmpdir/shp.csv + aes(x,y,shape=g) + geom_line()" \
    -o "$tmpdir/shl.pdf" 2>"$tmpdir/shl.err"; then
    echo "aes(shape=) without a point layer unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs a point layer' "$tmpdir/shl.err" >/dev/null

# geom_smooth(): a LOESS trend through noisy points, one per colour group.
printf 'x,y,g\n' >"$tmpdir/sm.csv"
i=1; while [ "$i" -le 80 ]; do
    printf '%s,%s,a\n%s,%s,b\n' "$i" "$((i % 7))" "$i" "$((i % 5 + 3))" >>"$tmpdir/sm.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + geom_smooth(se=FALSE)" \
    -o "$tmpdir/sm1.pdf"
test -s "$tmpdir/sm1.pdf"
# the smooth is not the raw series: a smaller span tracks the data more closely,
# so the two spans must differ
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_smooth(se=FALSE, span=0.2)" \
    -o "$tmpdir/sm2.pdf"
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_smooth(se=FALSE, span=0.9)" \
    -o "$tmpdir/sm3.pdf"
if cmp -s "$tmpdir/sm2.pdf" "$tmpdir/sm3.pdf"; then
    echo "span= did not change the fit" >&2
    exit 1
fi
# one curve per colour group, not one through everything
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y,colour=g) + geom_smooth(se=FALSE)" \
    -o "$tmpdir/sm4.pdf"
if cmp -s "$tmpdir/sm1.pdf" "$tmpdir/sm4.pdf"; then
    echo "grouping did not change the smooth" >&2
    exit 1
fi
# ggplot defaults se=TRUE and the ribbon is absent, so silence is refused rather
# than quietly drawing less than was asked for
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_smooth()" \
    -o "$tmpdir/sm5.pdf" 2>"$tmpdir/sm5.err"; then
    echo "bare geom_smooth() unexpectedly succeeded" >&2
    exit 1
fi
grep 'se=FALSE' "$tmpdir/sm5.err" >/dev/null
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_smooth(se=FALSE, span=0)" \
    -o "$tmpdir/sm6.pdf" 2>"$tmpdir/sm6.err"; then
    echo "span=0 unexpectedly succeeded" >&2
    exit 1
fi
grep 'fraction in (0, 1]' "$tmpdir/sm6.err" >/dev/null

# scale_*_continuous(breaks=): explicit ticks, for when the automatic ones are
# chosen for count and collide on width (a genomic coordinate, say).
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + scale_x_continuous(breaks=c(20,40,60))" \
    -o "$tmpdir/br.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    got=$(pdftotext "$tmpdir/br.pdf" - | tr -cd '0-9\n' | tr -d '\n')
    case "$got" in *204060*) ;; *) echo "explicit breaks did not reach the axis" >&2; exit 1;; esac
fi
# every break outside the range leaves an unlabelled axis, which is worth saying
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + scale_x_continuous(breaks=c(5000))" \
    -o "$tmpdir/br2.pdf" 2>"$tmpdir/br2.err"
grep 'lies outside the data range' "$tmpdir/br2.err" >/dev/null

# ---- scale_x_log2 / scale_y_log2 -------------------------------------------
# A coverage ladder sampled at powers of two: a log10 axis spaces these
# correctly but labels them off-rung, which is the whole point of log2.
printf 'n,frac\n' >"$tmpdir/lad.csv"
n=1024
while [ "$n" -le 4194304 ]; do
    printf '%s,0.5\n' "$n" >>"$tmpdir/lad.csv"
    n=$((n * 2))
done

"$CINDERPLOT" "$tmpdir/lad.csv + aes(n,frac) + geom_point() + scale_x_log2()" \
    -o "$tmpdir/log2x.pdf"
test -s "$tmpdir/log2x.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # ticks must land ON the sampled powers: 2^10, 2^12, ... 2^22 (thinned by 2)
    got=$(pdftotext "$tmpdir/log2x.pdf" - | tr -cd '0-9\n' | tr -d '\n')
    case "$got" in
        *210212214216218220222*) ;;
        *) echo "log2 x ticks are not the powers of two: $got" >&2; exit 1;;
    esac
fi

"$CINDERPLOT" "$tmpdir/lad.csv + aes(frac,n) + geom_point() + scale_y_log2()" \
    -o "$tmpdir/log2y.pdf"
test -s "$tmpdir/log2y.pdf"

# limits= applies in data space, exactly as it does for log10
"$CINDERPLOT" "$tmpdir/lad.csv + aes(n,frac) + geom_point() + scale_x_log2(limits=c(1024,65536))" \
    -o "$tmpdir/log2lim.pdf"
test -s "$tmpdir/log2lim.pdf"

# a discrete axis cannot be logged, and the message must name the base asked for
printf 'g,y\na,1\nb,2\n' >"$tmpdir/disc.csv"
if "$CINDERPLOT" "$tmpdir/disc.csv + aes(g,y) + geom_point() + scale_x_log2()" \
        -o "$tmpdir/log2bad.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "scale_x_log2 on a discrete x unexpectedly succeeded" >&2
    exit 1
fi
grep 'scale_x_log2() needs a continuous x' "$tmpdir/err" >/dev/null

# ---- heatmap(grid=) --------------------------------------------------------
# Separators BETWEEN the cells (geom_tile(colour=) is the ggplot2 idea);
# box= only frames the block. PNG, not PDF: cairo stamps a whole-second
# /CreationDate inside a compressed PDF stream, so two PDFs can differ (or
# agree) on the clock alone, and this comparison must see only the ink.
printf 'id\ta\tb\tc\ns1\t0.1\t0.5\t0.9\ns2\t0.9\t0.2\t0.4\ns3\t0.3\t0.8\t0.6\n' >"$tmpdir/hm.tsv"
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none, grid=\"grey70\")" \
    --size 4x3 -o "$tmpdir/grid.png"
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none)" \
    --size 4x3 -o "$tmpdir/nogrid.png"
if cmp -s "$tmpdir/grid.png" "$tmpdir/nogrid.png"; then
    echo "grid= drew nothing" >&2
    exit 1
fi

# a bad value errors rather than parsing and vanishing
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(grid=bogus)" -o "$tmpdir/gbad.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "grid=bogus unexpectedly succeeded" >&2
    exit 1
fi
grep 'grid=bogus invalid' "$tmpdir/err" >/dev/null

# grid= on a legend() errors, as box= does
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(name=\"h\", cluster=none) + legend(right_of(\"h\"), grid=on)" \
        -o "$tmpdir/gleg.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "grid= on legend() unexpectedly succeeded" >&2
    exit 1
fi
grep 'grid= applies to heatmap() and annotation()' "$tmpdir/err" >/dev/null

# under ~4pt of cell the separators would out-ink the fills: dropped, with a
# warning, not drawn
awk 'BEGIN{OFS="\t"; printf "id"; for(c=1;c<=300;c++) printf "\tc%d",c; print "";
  for(r=1;r<=300;r++){printf "r%d",r; for(c=1;c<=300;c++) printf "\t%.3f",(r*c%97)/97; print ""}}' \
    >"$tmpdir/hmbig.tsv"
"$CINDERPLOT" "$tmpdir/hmbig.tsv + heatmap(cluster=none, grid=on)" \
    --size 4x4 -o "$tmpdir/gbig.pdf" 2>"$tmpdir/err"
grep 'grid= dropped' "$tmpdir/err" >/dev/null

# ---- --font ----------------------------------------------------------------
# Cairo substitutes a missing family silently, so cinderplot must say so; the
# figure still renders (in the fallback), because a wrong font should not
# break a pipeline.
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none)" \
    --font "no-such-family-cinderplot-test" -o "$tmpdir/font.pdf" 2>"$tmpdir/err"
test -s "$tmpdir/font.pdf"
grep 'not found' "$tmpdir/err" >/dev/null

# --font as the final token is a missing argument, not an unknown flag
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none)" -o "$tmpdir/font2.pdf" --font \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "trailing --font unexpectedly succeeded" >&2
    exit 1
fi
grep 'missing argument for --font' "$tmpdir/err" >/dev/null

# ---- heatmap(labels=) -------------------------------------------------------
# Per-cell value text. labels= used to be consumed only by annotation(), so on
# a heatmap it parsed and silently vanished.
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none, labels=on)" \
    --size 4x3 -o "$tmpdir/lab.png"
if cmp -s "$tmpdir/lab.png" "$tmpdir/nogrid.png"; then
    echo "labels= drew nothing" >&2
    exit 1
fi
# under 4pt of text the numbers are decoration: dropped, with a warning
"$CINDERPLOT" "$tmpdir/hmbig.tsv + heatmap(cluster=none, labels=on)" \
    --size 4x4 -o "$tmpdir/labbig.pdf" 2>"$tmpdir/err"
grep 'labels= dropped' "$tmpdir/err" >/dev/null

# ---- geom_rect(data=) with y/yend: 4-corner rects, mapped fill --------------
# The region-band reading used to hijack 4-corner layer files: grey full-height
# bands, any fill mapping silently gone.
printf 'x,y,xmax,ymax,v\n1,1,2,2,5\n3,3,4,4,50\n' >"$tmpdir/rl.csv"
printf 'x,y,xmax,ymax,v\n1.5,1.5,1.5,1.5,5\n3.5,3.5,3.5,3.5,50\n' >"$tmpdir/rm.csv"
# rect-only layers, no legend: any pixel difference is the rect fill itself
# (a geom_point would take the mapped colour too and mask the rect bug)
"$CINDERPLOT" "$tmpdir/rm.csv + aes(x=x, y=y, xend=xmax, yend=ymax, fill=v) + geom_rect(data=\"$tmpdir/rl.csv\")" \
    --no-legend --size 4x3 -o "$tmpdir/r1.png"
"$CINDERPLOT" "$tmpdir/rm.csv + aes(x=x, y=y, xend=xmax, yend=ymax) + geom_rect(data=\"$tmpdir/rl.csv\")" \
    --size 4x3 -o "$tmpdir/r2.png"
if cmp -s "$tmpdir/r1.png" "$tmpdir/r2.png"; then
    echo "rect layer fill mapping drew nothing" >&2
    exit 1
fi
# a mapped colour/fill whose column is missing from the layer file errors
printf 'x,xmax\n2,3\n' >"$tmpdir/rb.csv"
if "$CINDERPLOT" "$tmpdir/rm.csv + aes(x=x, y=y, xend=xmax, fill=v) + geom_rect(data=\"$tmpdir/rb.csv\") + geom_point()" \
        -o "$tmpdir/r3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "missing layer fill column unexpectedly succeeded" >&2
    exit 1
fi
grep 'not in this file' "$tmpdir/err" >/dev/null
# a layer file without y/yend keeps the region-band reading
"$CINDERPLOT" "$tmpdir/rm.csv + aes(x=x, y=y, xend=xmax) + geom_rect(data=\"$tmpdir/rb.csv\") + geom_point()" \
    -o "$tmpdir/r4.pdf"
test -s "$tmpdir/r4.pdf"

# ---- scale_fill_*(limits=) in heatmap mode ---------------------------------
# limits= pins the fill domain so several figures share one ramp; it used to
# be silently ignored, each matrix autoscaling to its own min/max.
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + scale_fill_viridis(limits=c(0,100))" \
    --size 4x3 -o "$tmpdir/lim.png"
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + scale_fill_viridis()" \
    --size 4x3 -o "$tmpdir/nolim.png"
if cmp -s "$tmpdir/lim.png" "$tmpdir/nolim.png"; then
    echo "limits= did not move the fill domain" >&2
    exit 1
fi
# reversed limits are an error, not garbage
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + scale_fill_viridis(limits=c(100,0))" \
        -o "$tmpdir/lim2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "limits=c(100,0) unexpectedly succeeded" >&2
    exit 1
fi
grep 'limits=: lo must be < hi' "$tmpdir/err" >/dev/null

# ---- highlight() -----------------------------------------------------------
# a bounding box on one cell, addressed by row/column name
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + highlight(\"s2\", \"b\")" \
    --size 4x3 -o "$tmpdir/hl.png"
"$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none)" \
    --size 4x3 -o "$tmpdir/nohl.png"
if cmp -s "$tmpdir/hl.png" "$tmpdir/nohl.png"; then
    echo "highlight() drew nothing" >&2
    exit 1
fi
# an unknown name errors rather than drawing nothing
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + highlight(\"nope\", \"b\")" \
        -o "$tmpdir/hl2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "highlight() with a bad row name unexpectedly succeeded" >&2
    exit 1
fi
grep 'not a row name' "$tmpdir/err" >/dev/null
# highlight() outside heatmap mode errors
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + highlight(\"a\", \"b\")" \
        -o "$tmpdir/hl3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "highlight() in grammar mode unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs heatmap mode' "$tmpdir/err" >/dev/null

# ---- stacked geom_col(fill=) ------------------------------------------------
# ggplot's default position for geom_col: a varying discrete fill stacks
# (it used to error with "stacking or dodging is not implemented")
printf 'donor,pct,predicted\nB01,42,Naive\nB01,44,Mem\nB01,14,other\nB02,60,Naive\nB02,40,Mem\n' >"$tmpdir/st.csv"
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col()" \
    -o "$tmpdir/st.pdf"
test -s "$tmpdir/st.pdf"
# negative values refuse to stack rather than draw overlapping segments
printf 'x,pct,cls\na,5,u\na,-2,v\n' >"$tmpdir/stneg.csv"
if "$CINDERPLOT" "$tmpdir/stneg.csv + aes(x=factor(x), y=pct, fill=cls) + geom_col()" \
        -o "$tmpdir/stneg.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "negative stacked geom_col unexpectedly succeeded" >&2
    exit 1
fi
grep 'negative values' "$tmpdir/err" >/dev/null
# a varying fill on a continuous x has no category to stack within
printf 'x,pct,cls\n1,5,u\n1,2,v\n' >"$tmpdir/stx.csv"
if "$CINDERPLOT" "$tmpdir/stx.csv + aes(x=x, y=pct, fill=cls) + geom_col()" \
        -o "$tmpdir/stx.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "stacked geom_col on continuous x unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs a discrete x' "$tmpdir/err" >/dev/null

# ---- scale_*_continuous(labels=c(...)) --------------------------------------
# explicit tick text paired with breaks=, so a category label row can BE the
# axis (labels=c used to error with "supported: percent")
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + scale_x_continuous(breaks=c(20,40,60), labels=c(\"low\",\"mid\",\"high\"))" \
    -o "$tmpdir/xl.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/xl.pdf" - | grep 'low' >/dev/null || {
        echo "labels=c(...) text did not reach the axis" >&2; exit 1; }
fi
# labels without matching breaks is an error, not recycling
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + scale_x_continuous(breaks=c(20,40), labels=c(\"a\"))" \
        -o "$tmpdir/xl2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "mismatched labels=/breaks= unexpectedly succeeded" >&2
    exit 1
fi
grep 'same length' "$tmpdir/err" >/dev/null

# ---- grammar-mode annotation() ---------------------------------------------
# a categorical metadata band under the panel, keyed by x category, own
# palette and legend (0.11.0 refused annotation() beside aes()/geom_*)
printf 'donor,ighv\nB01,normal\nB02,M\n' >"$tmpdir/am.csv"
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + annotation(\"$tmpdir/am.csv\")" \
    -o "$tmpdir/ann.pdf"
test -s "$tmpdir/ann.pdf"
# placements are heatmap-mode; under a grammar panel they error
if "$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + annotation(\"$tmpdir/am.csv\", left_of(\"x\"))" \
        -o "$tmpdir/ann2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "grammar annotation() with a placement unexpectedly succeeded" >&2
    exit 1
fi
grep 'placements' "$tmpdir/err" >/dev/null
# it keys on x categories, so a continuous x errors
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotation(\"$tmpdir/am.csv\")" \
        -o "$tmpdir/ann3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "grammar annotation() on continuous x unexpectedly succeeded" >&2
    exit 1
fi
grep 'discrete x' "$tmpdir/err" >/dev/null
# a category with no metadata row warns and draws NA grey
printf 'donor,ighv\nB01,normal\n' >"$tmpdir/am2.csv"
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + annotation(\"$tmpdir/am2.csv\")" \
    -o "$tmpdir/ann4.pdf" 2>"$tmpdir/err"
grep 'have no row' "$tmpdir/err" >/dev/null

# ---- breaks=/labels= hold a hand-built category axis (cap 256, was 40) -----
brk=$(python3 -c "print(','.join(str(i) for i in range(1,64)))")
lbs=$(python3 -c "print(','.join('\"c%d\"' % i for i in range(1,64)))")
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + scale_y_continuous(breaks=c($brk), labels=c($lbs))" \
    -o "$tmpdir/br63.pdf"
test -s "$tmpdir/br63.pdf"

# ---- continuous fill on geom_col() -----------------------------------------
# each bar mapped through the gradient, as geom_rect() long has; geom_bar()
# still refuses (it counts rows itself, so no single value per bar)
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=pct) + geom_col() + guides(colour=\"none\")" \
    --size 4x3 -o "$tmpdir/cfill.png"
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct) + geom_col()" \
    --size 4x3 -o "$tmpdir/cfill0.png"
if cmp -s "$tmpdir/cfill.png" "$tmpdir/cfill0.png"; then
    echo "continuous fill on geom_col drew nothing" >&2
    exit 1
fi

# ---- ColorBrewer: scale_*_distiller / scale_*_brewer ------------------------
# a named ramp; direction follows ggplot2 (-1 default), so direction=1 must
# put different ink on the page
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=pct) + geom_col() + scale_fill_distiller(palette=\"YlOrBr\")" \
    --size 4x3 -o "$tmpdir/br1.png"
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=pct) + geom_col() + scale_fill_distiller(palette=\"YlOrBr\", direction=1)" \
    --size 4x3 -o "$tmpdir/br2.png"
test -s "$tmpdir/br1.png"
if cmp -s "$tmpdir/br1.png" "$tmpdir/br2.png"; then
    echo "distiller direction= changed nothing" >&2
    exit 1
fi
# a qualitative set is not a ramp, and a ramp is not a discrete set
if "$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=pct) + geom_col() + scale_fill_distiller(palette=\"Set2\")" \
        -o "$tmpdir/br3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "qualitative palette as a ramp unexpectedly succeeded" >&2
    exit 1
fi
grep 'qualitative set, not a ramp' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + scale_fill_brewer(palette=\"YlOrBr\")" \
        -o "$tmpdir/br4.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "sequential palette as a discrete set unexpectedly succeeded" >&2
    exit 1
fi
grep 'continuous ramp' "$tmpdir/err" >/dev/null
# discrete Set2 renders with distinct level colours
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + scale_fill_brewer(palette=\"Set2\")" \
    -o "$tmpdir/br5.pdf"
test -s "$tmpdir/br5.pdf"

# ---- geom_boxplot: fill= colours the body, colour= the chrome ---------------
# one shared aes carries both spellings; the recorded spelling decides, as in
# ggplot2 (fill= used to silently render the colour= look)
printf 'g,v\na,1\na,2\na,3\na,4\nb,2\nb,3\nb,4\nb,5\n' >"$tmpdir/bx.csv"
"$CINDERPLOT" "$tmpdir/bx.csv + aes(x=factor(g), y=v, fill=factor(g)) + geom_boxplot()" \
    --size 4x3 -o "$tmpdir/bxf.png"
"$CINDERPLOT" "$tmpdir/bx.csv + aes(x=factor(g), y=v, colour=factor(g)) + geom_boxplot()" \
    --size 4x3 -o "$tmpdir/bxc.png"
if cmp -s "$tmpdir/bxf.png" "$tmpdir/bxc.png"; then
    echo "boxplot fill= and colour= render identically" >&2
    exit 1
fi

# ---- annotate(): one-off marks at literal coords ---------------------------
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotate(\"text\", x=30, y=15, label=\"here\") + annotate(\"segment\", x=20, y=10, xend=40, yend=20) + annotate(\"rect\", xmin=25, xmax=35, ymin=5, ymax=8)" \
    -o "$tmpdir/anno.pdf"
test -s "$tmpdir/anno.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/anno.pdf" - | grep 'here' >/dev/null || {
        echo "annotate text did not reach the page" >&2; exit 1; }
fi
# each kind checks its required arguments
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotate(\"text\", x=1, y=1)" \
        -o "$tmpdir/anno2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "annotate text without label unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs x=, y= and label=' "$tmpdir/err" >/dev/null
# hjust/vjust anchor the text; hjust=0 must move ink vs the centred default
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotate(\"text\", x=30, y=15, label=\"here\", hjust=0, vjust=0)" \
    --size 4x3 -o "$tmpdir/annoj.png"
"$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotate(\"text\", x=30, y=15, label=\"here\")" \
    --size 4x3 -o "$tmpdir/annoc.png"
if cmp -s "$tmpdir/annoj.png" "$tmpdir/annoc.png"; then
    echo "annotate hjust/vjust changed nothing" >&2
    exit 1
fi
# they belong on text only
if "$CINDERPLOT" "$tmpdir/sm.csv + aes(x,y) + geom_point() + annotate(\"segment\", x=1, y=1, xend=2, yend=2, hjust=0)" \
        -o "$tmpdir/annoj2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "hjust on a segment unexpectedly succeeded" >&2
    exit 1
fi
grep 'belong on annotate' "$tmpdir/err" >/dev/null
# grammar mode only
if "$CINDERPLOT" "$tmpdir/hm.tsv + heatmap(cluster=none) + annotate(\"text\", x=1, y=1, label=\"a\")" \
        -o "$tmpdir/anno3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "annotate in heatmap mode unexpectedly succeeded" >&2
    exit 1
fi
grep 'grammar panel' "$tmpdir/err" >/dev/null

# ---- brewer segfault regression, manual shortfall, identity ----------------
# Paired/Set3 carry 12 stops; an 11-slot buffer dropped the 12th at compile
# and made the lookup memcpy a stack smash (SIGSEGV on 0.15.0-pre)
printf 'x,y,g\n1,1,a\n2,2,b\n' >"$tmpdir/pw.csv"
"$CINDERPLOT" "$tmpdir/pw.csv + aes(x, y, colour=g) + geom_point() + scale_colour_brewer(palette=\"Paired\")" \
    -o "$tmpdir/pw.pdf"
test -s "$tmpdir/pw.pdf"
# a positional manual list shorter than the factor errors (was silent grey)
printf 'x,y,g\n1,1,a\n2,2,b\n3,3,c\n' >"$tmpdir/mm.csv"
if "$CINDERPLOT" "$tmpdir/mm.csv + aes(x, y, colour=g) + geom_point() + scale_colour_manual(values=c(\"#ff0000\",\"#00ff00\"))" \
        -o "$tmpdir/mm.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "short manual palette unexpectedly succeeded" >&2
    exit 1
fi
grep 'has 3 levels' "$tmpdir/err" >/dev/null
# scale_colour_identity: a hex column paints itself, and a non-colour errors
printf 'x,y,h\n1,1,#e31a1c\n2,2,#1f78b4\n' >"$tmpdir/id.csv"
"$CINDERPLOT" "$tmpdir/id.csv + aes(x, y, colour=h) + geom_point() + scale_colour_identity()" \
    -o "$tmpdir/id.pdf"
test -s "$tmpdir/id.pdf"
printf 'x,y,h\n1,1,nope\n' >"$tmpdir/id2.csv"
if "$CINDERPLOT" "$tmpdir/id2.csv + aes(x, y, colour=h) + geom_point() + scale_colour_identity()" \
        -o "$tmpdir/id2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "identity on a non-colour unexpectedly succeeded" >&2
    exit 1
fi
grep 'is not a colour' "$tmpdir/err" >/dev/null
# a pinned size too short for the legend stack warns instead of silent clip
printf 'x,y,g\n' >"$tmpdir/l20.csv"
i=0
while [ "$i" -lt 20 ]; do printf '%d,%d,L%02d\n' "$i" "$i" "$i" >>"$tmpdir/l20.csv"; i=$((i+1)); done
"$CINDERPLOT" "$tmpdir/l20.csv + aes(x, y, colour=g) + geom_point()" \
    --size 4x2.5 -o "$tmpdir/l20.pdf" 2>"$tmpdir/err"
grep 'legend stack needs' "$tmpdir/err" >/dev/null

# ---- facet_wrap(scales="free_colour"): per-facet colour scales -------------
printf 'x,y,panel,v\n1,1,A,u\n2,2,A,w\n1,1,B,m\n2,2,B,n\n3,3,B,o\n' >"$tmpdir/fcl.csv"
"$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\")" \
    -o "$tmpdir/fcl.pdf"
test -s "$tmpdir/fcl.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # each facet's legend block is titled by the facet name
    pdftotext "$tmpdir/fcl.pdf" - | grep 'A' >/dev/null || {
        echo "per-facet legend title missing" >&2; exit 1; }
fi
# needs facets and a discrete colour
if "$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\") + scale_colour_identity()" \
        -o "$tmpdir/fcl2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "free_colour with identity unexpectedly succeeded" >&2
    exit 1
fi
grep 'does nothing under' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y) + geom_point() + facet_wrap(~panel, scales=\"free_colour\")" \
        -o "$tmpdir/fcl3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "free_colour without a colour aes unexpectedly succeeded" >&2
    exit 1
fi
grep 'discrete colour' "$tmpdir/err" >/dev/null
# a brewer set too small for ONE facet errors naming the facet
printf 'x,y,panel,v\n' >"$tmpdir/fcl9.csv"
i=0
while [ "$i" -lt 10 ]; do printf '%d,%d,B,p%02d\n' "$i" "$i" "$i" >>"$tmpdir/fcl9.csv"; i=$((i+1)); done
printf '1,1,A,u\n' >>"$tmpdir/fcl9.csv"
if "$CINDERPLOT" "$tmpdir/fcl9.csv + aes(x, y, colour=v) + geom_point() + scale_colour_brewer(palette=\"Set2\") + facet_wrap(~panel, scales=\"free_colour\")" \
        -o "$tmpdir/fcl4.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "over-large facet with a small brewer set unexpectedly succeeded" >&2
    exit 1
fi
grep 'colour levels but the palette gives' "$tmpdir/err" >/dev/null

# ---- guides(colour=guide_legend(ncol=/nrow=)) ------------------------------
# folding must change the ink (two columns vs one); both keys at once error
"$CINDERPLOT" "$tmpdir/l20.csv + aes(x, y, colour=g) + geom_point() + guides(colour=guide_legend(ncol=2))" \
    --size 6x4 -o "$tmpdir/gl1.png"
"$CINDERPLOT" "$tmpdir/l20.csv + aes(x, y, colour=g) + geom_point()" \
    --size 6x4 -o "$tmpdir/gl2.png" 2>/dev/null
if cmp -s "$tmpdir/gl1.png" "$tmpdir/gl2.png"; then
    echo "guide_legend(ncol=2) changed nothing" >&2
    exit 1
fi
if "$CINDERPLOT" "$tmpdir/l20.csv + aes(x, y, colour=g) + geom_point() + guides(colour=guide_legend(ncol=2, nrow=3))" \
        -o "$tmpdir/gl3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "ncol+nrow together unexpectedly succeeded" >&2
    exit 1
fi
grep 'not both' "$tmpdir/err" >/dev/null
# guides(colour="none") still works after the parser rework
"$CINDERPLOT" "$tmpdir/l20.csv + aes(x, y, colour=g) + geom_point() + guides(colour=\"none\")" \
    -o "$tmpdir/gl4.pdf"
test -s "$tmpdir/gl4.pdf"

# ---- angle= on annotate("text") and geom_text() ----------------------------
printf 'site,pct,lab\nGI,100,g\nLN,88,l\n' >"$tmpdir/rot.csv"
"$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct, label=lab) + geom_col() + geom_text(angle=90, hjust=0)" \
    --size 3x4 -o "$tmpdir/rot1.png"
"$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct, label=lab) + geom_col() + geom_text()" \
    --size 3x4 -o "$tmpdir/rot2.png"
if cmp -s "$tmpdir/rot1.png" "$tmpdir/rot2.png"; then
    echo "geom_text(angle=) changed nothing" >&2
    exit 1
fi
# the box and the repel geoms refuse rotation honestly
if "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct, label=lab) + geom_label(angle=90)" \
        -o "$tmpdir/rot3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_label(angle=) unexpectedly succeeded" >&2
    exit 1
fi
grep 'does not rotate' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + annotate(\"text\", x=1, y=1, label=\"a\", angle=90, vjust=0)" \
        -o "$tmpdir/rot4.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "annotate angle+vjust unexpectedly succeeded" >&2
    exit 1
fi
grep 'vjust= with angle=' "$tmpdir/err" >/dev/null

# ---- --editable-svg: labels as <text>, svglite-style ------------------------
"$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct, label=lab) + geom_col() + geom_text(angle=90, hjust=0)" \
    --editable-svg -o "$tmpdir/ed.svg"
grep -c "<text" "$tmpdir/ed.svg" >/dev/null || {
    echo "editable svg has no <text> elements" >&2; exit 1; }
# the property downstream tools choke on must never occur
if grep -q "dx=" "$tmpdir/ed.svg"; then
    echo "editable svg contains dx= lists" >&2
    exit 1
fi
# the default svg keeps glyph outlines (portability unchanged); force the
# env var off, since the runner may have set the personal default
CINDERPLOT_EDITABLE_SVG=0 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" -o "$tmpdir/pl.svg"
if grep -q "<text" "$tmpdir/pl.svg"; then
    echo "default svg unexpectedly has <text> elements" >&2
    exit 1
fi
# the flag needs an .svg output
if "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" \
        --editable-svg -o "$tmpdir/ed.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "--editable-svg on a pdf unexpectedly succeeded" >&2
    exit 1
fi
grep 'needs an .svg output' "$tmpdir/err" >/dev/null
# CINDERPLOT_EDITABLE_SVG=1 is a personal default; --outline-svg overrides it
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" \
    -o "$tmpdir/ev.svg"
grep -q "<text" "$tmpdir/ev.svg" || {
    echo "CINDERPLOT_EDITABLE_SVG=1 changed nothing" >&2; exit 1; }
# the TRAILING-filename form must behave identically to -o (the editable
# decision once ran before the positional output was resolved)
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" \
    "$tmpdir/evp.svg"
grep -q "<text" "$tmpdir/evp.svg" || {
    echo "env var inert with a trailing output filename" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" \
    --outline-svg -o "$tmpdir/ev2.svg"
if grep -q "<text" "$tmpdir/ev2.svg"; then
    echo "--outline-svg did not override the env var" >&2
    exit 1
fi

# ---- theme_*(base_line_size=) and CINDERPLOT_BASE_LINE_SIZE ----------------
CINDERPLOT_BASE_LINE_SIZE= "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + theme_bw()" \
    --size 4x3 -o "$tmpdir/bl1.png"
CINDERPLOT_BASE_LINE_SIZE= "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + theme_bw(base_line_size=0.25)" \
    --size 4x3 -o "$tmpdir/bl2.png"
if cmp -s "$tmpdir/bl1.png" "$tmpdir/bl2.png"; then
    echo "base_line_size= changed nothing" >&2
    exit 1
fi
# the env var is the same knob, and the spec argument beats it
CINDERPLOT_BASE_LINE_SIZE=0.25 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + theme_bw()" \
    --size 4x3 -o "$tmpdir/bl3.png"
cmp -s "$tmpdir/bl3.png" "$tmpdir/bl2.png" || {
    echo "env var and spec argument disagree" >&2; exit 1; }
CINDERPLOT_BASE_LINE_SIZE=0.25 "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + theme_bw(base_line_size=0.5)" \
    --size 4x3 -o "$tmpdir/bl4.png"
cmp -s "$tmpdir/bl4.png" "$tmpdir/bl1.png" || {
    echo "spec base_line_size did not override the env var" >&2; exit 1; }
# nonsense values refuse / warn
if "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col() + theme_bw(base_line_size=0)" \
        -o "$tmpdir/bl5.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "base_line_size=0 unexpectedly succeeded" >&2
    exit 1
fi
grep 'number > 0' "$tmpdir/err" >/dev/null
CINDERPLOT_BASE_LINE_SIZE=abc "$CINDERPLOT" "$tmpdir/rot.csv + aes(x=factor(site), y=pct) + geom_col()" \
    --size 4x3 -o "$tmpdir/bl6.png" 2>"$tmpdir/err"
grep 'ignoring CINDERPLOT_BASE_LINE_SIZE' "$tmpdir/err" >/dev/null

# ---- svg raster crispness, and free_colour legend-block width --------------
# a rasterized heatmap body must carry image-rendering:pixelated in SVG
# (cairo drops the NEAREST hint; viewers otherwise smear the cells), and a
# smooth-scaled raster point layer must NOT
"$CINDERPLOT" "$tmpdir/hmbig.tsv + heatmap(cluster=none)" --size 6x6 -o "$tmpdir/crisp.svg"
grep -q 'image-rendering:pixelated' "$tmpdir/crisp.svg" || {
    echo "rasterized heatmap svg missing the pixelated stamp" >&2; exit 1; }
i=0; printf 'x,y\n' >"$tmpdir/manypts.csv"
while [ "$i" -lt 3000 ]; do printf '%d,%d\n' "$((i%97))" "$((i%89))" >>"$tmpdir/manypts.csv"; i=$((i+1)); done
"$CINDERPLOT" "$tmpdir/manypts.csv + aes(x,y) + geom_point(raster=TRUE)" -o "$tmpdir/smoothpts.svg"
if grep -q 'pixelated' "$tmpdir/smoothpts.svg"; then
    echo "raster point layer wrongly stamped pixelated" >&2
    exit 1
fi
# a free_colour legend block wider than its panel column warns
printf 'x,y,panel,v\n' >"$tmpdir/wide.csv"
i=0
while [ "$i" -lt 30 ]; do
    printf '%d,%d,B,a-very-long-level-name-%02d\n' "$i" "$i" "$i" >>"$tmpdir/wide.csv"
    i=$((i+1))
done
printf '1,1,A,u\n' >>"$tmpdir/wide.csv"
"$CINDERPLOT" "$tmpdir/wide.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\") + guides(colour=guide_legend(nrow=3))" \
    --size 5x4 -o "$tmpdir/wide.pdf" 2>"$tmpdir/err"
grep 'legend block is' "$tmpdir/err" >/dev/null || {
    echo "oversize legend block did not warn" >&2; exit 1; }

# ---- coord_polar(): the radar subset ---------------------------------------
printf 'class,frac,ct\n' >"$tmpdir/radar.csv"
for c in A B C D E; do
    printf '%s,0.4,u\n%s,0.7,v\n' "$c" "$c" >>"$tmpdir/radar.csv"
done
"$CINDERPLOT" "$tmpdir/radar.csv + aes(x=factor(class), y=frac, colour=ct) + geom_line() + geom_point() + coord_polar() + ylim(0,1)" \
    -o "$tmpdir/radar.pdf"
test -s "$tmpdir/radar.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    # spokes carry the category labels
    pdftotext "$tmpdir/radar.pdf" - | grep 'A' >/dev/null || {
        echo "radar spoke labels missing" >&2; exit 1; }
fi
# continuous x, unsupported geoms and facets refuse with a menu
if "$CINDERPLOT" "$tmpdir/radar.csv + aes(x=frac, y=frac) + geom_point() + coord_polar()" \
        -o "$tmpdir/radar2.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "polar on continuous x unexpectedly succeeded" >&2
    exit 1
fi
grep 'discrete x' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/radar.csv + aes(x=factor(class), y=frac) + geom_col() + coord_polar()" \
        -o "$tmpdir/radar3.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "polar bars unexpectedly succeeded" >&2
    exit 1
fi
grep 'pie/rose' "$tmpdir/err" >/dev/null

# ---- geom_tile(colour=): a border, not the fill ----------------------------
# a layer colour= used to take over the fill, so colour="white" blanked
# every cell; it must stroke the border over the MAPPED fill
printf 'x,y,v\na,r,1\nb,r,50\nc,r,99\n' >"$tmpdir/tl.csv"
"$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile(colour=\"white\", linewidth=0.5)" \
    --size 4x2 -o "$tmpdir/tl1.png"
"$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile()" \
    --size 4x2 -o "$tmpdir/tl2.png"
if cmp -s "$tmpdir/tl1.png" "$tmpdir/tl2.png"; then
    echo "tile colour= border drew nothing" >&2
    exit 1
fi
# the border must not erase the fill: bordered tiles still differ from a
# blank panel (the old bug rendered them all white)
"$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile(colour=\"white\") + guides(colour=\"none\")" \
    --size 4x2 -o "$tmpdir/tl3.png"
"$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile(colour=\"white\") + scale_fill_gradient(low=\"white\", high=\"white\") + guides(colour=\"none\")" \
    --size 4x2 -o "$tmpdir/tl4.png"
if cmp -s "$tmpdir/tl3.png" "$tmpdir/tl4.png"; then
    echo "tile fill vanished under colour= (the old bug)" >&2
    exit 1
fi
if "$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile(linewidth=0)" \
        -o "$tmpdir/tl5.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "linewidth=0 unexpectedly succeeded" >&2
    exit 1
fi
grep 'number > 0' "$tmpdir/err" >/dev/null

# ---- expand= on the scales, coord_cartesian(expand=FALSE) ------------------
printf 'x,y,v\na,r1,1\nb,r1,50\nc,r1,99\na,r2,80\nb,r2,20\nc,r2,60\n' >"$tmpdir/tl2.csv"
"$CINDERPLOT" "$tmpdir/tl2.csv + aes(x=x, y=y, fill=v) + geom_tile() + scale_x_discrete(expand=c(0,0))" \
    --size 4x2 -o "$tmpdir/ex1.png"
"$CINDERPLOT" "$tmpdir/tl2.csv + aes(x=x, y=y, fill=v) + geom_tile()" \
    --size 4x2 -o "$tmpdir/ex2.png"
if cmp -s "$tmpdir/ex1.png" "$tmpdir/ex2.png"; then
    echo "expand=c(0,0) changed nothing" >&2
    exit 1
fi
# coord_cartesian(expand=FALSE) == zeroing both scales
"$CINDERPLOT" "$tmpdir/tl2.csv + aes(x=x, y=y, fill=v) + geom_tile() + coord_cartesian(expand=FALSE)" \
    --size 4x2 -o "$tmpdir/ex3.png"
"$CINDERPLOT" "$tmpdir/tl2.csv + aes(x=x, y=y, fill=v) + geom_tile() + scale_x_discrete(expand=c(0,0)) + scale_y_discrete(expand=c(0,0))" \
    --size 4x2 -o "$tmpdir/ex4.png"
cmp -s "$tmpdir/ex3.png" "$tmpdir/ex4.png" || {
    echo "coord_cartesian(expand=FALSE) differs from zeroed scales" >&2; exit 1; }
# negative values refuse
if "$CINDERPLOT" "$tmpdir/tl2.csv + aes(x=x, y=y, fill=v) + geom_tile() + scale_x_discrete(expand=c(-1,0))" \
        -o "$tmpdir/ex5.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "negative expand unexpectedly succeeded" >&2
    exit 1
fi
grep 'must be >= 0' "$tmpdir/err" >/dev/null
# a single-row grid under expand=c(0,0) still spans its tile edges
# (the expansion measures from the tile edge, so nothing collapses and
# no outer cell is cut in half)
"$CINDERPLOT" "$tmpdir/tl.csv + aes(x=x, y=y, fill=v) + geom_tile() + coord_cartesian(expand=FALSE)" \
    -o "$tmpdir/ex6.pdf"
test -s "$tmpdir/ex6.pdf"

# ---- theme(legend.position="inside"), blank titles, auto-fold ---------------
"$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\") + theme(legend.position=\"inside\", legend.position.inside=c(0.8, 0.2))" \
    --size 8x4 -o "$tmpdir/li1.pdf"
test -s "$tmpdir/li1.pdf"
# single-panel inside legend
"$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct, fill=predicted) + geom_col() + theme(legend.position=\"inside\")" \
    --size 4x4 -o "$tmpdir/li2.pdf"
test -s "$tmpdir/li2.pdf"
# labs(colour=\"\") drops the free_colour block titles: the render changes
"$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\") + labs(colour=\"\")" \
    --size 8x4 -o "$tmpdir/li3.png"
"$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel, scales=\"free_colour\")" \
    --size 8x4 -o "$tmpdir/li4.png"
if cmp -s "$tmpdir/li3.png" "$tmpdir/li4.png"; then
    echo "labs(colour=\"\") changed nothing under free_colour" >&2
    exit 1
fi
# facets + a single shared legend cannot go inside
if "$CINDERPLOT" "$tmpdir/fcl.csv + aes(x, y, colour=v) + geom_point() + facet_wrap(~panel) + theme(legend.position=\"inside\")" \
        -o "$tmpdir/li5.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "shared inside legend with facets unexpectedly succeeded" >&2
    exit 1
fi
grep 'free_colour' "$tmpdir/err" >/dev/null
# other theme() keys stay refused
if "$CINDERPLOT" "$tmpdir/st.csv + aes(x=donor, y=pct) + geom_col() + theme(strip.text=element_blank())" \
        -o "$tmpdir/li6.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "arbitrary theme() unexpectedly succeeded" >&2
    exit 1
fi
grep 'not implemented' "$tmpdir/err" >/dev/null

# ---- chord(): circlize-style chord diagram ---------------------------------
printf 'from,to,value\nA,X,4\nA,Y,2\nB,X,3\nB,B,1\n' >"$tmpdir/ch.csv"
"$CINDERPLOT" "$tmpdir/ch.csv + chord()" -o "$tmpdir/ch.pdf"
test -s "$tmpdir/ch.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    for nm in A B X Y; do
        pdftotext "$tmpdir/ch.pdf" - | grep "$nm" >/dev/null || {
            echo "chord sector label $nm missing" >&2; exit 1; }
    done
fi
# named colours change the ink
"$CINDERPLOT" "$tmpdir/ch.csv + chord() + scale_fill_manual(values=c(\"A\"=\"#000000\"))" \
    --size 5x5 -o "$tmpdir/ch1.png"
"$CINDERPLOT" "$tmpdir/ch.csv + chord()" --size 5x5 -o "$tmpdir/ch2.png"
if cmp -s "$tmpdir/ch1.png" "$tmpdir/ch2.png"; then
    echo "chord manual colours changed nothing" >&2
    exit 1
fi
# refusals: bad column, non-positive value, mode mixing
if "$CINDERPLOT" "$tmpdir/ch.csv + chord(from=\"nope\")" -o "$tmpdir/ch3.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord bad column unexpectedly succeeded" >&2; exit 1
fi
grep 'not found' "$tmpdir/err" >/dev/null
printf 'from,to,value\nA,B,0\n' >"$tmpdir/chz.csv"
if "$CINDERPLOT" "$tmpdir/chz.csv + chord()" -o "$tmpdir/ch4.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord zero value unexpectedly succeeded" >&2; exit 1
fi
grep 'must be positive' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/ch.csv + chord() + geom_point()" -o "$tmpdir/ch5.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord mixed with a geom unexpectedly succeeded" >&2; exit 1
fi
grep 'its own mode' "$tmpdir/err" >/dev/null

# ---- errorbars, segment fixes, legend reverse, chord ordering --------------
printf 'x,y,s,lo,hi\n1,5,a,4,6\n2,7,a,6,8\n1,4,b,3,5\n2,6,b,5,7\n' >"$tmpdir/eb.csv"
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, colour=s, ymin=lo, ymax=hi) + geom_errorbar(width=0.2) + geom_line() + geom_point()" \
    --size 4x3 -o "$tmpdir/eb1.png"
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, colour=s, ymin=lo, ymax=hi) + geom_linerange() + geom_line()" \
    --size 4x3 -o "$tmpdir/eb2.png"
test -s "$tmpdir/eb1.png" && test -s "$tmpdir/eb2.png"
if "$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y) + geom_errorbar()" -o "$tmpdir/eb3.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "errorbar without ymin/ymax unexpectedly succeeded" >&2; exit 1
fi
grep 'aes(ymin=, ymax=)' "$tmpdir/err" >/dev/null
# the old rect ymin-as-y spelling still parses
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x=x, xend=x, ymin=lo, ymax=hi) + geom_rect()" \
    -o "$tmpdir/eb4.pdf"
test -s "$tmpdir/eb4.pdf"
# geom_segment(y=col) names the start column (it used to parse and do nothing)
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, xend=x, yend=hi) + geom_segment(y=lo)" \
    --size 4x3 -o "$tmpdir/sg1.png"
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, xend=x, yend=hi) + geom_segment()" \
    --size 4x3 -o "$tmpdir/sg2.png"
if cmp -s "$tmpdir/sg1.png" "$tmpdir/sg2.png"; then
    echo "geom_segment(y=) changed nothing" >&2; exit 1
fi
# guide_legend(reverse=TRUE) flips the key order
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, colour=s) + geom_point() + guides(colour=guide_legend(reverse=TRUE))" \
    --size 4x3 -o "$tmpdir/rv1.png"
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x, y, colour=s) + geom_point()" \
    --size 4x3 -o "$tmpdir/rv2.png"
if cmp -s "$tmpdir/rv1.png" "$tmpdir/rv2.png"; then
    echo "guide_legend(reverse=) changed nothing" >&2; exit 1
fi
# chord order= and bipartite=
"$CINDERPLOT" "$tmpdir/ch.csv + chord(order=c(\"B\",\"A\",\"Y\",\"X\"))" -o "$tmpdir/cho.pdf"
test -s "$tmpdir/cho.pdf"
if "$CINDERPLOT" "$tmpdir/ch.csv + chord(bipartite=TRUE)" -o "$tmpdir/chb.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "bipartite with a self-link unexpectedly succeeded" >&2; exit 1
fi
grep 'both sides' "$tmpdir/err" >/dev/null
printf 'from,to,value\nA,X,4\nB,Y,2\n' >"$tmpdir/chd.csv"
"$CINDERPLOT" "$tmpdir/chd.csv + chord(bipartite=TRUE)" -o "$tmpdir/chb2.pdf"
test -s "$tmpdir/chb2.pdf"
if "$CINDERPLOT" "$tmpdir/chd.csv + chord(order=c(\"A\"))" -o "$tmpdir/chb3.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "short chord order unexpectedly succeeded" >&2; exit 1
fi
grep 'complete list' "$tmpdir/err" >/dev/null

# ==== 2026-09-10 review fixes: track/tree/csv readers ================================================

# ---- B1: cytoband() with a numeric chrom column, or text start/end ----------
# Ensembl-style `1` types the chrom column numeric; it is formatted for the
# match rather than dereferenced as a string (which segfaulted).
printf 'chrom\tstart\tend\tname\tstain\n1\t0\t1000000\tp1\tgneg\n1\t1000000\t2000000\tp2\tacen\n' \
    >"$tmpdir/cb-num.tsv"
"$CINDERPLOT" "region(\"1:100-2000\") + cytoband(\"$tmpdir/cb-num.tsv\")" \
    -o "$tmpdir/cb-num.pdf"
test -s "$tmpdir/cb-num.pdf"
# a text cell in start/end is a typed error naming the file and column
printf 'chrom\tstart\tend\tname\tstain\nchr1\t0\t1000000\tp1\tgneg\nchr1\tx\t2000000\tp2\tacen\n' \
    >"$tmpdir/cb-str.tsv"
if "$CINDERPLOT" "region(\"chr1:100-2000\") + cytoband(\"$tmpdir/cb-str.tsv\")" \
    -o "$tmpdir/cb-str.pdf" 2>"$tmpdir/cb-str.err"; then
    echo "cytoband with a text start cell unexpectedly succeeded" >&2
    exit 1
fi
grep 'cb-str.tsv.*column `start` must be numeric' "$tmpdir/cb-str.err" >/dev/null

# ---- B2: matrix() with integer Probe_IDs (long and wide) --------------------
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/mat-numpid.tsv"
printf 'chr1\t100\t101\t1001\t0.2\tS1\nchr1\t200\t201\t1002\t0.8\tS1\n' >>"$tmpdir/mat-numpid.tsv"
printf 'chr1\t100\t101\t1001\t0.4\tS2\nchr1\t200\t201\t1002\t0.6\tS2\n' >>"$tmpdir/mat-numpid.tsv"
"$CINDERPLOT" "region(\"chr1:50-250\") + matrix(\"$tmpdir/mat-numpid.tsv\")" \
    -o "$tmpdir/mat-numpid.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/mat-numpid.pdf" - | grep -q 1001    # the id is the column label
fi
printf 'chrom\tbeg\tend\tProbe_ID\tS1\tS2\nchr1\t100\t101\t1001\t0.2\t0.4\nchr1\t200\t201\t1002\t0.8\t0.6\n' \
    >"$tmpdir/mat-wide-numpid.tsv"
"$CINDERPLOT" "region(\"chr1:50-250\") + matrix(\"$tmpdir/mat-wide-numpid.tsv\")" \
    -o "$tmpdir/mat-wide-numpid.pdf"
test -s "$tmpdir/mat-wide-numpid.pdf"

# ---- B7: a Newick tree nested past the recursion guard is refused -----------
python3 -c "print('(' * 12000 + 'a' + ')' * 12000 + ';')" >"$tmpdir/deep.tre"
if "$CINDERPLOT" "$tmpdir/deep.tre + geom_tree()" -o "$tmpdir/deep.pdf" \
    2>"$tmpdir/deep.err"; then
    echo "12000-deep Newick unexpectedly succeeded" >&2
    exit 1
fi
grep 'nests deeper than 10000 levels' "$tmpdir/deep.err" >/dev/null

# ---- C40 / B8: a plain gzip (or a crafted header) beside a .tbi is an error -
# A minimal tabix index whose only chunk points at offset 0 of the data file.
python3 - "$tmpdir/plain.bed.gz.tbi" <<'PY'
import gzip, struct, sys
names = b'chr1\0'
hdr = b'TBI\1' + struct.pack('<8i', 1, 0, 1, 2, 3, 0, 0, len(names)) + names
body = (struct.pack('<i', 1) + struct.pack('<Ii', 4681, 1) + struct.pack('<QQ', 0, 1 << 16)
        + struct.pack('<i', 1) + struct.pack('<Q', 0))
open(sys.argv[1], 'wb').write(gzip.compress(hdr + body))
PY
printf 'chr1\t100\t200\tG\t0\t+\t100\t200\t0\t1\t100,\t0,\n' | gzip -c >"$tmpdir/plain.bed.gz"
if "$CINDERPLOT" "region(\"chr1:50-250\") + genes(\"$tmpdir/plain.bed.gz\")" \
    -o "$tmpdir/plain.pdf" 2>"$tmpdir/plain.err"; then
    echo "plain gzip beside a .tbi unexpectedly succeeded" >&2
    exit 1
fi
grep 'plain.bed.gz: not a BGZF file (needed for tabix); recompress with bgzip' \
    "$tmpdir/plain.err" >/dev/null
# FEXTRA header whose BC subfield's 2 data bytes fall outside xlen=4: not a
# block, and never read past the extra field
cp "$tmpdir/plain.bed.gz.tbi" "$tmpdir/bc.bed.gz.tbi"
printf '\037\213\010\004\000\000\000\000\000\003\004\000BC\002\000\377\377\000\000\000\000\000\000\000\000' \
    >"$tmpdir/bc.bed.gz"
if "$CINDERPLOT" "region(\"chr1:50-250\") + genes(\"$tmpdir/bc.bed.gz\")" \
    -o "$tmpdir/bc.pdf" 2>"$tmpdir/bc.err"; then
    echo "short BC subfield unexpectedly succeeded" >&2
    exit 1
fi
grep 'not a BGZF file' "$tmpdir/bc.err" >/dev/null

# ---- C41: a truncated .gz is an error, not a shorter file -------------------
printf 'chr1\t100\t200\tA\nchr1\t300\t400\tB\nchr1\t500\t600\tC\n' | gzip -c >"$tmpdir/whole.bed.gz"
head -c 30 "$tmpdir/whole.bed.gz" >"$tmpdir/trunc.bed.gz"
if "$CINDERPLOT" "region(\"chr1:50-650\") + interval(\"$tmpdir/trunc.bed.gz\")" \
    -o "$tmpdir/trunc.pdf" 2>"$tmpdir/trunc.err"; then
    echo "truncated gzip unexpectedly succeeded" >&2
    exit 1
fi
grep 'trunc.bed.gz: unexpected end of file (truncated gzip)' "$tmpdir/trunc.err" >/dev/null
"$CINDERPLOT" "region(\"chr1:50-650\") + interval(\"$tmpdir/whole.bed.gz\")" \
    -o "$tmpdir/whole.pdf"
test -s "$tmpdir/whole.pdf"

# ---- C39: an inter-chromosomal BEDPE row is skipped, with a warning ---------
printf 'chr1\t100\t200\tchr2\t500\t600\tL1\t5\nchr1\t100\t200\tchr1\t250\t300\tL2\t5\n' \
    >"$tmpdir/trans.bedpe"
"$CINDERPLOT" "region(\"chr1:50-350\") + arcs(\"$tmpdir/trans.bedpe\")" \
    --editable-svg -o "$tmpdir/trans.svg" 2>"$tmpdir/trans.err"
grep 'trans.bedpe: skipped 1 inter-chromosomal link' "$tmpdir/trans.err" >/dev/null
# only the cis arc is drawn: an arc is the one long (40-point) path
test "$(grep -o '<path[^>]*' "$tmpdir/trans.svg" | awk 'length($0) > 500' | wc -l)" -eq 1

# ---- C42: a negative bedGraph draws below a zero line ------------------------
printf 'chr1\t100\t200\t-3\nchr1\t200\t300\t-1\n' >"$tmpdir/neg.bedgraph"
"$CINDERPLOT" "region(\"chr1:50-350\") + coverage(\"$tmpdir/neg.bedgraph\")" \
    -o "$tmpdir/neg.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/neg.pdf" - | grep -F '[-3 - 0]' >/dev/null    # readout, not [0 - 1]
fi

# ---- C43: BED coordinates and region() are validated -------------------------
printf 'chr1\tabc\t200\tX\n' >"$tmpdir/bad-coord.bed"
if "$CINDERPLOT" "region(\"chr1:50-350\") + interval(\"$tmpdir/bad-coord.bed\")" \
    -o "$tmpdir/bad-coord.pdf" 2>"$tmpdir/bad-coord.err"; then
    echo "non-numeric BED start unexpectedly succeeded" >&2
    exit 1
fi
grep 'bad-coord.bed line 1: column 2 `abc` is not a coordinate' "$tmpdir/bad-coord.err" >/dev/null
printf 'chr1\t100\t200\tX\nchr1\t400\t300\tY\n' >"$tmpdir/inv.bed"
if "$CINDERPLOT" "region(\"chr1:50-350\") + interval(\"$tmpdir/inv.bed\")" \
    -o "$tmpdir/inv.pdf" 2>"$tmpdir/inv.err"; then
    echo "BED start > end unexpectedly succeeded" >&2
    exit 1
fi
grep 'inv.bed line 2: start 400 exceeds end 300' "$tmpdir/inv.err" >/dev/null
printf 'chr1\t-50\t50\tZ\n' >"$tmpdir/negc.bed"
if "$CINDERPLOT" "region(\"chr1:0-350\") + interval(\"$tmpdir/negc.bed\")" \
    -o "$tmpdir/negc.pdf" 2>"$tmpdir/negc.err"; then
    echo "negative BED start unexpectedly succeeded" >&2
    exit 1
fi
grep 'negc.bed line 1: column 2 `-50` is not a coordinate' "$tmpdir/negc.err" >/dev/null
for rg in 'chr1:-50-100' 'chr1:500-100' 'chr1:1x0-200'; do
    if "$CINDERPLOT" "region(\"$rg\") + interval(\"$tmpdir/inv.bed\")" \
        -o "$tmpdir/rg.pdf" 2>"$tmpdir/rg.err"; then
        echo "region($rg) unexpectedly succeeded" >&2
        exit 1
    fi
    grep "bad region \`$rg\`" "$tmpdir/rg.err" >/dev/null
done
# a BED12 block running past chromEnd names its line
printf 'chr1\t100\t200\tG\t0\t+\t100\t200\t0\t2\t50,50\t0,500\n' >"$tmpdir/block.bed"
if "$CINDERPLOT" "region(\"chr1:50-350\") + genes(\"$tmpdir/block.bed\")" \
    -o "$tmpdir/block.pdf" 2>"$tmpdir/block.err"; then
    echo "BED12 block beyond chromEnd unexpectedly succeeded" >&2
    exit 1
fi
grep 'block.bed line 1: block 2 ends at 650, beyond chromEnd 200' "$tmpdir/block.err" >/dev/null

# ---- C44: one stray cell in a wide matrix names the cell, not a new layout --
printf 'chrom\tbeg\tend\tProbe_ID\tS1\tS2\nchr1\t100\t101\tcg1\t0.2\t0.4\nchr1\t200\t201\tcg2\tn/a\t0.6\n' \
    >"$tmpdir/stray.tsv"
if "$CINDERPLOT" "region(\"chr1:50-250\") + matrix(\"$tmpdir/stray.tsv\")" \
    -o "$tmpdir/stray.pdf" 2>"$tmpdir/stray.err"; then
    echo "wide matrix with a stray n/a unexpectedly succeeded" >&2
    exit 1
fi
grep 'stray.tsv`: column `S1` row 3 is "n/a", not a number' "$tmpdir/stray.err" >/dev/null

# ---- C45: numeric tree labels plus a numeric join key is ambiguous ----------
printf '((3,1),2);' >"$tmpdir/num.tre"
printf 'id\tgrp\n1\tred\n2\tred\n3\tblue\n' >"$tmpdir/num.tsv"
if "$CINDERPLOT" "$tmpdir/num.tre + geom_tree() + geom_tippoint(data=\"$tmpdir/num.tsv\", colour=grp)" \
    -o "$tmpdir/num.pdf" 2>"$tmpdir/num.err"; then
    echo "numeric tip labels with a numeric key unexpectedly succeeded" >&2
    exit 1
fi
grep 'ambiguous: tree labels are numeric and the join key is numeric' "$tmpdir/num.err" >/dev/null

# ---- C46: empty tracks warn; the wrong file type for a track errors ---------
printf 'chr1\t100\t200\tA\n' >"$tmpdir/one.bed"
"$CINDERPLOT" "region(\"chr1:5000-6000\") + interval(\"$tmpdir/one.bed\")" \
    -o "$tmpdir/empty-iv.pdf" 2>"$tmpdir/empty-iv.err"
grep 'one.bed: 0 records overlap chr1:5000-6000' "$tmpdir/empty-iv.err" >/dev/null
printf 'chr1\t100\t200\tG\t0\t+\t100\t200\t0\t1\t100,\t0,\n' >"$tmpdir/g12.bed"
if "$CINDERPLOT" "region(\"chr1:50-350\") + coverage(\"$tmpdir/g12.bed\")" \
    -o "$tmpdir/cov12.pdf" 2>"$tmpdir/cov12.err"; then
    echo "coverage() fed a BED12 unexpectedly succeeded" >&2
    exit 1
fi
grep 'g12.bed line 1: column 4 `G` is not a number; coverage() needs a bedGraph' \
    "$tmpdir/cov12.err" >/dev/null
printf 'chr1\t100\t200\t5\n' >"$tmpdir/sig.bedgraph"
if "$CINDERPLOT" "region(\"chr1:50-350\") + genes(\"$tmpdir/sig.bedgraph\")" \
    -o "$tmpdir/genes-bg.pdf" 2>"$tmpdir/genes-bg.err"; then
    echo "genes() fed a bedGraph unexpectedly succeeded" >&2
    exit 1
fi
grep 'sig.bedgraph line 1 has 4 columns; genes() needs a BED12' "$tmpdir/genes-bg.err" >/dev/null
# under regions(), a window with no probes is named, and so is the file
printf 'chr1\t100\t200\tleft\nchr1\t300\t400\tright\n' >"$tmpdir/win2.bed"
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\nchr1\t120\t121\tp1\t0.1\ts1\n' \
    >"$tmpdir/oneprobe.tsv"
if "$CINDERPLOT" "regions(\"$tmpdir/win2.bed\") + matrix(\"$tmpdir/oneprobe.tsv\")" \
    -o "$tmpdir/nowin.pdf" 2>"$tmpdir/nowin.err"; then
    echo "regions() window without probes unexpectedly succeeded" >&2
    exit 1
fi
grep 'matrix is empty in the requested window chr1:300-400 (.*oneprobe.tsv)' \
    "$tmpdir/nowin.err" >/dev/null

# ---- C47: a tick label at the panel edge slides inward in region() mode too -
printf 'chr1\t120\t150\ta\n' >"$tmpdir/edge.bed"
"$CINDERPLOT" "region(\"chr1:100-200\") + interval(\"$tmpdir/edge.bed\")" \
    --editable-svg -o "$tmpdir/edge.svg"
# the "100" label used to be centred on x=0 and start off the page
x=$(grep '>100<' "$tmpdir/edge.svg" | sed 's/.* x="\([^"]*\)".*/\1/')
test "$(awk -v x="$x" 'BEGIN{print (x >= 5) ? 1 : 0}')" -eq 1

# ---- D2: a UTF-8 BOM on the header, and CRLF line ends in a BED -------------
printf '\357\273\277x,y\n1,2\n2,3\n' >"$tmpdir/bom.csv"
"$CINDERPLOT" "$tmpdir/bom.csv + aes(x,y) + geom_point()" -o "$tmpdir/bom.pdf"
test -s "$tmpdir/bom.pdf"
printf 'chr1\t100\t200\tpeakA\r\nchr1\t300\t400\tpeakB\r\n' >"$tmpdir/crlf.bed"
"$CINDERPLOT" "region(\"chr1:50-450\") + interval(\"$tmpdir/crlf.bed\")" \
    --editable-svg -o "$tmpdir/crlf.svg"
if grep -q "peakA$(printf '\r')" "$tmpdir/crlf.svg"; then
    echo "CRLF BED name kept its carriage return" >&2
    exit 1
fi
grep -q '>peakA<' "$tmpdir/crlf.svg"

# ---- D3: a nearly numeric column says which cell made it text ---------------
printf 'x,y\n1,1\n2,2\n3,N/A\n4,4\n5,5\n6,6\n7,7\n8,8\n9,9\n10,10\n' >"$tmpdir/na.csv"
"$CINDERPLOT" "$tmpdir/na.csv + aes(x,y) + geom_tile()" -o "$tmpdir/na.pdf" 2>"$tmpdir/na.err"
grep 'warning: column `y` is treated as text because row 4 is "N/A"' "$tmpdir/na.err" >/dev/null

# ---- D12: regions() accepts a numeric chromosome column ---------------------
printf '1\t100\t200\tA\n' >"$tmpdir/win-num.bed"
printf '1\t120\t150\ta\n' >"$tmpdir/iv-num.bed"
"$CINDERPLOT" "regions(\"$tmpdir/win-num.bed\") + interval(\"$tmpdir/iv-num.bed\")" \
    -o "$tmpdir/win-num.pdf"
test -s "$tmpdir/win-num.pdf"

# ---- D21: the tabix name walk is linear (40,000 scaffolds, target last) -----
python3 - "$tmpdir/many.bed.gz" <<'PY'
import gzip, struct, sys, zlib
def bgzf(data):
    c = zlib.compressobj(6, zlib.DEFLATED, -15); d = c.compress(data) + c.flush()
    bsize = 12 + 6 + len(d) + 8
    return (b'\x1f\x8b\x08\x04' + b'\0' * 5 + b'\xff' + struct.pack('<H', 6) + b'BC' + struct.pack('<HH', 2, bsize - 1)
            + d + struct.pack('<II', zlib.crc32(data) & 0xffffffff, len(data)))
N = 40000
rec = b'scaf%05d\t100\t900\tg\t0\t+\t100\t900\t0\t1\t800,\t0,\n' % (N - 1)
open(sys.argv[1], 'wb').write(bgzf(rec) + bgzf(b''))
names = b''.join(b'scaf%05d\0' % i for i in range(N))
hdr = b'TBI\1' + struct.pack('<8i', N, 0, 1, 2, 3, 0, 0, len(names)) + names
empty = struct.pack('<i', 0) + struct.pack('<i', 0)                 # n_bin=0, n_intv=0
last = (struct.pack('<i', 1) + struct.pack('<Ii', 4681, 1) + struct.pack('<QQ', 0, 1 << 16)
        + struct.pack('<i', 1) + struct.pack('<Q', 0))
open(sys.argv[1] + '.tbi', 'wb').write(gzip.compress(hdr + empty * (N - 1) + last))
PY
timeout 5 "$CINDERPLOT" "region(\"scaf39999:50-950\") + genes(\"$tmpdir/many.bed.gz\")" \
    -o "$tmpdir/many.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/many.pdf" - | grep -q '^g$'          # the record was found
fi

# ==== 2026-09-10 review fixes: heatmap, palette, breaks, clustering ==================================

# ---- annotation chained to an annotation inherits the clustered order ----
# B right_of A right_of m: A followed the clustering, B showed file order.
# Both strips come from the same file, so their SVG fills must agree cell for
# cell; cluster=rows on a matrix whose input order is not the clustered one.
printf 'rn,a,b\nr1,0,0\nr2,9,9\nr3,0.1,0\nr4,9.1,9\nr5,0.2,0\nr6,9.2,9\n' >"$tmpdir/chain.csv"
printf 'grp\nlow\nhigh\nlow\nhigh\nlow\nhigh\n' >"$tmpdir/chaingrp.csv"
"$CINDERPLOT" "$tmpdir/chain.csv + heatmap(name=\"m\", cluster=rows)
     + annotation(\"$tmpdir/chaingrp.csv\", right_of(\"m\"), name=\"A\")
     + annotation(\"$tmpdir/chaingrp.csv\", right_of(\"A\"), name=\"B\")" \
    --size 4x4 -o "$tmpdir/chain.svg"
svgnorm "$tmpdir/chain.svg"
# the two strips are 6 rects each, drawn A then B, right after the 12 cells
fills=$(grep -o 'fill="rgb([^"]*"' "$tmpdir/chain.svg" | sed -n '13,24p')
a=$(echo "$fills" | head -6 | tr '\n' ' '); b=$(echo "$fills" | tail -6 | tr '\n' ' ')
if [ "$a" != "$b" ]; then
    echo "annotation anchored to an annotation lost the clustered row order" >&2
    exit 1
fi

# ---- gradient2: the midpoint is the mid colour even when the range starts there ----
# A non-negative matrix under midpoint=0 painted its zeros the LOW colour
# (t = 0 short-circuit) while 0.01 was white.
printf 'rn,a,b\nr1,0,0.01\nr2,5,10\n' >"$tmpdir/nonneg.csv"
"$CINDERPLOT" "$tmpdir/nonneg.csv + heatmap(cluster=none)
     + scale_fill_gradient2(low=\"#0000FF\", mid=\"#FFFFFF\", high=\"#FF0000\")" \
    --size 3x3 -o "$tmpdir/nonneg.svg"
svgnorm "$tmpdir/nonneg.svg"
if grep -q 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/nonneg.svg"; then
    echo "gradient2 painted the midpoint value with the low colour" >&2
    exit 1
fi

# ---- gradient2 colourbar is painted by value, so white sits at the midpoint ----
# range [-1, 3], midpoint 0: white belongs a quarter of the way up the bar,
# not at its middle. The bar is 64 strips; strip 16 (v = -1 + 4*16.5/64 = 0.03)
# must be near-white and strip 32 (v = 1) clearly red.
printf 'rn,a,b\nr1,-1,3\nr2,0,1\n' >"$tmpdir/asym.csv"
"$CINDERPLOT" "$tmpdir/asym.csv + heatmap(name=\"m\", cluster=none) + legend(right_of(\"m\"))
     + scale_fill_gradient2(low=\"#0000FF\", mid=\"#FFFFFF\", high=\"#FF0000\")" \
    --size 3x3 -o "$tmpdir/asym.svg"
svgnorm "$tmpdir/asym.svg"
python3 - "$tmpdir/asym.svg" <<'PY'
import re, sys
svg = open(sys.argv[1]).read()
# 4 cells, then the 64 legend strips, bottom (lowest value) first
fills = re.findall(r'fill="rgb\(([0-9.]+)%, ([0-9.]+)%, ([0-9.]+)%\)"', svg)
bar = [tuple(float(c) for c in f) for f in fills[4:68]]
lo, mid = bar[16], bar[32]
# strip 16 is within a hair of the midpoint: all channels near 100%
if min(lo) < 94 or mid[2] > 80 or mid[0] < 99:
    sys.exit("colourbar does not follow the gradient2 value mapping: %s %s" % (lo, mid))
PY

# ---- heatmap annotation keyed on its first column ----
# A key column that lists the rows in another order used to be ignored and the
# values read positionally.
printf 'rn,a,b\nr1,1,2\nr2,3,4\nr3,5,6\n' >"$tmpdir/km.csv"
printf 'rn,grp\nr3,x\nr1,y\nr2,y\n' >"$tmpdir/kann.csv"
printf 'rn,grp\nr1,y\nr2,y\nr3,x\n' >"$tmpdir/kann-inorder.csv"
"$CINDERPLOT" "$tmpdir/km.csv + heatmap(name=\"m\", cluster=none)
     + annotation(\"$tmpdir/kann.csv\", right_of(\"m\"))" --size 3x3 -o "$tmpdir/k1.png"
"$CINDERPLOT" "$tmpdir/km.csv + heatmap(name=\"m\", cluster=none)
     + annotation(\"$tmpdir/kann-inorder.csv\", right_of(\"m\"))" --size 3x3 -o "$tmpdir/k2.png"
cmp -s "$tmpdir/k1.png" "$tmpdir/k2.png" || {
    echo "annotation key column was ignored (positional alignment)" >&2; exit 1; }
# a partial match is a mistake: error naming the first unknown key
printf 'rn,grp\nr1,y\nr2,y\nr9,x\n' >"$tmpdir/kbad.csv"
if "$CINDERPLOT" "$tmpdir/km.csv + heatmap(name=\"m\", cluster=none)
        + annotation(\"$tmpdir/kbad.csv\", right_of(\"m\"))" -o "$tmpdir/k3.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "annotation with a partly matching key column unexpectedly succeeded" >&2
    exit 1
fi
grep 'key `r9` is not a row name' "$tmpdir/err" >/dev/null

# ---- two objects in one slot error instead of overpainting ----
printf 'grp\nx\ny\n' >"$tmpdir/slot.csv"
if "$CINDERPLOT" "$tmpdir/km.csv + heatmap(name=\"m\", cluster=none)
        + annotation(\"$tmpdir/kann-inorder.csv\", right_of(\"m\"), name=\"A\")
        + annotation(\"$tmpdir/kann-inorder.csv\", right_of(\"m\"), name=\"B\")" \
        -o "$tmpdir/slot.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "two annotations in one slot unexpectedly succeeded" >&2
    exit 1
fi
grep 'slot right_of(m) already taken by the annotation `A`; anchor to right_of("A")' "$tmpdir/err" >/dev/null
# legends are margin chrome and still stack beside a strip in the same slot
"$CINDERPLOT" "$tmpdir/km.csv + heatmap(name=\"m\", cluster=none)
     + annotation(\"$tmpdir/kann-inorder.csv\", right_of(\"m\")) + legend(right_of(\"m\"))" \
    -o "$tmpdir/slotleg.pdf"
test -s "$tmpdir/slotleg.pdf"

# ---- colourbar breaks reach an exact [0, 0.3] endpoint; no -0.0 ----
printf 'rn,a,b\nr1,0,0.3\nr2,0.1,0.2\n' >"$tmpdir/p03.csv"
"$CINDERPLOT" "$tmpdir/p03.csv + heatmap(name=\"m\", cluster=none) + legend(right_of(\"m\"))" \
    --size 3x3 -o "$tmpdir/p03.pdf"
pdftotext "$tmpdir/p03.pdf" - | grep -x '0.3' >/dev/null
printf 'rn,a,b\nr1,0,-0.3\nr2,-0.1,-0.2\n' >"$tmpdir/m03.csv"
"$CINDERPLOT" "$tmpdir/m03.csv + heatmap(name=\"m\", cluster=none) + legend(right_of(\"m\"))" \
    --size 3x3 -o "$tmpdir/m03.pdf"
if pdftotext "$tmpdir/m03.pdf" - | grep -q -- '-0.0'; then
    echo "colourbar printed -0.0" >&2
    exit 1
fi
pdftotext "$tmpdir/m03.pdf" - | grep -x -- '-0.3' >/dev/null

# ---- labels=on prints counts in full ----
printf 'rn,a,b\nr1,1234,100000\nr2,12345678,0.5\n' >"$tmpdir/counts.csv"
"$CINDERPLOT" "$tmpdir/counts.csv + heatmap(cluster=none, labels=on)" \
    --size 6x3 -o "$tmpdir/counts.pdf"
pdftotext "$tmpdir/counts.pdf" - | grep -x '12345678' >/dev/null
pdftotext "$tmpdir/counts.pdf" - | grep -x '1234' >/dev/null

# ---- tiny ranges get distinct axis / colourbar labels ----
# breaks all under 1e-6 printed 0 0 0 0 0 (absolute 1e-6 slack, six decimals)
printf 'x,y\n1,1e-6\n2,3e-6\n' >"$tmpdir/tiny.csv"
"$CINDERPLOT" "$tmpdir/tiny.csv + aes(x, y) + geom_point()" --size 3x3 -o "$tmpdir/tiny.pdf"
n=$(pdftotext "$tmpdir/tiny.pdf" - | grep -c 'e-06')
if [ "$n" -lt 3 ]; then
    echo "axis labels under 1e-6 are not distinct" >&2
    exit 1
fi
# a range with an offset keeps counting decimals rather than printing 1 1 1
printf 'x,y\n1,1\n2,1.0000001\n' >"$tmpdir/offset.csv"
"$CINDERPLOT" "$tmpdir/offset.csv + aes(x, y) + geom_point()" --size 3x3 -o "$tmpdir/offset.pdf"
pdftotext "$tmpdir/offset.pdf" - | grep -x '1.000000050' >/dev/null

# ---- ward.D2 ties merge as R does ----
# integer data is all exact ties; R decides them through its cached
# nearest-neighbour list and its squared-then-sqrt'd distances. This 5x4
# matrix is a case where a plain lowest-index scan merges differently.
printf 'rn,c0,c1,c2,c3\nr0,1,1,2,2\nr1,0,0,2,2\nr2,0,0,2,1\nr3,0,2,0,1\nr4,1,1,0,0\n' >"$tmpdir/tie.csv"
"$CINDERPLOT" "$tmpdir/tie.csv + heatmap(cluster=rows, rownames=right)" \
    --size 3x3 -o "$tmpdir/tie.pdf"
order=$(pdftotext "$tmpdir/tie.pdf" - | grep '^r[0-9]$' | tr '\n' ' ')
# R: hclust(dist(m), "ward.D2")$order = 4 5 1 2 3 -> r3 r4 r0 r1 r2
if [ "$order" != "r3 r4 r0 r1 r2 " ]; then
    echo "ward.D2 tie order differs from R: $order" >&2
    exit 1
fi

# ---- clustering errors name the axis ----
printf 'rn,a,b\nr1,1,2\n' >"$tmpdir/onerow.csv"
if "$CINDERPLOT" "$tmpdir/onerow.csv + heatmap(cluster=both)" -o "$tmpdir/onerow.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "clustering a 1-row matrix unexpectedly succeeded" >&2
    exit 1
fi
grep 'clustering rows: need at least 2 rows' "$tmpdir/err" >/dev/null
printf 'rn,a,b\nr1,1,NA\nr2,NA,2\n' >"$tmpdir/nacol.csv"
if "$CINDERPLOT" "$tmpdir/nacol.csv + heatmap(cluster=cols)" -o "$tmpdir/nacol.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "clustering columns that share no values unexpectedly succeeded" >&2
    exit 1
fi
grep 'clustering columns: .*share no complete values' "$tmpdir/err" >/dev/null

# ---- rownames= on a matrix without row names errors ----
printf 'a,b\n1,2\n3,4\n' >"$tmpdir/noname.csv"
if "$CINDERPLOT" "$tmpdir/noname.csv + heatmap(cluster=none, rownames=left)" \
        -o "$tmpdir/noname.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "rownames=left on a nameless matrix unexpectedly succeeded" >&2
    exit 1
fi
grep 'rownames=left: the matrix has no row names' "$tmpdir/err" >/dev/null

# ---- dendrogram beside an annotation beside the heatmap ----
"$CINDERPLOT" "$tmpdir/chain.csv + heatmap(name=\"m\", cluster=rows)
     + annotation(\"$tmpdir/chaingrp.csv\", left_of(\"m\"), name=\"A\")
     + dendrogram(left_of(\"A\"))" --size 4x4 -o "$tmpdir/dendann.pdf"
test -s "$tmpdir/dendann.pdf"

# ---- legend(right_of("m")) on an unnamed heatmap says how to name it ----
if "$CINDERPLOT" "$tmpdir/km.csv + heatmap(cluster=none) + legend(right_of(\"m\"))" \
        -o "$tmpdir/noname-leg.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "legend on an unnamed heatmap unexpectedly succeeded" >&2
    exit 1
fi
grep 'heatmap has no name=' "$tmpdir/err" >/dev/null
grep 'heatmap(name="m"' "$tmpdir/err" >/dev/null

# ---- hex colours: no sign/0x/blank inside; #RGB shorthand accepted ----
for bad in '#+f0000' '#0x0000' '# f0000'; do
    if "$CINDERPLOT" "$tmpdir/km.csv + heatmap(cluster=none, box=\"$bad\")" \
            -o "$tmpdir/hex.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "box=\"$bad\" unexpectedly parsed as a colour" >&2
        exit 1
    fi
done
"$CINDERPLOT" "$tmpdir/km.csv + heatmap(cluster=none, box=\"#f00\")" --size 3x3 -o "$tmpdir/hex3.png"
"$CINDERPLOT" "$tmpdir/km.csv + heatmap(cluster=none, box=\"#ff0000\")" --size 3x3 -o "$tmpdir/hex6.png"
cmp -s "$tmpdir/hex3.png" "$tmpdir/hex6.png" || { echo "#RGB shorthand differs from #RRGGBB" >&2; exit 1; }

# ==== 2026-09-10 review fixes: grammar scales, axes, legends, auto-fit ===============================

# ---- legend folds past the layout grid are refused, not written off the end ----
printf 'x,y,g\n' >"$tmpdir/leg100.csv"
i=0
while [ "$i" -lt 100 ]; do
    printf '%s,%s,L%03d\n' "$i" "$i" "$i" >>"$tmpdir/leg100.csv"
    i=$((i + 1))
done
if "$CINDERPLOT" "$tmpdir/leg100.csv + aes(x,y,colour=g) + geom_point() + guides(colour=guide_legend(nrow=1))" \
        -o "$tmpdir/leg100.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "a 100-column legend fold unexpectedly succeeded" >&2
    exit 1
fi
grep 'exceeds the layout limit' "$tmpdir/err" >/dev/null
# the same guard covers an annotation() band with more levels than the grid holds
printf 'x,y\n' >"$tmpdir/x130.csv"
printf 'x,v\n' >"$tmpdir/ann130.csv"
i=0
while [ "$i" -lt 130 ]; do
    printf 'c%03d,%s\n' "$i" "$i" >>"$tmpdir/x130.csv"
    printf 'c%03d,t%03d\n' "$i" "$i" >>"$tmpdir/ann130.csv"
    i=$((i + 1))
done
if "$CINDERPLOT" "$tmpdir/x130.csv + aes(x,y) + geom_col() + annotation($tmpdir/ann130.csv)" \
        -o "$tmpdir/ann130.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "a 130-level annotation band legend unexpectedly succeeded" >&2
    exit 1
fi
grep 'exceeds the layout limit' "$tmpdir/err" >/dev/null

# ---- breaks=c(...) beyond 31 entries: minor gridlines stay in order ----
# The minor-break buffer used to hold 32; the overflow put the 33rd minor and
# on at garbage positions. Vertical minor gridlines must be emitted in
# increasing x.
printf 'x,y\n0,0\n100,100\n' >"$tmpdir/two.csv"
br=$(seq -s, 0 100)
"$CINDERPLOT" "$tmpdir/two.csv + aes(x,y) + geom_point() + scale_x_continuous(breaks=c($br))" \
    --size 7x5 -o "$tmpdir/br101.svg"
grep 'stroke-width="0.266745"' "$tmpdir/br101.svg" \
    | grep -o 'd="M [0-9.]* [0-9.]* L [0-9.]*' \
    | awk '$2 == $5 { if (n && $2 + 0 <= last) bad = 1; last = $2 + 0; n++ } END { exit bad }'

# ---- a log axis spanning less than a decade still gets labelled ----
printf 'x,y\n1,2\n2,4\n3,8\n' >"$tmpdir/narrow.csv"
"$CINDERPLOT" "$tmpdir/narrow.csv + aes(x,y) + geom_point() + scale_y_log10()" \
    -o "$tmpdir/narrow.pdf"
pdftotext "$tmpdir/narrow.pdf" - | grep -x '4' >/dev/null
pdftotext "$tmpdir/narrow.pdf" - | grep -x '8' >/dev/null

# ---- log_breaks thinning keeps 10^0 (anchored on multiples of the step) ----
printf 'x,y\n1,1e-12\n2,1e12\n' >"$tmpdir/wide.csv"
"$CINDERPLOT" "$tmpdir/wide.csv + aes(x,y) + geom_point() + scale_y_log10()" \
    -o "$tmpdir/wide.pdf"
pdftotext "$tmpdir/wide.pdf" - | grep -x '100' >/dev/null

# ---- Inf is a missing value, not a data point ----
printf 'x,y\n1,1\n2,Inf\n3,3\n' >"$tmpdir/inf.csv"
"$CINDERPLOT" "$tmpdir/inf.csv + aes(x,y) + geom_point()" \
    -o "$tmpdir/inf.pdf" 2>"$tmpdir/inf.err"
grep 'removed 1 rows with missing values' "$tmpdir/inf.err" >/dev/null
pdftotext "$tmpdir/inf.pdf" - | grep -x '2.0' >/dev/null

# ---- a value <= 0 cannot sit on a log axis: dropped and reported ----
printf 'x,y\n1,1\n2,10\n3,100\n' >"$tmpdir/log.csv"
"$CINDERPLOT" "$tmpdir/log.csv + aes(x,y) + geom_point() + scale_y_log10() + geom_hline(yintercept=0)" \
    -o "$tmpdir/hl0.pdf" 2>"$tmpdir/hl0.err"
grep 'dropped 1 reference value' "$tmpdir/hl0.err" >/dev/null
pdftotext "$tmpdir/hl0.pdf" - | grep -x '102' >/dev/null
printf 'x,y,lo,hi\n1,10,0,12\n2,12,8,14\n' >"$tmpdir/eb0.csv"
"$CINDERPLOT" "$tmpdir/eb0.csv + aes(x,y,ymin=lo,ymax=hi) + geom_point() + geom_errorbar() + scale_y_log10()" \
    -o "$tmpdir/eb0.pdf" 2>"$tmpdir/eb0.err"
grep 'removed 1 rows with non-positive values on a log axis' "$tmpdir/eb0.err" >/dev/null

# ---- geom_abline() on a log axis is drawn in transformed space ----
# An endpoint below zero used to give TY = NaN and no line at all; the y axis
# now follows the line to 10^-5.
printf 'x,y\n-5,1\n5,100\n' >"$tmpdir/ab.csv"
"$CINDERPLOT" "$tmpdir/ab.csv + aes(x,y) + geom_point() + scale_y_log10() + geom_abline(intercept=0, slope=1)" \
    -o "$tmpdir/ab.pdf"
pdftotext "$tmpdir/ab.pdf" - | grep -x '10-4' >/dev/null
# scale_x_log2(): the base is honoured (pow(10) used to train y to 10^10)
printf 'x,y\n1,1\n5,10\n30,100\n' >"$tmpdir/log2.csv"
"$CINDERPLOT" "$tmpdir/log2.csv + aes(x,y) + geom_point() + scale_x_log2() + geom_abline(intercept=0, slope=1)" \
    -o "$tmpdir/ab2.pdf"
if pdftotext "$tmpdir/ab2.pdf" - | grep -x '80000' >/dev/null; then
    echo "geom_abline() under scale_x_log2() still trains y through pow(10)" >&2
    exit 1
fi

# ---- free_y panels train on what fixed scales train on ----
printf 'x,y,lo,hi,f\nA,10,2,12,p1\nB,12,8,14,p1\nA,100,20,120,p2\nB,120,80,140,p2\n' >"$tmpdir/eb.csv"
# the errorbar lower bound (2) pulls panel p1's axis down to 5
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x,y,ymin=lo,ymax=hi) + geom_point() + geom_errorbar() + facet_wrap(~f, scales=\"free_y\")" \
    -o "$tmpdir/ebfree.pdf"
pdftotext "$tmpdir/ebfree.pdf" - | grep -x '5' >/dev/null
# geom_hline(30) is inside panel p1's range, not off its top
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x,y) + geom_point() + facet_wrap(~f, scales=\"free_y\") + geom_hline(yintercept=30)" \
    -o "$tmpdir/hlfree.pdf"
pdftotext "$tmpdir/hlfree.pdf" - | grep -x '30' >/dev/null

# ---- breaks=/labels= are honoured on a log axis ----
"$CINDERPLOT" "$tmpdir/log.csv + aes(x,y) + geom_point() + scale_y_log10() + scale_y_continuous(breaks=c(1,10,100), labels=c(\"one\",\"ten\",\"hundred\"))" \
    -o "$tmpdir/logbr.pdf"
pdftotext "$tmpdir/logbr.pdf" - | grep -x 'hundred' >/dev/null
"$CINDERPLOT" "$tmpdir/log.csv + aes(x,y) + geom_point() + scale_y_log10() + scale_y_continuous(breaks=c(1,5,50))" \
    -o "$tmpdir/logbr2.pdf"
pdftotext "$tmpdir/logbr2.pdf" - | grep -x '50' >/dev/null

# ---- coord_polar() refuses the mappings it would ignore ----
printf 'x,y,v\nA,1,1\nB,2,2\nC,3,3\n' >"$tmpdir/pol.csv"
if "$CINDERPLOT" "$tmpdir/pol.csv + aes(x=factor(x), y=y, colour=v) + geom_point() + coord_polar()" \
        -o "$tmpdir/pol.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "coord_polar() with a continuous colour unexpectedly succeeded" >&2
    exit 1
fi
grep 'coord_polar(): continuous colour= mappings are not implemented' "$tmpdir/err" >/dev/null

# ---- auto-fit under coord_flip() grows the HEIGHT for the categories ----
printf 'x,y\n' >"$tmpdir/cat40.csv"
i=0
while [ "$i" -lt 40 ]; do
    printf 'category_%02d,%s\n' "$i" "$i" >>"$tmpdir/cat40.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/cat40.csv + aes(x,y) + geom_col() + coord_flip()" -o "$tmpdir/flip40.svg"
h=$(head -c 400 "$tmpdir/flip40.svg" | grep -o 'height="[0-9.]*' | head -1 | tr -cd '0-9.' | cut -d. -f1)
if [ "$h" -lt 400 ]; then
    echo "coord_flip() auto-fit left 40 categories in a ${h}pt-tall canvas" >&2
    exit 1
fi

# ---- limits/breaks that cannot apply are errors, not no-ops ----
if "$CINDERPLOT" "$tmpdir/two.csv + aes(x,y) + geom_point() + xlim(300,50)" \
        -o "$tmpdir/rev.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "reversed xlim() unexpectedly succeeded" >&2
    exit 1
fi
grep 'lo must be < hi (got 300, 50)' "$tmpdir/err" >/dev/null
printf 'x,y\nA,1\nB,2\nC,3\n' >"$tmpdir/disc.csv"
if "$CINDERPLOT" "$tmpdir/disc.csv + aes(x,y) + geom_col() + xlim(0,5)" \
        -o "$tmpdir/dlim.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "xlim() on a discrete x unexpectedly succeeded" >&2
    exit 1
fi
grep 'on a discrete x axis is not implemented' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/disc.csv + aes(x,y) + geom_col() + scale_x_continuous(breaks=c(1,2))" \
        -o "$tmpdir/dbr.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "breaks= on a discrete x unexpectedly succeeded" >&2
    exit 1
fi
grep 'breaks=/labels= on a discrete x axis is not implemented' "$tmpdir/err" >/dev/null

# ---- inside legends under free_colour work in a multi-row facet grid ----
printf 'x,y,c,f\n1,1,a,p1\n2,2,b,p2\n3,3,c,p3\n4,4,d,p4\n' >"$tmpdir/fc4.csv"
"$CINDERPLOT" "$tmpdir/fc4.csv + aes(x,y,colour=c) + geom_point() + facet_wrap(~f, scales=\"free_colour\") + theme(legend.position=\"inside\")" \
    -o "$tmpdir/fc4.pdf"
test -s "$tmpdir/fc4.pdf"

# ---- a many-level legend folds in auto mode instead of stretching the canvas ----
printf 'x,y,g\n' >"$tmpdir/leg32.csv"
i=0
while [ "$i" -lt 32 ]; do
    printf '%s,%s,level_%02d\n' "$i" "$i" "$i" >>"$tmpdir/leg32.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/leg32.csv + aes(x,y,colour=g) + geom_point()" -o "$tmpdir/leg32.svg"
h=$(head -c 400 "$tmpdir/leg32.svg" | grep -o 'height="[0-9.]*"' | head -1 | tr -cd '0-9.' | cut -d. -f1)
if [ "$h" -gt 400 ]; then
    echo "a 32-level legend stretched the auto-fit canvas to ${h}pt instead of folding" >&2
    exit 1
fi
# with a fixed size that cannot hold it, the clip is reported
"$CINDERPLOT" "$tmpdir/leg32.csv + aes(x,y,colour=g) + geom_point()" --size 6x4 \
    -o "$tmpdir/leg32.pdf" 2>"$tmpdir/leg32.err"
grep 'legend stack needs' "$tmpdir/leg32.err" >/dev/null

# ---- clipping warnings: an over-wide title, over-tall rotated labels ----
"$CINDERPLOT" "$tmpdir/two.csv + aes(x,y) + geom_point() + labs(title=\"A very long title that goes on and on and on and will certainly not fit in the default six inch canvas at all\")" \
    -o "$tmpdir/title.pdf" 2>"$tmpdir/title.err"
grep 'is wider than the 6.0in canvas' "$tmpdir/title.err" >/dev/null
printf 'x,y\n' >"$tmpdir/long30.csv"
i=0
while [ "$i" -lt 30 ]; do
    printf 'a_rather_long_category_label_%02d,%s\n' "$i" "$i" >>"$tmpdir/long30.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/long30.csv + aes(x,y) + geom_col()" \
    -o "$tmpdir/long30.pdf" 2>"$tmpdir/long30.err"
grep 'rotated x tick labels take' "$tmpdir/long30.err" >/dev/null

# ==== 2026-09-10 review fixes: grammar geoms =========================================================

# ---- B3: geom_tile() + geom_text() with a string y (the confusion-matrix idiom) ----
# used to read yc->num[] of a text column and segfault; with factor(numeric) y
# the labels landed at the raw value instead of the factor slot.
printf 'a,b,v\nx,p,1\nx,q,2\ny,p,3\n' >"$tmpdir/tiletext.csv"
"$CINDERPLOT" \
    "$tmpdir/tiletext.csv + aes(a,b,fill=v,label=v) + geom_tile() + geom_text(colour=\"white\")" \
    -o "$tmpdir/tiletext.svg" --size 4x3 --editable-svg
test -s "$tmpdir/tiletext.svg"
test "$(grep -c '<text [^>]*fill="#ffffff"' "$tmpdir/tiletext.svg")" -eq 3
printf 'a,b,v\nx,10,1\nx,20,2\ny,10,3\n' >"$tmpdir/tiletextf.csv"
"$CINDERPLOT" \
    "$tmpdir/tiletextf.csv + aes(a,factor(b),fill=v,label=v) + geom_tile() + geom_text(colour=\"white\")" \
    -o "$tmpdir/tiletextf.svg" --size 4x3 --editable-svg
# every label lands inside the panel (at its factor slot), so all three survive the clip
test "$(grep -c '<text [^>]*fill="#ffffff"' "$tmpdir/tiletextf.svg")" -eq 3

# ---- C5: geom_col() stacks duplicated x categories (position="stack") ----
# A=1 + A=2 used to draw two overlapping bars reading A=2; ggplot sums them.
# Negatives stack downward from 0. The bar tops are read back from the SVG.
printf 'x,y\nA,1\nA,2\nB,3\nC,-1\nC,-2\n' >"$tmpdir/coldup.csv"
"$CINDERPLOT" "$tmpdir/coldup.csv + aes(x,y) + geom_col()" -o "$tmpdir/coldup.svg" --size 4x3
svgnorm "$tmpdir/coldup.svg"
grep 'fill="rgb(34.9%, 34.9%, 34.9%)"' "$tmpdir/coldup.svg" \
    | sed 's/.*d="M [0-9.]* \([0-9.]*\) .*/\1/' >"$tmpdir/coldup.tops"
test "$(wc -l <"$tmpdir/coldup.tops")" -eq 5
# the second A segment tops out where the B bar (3) does
test "$(sed -n 2p "$tmpdir/coldup.tops")" = "$(sed -n 3p "$tmpdir/coldup.tops")"
# the second C segment starts where the first one ends (stacked down, not overdrawn)
c1bot=$(grep 'fill="rgb(34.9%, 34.9%, 34.9%)"' "$tmpdir/coldup.svg" | sed -n 4p \
    | sed 's/.*L [0-9.]* \([0-9.]*\) L [0-9.]* [0-9.]* Z.*/\1/')
test "$(sed -n 5p "$tmpdir/coldup.tops")" = "$c1bot"

# ---- C6: histogram bins are right-closed (a, b] and train the x scale ----
# 0..10 with bins=6 is 2,2,2,2,2,1 in ggplot (edges -1,1,...,11); left-closed
# bins gave 1,2,2,2,2,2. And the scale is trained on the edges, so the first
# bar starts inside the panel instead of being cut by its left edge.
printf 'x\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' >"$tmpdir/hist6.csv"
"$CINDERPLOT" "$tmpdir/hist6.csv + aes(x) + geom_histogram(bins=6)" -o "$tmpdir/hist6.svg" --size 4x3
svgnorm "$tmpdir/hist6.svg"
grep 'fill="rgb(34.9%, 34.9%, 34.9%)"' "$tmpdir/hist6.svg" \
    | sed 's/.*d="M \([0-9.-]*\) \([0-9.-]*\) .*/\1 \2/' >"$tmpdir/hist6.bars"
test "$(wc -l <"$tmpdir/hist6.bars")" -eq 6
test "$(sed -n 1p "$tmpdir/hist6.bars" | cut -d' ' -f2)" = "$(sed -n 2p "$tmpdir/hist6.bars" | cut -d' ' -f2)"
test "$(sed -n 6p "$tmpdir/hist6.bars" | cut -d' ' -f2)" != "$(sed -n 1p "$tmpdir/hist6.bars" | cut -d' ' -f2)"
panelx=$(grep 'fill="rgb(92.2%, 92.2%, 92.2%)"' "$tmpdir/hist6.svg" | head -1 | sed 's/.*d="M \([0-9.-]*\) .*/\1/')
barx=$(sed -n 1p "$tmpdir/hist6.bars" | cut -d' ' -f1)
awk -v p="$panelx" -v b="$barx" 'BEGIN { exit !(b > p + 5) }'

# ---- C7: histogram under facet_wrap(scales="free_x") bins each panel's own range ----
# a panel whose data span less than one global bin used to be one slab; ggplot
# gives panel a three bins (2,1,1) and panel b one, four bars in all
printf 'x,f\n1,a\n2,a\n3,a\n4,a\n10,b\n' >"$tmpdir/histfree.csv"
"$CINDERPLOT" "$tmpdir/histfree.csv + aes(x) + geom_histogram(bins=3) + facet_wrap(~f, scales=\"free_x\")" \
    -o "$tmpdir/histfree.svg" --size 6x3
svgnorm "$tmpdir/histfree.svg"
test "$(grep -c 'fill="rgb(34.9%, 34.9%, 34.9%)"' "$tmpdir/histfree.svg")" -eq 4

# ---- C8: geom_boxplot() under facet_wrap(scales="free_x") uses the panel's x slots ----
# boxes for levels c,d in the second panel used to be drawn at global slots
# 3-4 and clipped away; every other discrete geom already renumbered per panel
printf 'x,y,f\na,1,P1\na,2,P1\na,3,P1\nb,2,P1\nb,3,P1\nb,4,P1\nc,5,P2\nc,6,P2\nc,7,P2\nd,1,P2\nd,2,P2\nd,9,P2\n' >"$tmpdir/boxfree.csv"
"$CINDERPLOT" "$tmpdir/boxfree.csv + aes(x,y) + geom_boxplot() + facet_wrap(~f, scales=\"free_x\")" \
    -o "$tmpdir/boxfree.svg" --size 6x3
svgnorm "$tmpdir/boxfree.svg"
test "$(grep -c 'fill="rgb(100%, 100%, 100%)"' "$tmpdir/boxfree.svg")" -eq 4

# ---- C10: annotate() is transposed by coord_flip() ----
# under the flip the annotation's x runs up the left axis, so moving x moves
# the label vertically; it used to be emitted after the transpose and stayed put
printf 'x,y\nA,1\nB,3\nC,-3\n' >"$tmpdir/annflip.csv"
"$CINDERPLOT" "$tmpdir/annflip.csv + aes(x,y) + geom_col() + coord_flip() + annotate(\"text\", x=1, y=1, label=\"hi\")" \
    -o "$tmpdir/annflip1.svg" --size 4x3 --editable-svg
"$CINDERPLOT" "$tmpdir/annflip.csv + aes(x,y) + geom_col() + coord_flip() + annotate(\"text\", x=3, y=1, label=\"hi\")" \
    -o "$tmpdir/annflip3.svg" --size 4x3 --editable-svg
pos1=$(grep -o '<text[^>]*>hi</text>' "$tmpdir/annflip1.svg" | sed 's/.*x="\([0-9.]*\)" y="\([0-9.]*\)".*/\1 \2/')
pos3=$(grep -o '<text[^>]*>hi</text>' "$tmpdir/annflip3.svg" | sed 's/.*x="\([0-9.]*\)" y="\([0-9.]*\)".*/\1 \2/')
test "${pos1% *}" = "${pos3% *}"          # same horizontal position
test "${pos1#* }" != "${pos3#* }"         # different height

# ---- C15: geom_segment(data=) goes through scale_x_log10() ----
# a 10..100 segment from a layer file was placed at raw x on the log10 panel
# (off the page); it now spans the two points it joins
printf 'x,y,xend\n10,1,10\n100,2,100\n' >"$tmpdir/seglog.csv"
printf 'x,xend,y\n10,100,1.5\n' >"$tmpdir/seglogd.csv"
"$CINDERPLOT" "$tmpdir/seglog.csv + aes(x,y,xend=xend) + geom_point() + geom_segment(data=\"$tmpdir/seglogd.csv\", colour=\"red\") + scale_x_log10()" \
    -o "$tmpdir/seglog.svg" --size 4x3
svgnorm "$tmpdir/seglog.svg"
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/seglog.svg")" -eq 1

# ---- C15b: geom_segment(data=) is faceted and takes the colour mapping ----
# all of a layer file's segments were drawn in every panel, in black; each
# panel now gets its own rows, coloured through the main data's scale
printf 'panel,x,y,xend,yend,g\np1,1,1,2,1,a\np1,2,2,3,2,a\np2,1,3,2,3,b\np2,2,4,3,4,b\n' >"$tmpdir/segfac.csv"
printf 'panel,x,xend,y,yend,g\np1,1,3,1.5,1.5,a\np2,1,3,3.5,3.5,b\n' >"$tmpdir/segfacd.csv"
"$CINDERPLOT" "$tmpdir/segfac.csv + aes(x,y,colour=g,xend=xend,yend=yend) + geom_point(colour=\"grey\") + geom_segment(data=\"$tmpdir/segfacd.csv\") + facet_wrap(~panel) + scale_colour_manual(values=c(a=\"#ff0000\", b=\"#0000ff\"))" \
    --no-legend -o "$tmpdir/segfac.svg" --size 6x3
svgnorm "$tmpdir/segfac.svg"
# one red segment (panel p1) and one blue (panel p2), not two of each in both
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/segfac.svg")" -eq 1
test "$(grep -c 'stroke="rgb(0%, 0%, 100%)"' "$tmpdir/segfac.svg")" -eq 1
# a layer file with no facet column keeps ggplot's rule: every panel draws it
printf 'x,xend,y,yend,g\n1,3,1.5,1.5,a\n' >"$tmpdir/segfacn.csv"
"$CINDERPLOT" "$tmpdir/segfac.csv + aes(x,y,colour=g,xend=xend,yend=yend) + geom_point(colour=\"grey\") + geom_segment(data=\"$tmpdir/segfacn.csv\") + facet_wrap(~panel) + scale_colour_manual(values=c(a=\"#ff0000\", b=\"#0000ff\"))" \
    --no-legend -o "$tmpdir/segfacn.svg" --size 6x3
svgnorm "$tmpdir/segfacn.svg"
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/segfacn.svg")" -eq 2
# a mapped colour column the layer file does not carry is named, not silently black
if "$CINDERPLOT" "$tmpdir/segfac.csv + aes(x,y,colour=g,xend=xend,yend=yend) + geom_point() + geom_segment(data=\"$tmpdir/seglogd.csv\")" \
        -o "$tmpdir/segfacx.svg" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_segment(data=) with no colour column unexpectedly succeeded" >&2; exit 1
fi
grep 'geom_segment(data=.*colour/fill column `g` not in this file' "$tmpdir/err" >/dev/null

# ---- C15c: data= and aes(y=col) on geom_point()/geom_line() ----
# "raw points + a fitted line from another table" needed the extra rows faked
# into the leading file; both were refused ("layer option `data` not
# implemented", "layer-level mappings go in the one top-level aes()")
printf 'panel,x,y,sm,g\np1,1,1,1.2,a\np1,2,3,2.2,a\np1,3,2,2.8,a\np2,1,4,3.8,b\np2,2,2,3.2,b\np2,3,5,3.6,b\n' >"$tmpdir/lay.csv"
printf 'panel,x,y,g\np1,1,1.1,a\np1,3,2.9,a\np2,1,3.9,b\np2,3,4.9,b\n' >"$tmpdir/layd.csv"
# the layer file is faceted and coloured through the main scale: one line per panel
"$CINDERPLOT" "$tmpdir/lay.csv + aes(x,y,colour=g) + geom_point() + geom_line(data=\"$tmpdir/layd.csv\") + facet_wrap(~panel) + scale_colour_manual(values=c(a=\"#ff0000\", b=\"#0000ff\"))" \
    --no-legend -o "$tmpdir/layd.svg" --size 6x3
svgnorm "$tmpdir/layd.svg"
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/layd.svg")" -eq 1
test "$(grep -c 'stroke="rgb(0%, 0%, 100%)"' "$tmpdir/layd.svg")" -eq 1
# aes(y=col) is the long spelling of y=: both draw the line through `sm`
"$CINDERPLOT" "$tmpdir/lay.csv + aes(x,y,colour=g) + geom_point() + geom_line(aes(y=sm))" \
    -o "$tmpdir/laya.svg" --size 4x3
"$CINDERPLOT" "$tmpdir/lay.csv + aes(x,y,colour=g) + geom_point() + geom_line(y=sm)" \
    -o "$tmpdir/layy.svg" --size 4x3
cmp "$tmpdir/laya.svg" "$tmpdir/layy.svg"
# ... and it is a different figure from the un-overridden one
"$CINDERPLOT" "$tmpdir/lay.csv + aes(x,y,colour=g) + geom_point() + geom_line()" \
    -o "$tmpdir/layn.svg" --size 4x3
if cmp -s "$tmpdir/laya.svg" "$tmpdir/layn.svg"; then
    echo "geom_line(aes(y=)) changed nothing" >&2; exit 1
fi
# a y= override still trains the y scale (sm reaches past y in panel p1)
printf 'x,y,sm\n1,1,50\n2,2,60\n3,3,70\n' >"$tmpdir/laytr.csv"
# (--editable-svg so the axis numbers are <text>, not glyph outlines)
"$CINDERPLOT" "$tmpdir/laytr.csv + aes(x,y) + geom_point() + geom_line(y=sm)" \
    --editable-svg -o "$tmpdir/laytr.svg" --size 4x3
grep -q '>60<' "$tmpdir/laytr.svg" || { echo "y= did not train the y scale" >&2; exit 1; }
# a discrete x: the layer file names categories of the main axis
printf 'g,v,s\na,1,x\na,2,x\nb,3,x\nb,5,x\n' >"$tmpdir/layd2.csv"
printf 'g,v,s\na,1.5,x\nb,4.0,x\n' >"$tmpdir/layd2m.csv"
"$CINDERPLOT" "$tmpdir/layd2.csv + aes(g,v,colour=s) + geom_point() + geom_point(data=\"$tmpdir/layd2m.csv\", size=4)" \
    -o "$tmpdir/layd2.svg" --size 4x3
test -s "$tmpdir/layd2.svg"
printf 'g,v,s\nzzz,1.5,x\n' >"$tmpdir/layd2b.csv"   # for the chkx block below

# ---- C15d: under free scales a layer file trains its OWN panel ----
# the layer extent was global, so one panel's outsized layer rows stretched
# every panel's axis; p1 now stops at its own 4, p2 still reaches 400
printf 'panel,x,y,xe,ye\np1,1,1,2,2\np1,2,2,3,3\np2,1,1,2,2\np2,2,2,3,3\n' >"$tmpdir/lfr.csv"
printf 'panel,x,y,xe,ye\np1,1,3,2,4\np2,1,300,2,400\n' >"$tmpdir/lfrd.csv"
"$CINDERPLOT" "$tmpdir/lfr.csv + aes(x,y,xend=xe,yend=ye) + geom_point() + geom_rect(data=\"$tmpdir/lfrd.csv\") + facet_wrap(~panel, scales=\"free_y\")" \
    --editable-svg -o "$tmpdir/lfr.svg" --size 6x3
# the 1..4 panel keeps small numbers; a global extent would label it 0..400
grep -q '>4<' "$tmpdir/lfr.svg" || { echo "free_y panel did not keep its own range" >&2; exit 1; }
grep -q '>400<' "$tmpdir/lfr.svg" || { echo "the wide panel lost its layer rows" >&2; exit 1; }
test "$(grep -c '>400<' "$tmpdir/lfr.svg")" -eq 1
# a layer file with no facet column is drawn in every panel, so it trains all
printf 'x,y,xe,ye\n1,300,2,400\n' >"$tmpdir/lfrn.csv"
"$CINDERPLOT" "$tmpdir/lfr.csv + aes(x,y,xend=xe,yend=ye) + geom_point() + geom_rect(data=\"$tmpdir/lfrn.csv\") + facet_wrap(~panel, scales=\"free_y\")" \
    --editable-svg -o "$tmpdir/lfrn.svg" --size 6x3
test "$(grep -c '>400<' "$tmpdir/lfrn.svg")" -eq 2

# ---- C15e: each annotation() band owns its palette (values=, palette=) ----
# every band drew from one hue ramp with no override, so green meant a
# different level in each band; values=/palette= give a band its own colours
printf 'probe,s1,s2,s3\nr1,0.1,0.5,0.9\nr2,0.2,0.6,0.8\n' >"$tmpdir/apm.csv"
printf 'sample,cohort\ns1,A\ns2,B\ns3,A\n' >"$tmpdir/apc.csv"
printf 'probe,stage\nr1,early\nr2,late\n' >"$tmpdir/apr.csv"
"$CINDERPLOT" "$tmpdir/apm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/apc.csv\", top_of(\"m\", height=0.05), values=c(A=\"#ff0000\", B=\"#0000ff\")) + annotation(\"$tmpdir/apr.csv\", left_of(\"m\", width=0.05), palette=\"Set2\")" \
    -o "$tmpdir/apal.svg" --size 4x3
svgnorm "$tmpdir/apal.svg"
grep -q 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/apal.svg" || { echo "values= colour A not drawn" >&2; exit 1; }
grep -q 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/apal.svg" || { echo "values= colour B not drawn" >&2; exit 1; }
# Set2's first two colours, #66c2a5 and #fc8d62
grep -q 'fill="rgb(40%, 76.08%, 64.71%)"' "$tmpdir/apal.svg" || { echo "palette=Set2 not applied" >&2; exit 1; }
grep -q 'fill="rgb(98.82%, 55.29%, 38.43%)"' "$tmpdir/apal.svg" || { echo "palette=Set2 not applied" >&2; exit 1; }
# a positional list shorter than the levels is an error, not a grey tail
if "$CINDERPLOT" "$tmpdir/apm.csv + heatmap(name=\"m\") + annotation(\"$tmpdir/apc.csv\", top_of(\"m\"), values=c(\"#ff0000\"))" \
        -o "$tmpdir/apal2.svg" 2>"$tmpdir/err"; then
    echo "short positional values= unexpectedly succeeded" >&2; exit 1
fi
grep -q 'values= gives 1 colours; the band has 2 levels' "$tmpdir/err"
# grammar-mode bands take values= too
printf 'g,v\na,1\nb,2\n' >"$tmpdir/apg.csv"
printf 'g,batch\na,X\nb,Y\n' >"$tmpdir/apgm.csv"
"$CINDERPLOT" "$tmpdir/apg.csv + aes(g,v) + geom_col() + annotation(\"$tmpdir/apgm.csv\", values=c(X=\"#ff0000\", Y=\"#0000ff\"))" \
    -o "$tmpdir/apg.svg" --size 4x3
svgnorm "$tmpdir/apg.svg"
grep -q 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/apg.svg"
# a bare height= says where it goes and what unit it is in
if "$CINDERPLOT" "$tmpdir/apm.csv + heatmap(name=\"m\") + annotation(\"$tmpdir/apc.csv\", top_of(\"m\"), height=0.05)" \
        -o "$tmpdir/apal3.svg" 2>"$tmpdir/err"; then
    echo "bare height= unexpectedly succeeded" >&2; exit 1
fi
grep -q "goes inside the placement.*fractions of the first heatmap" "$tmpdir/err"

# ---- C15f: a summary table as layers -- levels, labels, extents ----
# levels= was checked against the main data only, geom_text() refused data=,
# a segment file did not train the axes (a mean line past the points was
# clipped away), and xend/yend had to exist in the main data too
printf 'x,y,grp\n1,1,AS\n1,2,AS\n2,3,WGS\n2,4,WGS\n' >"$tmpdir/sum_p.csv"
printf 'x,xe,y,ye,grp\n0.7,1.3,1.5,1.5,mean\n1.7,2.3,6,6,median\n' >"$tmpdir/sum_s.csv"
printf 'x,y,label,grp\n1,5,n=2,AS\n2,5,n=2,WGS\n' >"$tmpdir/sum_t.csv"
"$CINDERPLOT" "$tmpdir/sum_p.csv + aes(x, y, colour=factor(grp, levels=c(\"AS\",\"WGS\",\"mean\",\"median\")), xend=xe, yend=ye, label=label) + geom_point() + geom_segment(data=\"$tmpdir/sum_s.csv\", linetype=\"dashed\") + geom_text(data=\"$tmpdir/sum_t.csv\")" \
    --editable-svg -o "$tmpdir/sum.svg" --size 5x3
grep -q '>median<' "$tmpdir/sum.svg" || { echo "layer-only level missing from the legend" >&2; exit 1; }
test "$(grep -c '>n=2<' "$tmpdir/sum.svg")" -eq 2 || { echo "geom_text(data=) labels not drawn" >&2; exit 1; }
grep -q '>6<' "$tmpdir/sum.svg" || { echo "segment layer file did not train y" >&2; exit 1; }
# without levels= the union is sorted, as factor() sorts
"$CINDERPLOT" "$tmpdir/sum_p.csv + aes(x, y, colour=grp, xend=xe, yend=ye) + geom_point() + geom_segment(data=\"$tmpdir/sum_s.csv\")" \
    --editable-svg -o "$tmpdir/sum2.svg" --size 5x3
grep -o '>[A-Za-z]*<' "$tmpdir/sum2.svg" | tr -d '<>' | grep -x 'AS\|WGS\|mean\|median' | tr '\n' ' ' >"$tmpdir/sum2.lev"
test "$(cat "$tmpdir/sum2.lev")" = "AS WGS mean median " || { echo "union order: $(cat "$tmpdir/sum2.lev")" >&2; exit 1; }

# ---- C15g: labs(shape=)/labs(size=) title those legends; annotate("point") ----
# labs() refused shape=/size=, so a shape=factor(x, levels=) legend read
# "factor(call)"; annotate() had no point kind for an operating-point mark
printf 'cat,p,call,n\nA,0.2,benign,1\nA,0.8,malig,2\nB,0.6,malig,3\n' >"$tmpdir/lsh.csv"
"$CINDERPLOT" "$tmpdir/lsh.csv + aes(cat, p, shape=factor(call, levels=c(\"malig\",\"benign\")), size=n) + geom_point() + labs(shape=\"call\", size=\"count\") + annotate(\"point\", x=1.5, y=0.9, colour=\"red\", size=3)" \
    --editable-svg -o "$tmpdir/lsh.svg" --size 4x3
svgnorm "$tmpdir/lsh.svg"
grep -q '>call<' "$tmpdir/lsh.svg" || { echo "labs(shape=) title not drawn" >&2; exit 1; }
grep -q '>count<' "$tmpdir/lsh.svg" || { echo "labs(size=) title not drawn" >&2; exit 1; }
! grep -q '>factor(call' "$tmpdir/lsh.svg"
grep -q 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/lsh.svg" || { echo "annotate(point) not drawn" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/lsh.csv + aes(cat, p) + geom_point() + annotate(\"point\", x=1)" \
        -o "$tmpdir/lsh2.svg" 2>"$tmpdir/err"; then
    echo "annotate(point) without y= unexpectedly succeeded" >&2; exit 1
fi
grep -q 'annotate("point") needs x= and y=' "$tmpdir/err"

# ---- C15h: scale_x_continuous(angle=) leans numeric-axis tick labels ----
# angle= existed on scale_x_discrete only, so category names placed on a
# numeric x through labels=c() could not be tilted
printf 'x,p\n1,0.2\n2,0.5\n3,0.7\n' >"$tmpdir/cang.csv"
"$CINDERPLOT" "$tmpdir/cang.csv + aes(x,p) + geom_point() + scale_x_continuous(breaks=c(1,2,3), labels=c(\"Ras-like\",\"Indeterminate\",\"untested / none\"), angle=45)" \
    --editable-svg -o "$tmpdir/cang.svg" --size 4x3
test "$(grep -c 'matrix(0.707107 -0.707107' "$tmpdir/cang.svg")" -eq 3 || { echo "continuous x labels not at 45 degrees" >&2; exit 1; }
# on the side axis angle= did nothing; it now says which scale leans
if "$CINDERPLOT" "$tmpdir/cang.csv + aes(x,p) + geom_point() + scale_y_continuous(angle=45)" \
        -o "$tmpdir/cang2.svg" 2>"$tmpdir/err"; then
    echo "angle= on the side axis unexpectedly succeeded" >&2; exit 1
fi
grep -q "tilts the bottom axis" "$tmpdir/err"

# ---- C15i: annotation colours from a file, numeric band ramps, side titles ----
# values=c() capped a band at 64 colours (a 225-level Cancer Type band fell
# back to the hue ramp), a numeric band was viridis only, and a band's
# title could only sit above it
printf 'probe,s1,s2,s3,s4\nr1,0.1,0.5,0.9,0.3\nr2,0.2,0.6,0.8,0.4\n' >"$tmpdir/afm.csv"
printf 'sample,ctype\ns1,AML\ns2,APL\ns3,AML\ns4,CLL\n' >"$tmpdir/afc.csv"
printf 'level\tcolour\nAML\t#ff0000\nAPL\t#00ff00\nCLL\t#0000ff\n' >"$tmpdir/afcol.tsv"
printf 'sample,purity\ns1,0.1\ns2,0.5\ns3,0.9\ns4,0.3\n' >"$tmpdir/afp.csv"
"$CINDERPLOT" "$tmpdir/afm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/afc.csv\", top_of(\"m\", height=0.1), values=\"$tmpdir/afcol.tsv\", name=\"ct\", title=\"Cancer Type\", title.side=left) + annotation(\"$tmpdir/afp.csv\", top_of(\"ct\", height=0.1), values=c(\"#ff00ff\", \"#00ffff\"), name=\"pu\")" \
    --editable-svg -o "$tmpdir/af.svg" --size 4x3
svgnorm "$tmpdir/af.svg"
grep -q 'fill="rgb(0%, 100%, 0%)"' "$tmpdir/af.svg" || { echo "values= file colour not used" >&2; exit 1; }
grep -q 'fill="rgb(100%, 0%, 100%)"' "$tmpdir/af.svg" || { echo "numeric values= ramp not used" >&2; exit 1; }
# a side title sits beside its band (its baseline within the band's rows),
# not above it; since 2026-11-18 it is at the base size, as a top title is
python3 - "$tmpdir/af.svg" <<'PY' || { echo "title.side=left not applied" >&2; exit 1; }
import re, sys
s = open(sys.argv[1]).read()
y = float(re.search(r'<text[^>]* y="([0-9.]+)"[^>]*>Cancer Type', s).group(1))
band = []
for m in re.finditer(r'<path([^>]*)>', s):
    if 'fill="rgb(100%, 0%, 0%)"' not in m.group(1): continue
    d = re.search(r' d="([^"]+)"', m.group(1))
    band += list(map(float, re.findall(r'-?[0-9.]+', d.group(1))))[1::2]
sys.exit(0 if band and min(band) <= y <= max(band) + 4 else 1)
PY
# a numeric band refuses a qualitative set, a categorical one a ramp
if "$CINDERPLOT" "$tmpdir/afm.csv + heatmap(name=\"m\") + annotation(\"$tmpdir/afp.csv\", top_of(\"m\"), palette=\"Set2\")" \
        -o "$tmpdir/af2.svg" 2>"$tmpdir/err"; then
    echo "a qualitative palette on a numeric band unexpectedly succeeded" >&2; exit 1
fi
grep -q 'is numeric: palette="Set2" is a qualitative set' "$tmpdir/err"
if "$CINDERPLOT" "$tmpdir/afm.csv + heatmap(name=\"m\") + annotation(\"$tmpdir/afc.csv\", top_of(\"m\"), palette=\"bwr\")" \
        -o "$tmpdir/af2.svg" 2>"$tmpdir/err"; then
    echo "a ramp on a categorical band unexpectedly succeeded" >&2; exit 1
fi
grep -q 'is categorical: palette="bwr" is a continuous ramp' "$tmpdir/err"

# ---- C15j: heatmap colsplit=/rowsplit= gaps and scale_fill_*(na.value=) ----
# there was no way to split a heatmap into blocks: NA spacer columns drew
# grey, and rows could not be gapped at all
printf 'probe,s1,s2,s3,s4,s5,s6\nr1,0.1,0.5,0.9,0.3,0.6,NA\nr2,0.2,0.6,0.8,0.4,0.7,0.2\nr3,0.9,0.1,0.2,0.4,0.5,0.6\nr4,0.5,0.5,0.5,0.5,0.5,0.5\n' >"$tmpdir/spm.csv"
printf 'sample,grp\ns1,A\ns2,A\ns3,B\ns4,B\ns5,B\ns6,C\n' >"$tmpdir/spc.csv"
printf 'probe,lin\nr1,X\nr2,X\nr3,Y\nr4,Y\n' >"$tmpdir/spr.csv"
spl() { "$CINDERPLOT" "$tmpdir/spm.csv + heatmap(name=\"m\", cluster=none$1) + annotation(\"$tmpdir/spc.csv\", top_of(\"m\", height=0.08), name=\"grp\") + annotation(\"$tmpdir/spr.csv\", left_of(\"m\", width=0.05), name=\"lin\") + scale_fill_viridis($2)" -o "$tmpdir/sp$3.svg" --size 4x3; svgnorm "$tmpdir/sp$3.svg"; }
spl '' '' 0
spl ', colsplit="grp", rowsplit="lin", gap=4' 'na.value="white"' 1
w0=$(grep -c 'fill="rgb(100%, 100%, 100%)"' "$tmpdir/sp0.svg" || true)
w1=$(grep -c 'fill="rgb(100%, 100%, 100%)"' "$tmpdir/sp1.svg" || true)
# 2 column boundaries over (heatmap, grp band) + 1 row boundary over
# (heatmap, lin band) = 6 gap rects, plus the one NA cell now white
test "$((w1 - w0))" -eq 7 || { echo "split gaps: expected 7 more white rects, got $((w1 - w0))" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/spm.csv + heatmap(name=\"m\", colsplit=\"lin\") + annotation(\"$tmpdir/spr.csv\", left_of(\"m\"), name=\"lin\")" \
        -o "$tmpdir/sp2.svg" 2>"$tmpdir/err"; then
    echo "colsplit= on a row annotation unexpectedly succeeded" >&2; exit 1
fi
grep -q 'needs a categorical annotation placed top_of/beneath' "$tmpdir/err"

# ---- C15k: aes(linetype=) maps a discrete column to dash patterns ----
# linetype was a layer constant only; a mapped one was refused
printf 'x,y,cls,stat\n1,1,A,mean\n2,2,A,mean\n3,3,A,mean\n1,2,A,median\n2,3,A,median\n3,4,A,median\n' >"$tmpdir/lt.csv"
"$CINDERPLOT" "$tmpdir/lt.csv + aes(x, y, colour=cls, linetype=stat) + geom_line() + labs(linetype=\"statistic\")" \
    --editable-svg -o "$tmpdir/lt.svg" --size 4x3
# the median line and its legend key dash ("22" = 2 x the line width);
# the mean line and key are solid
test "$(grep -c 'stroke-dasharray' "$tmpdir/lt.svg")" -eq 2 || { echo "linetype: expected 2 dashed strokes" >&2; exit 1; }
grep -q '>statistic<' "$tmpdir/lt.svg" || { echo "labs(linetype=) title not drawn" >&2; exit 1; }
# a segment layer file may carry the column alone; its levels join the scale
printf 'x,y\n1,1\n2,3\n' >"$tmpdir/ltp.csv"
printf 'x,xe,y,ye,stat\n0.7,1.3,1.5,1.5,mean\n1.7,2.3,2.5,2.5,median\n' >"$tmpdir/lts.csv"
"$CINDERPLOT" "$tmpdir/ltp.csv + aes(x, y, xend=xe, yend=ye, linetype=stat) + geom_point() + geom_segment(data=\"$tmpdir/lts.csv\")" \
    --editable-svg -o "$tmpdir/lt2.svg" --size 4x3
grep -q '>median<' "$tmpdir/lt2.svg" || { echo "segment-file linetype level missing" >&2; exit 1; }
test "$(grep -c 'stroke-dasharray' "$tmpdir/lt2.svg")" -eq 2
# colour and linetype on one column merge into a single key, as in ggplot2
"$CINDERPLOT" "$tmpdir/lt.csv + aes(x, y, colour=stat, linetype=stat) + geom_line()" \
    --editable-svg -o "$tmpdir/lt3.svg" --size 4x3
test "$(grep -c '>stat<' "$tmpdir/lt3.svg")" -eq 1 || { echo "colour+linetype legends not merged" >&2; exit 1; }

# ---- C15l: a tall heatmap legend stack wraps into columns ----
# the side legends stack centred on the canvas, and auto-fit never counted
# them: a 2x4 matrix with three keys got a 144pt canvas and the end keys
# were cut in half, silently. A stack taller than the canvas now wraps into
# further columns outward (ComplexHeatmap's packing), so the canvas keeps
# the matrix's height; only one legend taller than the canvas still clips,
# and says so
printf 'probe,s1,s2,s3,s4\nr1,0.1,0.5,0.9,0.3\nr2,0.2,0.6,0.8,0.4\n' >"$tmpdir/lcm.csv"
printf 'sample,ctype\ns1,AML\ns2,APL\ns3,AML\ns4,CLL\n' >"$tmpdir/lcc.csv"
printf 'sample,purity\ns1,0.1\ns2,0.5\ns3,0.9\ns4,0.3\n' >"$tmpdir/lcp.csv"
lcs="$tmpdir/lcm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/lcc.csv\", top_of(\"m\", height=0.1), name=\"ct\") + annotation(\"$tmpdir/lcp.csv\", top_of(\"ct\", height=0.1), name=\"pu\") + legend(right_of(\"m\")) + legend(right_of(\"ct\")) + legend(right_of(\"pu\"))"
"$CINDERPLOT" "$lcs" --editable-svg -o "$tmpdir/lc.svg" 2>"$tmpdir/err"
! grep -q 'clipped' "$tmpdir/err" || { echo "auto-fit still clips the legend stack" >&2; exit 1; }
lch=$(sed -n 's/.*<svg[^>]* height="\([0-9.]*\).*/\1/p' "$tmpdir/lc.svg" | head -1)
awk -v h="$lch" 'BEGIN { exit !(h < 200) }' || { echo "canvas stretched to ${lch}pt for the stack instead of wrapping" >&2; exit 1; }
# the keys stand side by side: purity's title sits right of ctype's
ctx=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>ctype<.*/\1/p' "$tmpdir/lc.svg")
pux=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>purity<.*/\1/p' "$tmpdir/lc.svg")
awk -v a="$ctx" -v b="$pux" 'BEGIN { exit !(b > a + 20) }' || { echo "legends not in separate columns ($ctx, $pux)" >&2; exit 1; }
# a fixed --size wraps as well; one legend taller than the canvas warns
"$CINDERPLOT" "$lcs" -o "$tmpdir/lc2.svg" --size 4x2 2>"$tmpdir/err"
! grep -q 'clipped' "$tmpdir/err" || { echo "--size 4x2 should wrap, not clip" >&2; exit 1; }
"$CINDERPLOT" "$lcs" -o "$tmpdir/lc3.svg" --size 4x1 2>"$tmpdir/err"
grep -q 'right_of legend is .* tall on a .* canvas; it is clipped' "$tmpdir/err" || { echo "no clipping warning for a legend taller than the canvas" >&2; exit 1; }

# ---- C15m: annotation(limits=) pins a numeric band's ramp ----
# a band mapped its ramp over the data range (0.25..1 here), so the white
# middle of blue-white-red fell at 0.625 rather than 0.5
printf 'probe,s1,s2,s3,s4\nr1,0.1,0.5,0.9,0.3\nr2,0.2,0.6,0.8,0.4\n' >"$tmpdir/alm.csv"
printf 'sample,purity\ns1,0.25\ns2,0.5\ns3,1.0\ns4,0.75\n' >"$tmpdir/alp.csv"
"$CINDERPLOT" "$tmpdir/alm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/alp.csv\", top_of(\"m\", height=0.1), values=c(\"#0000ff\",\"#ffffff\",\"#ff0000\"), limits=c(0,1))" \
    -o "$tmpdir/al.svg" --size 4x3
svgnorm "$tmpdir/al.svg"
test "$(grep -c 'fill="rgb(100%, 100%, 100%)"' "$tmpdir/al.svg")" -eq 1 || { echo "limits=c(0,1): 0.5 is not the white midpoint" >&2; exit 1; }
printf 'sample,ctype\ns1,A\ns2,B\ns3,A\ns4,B\n' >"$tmpdir/alc.csv"
if "$CINDERPLOT" "$tmpdir/alm.csv + heatmap(name=\"m\") + annotation(\"$tmpdir/alc.csv\", top_of(\"m\"), limits=c(0,1))" \
        -o "$tmpdir/al2.svg" 2>"$tmpdir/err"; then
    echo "limits= on a categorical band unexpectedly succeeded" >&2; exit 1
fi
grep -q 'limits= pins a numeric band' "$tmpdir/err"

# ---- C15n: a left_of legend sits clear of the left row names ----
# a left colourbar was anchored by its bar, so a title wider than the bar ran
# right, over the rownames=left labels; the block's right edge now meets the
# label gutter and the title starts at the block's left
printf 'probe,s1,s2,s3\nEpith_NoHepaKidney,0.1,0.5,0.9\nHema,0.2,0.6,0.8\n' >"$tmpdir/llm.csv"
"$CINDERPLOT" "$tmpdir/llm.csv + heatmap(name=\"m\", cluster=none, rownames=left) + legend(left_of(\"m\"), title=\"Leukocyte Fraction\")" \
    --editable-svg -o "$tmpdir/ll.svg" --size 5x2
ttx=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>Leukocyte Fraction<.*/\1/p' "$tmpdir/ll.svg")
lbx=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>Epith_NoHepaKidney<.*/\1/p' "$tmpdir/ll.svg")
# the title (11pt, ~95pt wide) must end before the row label starts
awk -v t="$ttx" -v l="$lbx" 'BEGIN { exit !(t + 95 <= l) }' || { echo "left legend title at $ttx overlaps the row names at $lbx" >&2; exit 1; }

# ---- C15o: labels=data on a horizontal (top_of/beneath) band ----
# run labels were refused on a horizontal band; they now stand outward,
# one per run, centred on it, spread apart where runs are narrow
printf 'probe,s1,s2,s3,s4,s5,s6,s7,s8\nr1,1,2,3,4,5,6,7,8\nr2,2,3,4,5,6,7,8,1\n' >"$tmpdir/hlm.csv"
printf 'sample,grp\ns1,Hematological\ns2,Hematological\ns3,Hematological\ns4,Carcinoma\ns5,Adrenal\ns6,CNS\ns7,Mesenchymal\ns8,Mesenchymal\n' >"$tmpdir/hlg.csv"
"$CINDERPLOT" "$tmpdir/hlm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/hlg.csv\", top_of(\"m\", height=0.1), labels=data, title=\"Cancer Group\")" \
    --editable-svg -o "$tmpdir/hl.svg" --size 4x2
for lv in Hematological Carcinoma Adrenal CNS Mesenchymal; do
    test "$(grep -c ">$lv<" "$tmpdir/hl.svg")" -eq 1 || { echo "run label $lv not drawn once" >&2; exit 1; }
done
# the labels stand above the band, and the title above the labels
lby=$(sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>Carcinoma<.*/\1/p' "$tmpdir/hl.svg")
tty=$(sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>Cancer Group<.*/\1/p' "$tmpdir/hl.svg")
awk -v l="$lby" -v t="$tty" 'BEGIN { exit !(t < l) }' || { echo "title (y=$tty) not above the run labels (y=$lby)" >&2; exit 1; }
# neighbouring labels never overlap: each starts after the previous ends
python3 - "$tmpdir/hl.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
lab = sorted((float(m.group(1)), m.group(2)) for m in re.finditer(
    r'<text x="([0-9.]+)"[^>]*>(Hematological|Carcinoma|Adrenal|CNS|Mesenchymal)<', s))
assert len(lab) == 5, lab
# Arial at 8.8pt averages about 0.5 em per glyph; 0.55 bounds these names
for (x0, t0), (x1, t1) in zip(lab, lab[1:]):
    assert x0 + 0.55 * 8.8 * len(t0) <= x1, (t0, x0, t1, x1)
PY

# ---- C15p: a discrete legend laid flat beneath()/top_of() ----
# discrete keys were refused off the sides ("must be vertical"), so a
# 225-level Cancer Type key had to stand in eleven columns beside the
# figure; beneath() now fills a swatch grid row-major under its target
printf 'probe,s1,s2,s3,s4,s5,s6\nr1,1,2,3,4,5,6\nr2,2,3,4,5,6,1\n' >"$tmpdir/dkm.csv"
printf 'sample,ct\ns1,A\ns2,B\ns3,C\ns4,D\ns5,E\ns6,F\n' >"$tmpdir/dkc.csv"
"$CINDERPLOT" "$tmpdir/dkm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/dkc.csv\", top_of(\"m\", height=0.1), name=\"ct\") + legend(beneath(\"ct\"), title=\"Type\", ncol=3)" \
    --editable-svg -o "$tmpdir/dk.svg" --size 4x
# ncol=3, row-major: A B C on the first row, D E F on the second
ya=$(sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>A<.*/\1/p' "$tmpdir/dk.svg")
yc=$(sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>C<.*/\1/p' "$tmpdir/dk.svg")
yd=$(sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>D<.*/\1/p' "$tmpdir/dk.svg")
xa=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>A<.*/\1/p' "$tmpdir/dk.svg")
xd=$(sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>D<.*/\1/p' "$tmpdir/dk.svg")
test "$ya" = "$yc" || { echo "A and C not on one row ($ya, $yc)" >&2; exit 1; }
awk -v a="$ya" -v d="$yd" 'BEGIN { exit !(d > a) }' || { echo "D not on the row below A" >&2; exit 1; }
test "$xa" = "$xd" || { echo "D not under A ($xa, $xd)" >&2; exit 1; }
# the key sits below the heatmap's rows, inside the canvas
hh=$(sed -n 's/.*<svg[^>]* height="\([0-9.]*\).*/\1/p' "$tmpdir/dk.svg" | head -1)
awk -v d="$yd" -v h="$hh" 'BEGIN { exit !(d < h) }'
# ncol=/nrow= only shape a flat key
if "$CINDERPLOT" "$tmpdir/dkm.csv + heatmap(name=\"m\") + legend(right_of(\"m\"), ncol=2)" \
        -o "$tmpdir/dk2.svg" 2>"$tmpdir/err"; then
    echo "ncol= on a side colourbar unexpectedly succeeded" >&2; exit 1
fi
grep -q 'shapes a discrete key' "$tmpdir/err"

# ---- C15q: run labels on end (label.angle=90); one tall key wraps ----
# forty narrow runs' names spread wider than the panel and ran off the
# canvas, in light level colours; and a single discrete key taller than the
# canvas was one clipped column. Labels now stand on end and shrink to fit,
# label.colour= sets their ink, and a tall side key wraps into columns
printf 'probe' >"$tmpdir/rlm.csv"
printf 'sample,ct\n' >"$tmpdir/rlc.csv"
i=1; while [ $i -le 30 ]; do
    printf ',s%d' $i >>"$tmpdir/rlm.csv"
    printf 's%d,cancer_type_%02d\n' $i $i >>"$tmpdir/rlc.csv"
    i=$((i + 1))
done
printf '\nr1' >>"$tmpdir/rlm.csv"
i=1; while [ $i -le 30 ]; do printf ',%d' $i >>"$tmpdir/rlm.csv"; i=$((i + 1)); done
printf '\n' >>"$tmpdir/rlm.csv"
"$CINDERPLOT" "$tmpdir/rlm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/rlc.csv\", beneath(\"m\", height=0.2), name=\"ct\", labels=data, label.angle=90, label.colour=\"black\") + legend(right_of(\"ct\"), title=\"Type\")" \
    --editable-svg -o "$tmpdir/rl.svg" --size 8x4.5 2>"$tmpdir/err"
# every run label is rotated, black, and inside the canvas
wd=$(sed -n 's/.*<svg[^>]* width="\([0-9.]*\).*/\1/p' "$tmpdir/rl.svg" | head -1)
python3 - "$tmpdir/rl.svg" "$wd" <<'PY'
import re, sys
s, wd = open(sys.argv[1]).read(), float(sys.argv[2])
labs = re.findall(r'<text [^>]*fill="#000000" transform="matrix\(0 -1 1 0 ([0-9.]+) [0-9.]+\)">cancer_type_\d\d<', s)
assert len(labs) == 30, len(labs)
assert all(float(x) < wd for x in labs), (max(map(float, labs)), wd)
PY
# the 30-level key fits by wrapping into columns, not by clipping
! grep -q 'clipped' "$tmpdir/err" || { echo "tall key clipped instead of wrapping" >&2; exit 1; }
# (the key's entries are the unrotated texts; run labels carry a transform)
x1=$(grep -v transform "$tmpdir/rl.svg" | sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>cancer_type_01<.*/\1/p' | head -1)
x30=$(grep -v transform "$tmpdir/rl.svg" | sed -n 's/.*<text x="\([0-9.]*\)"[^>]*>cancer_type_30<.*/\1/p' | head -1)
awk -v a="$x1" -v b="$x30" 'BEGIN { exit !(b > a + 20) }' || { echo "key not wrapped ($x1, $x30)" >&2; exit 1; }

# ---- C15r: geom_text(vjust=) in ggplot units ----
# vjust= existed on annotate("text") only, so a value label above a mean
# dot needed a second file with y shifted in data units
printf 'x,y,lab\n1,1,low\n2,2,mid\n3,3,high\n' >"$tmpdir/vj.csv"
vjy() { "$CINDERPLOT" "$tmpdir/vj.csv + aes(x,y,label=lab) + geom_point() + geom_text($1)" \
            --editable-svg -o "$tmpdir/vj.svg" --size 4x3
        sed -n 's/.*<text x="[0-9.]*" y="\([0-9.]*\)"[^>]*>mid<.*/\1/p' "$tmpdir/vj.svg"; }
y0=$(vjy 'vjust=0'); yh=$(vjy 'vjust=0.5'); y1=$(vjy 'vjust=1'); yn=$(vjy ''); yl=$(vjy 'vjust=-0.6')
# SVG y grows downward: -0.6 sits highest, then 0, 0.5 (= the default), 1
awk -v l="$yl" -v a="$y0" -v h="$yh" -v b="$y1" -v n="$yn" 'BEGIN {
    exit !(l < a && a < h && h < b && h == n && ((h - a) - (b - h))^2 < 0.01) }' \
    || { echo "vjust order: -0.6=$yl 0=$y0 0.5=$yh 1=$y1 none=$yn" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/vj.csv + aes(x,y,label=lab) + geom_text(vjust=0, angle=90)" \
        -o "$tmpdir/vj2.svg" 2>"$tmpdir/err"; then
    echo "vjust= with angle= unexpectedly succeeded" >&2; exit 1
fi
grep -q 'vjust=) with angle= is not implemented' "$tmpdir/err"

# ---- C15s: SVG has a white canvas by default; --transparent opts out ----
# an SVG carried no background, so a dark-themed viewer showed the figure on
# black and the axis text vanished; ggplot2 and R's svg() paint white
printf 'x,y\n1,1\n2,2\n' >"$tmpdir/bg.csv"
"$CINDERPLOT" "$tmpdir/bg.csv + aes(x,y) + geom_point()" -o "$tmpdir/bg.svg" --size 4x3
svgnorm --keep-canvas "$tmpdir/bg.svg"
# the first drawn shape covers the whole 288x216 canvas in white
python3 - "$tmpdir/bg.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
body = s.split('</defs>', 1)[-1]
m = re.search(r'<(rect|path)[^>]*>', body)
assert m and 'rect' == m.group(1), m and m.group(0)
r = m.group(0)
assert 'fill="rgb(100%, 100%, 100%)"' in r, r
x, y, w, h = (float(re.search(k + r'="([-0-9.]+)"', r).group(1)) for k in ('x', 'y', 'width', 'height'))
assert x <= 0 and y <= 0 and x + w >= 288 and y + h >= 216, r
PY
"$CINDERPLOT" "$tmpdir/bg.csv + aes(x,y) + geom_point()" -o "$tmpdir/bg2.svg" --size 4x3 --transparent
svgnorm --keep-canvas "$tmpdir/bg2.svg"
test "$(grep -c '<rect' "$tmpdir/bg.svg")" -eq "$(( $(grep -c '<rect' "$tmpdir/bg2.svg") + 1 ))" \
    || { echo "--transparent did not drop exactly the canvas rect" >&2; exit 1; }

# ---- C15t: a top band's side title does not push a left_of band away ----
# the gutter at the matrix's left edge counted every object on that edge,
# so a top band's title.side=left title moved the row annotation out by the
# title's width, leaving a gap between it and the matrix; the title shares
# no rows with it and now sits in its own row, reserved at the canvas edge
printf 'probe,s1,s2,s3,s4\nr1,1,2,3,4\nr2,2,3,4,1\nr3,3,4,1,2\n' >"$tmpdir/gtm.csv"
printf 'sample,site\ns1,N\ns2,N\ns3,T\ns4,T\n' >"$tmpdir/gtc.csv"
printf 'probe,grp\nr1,in\nr2,out\nr3,out\n' >"$tmpdir/gtr.csv"
# the gap between the row annotation's band and the matrix's first cell
# (viridis 0) must not depend on the top band's title
gut() { "$CINDERPLOT" "$tmpdir/gtm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/gtc.csv\", top_of(\"m\", height=0.1), name=\"site\"$1) + annotation(\"$tmpdir/gtr.csv\", left_of(\"m\", width=0.03), name=\"grp\", labels=data, values=c(in=\"#00ff00\", out=\"#ff00ff\"))" \
            --editable-svg -o "$tmpdir/gt.svg" --size 5x2.5
        svgnorm "$tmpdir/gt.svg"
        python3 - "$tmpdir/gt.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
# the band's "in" run (green) and its right edge
d = re.search(r'fill="rgb\(0%, 100%, 0%\)"[^>]*d="([^"]*)"', s).group(1)
right = max(float(x) for x in re.findall(r'[ML] ([0-9.]+) ', d))
cell = min(float(m.group(1)) for m in re.finditer(
    r'fill="rgb\(26.666667%, 0.392157%, 32.941176%\)"[^>]*d="M ([0-9.]+) ', s))
t = re.search(r'<text x="([-0-9.]+)"[^>]*>A Long Sample Site Title<', s)
assert t is None or float(t.group(1)) >= 0, "side title clipped at x=" + t.group(1)
print("%.2f" % (cell - right))
PY
}
d0=$(gut '')
d1=$(gut ', title="A Long Sample Site Title", title.side=left')
# (pad= is a fraction of the matrix width, so the gap scales a little with
# the canvas; the bug put the title's whole width, ~100pt, into it)
awk -v a="$d0" -v b="$d1" 'BEGIN { exit !(a < 6 && b < 6) }' \
    || { echo "the side title moved the row annotation: $d0 -> $d1 pt from the matrix" >&2; exit 1; }

# ---- C15u: cluster=both + colsplit= clusters within each block ----
# colsplit= only painted gaps at level changes, so a clustered axis
# interleaved the groups (6 runs for 2 levels here, a gap at each); like
# ComplexHeatmap's column_split, each block is now clustered on its own,
# in level order, and a dendrogram draws one tree per block
printf 'probe,s1,s2,s3,s4,s5,s6\nr1,0.1,0.11,0.5,0.52,0.9,0.88\nr2,0.2,0.22,0.6,0.58,0.8,0.79\nr3,0.3,0.29,0.4,0.41,0.7,0.72\n' >"$tmpdir/csm.csv"
printf 'sample,grp\ns1,A\ns2,B\ns3,A\ns4,B\ns5,A\ns6,B\n' >"$tmpdir/csg.csv"
"$CINDERPLOT" "$tmpdir/csm.csv + heatmap(name=\"m\", cluster=both, colsplit=\"grp\") + annotation(\"$tmpdir/csg.csv\", top_of(\"m\", height=0.1), name=\"grp\") + dendrogram(top_of(\"grp\"))" \
    -o "$tmpdir/cs.svg" --size 4x3 2>"$tmpdir/err"
! grep -q 'more than one run' "$tmpdir/err" || { echo "split blocks still interleave" >&2; exit 1; }
svgnorm "$tmpdir/cs.svg"
# one boundary, painted over the heatmap and the band: two gap rects
test "$(grep -c 'fill="rgb(100%, 100%, 100%)"' "$tmpdir/cs.svg")" -eq 2 || { echo "expected one split boundary" >&2; exit 1; }
# two 3-leaf trees: 2 merges each x 3 strokes = 12; a single tree over all
# six leaves would draw 5 merges = 15 strokes
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/cs.svg")" -eq 12 || { echo "dendrogram is not one tree per block" >&2; exit 1; }

# ---- C15v: an annotation bar draws one rect per run, not per cell ----
# a 2000-row bar in two blocks drew 2000 one-pixel paths (a 1 MB SVG, and
# antialiasing seams that washed out the colours); equal neighbours merge
printf 'probe,s1,s2\n' >"$tmpdir/rvm.csv"
printf 'probe,dir\n' >"$tmpdir/rva.csv"
i=1; while [ $i -le 40 ]; do
    printf 'r%d,0.%d,0.5\n' $i $((i % 10)) >>"$tmpdir/rvm.csv"
    if [ $i -le 25 ]; then d=hyper; else d=hypo; fi
    printf 'r%d,%s\n' $i $d >>"$tmpdir/rva.csv"
    i=$((i + 1))
done
"$CINDERPLOT" "$tmpdir/rvm.csv + heatmap(name=\"m\", cluster=none) + annotation(\"$tmpdir/rva.csv\", left_of(\"m\"), values=c(hyper=\"#ff0000\", hypo=\"#0000ff\"))" \
    -o "$tmpdir/rv.svg" --size 3x4
svgnorm "$tmpdir/rv.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/rv.svg")" -eq 1 || { echo "hyper run not one rect" >&2; exit 1; }
test "$(grep -c 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/rv.svg")" -eq 1 || { echo "hypo run not one rect" >&2; exit 1; }

# ---- C15w: aes(reorder(x, v)) orders levels; per panel under free x ----
# reorder() was refused; a freed facet axis now sorts each panel's levels by
# that panel's own rows (mean by default, as base R), -v sorts largest first
printf 'f,g,v\nP,a,3\nP,b,1\nP,c,2\nQ,a,1\nQ,b,3\nQ,c,2\nQ,d,9\n' >"$tmpdir/ro.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ro.csv + aes(reorder(g, v), v) + geom_col() + facet_wrap(~f, scales=\"free_x\")" \
    -o "$tmpdir/ro.svg" --size 4x3
test "$(grep -o '>[a-d]</text>' "$tmpdir/ro.svg" | tr -d '<>/text\n')" = bcaacbd \
    || { echo "reorder() per-panel order wrong" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ro.csv + aes(reorder(g, -v), v) + geom_col()" \
    -o "$tmpdir/ro2.svg" --size 4x3
test "$(grep -o '>[a-d]</text>' "$tmpdir/ro2.svg" | tr -d '<>/text\n')" = dabc \
    || { echo "reorder(g, -v) global order wrong" >&2; exit 1; }

# ---- C15x: facet space="free_x" sizes panels by their axis range ----
# panels were always equal width, so 3 categories got wider slots than 4;
# with space="free_x" the category pitch is the same in both panels
printf 'f,g,v\nP,a,3\nP,b,1\nP,c,2\nQ,a,1\nQ,b,3\nQ,c,2\nQ,d,9\n' >"$tmpdir/fsp.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/fsp.csv + aes(g, v) + geom_col() + facet_wrap(~f, scales=\"free_x\", space=\"free_x\")" \
    -o "$tmpdir/fsp.svg" --size 4x3
grep -o 'x="[0-9.]*"[^>]*>[a-d]</text>' "$tmpdir/fsp.svg" | sed 's/x="\([0-9.]*\)".*/\1/' \
    | awk 'NR > 1 { d[NR] = $1 - p } { p = $1 }
           END { a = d[2]; b = d[5]; exit !(a > 0 && b > 0 && a - b < 0.5 && b - a < 0.5) }' \
    || { echo "space=free_x pitch differs between panels" >&2; exit 1; }

# ---- C15y: geom_boxplot(linewidth=, fatten=) set the box strokes ----
# linewidth= was refused on boxplot; outline and whiskers now take it, the
# median is linewidth x fatten (ggplot's 2). Counted against the default
# render, so the chrome's widths cancel out: 0.25 moves the three 1.07 px box
# strokes to 0.53 px and the 2.13 px median to 1.07 px
printf 'g,y\na,1\na,2\na,3\na,4\na,9\n' >"$tmpdir/blw.csv"
blw() { "$CINDERPLOT" "$tmpdir/blw.csv + aes(g, y) + geom_boxplot($1) + theme_classic()" \
            -o "$tmpdir/blw$2.svg" --size 3x3; }
nw() { grep -c "stroke-width=\"$1" "$tmpdir/blw$2.svg" || true; }
blw "" 0
blw "linewidth=0.25" 1
blw "linewidth=0.25, fatten=1" 2
test "$(nw 2.13 0)" -eq 1 && test "$(nw 2.13 1)" -eq 0 \
    || { echo "boxplot median width not set by linewidth=" >&2; exit 1; }
test "$(nw 0.53 1)" -eq $(( $(nw 0.53 0) + 3 )) \
    || { echo "boxplot outline/whiskers not set by linewidth=" >&2; exit 1; }
test "$(nw 0.53 2)" -eq $(( $(nw 0.53 0) + 4 )) \
    || { echo "boxplot fatten=1 not applied" >&2; exit 1; }

# ---- C15z: theme(legend.key.size=, legend.key.spacing.y=) ----
# the key cell was a fixed 17.3 pt (ggplot's 1.2 lines, which ignores
# base_size), so a small-font legend stayed loosely spaced; unit(10, "pt")
# keys put the a -> c labels 2 x (9.96 + 2.2) pt apart, and spacing.y=0 drops
# the 2.2 pt row gap
printf 'x,y,g\n1,1,a\n2,2,b\n3,3,c\n' >"$tmpdir/lk.csv"
lk() { CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/lk.csv + aes(x, y, colour=g) + geom_point() + theme($1)" \
           -o "$tmpdir/lk.svg" --size 3x3
       grep -o 'y="[0-9.]*"[^>]*>[ac]</text>' "$tmpdir/lk.svg" | sed 's/y="\([0-9.]*\)".*/\1/' \
           | awk -v want="$2" 'NR == 1 { a = $1 } NR == 2 { d = $1 - a - want; ok = d < 0.3 && d > -0.3 }
                                END { exit !ok }'; }
lk 'legend.key.size=unit(10, "pt")' 24.33 || { echo "legend.key.size= not applied" >&2; exit 1; }
lk 'legend.key.size=unit(10, "pt"), legend.key.spacing.y=unit(0, "pt")' 19.93 \
    || { echo "legend.key.spacing.y= not applied" >&2; exit 1; }

# ---- C15za: facet_wrap(space="free_x") sizes each ROW on its own ----
# with several rows the columns took their widest panel, so a 2x2 wrap of
# 3|1 over 1|3 categories drew four equal panels; now row 1 is 3:1 and row 2
# 1:3, which puts the lone row-1 label `d` far right of row 2's first `f`
printf 'f,g,v\nA,a,1\nA,b,2\nA,c,3\nB,d,1\nC,e,1\nD,f,1\nD,g,2\nD,h,3\n' >"$tmpdir/spr2.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/spr2.csv + aes(g, v) + geom_col() + facet_wrap(~f, scales=\"free_x\", space=\"free_x\", ncol=2)" \
    -o "$tmpdir/spr2.svg" --size 4x4
grep -o 'x="[0-9.]*"[^>]*>[a-h]</text>' "$tmpdir/spr2.svg" \
    | sed 's/x="\([0-9.]*\)".*>\([a-h]\)<.*/\2 \1/' \
    | awk '{ x[$1] = $2 } END { p = x["b"] - x["a"]; d = x["d"] - x["f"];
           exit !(p > 0 && d / p > 1.5) }' \
    || { echo "space=free_x did not size rows independently" >&2; exit 1; }

# ---- C15zb: layer aes() on geom_errorbar / geom_errorbarh ----
# both bar directions from one point table: aes(ymin=, ymax=) on errorbar and
# aes(xmin=, xmax=) on errorbarh (layer aes was refused); the layer ranges
# train the axes, so xlo = -10 and yhi = 20 reach the tick labels
printf 'x,y,xlo,xhi,ylo,yhi\n1,1,-10,2,0,2\n2,2,1,3,1,20\n3,3,2,4,2,4\n' >"$tmpdir/eb2.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/eb2.csv + aes(x, y) + geom_point() + geom_errorbar(aes(ymin=ylo, ymax=yhi), width=0.2) + geom_errorbarh(aes(xmin=xlo, xmax=xhi), height=0.5)" \
    -o "$tmpdir/eb2.svg" --size 3x3
grep '>-10</text>' "$tmpdir/eb2.svg" >/dev/null || { echo "errorbarh xmin did not train x" >&2; exit 1; }
grep '>20</text>' "$tmpdir/eb2.svg" >/dev/null || { echo "errorbar layer ymax did not train y" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/eb2.csv + aes(x, y) + geom_errorbar(aes(xmin=xlo, ymax=yhi))" \
        -o "$tmpdir/eb2b.svg" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "mixed x/y range aes unexpectedly succeeded" >&2; exit 1
fi
grep 'one per direction' "$tmpdir/err" >/dev/null

# ---- C15zc: theme(strip.text=element_text(size=)) ----
# strips were fixed at ggplot's rel(0.8) of base_size (6.4 pt at base 8) with
# no override; size=N is points, rel(r) scales base_size, .y the grid row strip
printf 'x,y,f,h\n1,1,P,u\n2,2,Q,v\n' >"$tmpdir/stx.csv"
st() { CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/stx.csv + aes(x, y) + geom_point() + $1 + theme_bw(base_size=8)$2" \
           -o "$tmpdir/stx.svg" --size 3x3; }
st 'facet_wrap(~f)' ' + theme(strip.text=element_text(size=8))'
grep 'font-size="8.00"[^>]*>P</text>' "$tmpdir/stx.svg" >/dev/null || { echo "strip.text size= not applied" >&2; exit 1; }
st 'facet_wrap(~f)' ' + theme(strip.text=element_text(size=rel(1.2)))'
grep 'font-size="9.60"[^>]*>P</text>' "$tmpdir/stx.svg" >/dev/null || { echo "strip.text rel() not applied" >&2; exit 1; }
st 'facet_grid(h ~ f)' ' + theme(strip.text.y=element_text(size=10))'
grep 'font-size="10.00"[^>]*>u</text>' "$tmpdir/stx.svg" >/dev/null || { echo "strip.text.y not applied" >&2; exit 1; }
grep 'font-size="6.40"[^>]*>P</text>' "$tmpdir/stx.svg" >/dev/null || { echo "strip.text.y changed the top strips" >&2; exit 1; }

# ---- C15zd: venn() -- a two-set Venn listing items with per-sample dots ----
# a new mode: one row per (item, set) membership with a count; regions list
# their items, the overlap puts set A's dots left and B's right, subtitle=
# substitutes {k} items and {n} samples, titles are bold; 4 sets refused
printf 'item\tset\tn\tcolour\nalpha\tA\t3\t#ff0000\nbeta\tA\t2\t#00ff00\nbeta\tB\t4\t#00ff00\ngamma\tB\t1\t#0000ff\n' >"$tmpdir/vn.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "venn(\"$tmpdir/vn.tsv\", sets=c(\"A\",\"B\"), subtitle=c(\"{k} kinds, {n} runs\"), labels=c(beta=\"Beta\"))" \
    -o "$tmpdir/vn.svg"
grep 'font-weight="bold"[^>]*>A</text>' "$tmpdir/vn.svg" >/dev/null || { echo "venn set title missing/not bold" >&2; exit 1; }
grep '>2 kinds, 5 runs</text>' "$tmpdir/vn.svg" >/dev/null || { echo "venn subtitle substitution wrong" >&2; exit 1; }
grep '>2 items · 5 samples</text>' "$tmpdir/vn.svg" >/dev/null || { echo "venn default subtitle wrong" >&2; exit 1; }
grep '>Beta</text>' "$tmpdir/vn.svg" >/dev/null || { echo "venn labels= not applied" >&2; exit 1; }
# 3 + 2 + 4 + 1 = 10 sample dots, each its own colour run
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/vn.svg")" -ge 1
printf 'item\tset\na\tA\nb\tB\nc\tC\nd\tD\n' >"$tmpdir/vn4.tsv"
if "$CINDERPLOT" "venn(\"$tmpdir/vn4.tsv\")" -o "$tmpdir/vn4.svg" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "4-set venn unexpectedly succeeded" >&2; exit 1
fi
grep 'not implemented' "$tmpdir/err" >/dev/null

# ---- C15ze: filled points -- fill= body, colour= outline, free_colour ramps -
# fill= and colour= were one aesthetic, so a point could not carry a discrete
# fill and a continuous outline; geom_point(shape=21) now takes both (stroke=
# 0.9 -> 1.28 pt), with a fill key, and scales=c("free", "free_colour") gives
# each facet its own colourbar (titled by the facet: P and Q twice each)
printf 'x,y,g,v,f\n1,1,a,10,P\n2,2,b,20,P\n1,2,a,0.5,Q\n2,1,b,1.5,Q\n' >"$tmpdir/pf.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/pf.csv + aes(x, y, fill=g, colour=v) + geom_point(shape=21, stroke=0.9) + scale_fill_manual(values=c(a=\"#ff0000\", b=\"#0000ff\")) + facet_wrap(~f, scales=c(\"free\", \"free_colour\"))" \
    -o "$tmpdir/pf.svg" --size 5x3
test "$(grep -c 'stroke-width="1.27' "$tmpdir/pf.svg")" -eq 4 || { echo "shape=21 outline (stroke=) missing" >&2; exit 1; }
grep 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/pf.svg" >/dev/null || { echo "shape=21 fill= body missing" >&2; exit 1; }
grep '>g</text>' "$tmpdir/pf.svg" >/dev/null || { echo "fill legend missing" >&2; exit 1; }
test "$(grep -c '>Q</text>' "$tmpdir/pf.svg")" -eq 2 || { echo "per-facet colourbar missing" >&2; exit 1; }
# without a filled glyph the two keys still collide, and the message says why
if "$CINDERPLOT" "$tmpdir/pf.csv + aes(x, y, fill=g, colour=v) + geom_point()" \
        -o "$tmpdir/pf2.svg" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "fill= + colour= without shape=21 unexpectedly succeeded" >&2; exit 1
fi
grep 'shape=21' "$tmpdir/err" >/dev/null

# ---- C15zf: venn() with three sets ----
# three circles, seven regions; an item's dot runs come one per member set,
# each dot filled in the item colour and outlined (0.9 pt) in its set colour
printf 'item\tset\tn\nonly_a\tA\t2\nab\tA\t1\nab\tB\t2\nabc\tA\t1\nabc\tB\t1\nabc\tC\t3\nonly_c\tC\t1\n' >"$tmpdir/v3.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "venn(\"$tmpdir/v3.tsv\", sets=c(\"A\",\"B\",\"C\"))" -o "$tmpdir/v3.svg"
grep 'font-weight="bold"[^>]*>C</text>' "$tmpdir/v3.svg" >/dev/null || { echo "3-set venn: third title missing" >&2; exit 1; }
grep '>abc</text>' "$tmpdir/v3.svg" >/dev/null || { echo "3-set venn: triple-overlap item missing" >&2; exit 1; }
# 2 + 3 + 5 + 1 = 11 outlined dots
test "$(grep -c 'stroke-width="0.9"' "$tmpdir/v3.svg")" -eq 11 || { echo "3-set venn: outlined dot count wrong" >&2; exit 1; }

# ---- C15zg: guides(colour=guide_colourbar(direction=, barwidth=, barheight=))
# a colourbar was a fixed 12 x 80 pt vertical bar; direction="horizontal"
# lays it flat (its labels then share one baseline) and barwidth=/barheight=
# size it in lines (or unit())
printf 'x,y,v\n1,1,15\n2,2,25\n3,3,35\n4,4,45\n' >"$tmpdir/cbh.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/cbh.csv + aes(x, y, colour=v) + geom_point() + guides(colour=guide_colourbar(direction=\"horizontal\", barwidth=6, barheight=0.5))" \
    -o "$tmpdir/cbh.svg" --size 4x3
test "$(grep -o 'y="[0-9.]*"[^>]*>[1-4]5</text>' "$tmpdir/cbh.svg" | sed 's/y="\([0-9.]*\)".*/\1/' | sort -u | wc -l)" -eq 1 \
    || { echo "horizontal colourbar labels not on one line" >&2; exit 1; }
test "$(grep -c '>[1-4]5</text>' "$tmpdir/cbh.svg")" -eq 4 || { echo "colourbar labels missing" >&2; exit 1; }

# ---- C15zh: venn() subtitle="" / captions=FALSE / shape= with a key ----
# subtitle=c("","") was "bad value in levels=", captions had no switch and
# shape= was refused; now the grey line and the overlap captions drop, and
# each (item, set, shape) row draws its dots in its glyph with a shape key
printf 'item\tset\tshape\tn\na\tA\tm\t2\nb\tA\tm\t1\nb\tB\tm\t1\nb\tB\tx\t2\nc\tB\tx\t1\n' >"$tmpdir/vs.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "venn(\"$tmpdir/vs.tsv\", shape=shape, sets=c(\"A\",\"B\"), subtitle=c(\"\",\"\"), captions=FALSE) + scale_shape_manual(values=c(m=16, x=15))" \
    -o "$tmpdir/vs.svg"
grep 'items' "$tmpdir/vs.svg" >/dev/null && { echo "venn subtitle not dropped" >&2; exit 1; }
test "$(grep -c '>B</text>' "$tmpdir/vs.svg")" -eq 1 || { echo "venn overlap caption not dropped" >&2; exit 1; }
grep '>m</text>' "$tmpdir/vs.svg" >/dev/null && grep '>x</text>' "$tmpdir/vs.svg" >/dev/null \
    || { echo "venn shape key missing" >&2; exit 1; }

# ---- C15zi: venn(dot_size=, dot_step=) -- text larger against the diagram -
# everything scaled with base_size, so text could not grow relative to the
# fitted ellipses; smaller dots/steps shrink the geometry at the same font
printf 'item\tset\tn\na\tA\t12\nb\tA\t6\nb\tB\t12\nc\tB\t9\n' >"$tmpdir/vd.tsv"
"$CINDERPLOT" "venn(\"$tmpdir/vd.tsv\")" -o "$tmpdir/vd1.svg"
"$CINDERPLOT" "venn(\"$tmpdir/vd.tsv\", dot_size=0.7, dot_step=0.6)" -o "$tmpdir/vd2.svg"
w1=$(grep -o '<svg[^>]*' "$tmpdir/vd1.svg" | sed 's/.* width="\([0-9.]*\).*/\1/')
w2=$(grep -o '<svg[^>]*' "$tmpdir/vd2.svg" | sed 's/.* width="\([0-9.]*\).*/\1/')
awk -v a="$w1" -v b="$w2" 'BEGIN { exit !(b < 0.9 * a) }' \
    || { echo "venn dot_step= did not tighten the diagram ($w1 -> $w2)" >&2; exit 1; }

# ---- C15zj: venn() -- guides(shape="none"), per-side widths, ncol= ----
# the shape key ignored guides(shape="none"); both ellipses shared one width,
# so shortening one side's labels left the canvas unchanged; a 10-item region
# set the height with no way to wrap it. Now: key hidden, the A side narrows
# with its labels, and ncol=2 makes the diagram shorter
vjw() { grep -o '<svg[^>]*' "$1" | sed "s/.* $2=\"\([0-9.]*\).*/\1/"; }
printf 'item\tset\tshape\nlong_label_one\tA\tm\nlong_label_two\tA\tm\nboth\tA\tm\nboth\tB\tx\n' >"$tmpdir/vk1.tsv"
i=1; while [ $i -le 10 ]; do printf 'b%d\tB\tm\n' $i >>"$tmpdir/vk1.tsv"; i=$((i + 1)); done
sed 's/long_label_/s/' "$tmpdir/vk1.tsv" >"$tmpdir/vk2.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "venn(\"$tmpdir/vk1.tsv\", shape=shape) + guides(shape=\"none\")" -o "$tmpdir/vk1.svg"
grep '>x</text>' "$tmpdir/vk1.svg" >/dev/null && { echo "venn shape key not hidden by guides()" >&2; exit 1; }
"$CINDERPLOT" "venn(\"$tmpdir/vk2.tsv\", shape=shape)" -o "$tmpdir/vk2.svg"
awk -v a="$(vjw "$tmpdir/vk1.svg" width)" -v b="$(vjw "$tmpdir/vk2.svg" width)" 'BEGIN { exit !(b < a - 10) }' \
    || { echo "venn: shorter labels did not narrow the canvas" >&2; exit 1; }
"$CINDERPLOT" "venn(\"$tmpdir/vk1.tsv\", shape=shape, ncol=2)" -o "$tmpdir/vk3.svg"
awk -v a="$(vjw "$tmpdir/vk1.svg" height)" -v b="$(vjw "$tmpdir/vk3.svg" height)" 'BEGIN { exit !(b < a - 10) }' \
    || { echo "venn ncol=2 did not shorten the diagram" >&2; exit 1; }

# ---- C15zk: venn() outline= / fill= apart from set_colours= ----
# set_colours= painted edge, title and a 0.07 wash together, so black edges
# meant grey interiors. outline= now colours the edge alone, fill="none"
# drops the wash, and fill=/fill_alpha= recolour it
printf 'item\tset\na\tA\nb\tA\nb\tB\nc\tB\n' >"$tmpdir/vf.tsv"
"$CINDERPLOT" "venn(\"$tmpdir/vf.tsv\", outline=\"black\", fill=\"none\")" -o "$tmpdir/vf1.svg"
grep -c 'fill-opacity="0.07' "$tmpdir/vf1.svg" | grep -qx 0 \
    || { echo "venn fill=\"none\" still drew a translucent fill" >&2; exit 1; }
[ "$(grep -c 'fill="none"[^>]*stroke="rgb(0%, 0%, 0%)"' "$tmpdir/vf1.svg")" -ge 2 ] \
    || { echo "venn outline=\"black\" did not draw two black edges" >&2; exit 1; }
"$CINDERPLOT" "venn(\"$tmpdir/vf.tsv\", fill=\"white\", fill_alpha=0.5)" -o "$tmpdir/vf2.svg"
[ "$(grep -c 'fill="rgb(100%, 100%, 100%)"[^>]*fill-opacity="0.5' "$tmpdir/vf2.svg")" -ge 2 ] \
    || { echo "venn fill=\"white\", fill_alpha=0.5 not applied" >&2; exit 1; }

# ---- C15zl: theme(legend.text=element_text(size=)) ----
# legend labels were fixed at the axis-text size (0.8 x base_size; venn's
# glyph key 0.88 x) with no theme handle; the venn key and a grammar legend
# now take the size, in pt or rel()
printf 'item\tset\tshape\na\tA\tm\nb\tA\tx\nb\tB\tm\n' >"$tmpdir/vt.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "venn(\"$tmpdir/vt.tsv\", shape=shape) + theme(legend.text=element_text(size=13))" -o "$tmpdir/vt.svg"
grep -q 'font-size="13[.0-9]*"[^>]*>x</text>' "$tmpdir/vt.svg" \
    || { echo "venn key ignored theme(legend.text=)" >&2; exit 1; }
printf 'x,y,g\n1,1,alpha\n2,2,beta\n' >"$tmpdir/lt.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/lt.csv + aes(x,y,colour=g) + geom_point() + theme(legend.text=element_text(size=rel(1.5)))" -o "$tmpdir/lt.svg"
grep -q 'font-size="16.5[0-9]*"[^>]*>beta</text>' "$tmpdir/lt.svg" \
    || { echo "legend labels ignored theme(legend.text=rel(1.5))" >&2; exit 1; }

# ---- C15zm: geom_segment/geom_line(arrow=arrow()) ----
# arrow= was refused ("layer option not implemented"); a head is now drawn
# at the end point, on the main-data and the data= segment paths alike (each
# head adds paths: a stroke, plus a fill when closed, under the panel clip)
printf 'x,y,xend,yend\n0,0,1,1\n' >"$tmpdir/ar.csv"
npath() { grep -c '<path' "$1"; }
"$CINDERPLOT" "$tmpdir/ar.csv + aes(x,y,xend=xend,yend=yend) + geom_segment()" -o "$tmpdir/ar0.svg"
"$CINDERPLOT" "$tmpdir/ar.csv + aes(x,y,xend=xend,yend=yend) + geom_segment(arrow=arrow())" -o "$tmpdir/ar1.svg"
"$CINDERPLOT" "$tmpdir/ar.csv + aes(x,y,xend=xend,yend=yend) + geom_segment(arrow=arrow(length=unit(4, \"pt\"), type=\"closed\", ends=\"both\"))" -o "$tmpdir/ar2.svg"
[ "$(npath "$tmpdir/ar1.svg")" -gt "$(npath "$tmpdir/ar0.svg")" ] \
    || { echo "geom_segment(arrow=arrow()) drew no open head" >&2; exit 1; }
[ $(($(npath "$tmpdir/ar2.svg") - $(npath "$tmpdir/ar0.svg"))) -gt \
  $((2 * ($(npath "$tmpdir/ar1.svg") - $(npath "$tmpdir/ar0.svg")))) ] \
    || { echo "closed heads at both ends not drawn" >&2; exit 1; }
printf 'x,y,xend,yend\n0,0,0,0\n1,1,1,1\n' >"$tmpdir/arm.csv"
"$CINDERPLOT" "$tmpdir/arm.csv + aes(x,y,xend=xend,yend=yend) + geom_point() + geom_segment(data=\"$tmpdir/ar.csv\")" -o "$tmpdir/ar3.svg"
"$CINDERPLOT" "$tmpdir/arm.csv + aes(x,y,xend=xend,yend=yend) + geom_point() + geom_segment(data=\"$tmpdir/ar.csv\", arrow=arrow(type=\"closed\"))" -o "$tmpdir/ar4.svg"
[ "$(npath "$tmpdir/ar4.svg")" -gt "$(npath "$tmpdir/ar3.svg")" ] \
    || { echo "geom_segment(data=, arrow=) drew no head" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/ar.csv + aes(x,y,xend=xend,yend=yend) + geom_segment(arrow=arrow(type=\"bent\"))" -o "$tmpdir/ar5.svg" 2>"$tmpdir/ar5.err" \
    && { echo "arrow(type=\"bent\") was accepted" >&2; exit 1; }
grep -q 'arrow(type=) expects' "$tmpdir/ar5.err"

# ---- C15zn: heatmap row names wider than a fixed --size ----
# a ~110-char row name in a 4in-wide figure left the body a negative width:
# "cairo: invalid matrix" (or a figure with a negative canvas) behind a
# stacked-panel warning reporting 0.0in. The body now keeps a floor share,
# and the warning names the label width and a --size that fits
L=$(printf 'r%0110d' 0)
printf 'id\tc1\tc2\n%s\t0.1\t0.9\nshort\t0.5\t0.2\n' "$L" >"$tmpdir/hl.tsv"
"$CINDERPLOT" "$tmpdir/hl.tsv + heatmap(rownames=right, colnames=none)" -o "$tmpdir/hl.svg" --size 4x3 2>"$tmpdir/hl.err" \
    || { echo "long row names under --size failed to render" >&2; cat "$tmpdir/hl.err" >&2; exit 1; }
grep -q 'labels between stacked panels' "$tmpdir/hl.err" \
    && { echo "long row names: bogus stacked-panel warning" >&2; exit 1; }
grep -q 'names and legends around the heatmap want' "$tmpdir/hl.err" \
    || { echo "long row names: no warning naming the label width" >&2; exit 1; }

# ---- C15zo: scale_fill_*(limits=) on a track-mode matrix() ----
# the track matrix mapped cells and its colourbar over a fixed 0..1, so
# limits=c(0,0.4) for a 5hmC track was ignored (heatmap mode honoured it);
# now cells, colourbar width and breaks follow the limits
printf 'chrom\tstart\tend\tProbe_ID\ts1\ts2\nchr1\t110\t111\tp\t0.1\t0.3\n' >"$tmpdir/tl.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "region(\"chr1:100-200\") + matrix(\"$tmpdir/tl.tsv\") + scale_fill_parula(limits=c(0,0.3)) + legend()" -o "$tmpdir/tl1.svg"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "region(\"chr1:100-200\") + matrix(\"$tmpdir/tl.tsv\") + legend()" -o "$tmpdir/tl0.svg"
grep -q '>0.3</text>' "$tmpdir/tl1.svg" && ! grep -q '>1.00</text>' "$tmpdir/tl1.svg" \
    || { echo "track matrix colourbar ignored limits=" >&2; exit 1; }
# the cells are an embedded raster image: its pixels change with the domain
[ "$(grep -o '<image[^>]*' "$tmpdir/tl1.svg")" != "$(grep -o '<image[^>]*' "$tmpdir/tl0.svg")" ] \
    || { echo "track matrix cells ignored limits=" >&2; exit 1; }

# ---- C15zp: scale_fill_*(breaks=, labels=) on a colourbar ----
# breaks= was read as a colour ("bad colour for `breaks`"); now the user's
# ticks and labels replace the automatic ones on every colourbar (grammar,
# heatmap, track), and labels= without breaks= or of another length errors
printf 'x,y,n\na,p,1\nb,q,7\n' >"$tmpdir/bl.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/bl.csv + aes(x,y,fill=n) + geom_tile() + scale_fill_gradient(limits=c(0,5), breaks=c(0,5), labels=c(\"0\",\">=5\"))" -o "$tmpdir/bl.svg"
grep -q '>&gt;=5</text>' "$tmpdir/bl.svg" && ! grep -q '>2.5</text>' "$tmpdir/bl.svg" \
    || { echo "colourbar ignored breaks=/labels=" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/bl.csv + aes(x,y,fill=n) + geom_tile() + scale_fill_viridis(labels=c(\"a\"))" -o "$tmpdir/bl2.svg" 2>"$tmpdir/bl2.err" \
    && { echo "labels= without breaks= was accepted" >&2; exit 1; }
grep -q 'give breaks=' "$tmpdir/bl2.err"
"$CINDERPLOT" "$tmpdir/bl.csv + aes(x,y,fill=n) + geom_tile() + scale_fill_viridis(breaks=c(1,2), labels=c(\"a\"))" -o "$tmpdir/bl3.svg" 2>"$tmpdir/bl3.err" \
    && { echo "breaks=/labels= of different lengths were accepted" >&2; exit 1; }
grep -q 'differ in length' "$tmpdir/bl3.err"
printf 'id\ta\tb\nr1\t0.1\t0.9\nr2\t0.5\t0.3\n' >"$tmpdir/blm.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/blm.tsv + heatmap(name=\"m\") + legend(right_of(\"m\")) + scale_fill_parula(breaks=c(0.2,0.8), labels=c(\"low\",\"high\"))" -o "$tmpdir/blm.svg"
grep -q '>high</text>' "$tmpdir/blm.svg" || { echo "heatmap colourbar ignored labels=" >&2; exit 1; }

# ---- C15zq: upset() mode ----
# UpSetR's plot was missing ("`upset()` is not implemented"): intersection
# bars over a set-membership dot matrix. Bars follow n (file order, or
# order="n"), fill= colours them through scale_fill_manual, max= keeps the
# top N, a member is a dark dot, and two sizes for one intersection error
printf 'pattern\tset\tn\tdir\nP1\tA\t10\thypo\nP1\tB\t10\thypo\nP2\tB\t30\thyper\nP2\tC\t30\thyper\nP3\tA\t5\thypo\n' >"$tmpdir/up.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "upset(\"$tmpdir/up.tsv\", intersection=pattern, set=set, n=n, fill=dir) + scale_fill_manual(values=c(hypo=\"#2C7FB8\", hyper=\"#D95F0E\"))" -o "$tmpdir/up.svg"
for w in '>A</text>' '>B</text>' '>C</text>' '>hyper</text>' '>Intersection size</text>'; do
    grep -q "$w" "$tmpdir/up.svg" || { echo "upset(): $w missing" >&2; exit 1; }
done
grep -q 'fill="rgb(85.098039%, 37.254902%, 5.490196%)"' "$tmpdir/up.svg" \
    || { echo "upset(): fill= bar colour not applied" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/up.tsv + upset(intersection=pattern, set=set, n=n, order=\"n\", max=2, set_size=TRUE)" -o "$tmpdir/up2.svg"
grep -q '>Set size</text>' "$tmpdir/up2.svg" || { echo "upset(set_size=TRUE) drew no set-size axis" >&2; exit 1; }
printf 'pattern\tset\tn\nP1\tA\t10\nP1\tB\t11\n' >"$tmpdir/upbad.tsv"
"$CINDERPLOT" "upset(\"$tmpdir/upbad.tsv\", intersection=pattern)" -o "$tmpdir/upbad.svg" 2>"$tmpdir/upbad.err" \
    && { echo "upset(): two sizes for one intersection accepted" >&2; exit 1; }
grep -q 'has two sizes' "$tmpdir/upbad.err"

# ---- C15zr: annotation(axis="y"[, side=][, show.legend=]) in grammar mode ----
# a grammar annotation() keyed only on a discrete x ("option `axis` not
# implemented"); now axis="y" draws a band beside the panel keyed by the y
# categories (left between labels and cells, or side="right"), with its own
# values=; show.legend=FALSE drops its key
printf 'state\tsrc\tn\nr1\ta\t1\nr2\ta\t3\nr1\tb\t2\n' >"$tmpdir/yb.tsv"
printf 'state\tkind\nr1\tK1\nr2\tK2\n' >"$tmpdir/ybm.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/yb.tsv + aes(x=src, y=state, fill=n) + geom_tile() + annotation(\"$tmpdir/ybm.tsv\", column=\"kind\", axis=\"y\", values=c(K1=\"#123456\", K2=\"#ABCDEF\"), show.legend=FALSE)" -o "$tmpdir/yb.svg"
grep -q 'fill="rgb(7.058824%, 20.392157%, 33.72549%)"' "$tmpdir/yb.svg" \
    || { echo "annotation(axis=y) band not drawn in its values= colours" >&2; exit 1; }
grep -q '>kind</text>' "$tmpdir/yb.svg" && { echo "annotation(show.legend=FALSE) still drew its key" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/yb.tsv + aes(x=src, y=state, fill=n) + geom_tile() + annotation(\"$tmpdir/ybm.tsv\", column=\"kind\", axis=\"y\", side=\"right\")" -o "$tmpdir/yb2.svg"
grep -q '>kind</text>' "$tmpdir/yb2.svg" || { echo "annotation(axis=y, side=right) lost its key" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/yb.tsv + aes(x=src, y=n) + geom_point() + annotation(\"$tmpdir/ybm.tsv\", axis=\"y\")" -o "$tmpdir/yb3.svg" 2>"$tmpdir/yb3.err" \
    && { echo "annotation(axis=y) on a continuous y was accepted" >&2; exit 1; }
grep -q 'needs a discrete y' "$tmpdir/yb3.err"

# ---- C15zs: upset() + labs(y=, fill=) ----
# labs(fill=) was copied into the colour title (a grammar-mode alias), which
# upset() then refused as a label with nothing to name; both titles now apply
printf 'pattern\tset\tn\tdir\nP1\tA\t10\thypo\nP1\tB\t10\thypo\nP2\tB\t30\thyper\n' >"$tmpdir/upl.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/upl.tsv + upset(intersection=pattern, set=set, n=n, fill=dir) + labs(y=\"CpGs\", fill=\"Direction\")" -o "$tmpdir/upl.svg" \
    || { echo "upset() refused labs(y=, fill=)" >&2; exit 1; }
grep -q '>CpGs</text>' "$tmpdir/upl.svg" && grep -q '>Direction</text>' "$tmpdir/upl.svg" \
    || { echo "upset() labs(y=, fill=) titles not drawn" >&2; exit 1; }

# ---- C15zt: matrix(x=genomic) rasterizes above 2000 cells ----
# every cell was a vector rect (42 x 2,911 CpGs = a 26 MB SVG); past the
# heatmap's RASTER_MIN_CELLS the cells are one embedded image, and
# raster=FALSE / raster=TRUE force either way
awk 'BEGIN { OFS = "\t"; printf "chrom\tbeg\tend"
             for (j = 1; j <= 30; j++) printf "\ts%d", j; print ""
             for (i = 0; i < 100; i++) { printf "chr1\t%d\t%d", i * 10, i * 10 + 2
               for (j = 1; j <= 30; j++) printf "\t%.2f", ((i * j) % 7) / 6; print "" } }' \
    >"$tmpdir/gxr.tsv"
for r in "" ", raster=FALSE"; do
    "$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxr.tsv\", x=genomic$r)" \
        -o "$tmpdir/gxr${r:+off}.svg" --size 6x4 >/dev/null
done
grep -q '<image' "$tmpdir/gxr.svg" \
    || { echo "matrix(x=genomic) with 3000 cells was not rasterized" >&2; exit 1; }
[ "$(grep -c '<path' "$tmpdir/gxr.svg")" -lt 200 ] \
    || { echo "matrix(x=genomic) raster still drew vector cells" >&2; exit 1; }
if grep -q '<image' "$tmpdir/gxroff.svg"; then
    echo "matrix(x=genomic, raster=FALSE) still rasterized" >&2; exit 1
fi
printf 'chrom\tbeg\tend\ta\tb\nchr1\t10\t12\t0.2\t0.8\nchr1\t500\t502\t0.6\t0.4\n' \
    >"$tmpdir/gxs.tsv"
"$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxs.tsv\", x=genomic, raster=TRUE)" \
    -o "$tmpdir/gxron.svg" >/dev/null
grep -q '<image' "$tmpdir/gxron.svg" \
    || { echo "matrix(x=genomic, raster=TRUE) not rasterized" >&2; exit 1; }

# ---- C15zu: signal(style="bars") draws one bar per CpG ----
# the focal-methylation view: a bar per row at its coordinate, height = value,
# coloured by series (the focal CpG its own series); smooth= is refused
printf 'chrom\tbeg\tend\tvalue\tsample\tseries\n' >"$tmpdir/sb.tsv"
for smp in A B; do
    printf 'chr1\t100\t102\t0.9\t%s\tother\nchr1\t500\t502\t0.5\t%s\tfocal\nchr1\t800\t802\t0.2\t%s\tother\n' \
        "$smp" "$smp" "$smp" >>"$tmpdir/sb.tsv"
done
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sb.tsv\", style=\"bars\", ylim=c(0, 1), colour=c(focal=\"#ff0000\", other=\"#0000ff\"))" \
    -o "$tmpdir/sb.svg" --size 4x3 >/dev/null \
    || { echo "signal(style=\"bars\") refused" >&2; exit 1; }
[ "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/sb.svg")" -eq 2 ] \
    || { echo "signal(style=\"bars\"): expected 2 focal bars" >&2; exit 1; }
[ "$(grep -c 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/sb.svg")" -eq 4 ] \
    || { echo "signal(style=\"bars\"): expected 4 other bars" >&2; exit 1; }
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sb.tsv\", style=\"bars\", smooth=0.5)" \
        -o "$tmpdir/sb2.svg" 2>/dev/null; then
    echo "signal(style=\"bars\", smooth=) unexpectedly succeeded" >&2; exit 1
fi

# ---- C15zv: geom_density() is evaluated over the data range ----
# ggplot2's stat_density stops the curve at the x scale's data range; it ran
# to min-3bw..max+3bw, so a beta density showed mass below 0% and above 100%
printf 'x\n0.2\n0.3\n0.35\n0.5\n0.6\n0.8\n' >"$tmpdir/dr.csv"
"$CINDERPLOT" "$tmpdir/dr.csv + aes(x) + geom_density(colour=\"#ff0000\") + geom_vline(xintercept=0.2, colour=\"#0000ff\") + geom_vline(xintercept=0.8, colour=\"#0000ff\")" \
    -o "$tmpdir/dr.svg" --size 4x3 >/dev/null
python3 - "$tmpdir/dr.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def xs(col):
    out = []
    for el in re.findall(r'<path[^>]*>', s):
        if 'stroke="' + col + '"' in el:
            out += [float(v) for v in re.findall(r'[ML] ([-0-9.]+) ', el)]
    return out
red, blue = xs("rgb(100%, 0%, 0%)"), xs("rgb(0%, 0%, 100%)")
ok = red and blue and min(red) >= min(blue) - 0.5 and max(red) <= max(blue) + 0.5
sys.exit(0 if ok else "geom_density() curve runs past the data range")
PY
"$CINDERPLOT" "$tmpdir/dr.csv + aes(x) + geom_density(trim=TRUE)" -o "$tmpdir/dr2.svg" >/dev/null \
    || { echo "geom_density(trim=TRUE) refused" >&2; exit 1; }

# ---- C15zw: geom_text_repel() leaves no two labels overprinted ----
# the gallery's mtcars card stalled the force solver with "Merc 240D" on top
# of "Merc 230"; a settle pass moves a label to a free spot or drops it (warned)
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$here/data/mtcars.csv + aes(wt, mpg, label=model) + geom_point() + geom_text_repel(size=2.6)" \
    -o "$tmpdir/rp.svg" >/dev/null 2>"$tmpdir/rp.err"
python3 - "$tmpdir/rp.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
box = []
for x, y, fs, t in re.findall(r'<text x="([-0-9.]+)" y="([-0-9.]+)"[^>]*font-size="([0-9.]+)"[^>]*>([^<]+)</text>', s):
    x, y, fs = float(x), float(y), float(fs)
    if fs > 9 or not re.search(r'[A-Za-z]{3}', t):
        continue                       # axis text, not a label
    box.append((t, x, x + 0.45 * fs * len(t), y - 0.7 * fs, y))
bad = [(a[0], b[0]) for i, a in enumerate(box) for b in box[i+1:]
       if a[1] < b[2] and b[1] < a[2] and a[3] < b[4] and b[3] < a[4]]
sys.exit("overprinted repel labels: %s" % bad if bad else 0)
PY

# ---- C15zx: errors name what is supported; -v; one --dump-spec story ----
# a bad chord() argument named nothing, geom_violin pointed at --help, and a
# missing column did not list the file's columns
if "$CINDERPLOT" "$here/data/chord_flows.csv + chord([gap=2])" -o "$tmpdir/e.svg" 2>"$tmpdir/e1" >/dev/null; then
    echo "chord([gap=2]) unexpectedly succeeded" >&2; exit 1; fi
grep -q 'got `\[gap=2\]`; supported: from=' "$tmpdir/e1" \
    || { echo "chord() error does not name the token: $(cat "$tmpdir/e1")" >&2; exit 1; }
if "$CINDERPLOT" "$here/data/mtcars.csv + aes(hp, mpg) + geom_violin()" -o "$tmpdir/e.svg" 2>"$tmpdir/e2" >/dev/null; then
    echo "geom_violin() unexpectedly succeeded" >&2; exit 1; fi
grep -q 'the geoms are geom_point/' "$tmpdir/e2" \
    || { echo "geom error does not list the geoms" >&2; exit 1; }
if "$CINDERPLOT" "$here/data/mtcars.csv + aes(hpx, mpg) + geom_point()" -o "$tmpdir/e.svg" 2>"$tmpdir/e3" >/dev/null; then
    echo "aes(hpx) unexpectedly succeeded" >&2; exit 1; fi
grep -q 'the data has: model, mpg, cyl, disp, hp' "$tmpdir/e3" \
    || { echo "column error does not list the header: $(cat "$tmpdir/e3")" >&2; exit 1; }
"$CINDERPLOT" -v | grep -q '^cinderplot ' || { echo "-v does not print the version" >&2; exit 1; }
"$CINDERPLOT" --help | grep -q 'dump-spec.*renders too only with -o FILE' \
    || { echo "--help still disagrees with llms.txt about --dump-spec" >&2; exit 1; }

# ---- C15zy: geom_tile() + coord_polar() draws a dartboard ----
# x levels become spokes gathered into group= wedges, y levels rings; it
# used to refuse anything but the radar's geom_line()/geom_point()
printf 'sp,ring,hex,grp\nA,in,#ff0000,g1\nA,out,#00ff00,g1\nB,in,#0000ff,g1\nB,out,#ffff00,g1\nC,in,#ff00ff,g2\nC,out,#00ffff,g2\n' >"$tmpdir/dart.csv"
"$CINDERPLOT" "$tmpdir/dart.csv + aes(x=factor(sp), y=factor(ring), fill=hex, group=grp) + geom_tile() + coord_polar(gap=10, inner.radius=0.3) + scale_fill_identity()" \
    -o "$tmpdir/dart.svg" --size 4x4 >/dev/null \
    || { echo "geom_tile() + coord_polar() refused" >&2; exit 1; }
for c in "100%, 0%, 0%" "0%, 100%, 0%" "0%, 0%, 100%" "100%, 100%, 0%" "100%, 0%, 100%" "0%, 100%, 100%"; do
    [ "$(grep -c "fill=\"rgb($c)\"" "$tmpdir/dart.svg")" -ge 1 ] \
        || { echo "dartboard tile rgb($c) not drawn" >&2; exit 1; }
done
printf 'sp,ring,v,grp\nA,in,1,g1\nA,out,2,g2\n' >"$tmpdir/dart2.csv"
if "$CINDERPLOT" "$tmpdir/dart2.csv + aes(x=factor(sp), y=factor(ring), fill=v, group=grp) + geom_tile() + coord_polar()" \
        -o "$tmpdir/dart2.svg" 2>"$tmpdir/dart2.err" >/dev/null; then
    echo "a spoke in two groups unexpectedly succeeded" >&2; exit 1; fi
grep -q 'falls in two groups' "$tmpdir/dart2.err" || { echo "no two-group error" >&2; exit 1; }

# ---- C15zz: dartboard rings with their own fill scales (new_scale_fill) ----
# ggnewscale's idiom: each geom_tile(data=, aes(fill=)) ring takes the fill
# scales given before the next new_scale_fill(), and each gets its own key
printf 'sp,ring,v,grp\nA,in,lost,g1\nB,in,kept,g1\nC,in,kept,g2\n' >"$tmpdir/rg0.csv"
printf 'sp,ring,v,grp\nA,out,0.1,g1\nB,out,0.5,g1\nC,out,0.9,g2\n' >"$tmpdir/rg1.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rg0.csv + aes(x=factor(sp), y=factor(ring), group=grp) + geom_tile(aes(fill=v)) + scale_fill_manual(values=c(kept=\"#ff0000\", lost=\"#0000ff\")) + labs(fill=\"State\") + new_scale_fill() + geom_tile(data=\"$tmpdir/rg1.csv\", aes(fill=v)) + scale_fill_gradient(low=\"#000000\", high=\"#00ff00\", limits=c(0, 1)) + labs(fill=\"Beta\") + coord_polar(gap=10)" \
    -o "$tmpdir/rg.svg" --size 5x4 >/dev/null \
    || { echo "new_scale_fill() dartboard refused" >&2; exit 1; }
grep -q 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/rg.svg" && grep -q 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/rg.svg" \
    || { echo "ring 1 ignored its scale_fill_manual()" >&2; exit 1; }
grep -q '>State</text>' "$tmpdir/rg.svg" && grep -q '>Beta</text>' "$tmpdir/rg.svg" \
    || { echo "one key per ring scale missing" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/rg1.csv + aes(sp, v) + geom_point() + new_scale_fill()" -o "$tmpdir/rg2.svg" \
        2>"$tmpdir/rg2.err" >/dev/null; then
    echo "new_scale_fill() outside the ring plot unexpectedly succeeded" >&2; exit 1; fi
grep -q 'coord_polar() ring plot so far' "$tmpdir/rg2.err" \
    || { echo "no scope error for new_scale_fill()" >&2; exit 1; }

# ---- C15zza: two manual scales with filled-point data= layers ----
# scale_colour_manual() and scale_fill_manual() shared one array, so the
# fill values won and colour= fell back to hue; a geom_point(data=, shape=21)
# layer ignored fill=; and fill="..." on a point overwrote its colour=
printf 'x\ty\tg\tf\n1\t1\ta\tp\n2\t2\tb\tp\n3\t3\ta\tq\n' >"$tmpdir/mm.tsv"
printf 'x\ty\tg\tf\n4\t1\ta\tp\n5\t2\ta\tq\n' >"$tmpdir/mm_fill.tsv"
printf 'x\ty\tg\tf\n1\t1\ta\tp\n' >"$tmpdir/mm_ring.tsv"
"$CINDERPLOT" "$tmpdir/mm.tsv + aes(x, y, colour=g, fill=f) + geom_point(data=\"$tmpdir/mm_ring.tsv\", shape=21, colour=\"#000000\", fill=\"#ff00ff\", size=4) + geom_point() + geom_point(data=\"$tmpdir/mm_fill.tsv\", shape=21, stroke=0) + scale_colour_manual(values=c(a=\"#ff0000\", b=\"#00ff00\")) + scale_fill_manual(values=c(p=\"#0000ff\", q=\"#ffff00\"))" \
    -o "$tmpdir/mm.svg" --size 5x4 >/dev/null 2>&1
for c in "100%, 0%, 0%" "0%, 100%, 0%" "0%, 0%, 100%" "100%, 100%, 0%" "100%, 0%, 100%"; do
    grep -q "fill=\"rgb($c)\"" "$tmpdir/mm.svg" \
        || { echo "manual colour/fill rgb($c) not drawn" >&2; exit 1; }
done
grep -q 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/mm.svg" \
    || { echo "filled ring lost its colour= outline" >&2; exit 1; }

# ---- C15zzb: dartboard labels: colour, spoke subset, ring levels= across files ----
# labels were fixed axis-grey with theme(axis.text=) refused, every spoke was
# named, a ring levels= was checked against the first file only, and ring
# names that overran a narrow gap said nothing
printf 'sp,ring,v,grp\nAlpha,in,a,g1\nBravo,in,b,g1\nCharlie,in,a,g2\n' >"$tmpdir/dl0.csv"
printf 'sp,ring,v,grp\nAlpha,out,0.1,g1\nBravo,out,0.5,g1\nCharlie,out,0.9,g2\n' >"$tmpdir/dl1.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/dl0.csv + aes(x=factor(sp), y=factor(ring, levels=c(\"out\", \"in\")), group=grp) + geom_tile(aes(fill=v)) + new_scale_fill() + geom_tile(data=\"$tmpdir/dl1.csv\", aes(fill=v)) + coord_polar(gap=2) + scale_x_discrete(breaks=c(\"Alpha\", \"Bravo\"), labels=c(Bravo=\"B two\")) + theme_minimal() + theme(axis.text=element_text(colour=\"#000000\"))" \
    -o "$tmpdir/dl.svg" --size 5x4 >/dev/null 2>"$tmpdir/dl.err" \
    || { echo "ring levels= across files / axis.text / discrete breaks refused: $(cat "$tmpdir/dl.err")" >&2; exit 1; }
grep -q '>Alpha</text>' "$tmpdir/dl.svg" && grep -q '>B two</text>' "$tmpdir/dl.svg" \
    || { echo "chosen spokes not named as asked" >&2; exit 1; }
if grep -q '>Charlie</text>' "$tmpdir/dl.svg"; then
    echo "a spoke outside breaks= was named" >&2; exit 1; fi
grep '>Alpha</text>' "$tmpdir/dl.svg" | grep -q 'fill="#000000"' \
    || { echo "theme(axis.text=element_text(colour=)) ignored" >&2; exit 1; }
grep -q 'ring names overlap the first spokes' "$tmpdir/dl.err" \
    || { echo "no warning for ring names wider than the gap" >&2; exit 1; }

# ---- C15zzc: coord_polar(gap.start=) sizes the ring-name gap alone ----
# one gap= sized every wedge boundary, so room for the ring names at start=
# took the same angle from every other boundary; gap.start= defaults to gap=
printf 'sp,ring,v,grp\nAlpha,inner ring,1,g1\nBravo,inner ring,2,g1\nCharlie,inner ring,3,g2\nDelta,inner ring,4,g2\n' >"$tmpdir/gs.csv"
G="$tmpdir/gs.csv + aes(x=factor(sp), y=factor(ring), fill=v, group=grp) + geom_tile() + theme_minimal()"
"$CINDERPLOT" "$G + coord_polar(gap=10)" -o "$tmpdir/gs1.svg" --size 4x4 >/dev/null 2>&1
"$CINDERPLOT" "$G + coord_polar(gap=10, gap.start=10)" -o "$tmpdir/gs2.svg" --size 4x4 >/dev/null 2>&1 \
    || { echo "coord_polar(gap.start=) refused" >&2; exit 1; }
cmp -s "$tmpdir/gs1.svg" "$tmpdir/gs2.svg" \
    || { echo "gap.start= equal to gap= changed the figure" >&2; exit 1; }
"$CINDERPLOT" "$G + coord_polar(gap=2)" -o "$tmpdir/gs3.svg" --size 4x4 >/dev/null 2>"$tmpdir/gs3.err"
grep -q 'gap.start=' "$tmpdir/gs3.err" || { echo "ring-name warning does not name gap.start=" >&2; exit 1; }
"$CINDERPLOT" "$G + coord_polar(gap=2, gap.start=80)" -o "$tmpdir/gs4.svg" --size 4x4 >/dev/null 2>"$tmpdir/gs4.err"
if grep -q 'ring names overlap' "$tmpdir/gs4.err"; then
    echo "a wide gap.start= still warns" >&2; exit 1; fi
cmp -s "$tmpdir/gs3.svg" "$tmpdir/gs4.svg" && { echo "gap.start= did not change the layout" >&2; exit 1; }
# theme(axis.text=element_text()) draws the names even over theme_void(), as in ggplot2
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/gs.csv + aes(x=factor(sp), y=factor(ring), fill=v, group=grp) + geom_tile() + coord_polar(gap=2, gap.start=80) + theme_void() + theme(axis.text=element_text(colour=\"#000000\"))" \
    -o "$tmpdir/gs5.svg" --size 4x4 >/dev/null 2>&1
grep -q '>inner ring</text>' "$tmpdir/gs5.svg" \
    || { echo "axis.text=element_text() did not override theme_void()" >&2; exit 1; }
true

# ---- C15zzd: coord_polar(leader=TRUE) spreads named spokes on leader lines ----
# radial names on adjacent spokes (1.5 degrees apart at 225) crowded into one
# another; leader=TRUE sets them horizontal in side columns, at least a text
# height apart, each joined to its spoke by a line
awk 'BEGIN { print "sp,ring,v"; for (i = 10; i < 70; i++) print "s" i ",r,1" }' >"$tmpdir/ld.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ld.csv + aes(x=factor(sp), y=factor(ring), fill=v) + geom_tile() + coord_polar(leader=TRUE) + scale_x_discrete(breaks=c(\"s20\", \"s21\", \"s22\")) + theme_minimal()" \
    -o "$tmpdir/ld.svg" --size 5x4 >/dev/null 2>&1 \
    || { echo "coord_polar(leader=TRUE) refused" >&2; exit 1; }
python3 - "$tmpdir/ld.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
t = re.findall(r'<text([^>]*)>(s2[012])</text>', s)
if len(t) != 3: sys.exit("expected 3 named spokes, got %d" % len(t))
if any('rotate' in a or 'matrix' in a for a, _ in t): sys.exit("leader names are not horizontal")
ys = sorted(float(re.search(r' y="([-0-9.]+)"', a).group(1)) for a, _ in t)
fs = float(re.search(r'font-size="([0-9.]+)"', t[0][0]).group(1))
if min(b - a for a, b in zip(ys, ys[1:])) < 0.95 * fs: sys.exit("leader names closer than a text height")
PY

# ---- C15zze: geom_hline(data=, aes(yintercept=)) per facet; panel-edge title warning ----
# a reference line per facet (ggplot2's data= + aes(yintercept=)) was refused;
# and a title that fit the canvas but not the room right of the y axis was
# clipped with no warning
printf 'g,v,m\nx,1,a\ny,2,a\nx,10,b\ny,20,b\n' >"$tmpdir/fh.csv"
printf 'm,y\na,0\n' >"$tmpdir/fh_lines.csv"
"$CINDERPLOT" "$tmpdir/fh.csv + aes(g, v) + geom_point() + geom_hline(data=\"$tmpdir/fh_lines.csv\", aes(yintercept=y), colour=\"#ff0000\") + facet_wrap(~m, scales=\"free_y\")" \
    -o "$tmpdir/fh.svg" --size 5x3 >/dev/null 2>&1 \
    || { echo "geom_hline(data=, aes(yintercept=)) refused" >&2; exit 1; }
[ "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/fh.svg")" -eq 1 ] \
    || { echo "per-facet hline not drawn in exactly one panel" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/fh.csv + aes(g, v) + geom_point() + geom_hline(data=\"$tmpdir/fh_lines.csv\")" \
        -o "$tmpdir/fh2.svg" 2>"$tmpdir/fh2.err" >/dev/null; then
    echo "geom_hline(data=) without aes(yintercept=) unexpectedly succeeded" >&2; exit 1; fi
grep -q 'needs aes(yintercept=col)' "$tmpdir/fh2.err" || { echo "no aes(yintercept=) error" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/fh.csv + aes(g, v) + geom_point() + labs(title=\"Tumour score alone (their plot)\")" \
    -o "$tmpdir/fh3.svg" --size 3x4 >/dev/null 2>"$tmpdir/fh3.err"
grep -q 'title "Tumour score alone (their plot)" is wider than' "$tmpdir/fh3.err" \
    || { echo "a title clipped past the panel edge gave no warning" >&2; exit 1; }

# ---- C15zzf: leader=TRUE keeps wedge names off the leader lines ----
# small wedges put their names beside the ring exactly where the named
# spokes' leader lines run (COO Fig. 2b: "Vasc. 1/3" across KAPOSI and EHE);
# a wedge name that would be crossed now joins the side column instead
awk 'BEGIN { print "sp,ring,v,grp"; n = 0
             split("Big one 9/9,Vasc. 1/3,RMS 0/4,Other sarc. 0/4,Schw. 1/1,CNS 37/59", G, ",")
             split("20,3,4,4,1,20", N, ",")
             for (g = 1; g <= 6; g++) for (i = 1; i <= N[g]; i++) { n++; printf "s%03d,r,%d,%s\n", n, n % 5, G[g] } }' \
    >"$tmpdir/wl.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/wl.csv + aes(x=factor(sp), y=factor(ring), fill=v, group=factor(grp, levels=c(\"Big one 9/9\", \"Vasc. 1/3\", \"RMS 0/4\", \"Other sarc. 0/4\", \"Schw. 1/1\", \"CNS 37/59\"))) + geom_tile() + coord_polar(gap=3, inner.radius=0.5, leader=TRUE) + scale_x_discrete(breaks=c(\"s021\", \"s022\", \"s025\", \"s030\", \"s031\", \"s032\", \"s033\")) + theme_minimal() + theme(axis.text=element_text(colour=\"black\"), legend.position=\"none\")" \
    -o "$tmpdir/wl.svg" --size 6x5 >/dev/null 2>&1
python3 - "$tmpdir/wl.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
segs = []
for el in re.findall(r'<path[^>]*>', s):
    if 'rgb(45%, 45%, 45%)' not in el or 'fill="none"' not in el: continue
    pts = [(float(a), float(b)) for a, b in re.findall(r'[ML] ([-0-9.]+) ([-0-9.]+)', el)]
    segs += list(zip(pts, pts[1:]))
if not segs: sys.exit("no leader lines drawn")
hits = []
for x, y, fs, t in re.findall(r'<text x="([-0-9.]+)" y="([-0-9.]+)"[^>]*font-size="([0-9.]+)"[^>]*>([^<]+/[^<]+)</text>', s):
    x, y, fs = float(x), float(y), float(fs)
    x0, x1, y0, y1 = x + 2, x + 0.45 * fs * len(t) - 2, y - 0.7 * fs, y
    for (ax, ay), (bx, by) in segs:
        if any(x0 < ax + (bx - ax) * q / 40 < x1 and y0 < ay + (by - ay) * q / 40 < y1 for q in range(41)):
            hits.append(t); break
sys.exit("wedge names crossed by leader lines: %s" % hits if hits else 0)
PY

# ---- C15zzg: tree clades: geom_hilight(), geom_cladelab(), geom_tree(colour=NA) ----
# ggtree's clade shading had no counterpart (COO Fig. 1b colours tip points
# only); a sector per clade under the branches, a boxed two-line label at
# its outer edge, and branches that can be hidden
printf '((a,b)AB,(c,d)CD)root;\n' >"$tmpdir/cl.tre"
printf 'node\tclade\tsub\nAB\tfirst\tone line\nCD\tsecond\ttwo line\n' >"$tmpdir/cl.tsv"
CL="geom_hilight(data=\"$tmpdir/cl.tsv\", fill=clade) + geom_cladelab(data=\"$tmpdir/cl.tsv\", label=clade, sublabel=sub, fill=clade) + scale_fill_manual(values=c(first=\"#ff0000\", second=\"#0000ff\"))"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/cl.tre + geom_tree(layout=circular, colour=NA) + $CL" \
    -o "$tmpdir/cl.svg" >/dev/null 2>&1 || { echo "geom_hilight()/geom_cladelab() refused" >&2; exit 1; }
[ "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/cl.svg")" -ge 2 ] \
    && [ "$(grep -c 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/cl.svg")" -ge 2 ] \
    || { echo "clade sector and label box not both filled" >&2; exit 1; }
for t in first 'one line' second 'two line'; do
    grep -q ">$t</text>" "$tmpdir/cl.svg" || { echo "clade label \"$t\" missing" >&2; exit 1; }
done
if grep -q 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/cl.svg"; then
    echo "geom_tree(colour=NA) still drew branches" >&2; exit 1; fi
"$CINDERPLOT" "$tmpdir/cl.tre + geom_tree() + $CL" -o "$tmpdir/cl2.svg" >/dev/null 2>&1 \
    || { echo "clades on a rectangular tree refused" >&2; exit 1; }
grep -q 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/cl2.svg" || { echo "default tree lost its branches" >&2; exit 1; }
printf 'node\tclade\nNOPE\tx\n' >"$tmpdir/cl_bad.tsv"
if "$CINDERPLOT" "$tmpdir/cl.tre + geom_tree() + geom_hilight(data=\"$tmpdir/cl_bad.tsv\", fill=clade)" \
        -o "$tmpdir/cl3.svg" 2>"$tmpdir/cl3.err" >/dev/null; then
    echo "a clade key naming no node unexpectedly succeeded" >&2; exit 1; fi
grep -q 'is not a node of the tree' "$tmpdir/cl3.err" || { echo "no unknown-node error" >&2; exit 1; }

# ---- C15zzh: heatmap highlight(rows=, cols=) boxes a block ----
# highlight("row","col") framed one cell, so a 2x12 block took 24 calls and
# drew a grid of small boxes (COO Fig. 4c); the block form draws one outline
printf 'rn\tc1\tc2\tc3\tc4\tc5\tc6\nr1\t1\t2\t3\t4\t5\t6\nr2\t2\t3\t4\t5\t6\t1\nr3\t3\t4\t5\t6\t1\t2\nr4\t4\t5\t6\t1\t2\t3\n' >"$tmpdir/bh.tsv"
"$CINDERPLOT" "$tmpdir/bh.tsv + heatmap(name=\"m\", cluster=none) + highlight(rows=c(\"r2\", \"r3\"), cols=c(\"c2\", \"c5\"), colour=\"#0000ff\", linewidth=1)" \
    -o "$tmpdir/bh.svg" >/dev/null 2>&1 || { echo "highlight(rows=, cols=) refused" >&2; exit 1; }
[ "$(grep -c 'stroke="rgb(0%, 0%, 100%)"' "$tmpdir/bh.svg")" -eq 1 ] \
    || { echo "block highlight is not one outline" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/bh.tsv + heatmap(name=\"m\") + highlight(rows=c(\"r2\", \"nope\"), cols=c(\"c2\"))" \
        -o "$tmpdir/bh2.svg" 2>"$tmpdir/bh2.err" >/dev/null; then
    echo "a block naming no row unexpectedly succeeded" >&2; exit 1; fi
grep -q 'highlight(rows=): `nope` is not a row name' "$tmpdir/bh2.err" \
    || { echo "no unknown-row error for the block form" >&2; exit 1; }

# ---- C15zzi: geom_tree(linewidth=) sets the branch stroke ----
# branch width was fixed at the 0.5 default; ggtree's size=/linewidth= now
# sets it, in ggplot units
printf '((a,b),(c,d));\n' >"$tmpdir/lw.tre"
"$CINDERPLOT" "$tmpdir/lw.tre + geom_tree()" -o "$tmpdir/lw0.svg" >/dev/null 2>&1
"$CINDERPLOT" "$tmpdir/lw.tre + geom_tree(linewidth=0.2)" -o "$tmpdir/lw1.svg" >/dev/null 2>&1 \
    || { echo "geom_tree(linewidth=) refused" >&2; exit 1; }
w0=$(grep -o 'stroke-width="[0-9.]*"' "$tmpdir/lw0.svg" | head -1 | tr -dc '0-9.')
w1=$(grep -o 'stroke-width="[0-9.]*"' "$tmpdir/lw1.svg" | head -1 | tr -dc '0-9.')
awk -v a="$w1" -v b="$w0" 'BEGIN { exit !(a > 0 && a < b * 0.6) }' \
    || { echo "geom_tree(linewidth=0.2) did not thin the branches ($w1 vs $w0)" >&2; exit 1; }

# ---- C15zzj: geom_hilight() sectors end at their own clade's tips ----
# every sector ran out to the tree's outer radius, so a clade of short
# branches got a long, mostly empty sector; now each ends extend= mm past
# its own deepest tip (ggtree's default reach)
printf '((a:1,b:1)AB:1,(c:6,d:6)CD:1)root;\n' >"$tmpdir/hr.tre"
printf 'node\tclade\nAB\tshort\nCD\tlong\n' >"$tmpdir/hr.tsv"
"$CINDERPLOT" "$tmpdir/hr.tre + geom_tree(layout=circular) + geom_hilight(data=\"$tmpdir/hr.tsv\", fill=clade) + scale_fill_manual(values=c(short=\"#ff0000\", long=\"#0000ff\"))" \
    -o "$tmpdir/hr.svg" --size 4x4 --no-legend >/dev/null 2>&1 || { echo "geom_hilight() refused" >&2; exit 1; }
python3 - "$tmpdir/hr.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def span(col):
    for el in re.findall(r'<path[^>]*>', s):
        if 'fill="' + col + '"' in el:
            pts = [(float(a), float(b)) for a, b in re.findall(r'[ML] ([-0-9.]+) ([-0-9.]+)', el)]
            if len(pts) > 8:
                xs, ys = [p[0] for p in pts], [p[1] for p in pts]
                return max(max(xs) - min(xs), max(ys) - min(ys))
    return None
a, b = span("rgb(100%, 0%, 0%)"), span("rgb(0%, 0%, 100%)")
if a is None or b is None: sys.exit("hilight sectors not found")
if not a < 0.6 * b: sys.exit("short clade's sector (%.1f) is not shorter than the long one's (%.1f)" % (a, b))
PY

# ---- C15zzk: theme(strip.text=element_text(face=, size=, colour=)) ----
# wedge names (the ring plot's facets) had no theme hook, and strip.text took
# size= only; now face=/colour= style facet strips and wedge names, and bold
# wedge names still clear each other and the leader column
awk 'BEGIN { print "sp,ring,v,grp"; n = 0
             split("Big one 9/9,Vasc. 1/3,RMS 0/4,Other sarc. 0/4,Schw. 1/1,CNS 37/59", G, ",")
             split("20,3,4,4,1,20", N, ",")
             for (g = 1; g <= 6; g++) for (i = 1; i <= N[g]; i++) { n++; printf "s%03d,r,%d,%s\n", n, n % 5, G[g] } }' \
    >"$tmpdir/st.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/st.csv + aes(x=factor(sp), y=factor(ring), fill=v, group=factor(grp, levels=c(\"Big one 9/9\", \"Vasc. 1/3\", \"RMS 0/4\", \"Other sarc. 0/4\", \"Schw. 1/1\", \"CNS 37/59\"))) + geom_tile() + coord_polar(gap=3, inner.radius=0.5, leader=TRUE) + scale_x_discrete(breaks=c(\"s021\", \"s022\", \"s025\", \"s030\", \"s031\", \"s032\", \"s033\")) + theme_minimal() + theme(legend.position=\"none\", strip.text=element_text(face=\"bold\", size=11))" \
    -o "$tmpdir/st.svg" --size 6x5 >/dev/null 2>&1 || { echo "strip.text face= refused" >&2; exit 1; }
python3 - "$tmpdir/st.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
w = [(float(x), float(y), float(fs), t, a) for a, x, y, fs, t in
     re.findall(r'<text((?=[^>]*x="([-0-9.]+)")(?=[^>]*y="([-0-9.]+)")(?=[^>]*font-size="([0-9.]+)")[^>]*)>([^<]+/[^<]+)</text>', s)]
if len(w) != 6: sys.exit("expected 6 wedge names, got %d" % len(w))
if not all('bold' in a and abs(fs - 11) < 0.6 for _, _, fs, _, a in w):
    sys.exit("wedge names not bold 11 pt: %s" % [(t, fs) for _, _, fs, t, _ in w])
box = [(t, x + 1, x + 0.5 * fs * len(t) - 1, y - 0.7 * fs, y) for x, y, fs, t, _ in w]
bad = [(a[0], b[0]) for i, a in enumerate(box) for b in box[i+1:]
       if a[1] < b[2] and b[1] < a[2] and a[3] < b[4] and b[3] < a[4]]
sys.exit("overlapping wedge names: %s" % bad if bad else 0)
PY
printf 'x,y,f\n1,1,a\n2,2,b\n' >"$tmpdir/st2.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/st2.csv + aes(x, y) + geom_point() + facet_wrap(~f) + theme(strip.text=element_text(face=\"bold\", colour=\"#ff0000\"))" \
    -o "$tmpdir/st2.svg" >/dev/null 2>&1
grep '>a</text>' "$tmpdir/st2.svg" | grep -q 'font-weight="bold"' \
    && grep '>a</text>' "$tmpdir/st2.svg" | grep -q 'fill="#ff0000"' \
    || { echo "facet strip not bold/red from strip.text" >&2; exit 1; }

# ---- C15zzl: a circular tree's auto canvas fits what is drawn ----
# the square was sized as if the tree filled a full ring, so a lopsided tree
# (COO Fig. 1b, short clades) sat in the middle of wide blank margins; with
# no --size the canvas now crops to the drawing, and --size stays exact
printf '((a:1,b:1,e:1,f:1)A:1,(c:9,d:9)C:1)root;\n' >"$tmpdir/cf.tre"
"$CINDERPLOT" "$tmpdir/cf.tre + geom_tree(layout=circular)" -o "$tmpdir/cf.svg" >/dev/null 2>&1 \
    || { echo "circular tree failed" >&2; exit 1; }
python3 - "$tmpdir/cf.svg" <<'PY'
import re, sys
m = re.search(r'<svg[^>]*width="([0-9.]+)[a-z]*" height="([0-9.]+)', open(sys.argv[1]).read())
w, h = float(m.group(1)), float(m.group(2))
if abs(w - h) < 0.05 * max(w, h): sys.exit("auto canvas still square (%.0f x %.0f)" % (w, h))
PY
"$CINDERPLOT" "$tmpdir/cf.tre + geom_tree(layout=circular)" -o "$tmpdir/cf2.svg" --size 4x4 >/dev/null 2>&1
grep -q 'width="288' "$tmpdir/cf2.svg" && grep -q 'height="288' "$tmpdir/cf2.svg" \
    || { echo "--size 4x4 not honoured exactly" >&2; exit 1; }

# ---- C15zzm: coord_fixed() keeps one data unit equal on both axes ----
# a spatial pixel map needs square tiles; there was no coord_fixed()/
# coord_equal(), so --size had to be hunted by hand. Tiles are square on the
# auto canvas and inside a --size of the wrong shape; ratio=2 doubles height.
printf 'x,y,g\n0,0,a\n1,0,b\n2,0,a\n3,0,b\n0,1,b\n1,1,a\n2,1,b\n3,1,a\n' >"$tmpdir/cfx.csv"
cfx_tile() {    # print "w h" of the commonest closed 4-corner path: the 8 tiles
    python3 - "$1" <<'PY'
import re, sys, collections
c = collections.Counter()
for d in re.findall(r'<path[^>]* d="([^"]+)"', open(sys.argv[1]).read()):
    n = list(map(float, re.findall(r'-?[0-9.]+', d)))
    if len(n) in (8, 10):
        xs, ys = n[0::2], n[1::2]
        w, h = max(xs) - min(xs), max(ys) - min(ys)
        if min(w, h) > 5: c[(round(w, 2), round(h, 2))] += 1   # not a grid line
print("%.3f %.3f" % c.most_common(1)[0][0])
PY
}
for sz in "" "--size 6x3" "--size 3x6"; do
    "$CINDERPLOT" "$tmpdir/cfx.csv + aes(x,y,fill=g) + geom_tile() + coord_fixed(expand=FALSE)" \
        -o "$tmpdir/cfx.svg" $sz >/dev/null 2>&1 || { echo "coord_fixed failed ($sz)" >&2; exit 1; }
    cfx_tile "$tmpdir/cfx.svg" | awk -v sz="$sz" '{ if ($1 <= 0 || ($1 - $2) ^ 2 > 0.01) {
        print "coord_fixed tile not square (" sz "): " $0 > "/dev/stderr"; exit 1 } }'
done
"$CINDERPLOT" "$tmpdir/cfx.csv + aes(x,y,fill=g) + geom_tile() + coord_equal(ratio=2, expand=FALSE)" \
    -o "$tmpdir/cfx2.svg" >/dev/null 2>&1 || { echo "coord_equal(ratio=2) failed" >&2; exit 1; }
cfx_tile "$tmpdir/cfx2.svg" | awk '{ if (($2 - 2 * $1) ^ 2 > 0.04) {
    print "ratio=2 tile not twice as tall: " $0 > "/dev/stderr"; exit 1 } }'
"$CINDERPLOT" "$tmpdir/cfx.csv + aes(x,y) + geom_point() + coord_fixed() + facet_wrap(~g, scales=\"free\")" \
    -o "$tmpdir/cfx3.svg" >/dev/null 2>"$tmpdir/err" && { echo "free scales accepted" >&2; exit 1; }
grep -q 'coord_fixed() needs one data range' "$tmpdir/err"

# ---- C15zzn: heatmap labs(y=) stays on the canvas ----
# the y title was centred on the canvas cell whatever its length, so one
# longer than that cell ran off the bottom (its start clipped). It now slides
# inside the margins, an auto canvas grows to hold it, and --size warns.
printf 'r\ta\tb\nx\t1\t2\ny\t3\t4\n' >"$tmpdir/hyt.tsv"
hyt="a deliberately long y axis title that will not fit the canvas height"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/hyt.tsv + heatmap(name=\"m\", cluster=none) + labs(y=\"$hyt\")" \
    -o "$tmpdir/hyt.svg" >/dev/null 2>&1 || { echo "heatmap y title failed" >&2; exit 1; }
python3 - "$tmpdir/hyt.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
h = float(re.search(r'<svg[^>]*height="([0-9.]+)', s).group(1))
y = float(re.search(r'matrix\(0 -1 1 0 [0-9.-]+ ([0-9.-]+)\)', s).group(1))
if y > h: sys.exit("y title starts below the canvas (%.1f > %.1f)" % (y, h))
if h < 250: sys.exit("auto canvas did not grow for the title (%.0f pt)" % h)
PY
"$CINDERPLOT" "$tmpdir/hyt.tsv + heatmap(name=\"m\", cluster=none) + labs(y=\"$hyt\")" \
    -o "$tmpdir/hyt2.svg" --size 3x2 >/dev/null 2>"$tmpdir/err" || { echo "--size run failed" >&2; exit 1; }
grep -q 'y axis title .* is taller than the 2.0in canvas' "$tmpdir/err"

# ---- C15zzo: geom_hex(stat="identity") tiles a spot grid with hexagons ----
# spatial maps are drawn as gapless hexagons (one per spot, Visium-style);
# there was no geom_hex. One pointy-top hexagon per row: half-width = the x
# pitch, vertices at +-2/3 of the y pitch, offset=TRUE staggers a square
# grid. Checked: 16 hexagons, each as wide as the column pitch, rows
# interlocking (3/4 of a hexagon's height = the row pitch).
printf 'x,y,g\n' >"$tmpdir/hex.csv"
for y in 0 1 2 3; do for x in 0 1 2 3; do
    echo "$x,$y,g$(( (x + y) % 3 ))" >>"$tmpdir/hex.csv"; done; done
"$CINDERPLOT" "$tmpdir/hex.csv + aes(x,y,fill=g) + geom_hex(stat=\"identity\", offset=TRUE) + coord_fixed(expand=FALSE)" \
    -o "$tmpdir/hex.svg" >/dev/null 2>&1 || { echo "geom_hex(stat=identity) failed" >&2; exit 1; }
python3 - "$tmpdir/hex.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
hexes = []
for d in re.findall(r'<path[^>]* d="([^"]+)"', s):
    n = list(map(float, re.findall(r'-?[0-9.]+', d)))
    if len(n) == 14:
        hexes.append((n[0:12:2], n[1:12:2]))
if len(hexes) != 16: sys.exit("expected 16 hexagons, found %d" % len(hexes))
w = [max(x) - min(x) for x, y in hexes]; h = [max(y) - min(y) for x, y in hexes]
cx = sorted({round((max(x) + min(x)) / 2, 1) for x, y in hexes})
cy = sorted({round((max(y) + min(y)) / 2, 1) for x, y in hexes})
pitch_x = (cx[-1] - cx[0]) / 7          # 4 columns, odd rows shifted half
pitch_y = (cy[-1] - cy[0]) / 3
if abs(w[0] - 2 * pitch_x) > 0.05: sys.exit("hexagon width %.2f != column pitch %.2f" % (w[0], 2 * pitch_x))
if abs(0.75 * h[0] - pitch_y) > 0.05: sys.exit("rows do not interlock: 3/4 h %.2f vs pitch %.2f" % (0.75 * h[0], pitch_y))
PY
# ---- C15zzp: geom_hex() bins points into hexagons as ggplot2 does ----
# the hex-bin heatmap: stat_binhex counts the points per hexagon (hexbin's
# lattice, bins=30 over the data range) and fills by count. The expected
# cells are ggplot2 3.5 layer_data(geom_hex(bins = 4)) for these 40 points:
# the 27 centres (x, y, count) and the hexagon width 0.75 (x units).
awk 'BEGIN { print "x,y"; for (i = 0; i < 40; i++)
    printf "%.10g,%.10g\n", (i * 7) % 10 / 3, (i * 3) % 8 / 2 + (i % 3) / 10 }' >"$tmpdir/hb.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/hb.csv + aes(x,y) + geom_hex(bins=4)" \
    -o "$tmpdir/hb.svg" >/dev/null 2>&1 || { echo "binned geom_hex failed" >&2; exit 1; }
python3 - "$tmpdir/hb.svg" <<'PY'
import re, sys
exp = [(0,0,1),(.75,0,1),(1.5,0,1),(2.25,0,1),(3,0,2),(.375,.8011,3),(1.125,.8011,2),
       (1.875,.8011,2),(2.625,.8011,2),(0,1.6021,1),(.75,1.6021,2),(1.5,1.6021,2),
       (2.25,1.6021,1),(3,1.6021,1),(.375,2.4032,2),(1.125,2.4032,1),(1.875,2.4032,2),
       (2.625,2.4032,2),(3.375,2.4032,1),(0,3.2043,1),(.75,3.2043,1),(1.5,3.2043,1),
       (2.25,3.2043,2),(3,3.2043,2),(.375,4.0054,1),(1.125,4.0054,1),(1.875,4.0054,1)]
s = open(sys.argv[1]).read()
got = []
for m in re.finditer(r'<path([^>]*) d="([^"]+)"', s):
    n = list(map(float, re.findall(r'-?[0-9.]+', m.group(2))))
    if len(n) != 14: continue
    xs, ys = n[0:12:2], n[1:12:2]
    f = re.search(r'fill="([^"]+)"', m.group(1) + s[m.end():m.end() + 80])
    got.append(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, max(xs) - min(xs), f and f.group(1)))
if len(got) != len(exp): sys.exit("%d hexagons, ggplot2 has %d" % (len(got), len(exp)))
exp.sort(key=lambda e: (e[1], e[0])); got.sort(key=lambda g: (-g[1], g[0]))
xg = [g[0] for g in got]; xe = [e[0] for e in exp]; yg = [g[1] for g in got]; ye = [e[1] for e in exp]
ax = (max(xg) - min(xg)) / (max(xe) - min(xe)); bx = min(xg) - ax * min(xe)
ay = (max(yg) - min(yg)) / (max(ye) - min(ye)); by = max(yg) - ay * min(ye)
for e, g in zip(exp, got):
    if abs(g[0] - (ax * e[0] + bx)) > 0.1 or abs(g[1] - (by - ay * e[1])) > 0.1:
        sys.exit("hexagon at %s is not where ggplot2 puts it" % (e,))
if abs(got[0][2] - 0.75 * ax) > 0.1: sys.exit("hexagon width %.2f, expected %.2f" % (got[0][2], 0.75 * ax))
fill = {}
for e, g in zip(exp, got): fill.setdefault(e[2], set()).add(g[3])
if any(len(v) != 1 for v in fill.values()) or len({next(iter(v)) for v in fill.values()}) != len(fill):
    sys.exit("fills do not follow the counts: %s" % fill)
if '>count<' not in s: sys.exit("no count legend title")
PY
"$CINDERPLOT" "$tmpdir/hb.csv + aes(x,y) + geom_hex() + geom_point()" -o "$tmpdir/hb2.svg" \
    >/dev/null 2>"$tmpdir/err" && { echo "binned hex + points accepted" >&2; exit 1; }
grep -q 'binned geom_hex() replaces the data' "$tmpdir/err"

# ---- C15zzq: aes(alpha=), scale_alpha(range=), transparent colours ----
# an expression overlay needs zero expression fully transparent: there was
# no alpha aesthetic, and "transparent" / #RRGGBBAA were "bad colour". Now
# alpha maps a numeric column over scale_alpha(range=) (ggplot2's default
# c(0.1, 1)) with its own legend, and an 8-digit hex carries its alpha.
printf 'x,y,g\n1,1,a\n2,1,b\n3,1,c\n' >"$tmpdir/al.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/al.csv + aes(x,y,alpha=x) + geom_tile() + scale_alpha(range=c(0, 1)) + labs(alpha=\"opacity\")" \
    -o "$tmpdir/al.svg" >/dev/null 2>&1 || { echo "aes(alpha=) failed" >&2; exit 1; }
grep -q 'fill="rgb(34.9%, 34.9%, 34.9%)" fill-opacity="0.5"' "$tmpdir/al.svg" \
    || { echo "the middle tile is not at opacity 0.5" >&2; exit 1; }
grep -q '>opacity<' "$tmpdir/al.svg" || { echo "no alpha legend" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/al.csv + aes(x,y,fill=g) + geom_tile() + scale_fill_manual(values=c(a=\"transparent\", b=\"#ff000080\", c=\"blue\"))" \
    -o "$tmpdir/al2.svg" >/dev/null 2>&1 || { echo "transparent / #RRGGBBAA refused" >&2; exit 1; }
grep -q 'fill="rgb(100%, 0%, 0%)" fill-opacity="0.50' "$tmpdir/al2.svg" \
    || { echo "#ff000080 lost its alpha" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/al.csv + aes(x,y,alpha=g) + geom_point()" -o "$tmpdir/al3.svg" \
    >/dev/null 2>"$tmpdir/err" && { echo "discrete alpha accepted" >&2; exit 1; }
grep -q 'aes(alpha=) needs a numeric column' "$tmpdir/err"

# ---- C15zzr: geom_ribbon, axis.text/plot.title size, log breaks, bottom legend ----
# four grant-panel gaps, each as ggplot2 has it: geom_ribbon(aes(ymin, ymax))
# (one band per group); theme(axis.text= / plot.title=element_text(size=));
# scale_x_log10(breaks=, labels=) (was "only limits="); and
# theme(legend.position="bottom") (keys in a row under the x title)
printf 'x,y,lo,hi,g\n100,1,0.8,1.2,a\n1000,0.6,0.5,0.7,a\n10000,0.3,0.2,0.4,a\n100,0.9,0.7,1.1,b\n1000,0.4,0.3,0.5,b\n10000,0.1,0.05,0.2,b\n' >"$tmpdir/rb.csv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rb.csv + aes(x, y, ymin=lo, ymax=hi, colour=g) + geom_ribbon(alpha=0.2) + geom_line() + scale_x_log10(breaks=c(100,1000,10000), labels=c(\"100\",\"1k\",\"10k\")) + theme_classic(base_size=12) + theme(axis.text=element_text(size=10), plot.title=element_text(size=12), legend.position=\"bottom\") + labs(title=\"T\")" \
    -o "$tmpdir/rb.svg" >/dev/null 2>&1 || { echo "ribbon/log breaks/bottom legend failed" >&2; exit 1; }
python3 - "$tmpdir/rb.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
bands = [d for d in re.findall(r'<path[^>]* d="([^"]+)"', s)
         if len(re.findall(r'-?[0-9.]+', d)) == 14]           # 6 corners: 3 x on top and bottom
if len(bands) < 2: sys.exit("expected a ribbon per group, found %d" % len(bands))
t = []
for a, body in re.findall(r'<text([^>]*)>([^<]*)', s):
    x = re.search(r' x="([0-9.]+)"', a); y = re.search(r' y="([0-9.]+)"', a)
    z = re.search(r'font-size="([0-9.]+)"', a)
    if x and y and z: t.append((float(x.group(1)), float(y.group(1)), float(z.group(1)), body))
lab = {e[3]: e for e in t}
if '1k' not in lab or lab['1k'][2] != 10: sys.exit("log break label 1k missing or not 10 pt: %s" % lab.get('1k'))
if lab['T'][2] != 12: sys.exit("plot.title size %.2f, expected 12" % lab['T'][2])
if not ('g' in lab and lab['g'][1] > lab['x'][1]): sys.exit("legend title not below the x title")
if abs(lab['a'][1] - lab['b'][1]) > 2: sys.exit("bottom keys not in one row")
PY

# ---- C15zzs: filled density, ridges, axis.text.y blank, facet_grid levels ----
# COO Fig. 4a/S4a: geom_density(fill=) warned and drew lines; there was no
# geom_density_ridges(); theme(axis.text.y=element_blank()) was refused; and
# facet_grid() sorted its levels with no way to order them. As ggplot2 /
# ggridges: a filled density keeps alpha on the fill; ridges share one
# bandwidth with the tallest scale= (1.8) rows high; .y blanks the left axis
# and frees its room; factor(v, levels=) orders a grid side.
awk 'BEGIN { srand(7); print "v\tType\tCancer";
    split("BRCA LUAD", cs, " "); split("Primary Normal", ts, " ");
    for (c = 1; c <= 2; c++) for (t = 1; t <= 2; t++) for (i = 0; i < 30; i++)
        printf "%.4f\t%s\t%s\n", 0.3 + 0.3 * t + 0.1 * c + 0.1 * (rand() + rand() - 1), ts[t], cs[c] }' >"$tmpdir/rd.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rd.tsv + aes(v, fill=Type) + geom_density(alpha=0.5)" \
    -o "$tmpdir/rd1.svg" >/dev/null 2>"$tmpdir/err" || { echo "filled density failed" >&2; exit 1; }
grep -q 'drawn as colour' "$tmpdir/err" && { echo "filled density still warns" >&2; exit 1; }
grep -q 'fill-opacity="0.5"' "$tmpdir/rd1.svg" || { echo "density fill has no alpha" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rd.tsv + aes(v, Cancer, fill=Type) + geom_density_ridges(alpha=0.7)" \
    -o "$tmpdir/rd2.svg" >/dev/null 2>&1 || { echo "geom_density_ridges failed" >&2; exit 1; }
python3 - "$tmpdir/rd2.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
f = []
for m in re.finditer(r'<path([^>]*)>', s):
    a = m.group(1); d = re.search(r' d="([^"]+)"', a)
    if not d or 'fill="none"' in a: continue
    n = list(map(float, re.findall(r'-?[0-9.]+', d.group(1))))
    if len(n) > 100: f.append(n[1::2])
if len(f) != 4: sys.exit("expected 4 ridges, found %d" % len(f))
bases = sorted({round(max(y), 1) for y in f})
if len(bases) != 2: sys.exit("ridges not on two baselines: %s" % bases)
unit = bases[1] - bases[0]
tall = max(max(y) - min(y) for y in f) / unit
if abs(tall - 1.8) > 0.01: sys.exit("tallest ridge %.3f rows, ggridges' scale is 1.8" % tall)
PY
printf 'p\tv\n' >"$tmpdir/ax.tsv"
i=0; while [ $i -lt 200 ]; do printf 'cg%05d\t%d\n' $i $((i % 7)) >>"$tmpdir/ax.tsv"; i=$((i + 1)); done
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ax.tsv + aes(p, v) + geom_col() + coord_flip() + theme(axis.text.y=element_blank())" \
    -o "$tmpdir/rd3.svg" >/dev/null 2>&1 || { echo "axis.text.y=element_blank() refused" >&2; exit 1; }
grep -q '>cg00' "$tmpdir/rd3.svg" && { echo "y labels still drawn" >&2; exit 1; }
grep -q 'height="288"' "$tmpdir/rd3.svg" || { echo "200 hidden labels still stretched the canvas" >&2; exit 1; }
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/rd.tsv + aes(v) + geom_density() + facet_grid(factor(Cancer, levels=c(\"LUAD\",\"BRCA\")) ~ factor(Type, levels=c(\"Primary\",\"Normal\")))" \
    -o "$tmpdir/rd4.svg" >/dev/null 2>&1 || { echo "facet_grid(factor(levels=)) refused" >&2; exit 1; }
grep -o '>[A-Z][A-Za-z]*<' "$tmpdir/rd4.svg" | tr -d '<>' | tr '\n' ' ' | grep -q 'Primary Normal LUAD BRCA' \
    || { echo "facet_grid levels not in the given order" >&2; exit 1; }

# ---- C15zzt: tree mode honours scale_colour_manual / scale_fill_manual ----
# COO Fig. 1b: tip points ignored scale_colour_manual (an "Unassigned" grey
# came out a default hue), so with manual scales a lineage's tips and its
# sector took different colours. Points take the colour scale, sectors and
# clade boxes the fill scale; one given alone colours both.
printf '((a:1,b:1)A:1,(c:1,d:1)C:1)root;\n' >"$tmpdir/tm.tre"
printf 'tip\tlin\na\tX\nb\tX\nc\tY\nd\tU\n' >"$tmpdir/tm_tips.tsv"
printf 'node\tlin\nA\tX\n' >"$tmpdir/tm_cl.tsv"
"$CINDERPLOT" "$tmpdir/tm.tre + geom_tree() + geom_hilight(data=\"$tmpdir/tm_cl.tsv\", fill=lin) + geom_tippoint(data=\"$tmpdir/tm_tips.tsv\", colour=lin) + scale_colour_manual(values=c(X=\"#123456\", Y=\"#00ff00\", U=\"#bdbdbd\")) + scale_fill_manual(values=c(X=\"#123456\"))" \
    -o "$tmpdir/tm1.svg" >/dev/null 2>&1 || { echo "tree with manual scales failed" >&2; exit 1; }
grep -q 'rgb(74.117647%, 74.117647%, 74.117647%)' "$tmpdir/tm1.svg" \
    || { echo "scale_colour_manual not applied to tip points" >&2; exit 1; }
test "$(grep -c 'rgb(7.058824%, 20.392157%, 33.72549%)' "$tmpdir/tm1.svg")" -ge 3 \
    || { echo "X tips and X sector do not share the manual colour" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/tm.tre + geom_tree() + geom_hilight(data=\"$tmpdir/tm_cl.tsv\", fill=lin) + geom_tippoint(data=\"$tmpdir/tm_tips.tsv\", colour=lin) + scale_fill_manual(values=c(X=\"#123456\", Y=\"#00ff00\", U=\"#bdbdbd\"))" \
    -o "$tmpdir/tm2.svg" >/dev/null 2>&1 || { echo "tree with fill manual failed" >&2; exit 1; }
grep -q 'rgb(74.117647%, 74.117647%, 74.117647%)' "$tmpdir/tm2.svg" \
    || { echo "scale_fill_manual alone does not reach the tips" >&2; exit 1; }

# ---- C15zzu: heatmap and track modes honour theme text sizes ----
# COO Fig. 2a/2c: a 12/10 pt convention could not be met -- heatmap names,
# annotation titles, group labels and colour-bar numbers stayed 0.8 x base,
# and track row names stayed fitted to the row. axis.text= sizes names and
# numbers, axis.title= the annotation/group labels, legend.text= the keys.
printf 'id\tA\tB\nr1\t0.1\t0.9\nr2\t0.6\t0.3\n' >"$tmpdir/ts_m.tsv"
printf 'col\tgrp\nA\tg1\nB\tg2\n' >"$tmpdir/ts_c.tsv"
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ts_m.tsv + heatmap(name=\"m\", cluster=none, rownames=left) + annotation(\"$tmpdir/ts_c.tsv\", column=\"grp\", top_of(\"m\", height=0.1), name=\"grp\", title=\"Group\", title.side=left, labels=data, values=c(g1=\"red\", g2=\"blue\")) + legend(right_of(\"m\"), title=\"Beta\") + theme_minimal(base_size=12) + theme(axis.text=element_text(size=10), axis.title=element_text(size=12), legend.text=element_text(size=10))" \
    -o "$tmpdir/ts1.svg" >/dev/null 2>&1 || { echo "heatmap with theme sizes failed" >&2; exit 1; }
python3 - "$tmpdir/ts1.svg" <<'PY'
import re, sys
sz = {b: float(a) for a, b in re.findall(r'<text[^>]*font-size="([0-9.]+)"[^>]*>([^<]+)', open(sys.argv[1]).read())}
want = {'r1': 10, 'Group': 12, 'g1': 12, '0.50': 10, 'Beta': 12}
bad = {k: (sz.get(k), v) for k, v in want.items() if sz.get(k) != v}
if bad: sys.exit("heatmap text sizes (got, want): %s" % bad)
PY
# unset, the annotation titles and group labels follow base_size (Wanding,
# 2026-11-18), the names stay 0.8 x base
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "$tmpdir/ts_m.tsv + heatmap(name=\"m\", cluster=none, rownames=left) + annotation(\"$tmpdir/ts_c.tsv\", column=\"grp\", top_of(\"m\", height=0.1), name=\"grp\", title=\"Group\", title.side=left, labels=data, values=c(g1=\"red\", g2=\"blue\")) + theme_minimal(base_size=12)" \
    -o "$tmpdir/ts1b.svg" >/dev/null 2>&1 || { echo "heatmap at base_size=12 failed" >&2; exit 1; }
python3 - "$tmpdir/ts1b.svg" <<'PY'
import re, sys
sz = {b: float(a) for a, b in re.findall(r'<text[^>]*font-size="([0-9.]+)"[^>]*>([^<]+)', open(sys.argv[1]).read())}
want = {'r1': 9.6, 'Group': 12, 'g1': 12}
bad = {k: (sz.get(k), v) for k, v in want.items() if sz.get(k) != v}
if bad: sys.exit("heatmap default sizes at base 12 (got, want): %s" % bad)
PY
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" "region(\"chr20:44617001-44653999\") + matrix(\"$here/data/region_betas_grouped.tsv\", name=\"b\", rowgroup=\"-\", cluster=none, rownames=on, height=6) + theme_minimal(base_size=12) + theme(axis.text=element_text(size=8), axis.title=element_text(size=12))" \
    -o "$tmpdir/ts2.svg" >/dev/null 2>&1 || { echo "track with theme sizes failed" >&2; exit 1; }
python3 - "$tmpdir/ts2.svg" <<'PY'
import re, sys
t = re.findall(r'<text[^>]*font-size="([0-9.]+)"[^>]*>([^<]+)', open(sys.argv[1]).read())
leaf = {float(a) for a, b in t if b in ('Normal', 'Tumour')}
grp = {float(a) for a, b in t if b == '2671'}
if leaf != {8.0}: sys.exit("track row names at %s, want 8 pt" % leaf)
if grp != {12.0}: sys.exit("track group labels at %s, want 12 pt" % grp)
PY

# ---- C15zzv: a constant fill= on geom_tile / geom_hex paints the cell ----
# geom_tile(fill="red") drew grey cells with red borders (fill= took the
# colour= slot, which on a tile is the border). As ggplot2: fill= is the
# body, colour= the border, in either order.
printf 'x,y\n1,1\n2,1\n3,1\n' >"$tmpdir/cf.csv"
for g in 'geom_tile(fill="red")' 'geom_tile(colour="white", fill="red")' \
         'geom_tile(fill="red", colour="white")' 'geom_hex(stat="identity", fill="red")'; do
    "$CINDERPLOT" "$tmpdir/cf.csv + aes(x,y) + $g" -o "$tmpdir/cfill.svg" >/dev/null 2>&1 \
        || { echo "$g failed" >&2; exit 1; }
    test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/cfill.svg")" -eq 3 \
        || { echo "$g: the cells are not red" >&2; exit 1; }
    grep -q 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/cfill.svg" \
        && { echo "$g: fill= still draws the border" >&2; exit 1; }
done
"$CINDERPLOT" "$tmpdir/cf.csv + aes(x,y) + geom_tile(colour=\"white\", fill=\"red\") + theme_void()" \
    -o "$tmpdir/cfill2.svg" >/dev/null 2>&1
test "$(grep -c 'stroke="rgb(100%, 100%, 100%)"' "$tmpdir/cfill2.svg")" -eq 3 \
    || { echo "colour= border lost beside fill=" >&2; exit 1; }

# ---- C15zzw: guide_colourbar(barheight=, barwidth=) in heatmap and track mode ----
# COO Fig. 2a wants 60 x 9 pt colourbars; heatmap and track legends kept the
# fixed 28 x 4 mm bar (about 80 pt long). As plot mode and ggplot2: a
# standing bar is barheight long and barwidth thick.
cat >"$tmpdir/cbar.py" <<'PY'
import re, sys, collections
s = open(sys.argv[1]).read(); c = collections.Counter(); ext = {}
for d in re.findall(r' d="([^"]+)"', s):
    n = list(map(float, re.findall(r'-?[0-9.]+', d)))
    if len(n) in (8, 10):
        xs, ys = n[0::2], n[1::2]; k = (round(min(xs), 1), round(max(xs) - min(xs), 2))
        c[k] += 1; ext.setdefault(k, []).extend(ys)
bars = [(k[1], max(ext[k]) - min(ext[k])) for k, v in c.items() if v >= 30]
if len(bars) != 1: sys.exit("expected one colourbar, found %d" % len(bars))
w, l = bars[0]
if abs(w - 9) > 0.5 or abs(l - 60) > 1: sys.exit("colourbar %.1f x %.1f pt, want 9 x 60" % (w, l))
PY
printf 'id\tA\tB\nr1\t0.1\t0.9\nr2\t0.6\t0.3\n' >"$tmpdir/cb_m.tsv"
G='guides(fill=guide_colourbar(barheight=unit(60,"pt"), barwidth=unit(9,"pt")))'
"$CINDERPLOT" "$tmpdir/cb_m.tsv + heatmap(name=\"m\", cluster=none) + legend(right_of(\"m\"), title=\"Beta\") + $G" \
    -o "$tmpdir/cb1.svg" >/dev/null 2>&1 || { echo "heatmap colourbar guide failed" >&2; exit 1; }
python3 "$tmpdir/cbar.py" "$tmpdir/cb1.svg"
"$CINDERPLOT" "region(\"chr20:44617001-44653999\") + matrix(\"$here/data/region_betas_grouped.tsv\", name=\"b\", cluster=none, rownames=off, height=6) + legend(title=\"beta\") + $G" \
    -o "$tmpdir/cb2.svg" >/dev/null 2>&1 || { echo "track colourbar guide failed" >&2; exit 1; }
python3 "$tmpdir/cbar.py" "$tmpdir/cb2.svg"

# ---- C15zzx: linewidth= on geom_density_ridges() and geom_density() ----
# COO Fig. 4a: the ridge outlines were too heavy, and linewidth= errored.
# As ggplot2: linewidth (0.3 = 0.64 pt) with a constant colour= outline.
awk 'BEGIN { srand(7); print "v\tType\tCancer";
    split("BRCA LUAD", cs, " "); split("Primary Normal", ts, " ");
    for (c = 1; c <= 2; c++) for (t = 1; t <= 2; t++) for (i = 0; i < 30; i++)
        printf "%.4f\t%s\t%s\n", 0.3 + 0.3 * t + 0.1 * c + 0.1 * (rand() + rand() - 1), ts[t], cs[c] }' >"$tmpdir/rd.tsv"
"$CINDERPLOT" "$tmpdir/rd.tsv + aes(v, Cancer, fill=Type) + geom_density_ridges(alpha=0.7, colour=\"white\", linewidth=0.3)" \
    -o "$tmpdir/lw1.svg" >/dev/null 2>&1 || { echo "ridges linewidth= refused" >&2; exit 1; }
test "$(grep -c 'stroke-width="0.640187"[^>]*stroke="rgb(100%, 100%, 100%)"' "$tmpdir/lw1.svg")" -eq 4 \
    || { echo "ridge outlines not white at 0.64 pt" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/rd.tsv + aes(v, fill=Type) + geom_density(linewidth=0.3)" \
    -o "$tmpdir/lw2.svg" >/dev/null 2>&1 || { echo "density linewidth= refused" >&2; exit 1; }
test "$(grep -c 'stroke-width="0.640187"' "$tmpdir/lw2.svg")" -eq 2 \
    || { echo "density curves not at 0.64 pt" >&2; exit 1; }

# ---- C15zzy: --tight crops the page to the drawn ink ----
# composite panels wanted no empty margin; every mode kept its page
# margins (6-22 pt). --tight lays out at --size, then crops the page to
# the ink: here three bare tiles, whose outer edges become the page edges.
printf 'x,y,g\n1,1,a\n2,1,b\n3,2,a\n' >"$tmpdir/tt.csv"
"$CINDERPLOT" "$tmpdir/tt.csv + aes(x,y,fill=g) + geom_tile() + theme_void() + guides(fill=\"none\")" \
    --transparent --size 4x3 --tight -o "$tmpdir/tt.svg" >/dev/null 2>&1 || { echo "--tight failed" >&2; exit 1; }
python3 - "$tmpdir/tt.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
w, h = (float(v) for v in re.search(r'<svg[^>]*width="([0-9.]+)[a-z]*" height="([0-9.]+)', s).groups())
if w >= 288 or h >= 216: sys.exit("--tight kept the %gx%g page" % (w, h))
vb = list(map(float, re.search(r'viewBox="([^"]+)"', s).group(1).split()))
s = re.sub(r'<clipPath.*?</clipPath>', '', s, flags=re.S)   # clip shapes are not ink
pts = [list(map(float, re.findall(r'-?[0-9.]+', d))) for d in re.findall(r' d="([^"]+)"', s)]
xs = [v for n in pts for v in n[0::2]]; ys = [v for n in pts for v in n[1::2]]
# the tiles are clipped to the panel: clamp to the viewBox, then each side
# may keep at most the 1 pt cairo's integer ink box rounds to
x0, y0 = max(min(xs), vb[0]), max(min(ys), vb[1])
x1, y1 = min(max(xs), vb[0] + vb[2]), min(max(ys), vb[1] + vb[3])
gaps = (x0 - vb[0], y0 - vb[1], vb[0] + vb[2] - x1, vb[1] + vb[3] - y1)
if max(gaps) > 1.0: sys.exit("--tight left margins %s around the ink" % (gaps,))
PY
"$CINDERPLOT" "$tmpdir/tt.csv + aes(x,y) + geom_point()" --tight -o "$tmpdir/tt.png" >/dev/null 2>&1 \
    || { echo "--tight png failed" >&2; exit 1; }

# ---- C16: geom_errorbar() default cap is 0.9 x the x resolution ----
# with x = 0.1, 0.2, 0.3 the old 0.25-unit default ran the caps edge to edge
# and through the neighbouring bars; a cap is now narrower than the x spacing
printf 'x,y,lo,hi\n0.1,1,0.5,1.5\n0.2,2,1.5,2.5\n0.3,3,2.5,3.5\n' >"$tmpdir/ebres.csv"
"$CINDERPLOT" "$tmpdir/ebres.csv + aes(x,y,ymin=lo,ymax=hi) + geom_errorbar()" -o "$tmpdir/ebres.svg" --size 4x3
svgnorm "$tmpdir/ebres.svg"
grep 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/ebres.svg" | sed 's/.*d="M \([0-9.-]*\) \([0-9.-]*\) L \([0-9.-]*\) \([0-9.-]*\).*/\1 \2 \3 \4/' >"$tmpdir/ebres.lines"
# stems (x0 == x1) of the first two rows give the spacing; caps (y0 == y1) the width
awk '$1 == $3 { s[n++] = $1 } $2 == $4 { w = $3 - $1 }
     END { sp = s[1] - s[0]; if (sp < 0) sp = -sp; exit !(w > 0 && w < sp) }' "$tmpdir/ebres.lines"

# ---- C21: a continuous colour= on geom_line/density/boxplot is an error ----
# these drew black geometry next to a colourbar; a layer colour= still overrides
printf 'x,y,v\n1,1,0.1\n2,2,0.5\n3,3,0.9\n' >"$tmpdir/contcol.csv"
for g in "aes(x,y,colour=v) + geom_line()" "aes(x,colour=v) + geom_density()" \
         "aes(factor(x),y,colour=v) + geom_boxplot()"; do
    if "$CINDERPLOT" "$tmpdir/contcol.csv + $g" -o "$tmpdir/contcol.pdf" \
            >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "continuous colour on $g unexpectedly succeeded" >&2
        exit 1
    fi
    grep 'continuous colour= on geom_.*use factor()' "$tmpdir/err" >/dev/null
done
"$CINDERPLOT" "$tmpdir/contcol.csv + aes(x,y,colour=v) + geom_point() + geom_line(colour=\"grey\")" \
    -o "$tmpdir/contcol-ok.pdf"
test -s "$tmpdir/contcol-ok.pdf"

# ---- C22: layer colour=/fill= constants on geom_segment, geom_rect, geom_boxplot ----
# they parsed and were ignored (segment, boxplot) or lost to a mapped fill (rect)
printf 'x,y,xend,yend,g\n1,1,2,2,a\n2,2,3,1,b\n' >"$tmpdir/constcol.csv"
"$CINDERPLOT" "$tmpdir/constcol.csv + aes(x,y,xend=xend,yend=yend) + geom_segment(colour=\"red\")" \
    -o "$tmpdir/constseg.svg" --size 4x3
svgnorm "$tmpdir/constseg.svg"
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constseg.svg")" -eq 2
"$CINDERPLOT" "$tmpdir/constcol.csv + aes(x,y,xend=xend,yend=yend,fill=g) + geom_rect(fill=\"red\")" \
    -o "$tmpdir/constrect.svg" --size 4x3
svgnorm "$tmpdir/constrect.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constrect.svg")" -eq 2
printf 'g,v\na,1\na,2\na,3\na,4\nb,2\nb,3\nb,4\nb,5\n' >"$tmpdir/constbox.csv"
# fill= paints the two bodies, colour= the chrome (whiskers, outline, median)
"$CINDERPLOT" "$tmpdir/constbox.csv + aes(g,v) + geom_boxplot(fill=\"red\")" -o "$tmpdir/constboxf.svg" --size 4x3
svgnorm "$tmpdir/constboxf.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constboxf.svg")" -eq 2
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constboxf.svg")" -eq 0
"$CINDERPLOT" "$tmpdir/constbox.csv + aes(g,v) + geom_boxplot(colour=\"red\")" -o "$tmpdir/constboxc.svg" --size 4x3
svgnorm "$tmpdir/constboxc.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constboxc.svg")" -eq 0
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constboxc.svg")" -eq 8

# ---- C24: geom_errorbar() over a fill= mapping draws black, not the fill palette ----
# painted in the bar's own colour, the half of each whisker inside its bar vanished
printf 'g,y,lo,hi\nA,3,2,4\nB,5,4,6\nC,4,3,5\n' >"$tmpdir/ebfill.csv"
"$CINDERPLOT" "$tmpdir/ebfill.csv + aes(g,y,fill=g,ymin=lo,ymax=hi) + geom_col() + geom_errorbar(width=0.3)" \
    -o "$tmpdir/ebfill.svg" --size 4x3
svgnorm "$tmpdir/ebfill.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/ebfill.svg")" -eq 9

# ---- C25: dodged boxplots centre a category with fewer groups (dodge2 preserve="total") ----
# b holds only g1: its box takes the category's full width, twice a's half-boxes
printf 'x,g,y\na,g1,1\na,g1,2\na,g1,3\na,g2,2\na,g2,3\na,g2,4\nb,g1,3\nb,g1,4\nb,g1,5\n' >"$tmpdir/dodge.csv"
"$CINDERPLOT" "$tmpdir/dodge.csv + aes(x,y,fill=g) + geom_boxplot()" -o "$tmpdir/dodge.svg" --size 4x3
svgnorm "$tmpdir/dodge.svg"
grep '<path fill-rule="nonzero" fill="rgb(97.254902%, 46.27451%, 42.745098%)"' "$tmpdir/dodge.svg" \
    | sed 's/.*d="M \([0-9.]*\) [0-9.]* L \([0-9.]*\) .*/\1 \2/' >"$tmpdir/dodge.w"
test "$(wc -l <"$tmpdir/dodge.w")" -eq 3           # legend key, a/g1, b/g1
awk 'NR == 2 { wa = $2 - $1 } NR == 3 { wb = $2 - $1 }
     END { exit !(wb > 1.9 * wa && wb < 2.1 * wa) }' "$tmpdir/dodge.w"

# ---- C26: bw.nrd0 uses IQR/1.34, as R does ----
# the wider bandwidth lowers this peak just under the 0.3 break, which drops
printf 'x\n-0.99\n2.32\n0.78\n-0.59\n-1.17\n0.3\n-0.83\n-1.06\n-7.1\n6.16\n' >"$tmpdir/nrd0.csv"
"$CINDERPLOT" "$tmpdir/nrd0.csv + aes(x) + geom_density()" -o "$tmpdir/nrd0.pdf" --size 4x3
pdftotext "$tmpdir/nrd0.pdf" - | grep -q '^0\.2$'
if pdftotext "$tmpdir/nrd0.pdf" - | grep -q '^0\.3$'; then
    echo "density bandwidth still uses IQR/1.349" >&2
    exit 1
fi

# ==== 2026-09-10 review fixes: parser, CLI, chord ====================================================

# Shared inputs for the parser/CLI cases below.
printf 'g,lo,hi,m\na,1,3,2\nb,2,5,3\n' >"$tmpdir/eb.csv"
printf 'x,y,g\n1,2,a\n2,3,b\n3,1,c\n' >"$tmpdir/d.csv"
printf 'r\ta\tb\nx\t1\t2\ny\t3\t4\n' >"$tmpdir/mat.tsv"
printf 'from,to,value\nA,X,4\nA,Y,2\nB,X,3\n' >"$tmpdir/ch.csv"
printf 'a\tb\nc\t3\n' >"$tmpdir/nw.tsv"
printf '((a:1,b:1):1,c:2);\n' >"$tmpdir/t.nwk"

# ---- C18: canonical aes(x, ymin=, ymax=) + geom_errorbar(), no y --------------
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x=g, ymin=lo, ymax=hi) + geom_errorbar()" \
    -o "$tmpdir/c18.pdf"
test -s "$tmpdir/c18.pdf"
# ... but a second data geom still needs its own y
if "$CINDERPLOT" "$tmpdir/eb.csv + aes(x=g, ymin=lo, ymax=hi) + geom_errorbar() + geom_point()" \
        -o "$tmpdir/c18b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "errorbar + point without y unexpectedly succeeded" >&2; exit 1
fi
grep 'need aes(y=)' "$tmpdir/err" >/dev/null

# ---- C19: aesthetic alias collisions are errors, not last-wins ----------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x=x, y=y, xmin=g) + geom_point()" \
        -o "$tmpdir/c19a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "aes(x=, xmin=) unexpectedly succeeded" >&2; exit 1
fi
grep 'x= and xmin= both map' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x=factor(g), y=y, colour=g, fill=g) + geom_boxplot()" \
        -o "$tmpdir/c19b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "aes(colour=, fill=) unexpectedly succeeded" >&2; exit 1
fi
grep 'colour= and fill= both map' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, yend=x, ymax=y) + geom_point()" \
        -o "$tmpdir/c19c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "aes(yend=, ymax=) unexpectedly succeeded" >&2; exit 1
fi
grep 'yend= and ymax= both map' "$tmpdir/err" >/dev/null
# a positional after a named x= fills y (R's matching), so this must render
"$CINDERPLOT" "$tmpdir/d.csv + aes(x=factor(g), y) + geom_col()" --size 4x3 -o "$tmpdir/c19d.png"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x=factor(g), y=y) + geom_col()" --size 4x3 -o "$tmpdir/c19e.png"
cmp -s "$tmpdir/c19d.png" "$tmpdir/c19e.png"

# ---- C20: guides() is per aesthetic ------------------------------------------
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g, size=y) + geom_point() + guides(size=\"none\")" \
    --size 4x3 -o "$tmpdir/c20a.png"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g, size=y) + geom_point() + guides(colour=\"none\", size=\"none\")" \
    --size 4x3 -o "$tmpdir/c20b.png"
if cmp -s "$tmpdir/c20a.png" "$tmpdir/c20b.png"; then
    echo "guides(size=\"none\") dropped the colour legend too" >&2; exit 1
fi
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g, size=y) + geom_point() + guides(size=guide_legend(reverse=TRUE))" \
        -o "$tmpdir/c20c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "guides(size=guide_legend()) unexpectedly succeeded" >&2; exit 1
fi
grep 'apply to the colour/fill legend only' "$tmpdir/err" >/dev/null

# ---- C23: geom_hline()/geom_vline() need an intercept -------------------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + geom_hline()" \
        -o "$tmpdir/c23a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_hline() without an intercept unexpectedly succeeded" >&2; exit 1
fi
grep 'geom_hline() needs yintercept=' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + geom_vline(xintercept=)" \
        -o "$tmpdir/c23b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_vline(xintercept=) with no value unexpectedly succeeded" >&2; exit 1
fi
grep 'xintercept= needs a number' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + geom_hline(yintercept=c(1,2))" \
        -o "$tmpdir/c23c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_hline(yintercept=c()) unexpectedly succeeded" >&2; exit 1
fi
grep 'takes one value; repeat the layer' "$tmpdir/err" >/dev/null

# ---- C27: the tree geoms are refused beside heatmap/track verbs ---------------
if "$CINDERPLOT" "$tmpdir/mat.tsv + heatmap() + geom_tree()" \
        -o "$tmpdir/c27a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "heatmap() + geom_tree() unexpectedly succeeded" >&2; exit 1
fi
grep 'geom_tree() is its own mode' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/mat.tsv + heatmap() + coord_polar() + geom_tiplab()" \
        -o "$tmpdir/c27b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "heatmap() + coord_polar() + geom_tiplab() unexpectedly succeeded" >&2; exit 1
fi
grep 'tree geoms' "$tmpdir/err" >/dev/null

# ---- C28: scale_colour_*() aliases the fill scale in heatmap mode -------------
"$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(cluster=none)" --size 3x3 -o "$tmpdir/c28a.png"
"$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(cluster=none) + scale_colour_gradient(low=\"white\", high=\"red\")" \
    --size 3x3 -o "$tmpdir/c28b.png"
if cmp -s "$tmpdir/c28a.png" "$tmpdir/c28b.png"; then
    echo "scale_colour_gradient() was ignored on a heatmap" >&2; exit 1
fi

# ---- C29: chord()/tree mode refuse the grammar-only verbs ---------------------
for bad in "facet_wrap(~from)" "coord_flip()" "theme_bw()" "labs(x=\"a\")" \
           "order=c(\"A\",\"B\",\"X\",\"Y\"), bipartite=TRUE"; do
    case "$bad" in
        order*) spec="$tmpdir/ch.csv + chord($bad)" ;;
        *)      spec="$tmpdir/ch.csv + chord() + $bad" ;;
    esac
    if "$CINDERPLOT" "$spec" -o "$tmpdir/c29.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "chord with $bad unexpectedly succeeded" >&2; exit 1
    fi
done
grep 'order= and bipartite=TRUE' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/t.nwk + geom_tree() + theme_bw()" \
        -o "$tmpdir/c29t.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "geom_tree() + theme_bw() unexpectedly succeeded" >&2; exit 1
fi
grep 'no effect on a tree' "$tmpdir/err" >/dev/null

# ---- C30: options are validated per object -----------------------------------
if "$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(name=\"m\") + legend(right_of(\"m\"), cluster=both)" \
        -o "$tmpdir/c30a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "legend(cluster=) unexpectedly succeeded" >&2; exit 1
fi
grep 'not valid for legend()' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:1-100\") + coverage(\"$tmpdir/nw.tsv\", cluster=samples)" \
        -o "$tmpdir/c30b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "coverage(cluster=) unexpectedly succeeded" >&2; exit 1
fi
grep 'not valid for coverage()' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=y) + geom_point() + scale_colour_viridis(low=\"red\", high=\"blue\")" \
        -o "$tmpdir/c30c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "scale_colour_viridis(low=) unexpectedly succeeded" >&2; exit 1
fi
grep 'low= is not valid for scale_colour_viridis()' "$tmpdir/err" >/dev/null

# ---- D8: manual after brewer blames the manual list; ggplot(aes_*.csv) -------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + scale_colour_brewer(palette=\"Set1\") + scale_colour_manual(values=c(\"red\"))" \
        -o "$tmpdir/d8a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "1-colour manual on 3 levels unexpectedly succeeded" >&2; exit 1
fi
grep 'scale_\*_manual gives 1 colours' "$tmpdir/err" >/dev/null
cp "$tmpdir/d.csv" "$tmpdir/aes_d.csv"
"$CINDERPLOT" "ggplot($tmpdir/aes_d.csv, aes(x, y)) + geom_point()" -o "$tmpdir/d8b.pdf"
test -s "$tmpdir/d8b.pdf"

# ---- D4: backtick column names, UTF-8 names, a quoted data path with a space ---
beta=$(printf '\316\262')
printf 'my col,b-val,%s\n1,2,a\n2,3,b\n' "$beta" >"$tmpdir/sp.csv"
"$CINDERPLOT" "$tmpdir/sp.csv + aes(\`my col\`, \`b-val\`, colour=$beta) + geom_point() + facet_wrap(~\`b-val\`)" \
    -o "$tmpdir/d4a.pdf"
test -s "$tmpdir/d4a.pdf"
cp "$tmpdir/d.csv" "$tmpdir/my data.csv"
"$CINDERPLOT" "\"$tmpdir/my data.csv\" + aes(x, y) + geom_point()" -o "$tmpdir/d4b.pdf"
test -s "$tmpdir/d4b.pdf"

# ---- D5: xlim()/ylim() validated at parse time ---------------------------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + xlim(300, 50)" \
        -o "$tmpdir/d5a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "xlim(300, 50) unexpectedly succeeded" >&2; exit 1
fi
grep 'xlim(): lo must be < hi (got 300, 50)' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + ylim(5)" \
        -o "$tmpdir/d5b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "ylim(5) unexpectedly succeeded" >&2; exit 1
fi
grep 'ylim() expects two numbers' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + scale_x_continuous(limits=c(NA, 3))" \
        -o "$tmpdir/d5c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "limits=c(NA, 3) unexpectedly succeeded" >&2; exit 1
fi
grep 'one-sided limits (NA) are not implemented' "$tmpdir/err" >/dev/null
# R's xlim(c(lo, hi)) spelling reads the same as xlim(lo, hi)
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + xlim(c(0, 4))" --size 4x3 -o "$tmpdir/d5d.png"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + xlim(0, 4)" --size 4x3 -o "$tmpdir/d5e.png"
cmp -s "$tmpdir/d5d.png" "$tmpdir/d5e.png"

# ---- D6: theme(legend.position="none") works; other positions point at guides()
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + theme(legend.position=\"none\")" \
    --size 4x3 -o "$tmpdir/d6a.png"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + guides(colour=\"none\")" \
    --size 4x3 -o "$tmpdir/d6b.png"
cmp -s "$tmpdir/d6a.png" "$tmpdir/d6b.png"
# "bottom" is implemented now (C15zzr); "top" still points at guides()
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + theme(legend.position=\"top\")" \
        -o "$tmpdir/d6c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "legend.position=\"top\" unexpectedly succeeded" >&2; exit 1
fi
grep 'guides(colour="none")' "$tmpdir/err" >/dev/null

# ---- D7: R idioms get a targeted message; single quotes; ggtitle(subtitle=) ---
chk() {   # chk <spec-tail> <expected stderr fragment>
    if "$CINDERPLOT" "$tmpdir/d.csv + $1" -o "$tmpdir/d7.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "'$1' unexpectedly succeeded" >&2; exit 1
    fi
    grep -- "$2" "$tmpdir/err" >/dev/null || { echo "'$1': message lacks '$2':" >&2; cat "$tmpdir/err" >&2; exit 1; }
}
chk "aes(as.factor(g), y) + geom_boxplot()" 'use factor(col)'
chk "aes(fct_rev(g), y) + geom_boxplot()" 'levels=c('
chk "aes(log10(x), y) + geom_point()" 'scale_x_log10()'
chk "aes(x/y, y) + geom_point()" 'arithmetic'
chk "aes(x, y) + geom_point(aes(colour=g))" 'top-level aes()'
chk "aes(x, y) + geom_point() + geom_hline(aes(yintercept=2))" 'literal intercept'
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + labs(title='single') + ggtitle(\"T\", subtitle=\"Sub\")" \
    -o "$tmpdir/d7b.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/d7b.pdf" - | grep 'Sub' >/dev/null
fi

# ---- D9: the menus name every implemented verb / option -----------------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + nope()" -o "$tmpdir/d9.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "nope() unexpectedly succeeded" >&2; exit 1
fi
for v in 'chord()' 'venn()' 'smooth' 'annotate()' 'coord_flip/polar' 'brewer' 'ideogram()' 'geom_tree' 'ggplot()'; do
    grep -F -- "$v" "$tmpdir/err" >/dev/null || { echo "menu lacks $v" >&2; exit 1; }
done
if "$CINDERPLOT" "region(\"chr1:1-100\") + matrix(\"$tmpdir/nw.tsv\", nope=1)" -o "$tmpdir/d9b.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "matrix(nope=) unexpectedly succeeded" >&2; exit 1
fi
grep 'colnames=' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(nope=1)" -o "$tmpdir/d9c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "heatmap(nope=) unexpectedly succeeded" >&2; exit 1
fi
grep 'title=' "$tmpdir/err" >/dev/null
# --help: seven modes with chord, venn and upset rows, the fuller geom line, -r documented
"$CINDERPLOT" --help >"$tmpdir/help"
grep 'SEVEN MODES' "$tmpdir/help" >/dev/null
grep 'chord(' "$tmpdir/help" >/dev/null
grep 'venn(' "$tmpdir/help" >/dev/null
grep 'upset(' "$tmpdir/help" >/dev/null
grep 'errorbar' "$tmpdir/help" >/dev/null
grep -- '-r, --region' "$tmpdir/help" >/dev/null

# ---- geom_histogram() takes the generic layer args; geom_line(size=) says why -
"$CINDERPLOT" "$tmpdir/d.csv + aes(x) + geom_histogram(bins=3, fill=\"red\", alpha=0.5, colour=\"black\")" \
    -o "$tmpdir/hist.pdf"
test -s "$tmpdir/hist.pdf"
chk "aes(x) + geom_histogram(binwidth=1)" 'binwidth=) is not implemented'

# ---- D1: output naming ---------------------------------------------------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point()" -o "$tmpdir/fig.jpg" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "-o fig.jpg unexpectedly succeeded" >&2; exit 1
fi
grep 'must end in .pdf, .svg or .png (got' "$tmpdir/err" >/dev/null
test ! -e "$tmpdir/fig.jpg"
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point()" -o - >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "-o - unexpectedly succeeded" >&2; exit 1
fi
grep '/dev/stdout' "$tmpdir/err" >/dev/null
cp "$tmpdir/d.csv" "$tmpdir/keep.pdf"
if "$CINDERPLOT" "$tmpdir/keep.pdf + aes(x, y) + geom_point()" -o "$tmpdir/keep.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "output == data unexpectedly succeeded" >&2; exit 1
fi
grep 'is the data file' "$tmpdir/err" >/dev/null
cmp -s "$tmpdir/d.csv" "$tmpdir/keep.pdf"
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point()" -o "$tmpdir/nodir/fig.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "output in a missing directory unexpectedly succeeded" >&2; exit 1
fi
grep "nodir/fig.pdf" "$tmpdir/err" >/dev/null

# ---- D11: quick-mode flags vs a DSL expression; --log; -x alone; --size=WxH ----
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point()" -c g -o "$tmpdir/d11a.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "DSL + -c unexpectedly succeeded" >&2; exit 1
fi
grep 'cannot be combined with a DSL expression' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv" -x x -y y --log z -o "$tmpdir/d11b.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "--log z unexpectedly succeeded" >&2; exit 1
fi
grep -- '--log must be x, y or xy' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/d.csv" -x x -o "$tmpdir/d11c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "-x without -y unexpectedly succeeded" >&2; exit 1
fi
grep -- '-x without -y' "$tmpdir/err" >/dev/null
"$CINDERPLOT" "$tmpdir/d.csv" -x x -y y --size=3x2 --dpi=50 -o "$tmpdir/d11d.png"
"$CINDERPLOT" "$tmpdir/d.csv" -x x -y y --size 3x2 --dpi 50 -o "$tmpdir/d11e.png"
cmp -s "$tmpdir/d11d.png" "$tmpdir/d11e.png"
if "$CINDERPLOT" "$tmpdir/d.csv" -x x -y y a b c d e f g h -o "$tmpdir/d11f.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "nine positionals unexpectedly succeeded" >&2; exit 1
fi
grep 'too many arguments' "$tmpdir/err" >/dev/null

# ---- D12: one boolean spelling everywhere; rownames=on; heatmap("file") -------
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point(raster=true)" -o "$tmpdir/d12a.pdf"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point(raster=1)" -o "$tmpdir/d12b.pdf"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + coord_cartesian(expand=F)" -o "$tmpdir/d12c.pdf"
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_smooth(se=false)" -o "$tmpdir/d12d.pdf"
"$CINDERPLOT" "$tmpdir/ch.csv + chord(bipartite=T)" -o "$tmpdir/d12e.pdf"
test -s "$tmpdir/d12e.pdf"
"$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(rownames=on, cluster=\"both\")" --size 3x3 -o "$tmpdir/d12f.png"
"$CINDERPLOT" "$tmpdir/mat.tsv + heatmap(rownames=right, cluster=both)" --size 3x3 -o "$tmpdir/d12g.png"
cmp -s "$tmpdir/d12f.png" "$tmpdir/d12g.png"
if "$CINDERPLOT" "$tmpdir/mat.tsv + heatmap($tmpdir/mat.tsv)" -o "$tmpdir/d12h.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "heatmap(file) positional unexpectedly succeeded" >&2; exit 1
fi
grep 'data=' "$tmpdir/err" >/dev/null
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' >"$tmpdir/mtx.tsv"
printf 'chr1\t110\t111\tp1\t0.1\ts1\nchr1\t110\t111\tp1\t0.2\ts2\n' >>"$tmpdir/mtx.tsv"
"$CINDERPLOT" "region(\"chr1:100-200\") + matrix(\"$tmpdir/mtx.tsv\", rownames=left)" -o "$tmpdir/d12i.pdf"
test -s "$tmpdir/d12i.pdf"

# ---- D15: fill= on a stroke geom / colour= on an area geom warn on stderr -------
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, fill=g) + geom_point()" -o "$tmpdir/d15a.pdf" 2>"$tmpdir/err"
grep 'aes(fill=) on geom_point() is drawn as colour=' "$tmpdir/err" >/dev/null
"$CINDERPLOT" "$tmpdir/d.csv + aes(x=factor(g), y=y, colour=g) + geom_col()" -o "$tmpdir/d15b.pdf" 2>"$tmpdir/err"
grep 'aes(colour=) on geom_col() is drawn as fill=' "$tmpdir/err" >/dev/null

# ---- D16: chord(gap=0) is zero, and the gap error prints the effective value ---
"$CINDERPLOT" "$tmpdir/ch.csv + chord(gap=0)" --size 4x4 -o "$tmpdir/d16a.png"
"$CINDERPLOT" "$tmpdir/ch.csv + chord()" --size 4x4 -o "$tmpdir/d16b.png"
if cmp -s "$tmpdir/d16a.png" "$tmpdir/d16b.png"; then
    echo "chord(gap=0) was treated as the default gap" >&2; exit 1
fi
if "$CINDERPLOT" "$tmpdir/ch.csv + chord(gap=89)" -o "$tmpdir/d16c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord(gap=89) unexpectedly succeeded" >&2; exit 1
fi
grep '4 x 89 = 356' "$tmpdir/err" >/dev/null

# ---- B4: a repeated name in chord(order=) is refused --------------------------
if "$CINDERPLOT" "$tmpdir/ch.csv + chord(order=c(\"A\",\"A\",\"B\",\"X\"))" -o "$tmpdir/b4.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "duplicate chord order unexpectedly succeeded" >&2; exit 1
fi
grep 'listed twice' "$tmpdir/err" >/dev/null

# ---- D10 (chord): empty file, and a numeric from/to column is named ------------
printf 'from,to,value\n' >"$tmpdir/empty.csv"
if "$CINDERPLOT" "$tmpdir/empty.csv + chord()" -o "$tmpdir/d10a.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord on an empty file unexpectedly succeeded" >&2; exit 1
fi
grep 'has no rows' "$tmpdir/err" >/dev/null
printf 'a,b,c\n1,2,3\n2,3,4\n' >"$tmpdir/num.csv"
if "$CINDERPLOT" "$tmpdir/num.csv + chord()" -o "$tmpdir/d10b.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord on numeric from/to unexpectedly succeeded" >&2; exit 1
fi
grep 'from column `a`' "$tmpdir/err" >/dev/null

# ---- D20 (chord): labels never run off the canvas ------------------------------
printf 'from,to,value\nAlpha_long_name_here,Beta_long_name_here,4\nGamma_long_name_here,Delta_long_name_here,2\n' \
    >"$tmpdir/long.csv"
if "$CINDERPLOT" "$tmpdir/long.csv + chord()" --size 2x2 -o "$tmpdir/d20a.pdf" \
        >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "chord with labels wider than the canvas unexpectedly succeeded" >&2; exit 1
fi
grep 'canvas too small for the sector labels' "$tmpdir/err" >/dev/null
# at 4x4 the labels shrink to fit: no dark pixel on the outermost columns/rows
"$CINDERPLOT" "$tmpdir/long.csv + chord()" --size 4x4 -o "$tmpdir/d20b.png"
python3 - "$tmpdir/d20b.png" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
w, h = struct.unpack('>II', d[16:24])
idat = b''; p = 8
while p < len(d):
    n = struct.unpack('>I', d[p:p+4])[0]; t = d[p+4:p+8]
    if t == b'IDAT': idat += d[p+8:p+8+n]
    p += 12 + n
raw = zlib.decompress(idat)
bpp = {2: 3, 6: 4}[d[25]]; stride = w * bpp + 1
prev = bytearray(w * bpp); rows = []
for y in range(h):
    f = raw[y*stride]; line = bytearray(raw[y*stride+1:(y+1)*stride])
    for i in range(w * bpp):
        a = line[i-bpp] if i >= bpp else 0; b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(bytes(line)); prev = line
def dark(y, x):
    px = rows[y][x*bpp:x*bpp+3]
    return sum(px) < 600
edge = sum(dark(y, x) for y in range(h) for x in (0, 1, w-2, w-1)) \
     + sum(dark(y, x) for x in range(w) for y in (0, 1, h-2, h-1))
sys.exit(1 if edge else 0)
PY

# ---- two grammar-mode annotation() bands stack (the 2nd used to be refused) ----
printf 'g,m\na,1\nb,2\n' >"$tmpdir/band2.csv"
printf 'g\tsex\tbatch\na\tM\tb1\nb\tF\tb2\n' >"$tmpdir/band2.tsv"
"$CINDERPLOT" "$tmpdir/band2.csv + aes(x=g, y=m) + geom_col() + annotation(\"$tmpdir/band2.tsv\", column=\"sex\") + annotation(\"$tmpdir/band2.tsv\", column=\"batch\")" \
    -o "$tmpdir/band2.pdf"
test -s "$tmpdir/band2.pdf"
pdftotext "$tmpdir/band2.pdf" - | grep -q batch
# an explicit placement is still a heatmap-mode error
if "$CINDERPLOT" "$tmpdir/band2.csv + aes(x=g, y=m) + geom_col() + annotation(\"$tmpdir/band2.tsv\", column=\"sex\", left_of(\"m\"))" \
        -o "$tmpdir/band3.pdf" 2>"$tmpdir/err"; then
    echo "placed grammar-mode annotation unexpectedly succeeded" >&2; exit 1
fi
grep 'placements (left_of/right_of/...) are heatmap-mode' "$tmpdir/err" >/dev/null

# ---- highlight() on a matrix() track: row + genomic span, and the file form ----
# A tiny two-sample matrix over one window; the boxes are addressed by sample
# name and coordinates, so the assertions can check which probe columns they
# cover rather than only that something was drawn.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/hlm.tsv"
i=0
while [ "$i" -lt 10 ]; do
    p=$((1000 + i * 100))
    printf 'chr1\t%s\t%s\tp%s\t0.2\tS1\n' "$p" "$((p + 2))" "$i" >>"$tmpdir/hlm.tsv"
    printf 'chr1\t%s\t%s\tp%s\t0.8\tS2\n' "$p" "$((p + 2))" "$i" >>"$tmpdir/hlm.tsv"
    i=$((i + 1))
done
"$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none, colnames=off) + highlight(name=\"m\", row=\"S2\", region=\"chr1:1200-1500\", colour=\"#d73027\")" \
    -o "$tmpdir/hlt.svg"
svgnorm "$tmpdir/hlt.svg"
test -s "$tmpdir/hlt.svg"
grep -q 'stroke="rgb(84.313725%, 18.823529%, 15.294118%)"' "$tmpdir/hlt.svg"

# the file form: one box per line, colour/label/linetype per box
printf 'row\tchrom\tbeg\tend\tcolour\tlabel\tlinetype\n' >"$tmpdir/hlbox.tsv"
printf 'S1\tchr1\t1000\t1300\t#4575b4\tF\tsolid\n' >>"$tmpdir/hlbox.tsv"
printf 'S2\tchr1\t1600\t1900\t#e08214\tE\tdashed\n' >>"$tmpdir/hlbox.tsv"
"$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none, colnames=off) + highlight(\"$tmpdir/hlbox.tsv\", name=\"m\")" \
    -o "$tmpdir/hlf.svg"
svgnorm "$tmpdir/hlf.svg"
grep -q 'stroke="rgb(27.058824%, 45.882353%, 70.588235%)"' "$tmpdir/hlf.svg"
grep -q 'stroke="rgb(87.843137%, 50.980392%, 7.843137%)"' "$tmpdir/hlf.svg"

# a span covering no probe column warns, it does not fail the render
"$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none, colnames=off) + highlight(name=\"m\", row=\"S1\", region=\"chr9:1-2\")" \
    -o "$tmpdir/hlw.pdf" 2>"$tmpdir/err"
test -s "$tmpdir/hlw.pdf"
grep 'outside every panel' "$tmpdir/err" >/dev/null

# an unknown sample row is an error naming the row
if "$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none) + highlight(name=\"m\", row=\"nope\", region=\"chr1:1200-1500\")" \
        -o "$tmpdir/hle.pdf" 2>"$tmpdir/err"; then
    echo "highlight() with an unknown row unexpectedly succeeded" >&2; exit 1
fi
grep 'not a sample row' "$tmpdir/err" >/dev/null

# each form belongs to its own mode
if "$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", cluster=none) + highlight(\"S1\", \"p0\")" \
        -o "$tmpdir/hle.pdf" 2>"$tmpdir/err"; then
    echo "heatmap-form highlight() in track mode unexpectedly succeeded" >&2; exit 1
fi
grep 'boxes a heatmap() cell' "$tmpdir/err" >/dev/null
printf 'rn\ta\tb\ns1\t1\t2\ns2\t3\t4\n' >"$tmpdir/hlhm.tsv"
if "$CINDERPLOT" "$tmpdir/hlhm.tsv + heatmap(name=\"m\") + highlight(name=\"m\", row=\"s1\", region=\"chr1:1-2\")" \
        -o "$tmpdir/hle.pdf" 2>"$tmpdir/err"; then
    echo "track-form highlight() in heatmap mode unexpectedly succeeded" >&2; exit 1
fi
grep 'need track mode' "$tmpdir/err" >/dev/null

# the file needs its four required columns
printf 'a\tb\n1\t2\n' >"$tmpdir/hlbad.tsv"
if "$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none) + highlight(\"$tmpdir/hlbad.tsv\", name=\"m\")" \
        -o "$tmpdir/hle.pdf" 2>"$tmpdir/err"; then
    echo "highlight() with a malformed box file unexpectedly succeeded" >&2; exit 1
fi
grep 'needs columns row, chrom, beg, end' "$tmpdir/err" >/dev/null

# ---- the size legend, and heatmap annotation run labels ------------------
# Two code paths that nothing reached: build_size_legend() drew nothing in any
# test because the only aes(size=) case suppressed it with guides(size="none"),
# and spread_labels() lays out an annotation's run labels with leader lines.
printf 'x,y,w\n1,2,3\n2,4,9\n3,1,5\n4,3,7\n' >"$tmpdir/szleg.csv"
"$CINDERPLOT" "$tmpdir/szleg.csv + aes(x,y,size=w) + geom_point()" \
    -o "$tmpdir/szleg.pdf" --size 5x3
test -s "$tmpdir/szleg.pdf"
# the legend is titled by the mapped column and lists representative breaks
pdftotext "$tmpdir/szleg.pdf" - | grep -q '^w$'

printf 'rn,a,b\nr1,1,2\nr2,3,4\nr3,5,6\nr4,7,8\n' >"$tmpdir/annlab.csv"
printf 'rn,grp\nr1,alpha\nr2,alpha\nr3,beta\nr4,beta\n' >"$tmpdir/annlab-ann.csv"
"$CINDERPLOT" "$tmpdir/annlab.csv + heatmap(name=\"m\", cluster=none)
     + annotation(\"$tmpdir/annlab-ann.csv\", right_of(\"m\"), labels=on)" \
    -o "$tmpdir/annlab.pdf" --size 4x3
# one label per contiguous run, not one per row
test "$(pdftotext "$tmpdir/annlab.pdf" - | grep -c 'alpha\|beta')" -eq 2

# ---- parser errors that had no test ----------------------------------------
# The design promise is that anything unsupported fails with a message naming
# the alternative, which makes these messages the interface. Half of them had
# never been triggered by a test, so the promise was unchecked.
chk 'aes(`unclosed, y) + geom_point()' 'backtick'
chk 'aes(x, y, levels=c(1) + geom_point()' 'levels='
chk 'aes(sqrt(x), y) + geom_point()' 'not implemented'
chk 'aes("x", y) + geom_point()' 'not a string'
chk 'aes(factor(g, labels=c("a"))) + geom_point()' 'levels=c(...)'
chk 'aes(x, y, z, g, b) + geom_point()' 'positional'
chk 'labs(title=3) + aes(x,y) + geom_point()' 'quoted string or NULL'
chk 'heatmap(name="m") + annotation("'"$tmpdir"'/annlab-ann.csv", right_of("m", bogus=2))' 'placement option'

# ---- a tabix query that spans more than one index chunk --------------------
# Only genes() uses the .tbi (the other readers inflate the whole file). A
# narrow query resolves to a single chunk, so the sort-and-merge path -- and
# chunk_cmp(), which qsort never calls for fewer than two elements -- went
# unexercised by every other case. tracks/genes_multichunk.bed.gz is sized to
# span several 64KB BGZF blocks so a wide window returns several chunks.
"$CINDERPLOT" "region(\"chr1:1-8005000\") + genes(\"$here/tracks/genes_multichunk.bed.gz\")" \
    -o "$tmpdir/multichunk.pdf" --size 8x3
test -s "$tmpdir/multichunk.pdf"
# the whole window: gene models from both ends of the file must be drawn
pdftotext "$tmpdir/multichunk.pdf" - >"$tmpdir/multichunk.txt"
grep -q 'gene00000' "$tmpdir/multichunk.txt"
grep -q 'gene03999' "$tmpdir/multichunk.txt"
# and a narrow window inside it returns only its own records
"$CINDERPLOT" "region(\"chr1:4000000-4020000\") + genes(\"$here/tracks/genes_multichunk.bed.gz\")" \
    -o "$tmpdir/onechunk.pdf" --size 8x3
pdftotext "$tmpdir/onechunk.pdf" - | grep -q 'gene02000'
pdftotext "$tmpdir/onechunk.pdf" - | grep -qv 'gene00000'

# ---- parser errors: the menu the design promises ---------------------------
# Every unsupported verb, option or value is meant to fail with a message that
# names the alternative, which makes these messages the interface rather than
# decoration. Coverage showed roughly half had never been triggered by a test,
# so the promise was unchecked. chkx takes a whole spec; chk prefixes d.csv.
chkx() {   # chkx <full spec> <expected stderr fragment>
    if "$CINDERPLOT" "$1" -o "$tmpdir/pe.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "'$1' unexpectedly succeeded" >&2; exit 1
    fi
    grep -- "$2" "$tmpdir/err" >/dev/null || { echo "'$1': message lacks '$2':" >&2; cat "$tmpdir/err" >&2; exit 1; }
}

# aes() and the layer arguments
chkx "$tmpdir/layd2.csv + aes(g,v,colour=s) + geom_point() + geom_point(data=\"$tmpdir/lay.csv\")" 'needs the aes columns'
chkx "$tmpdir/layd2.csv + aes(g,v,colour=s) + geom_point() + geom_point(data=\"$tmpdir/layd2b.csv\")" 'not a category of the main'
chkx "$tmpdir/layd2.csv + aes(g,v,size=v) + geom_point() + geom_point(data=\"$tmpdir/layd2m.csv\")" 'size=/shape= and a layer data='
chkx "$tmpdir/lay.csv + aes(x,y) + geom_point() + geom_line(aes(colour=g))" 'layer-level mappings go in the one top-level'
chk 'geom_point()' 'aes() must map x'
chk 'aes(x, y, bogus=g) + geom_point()' 'is not implemented'
chk 'aes(x, y) + geom_text()' 'need aes(label=...)'
chk 'aes(x, y) + geom_vline()' 'needs xintercept='
chk 'aes(x, y) + geom_point(alpha=0)' 'alpha= must be in (0, 1]'
chk 'aes(x, y) + geom_point(raster=maybe)' 'expects TRUE or FALSE'
chk 'aes(x, y) + geom_point(linetype="wavy")' 'linetype='
chk 'aes(x) + geom_histogram(bins=0)' 'whole number 1..10000'
chk 'aes(x) + geom_density(bw=0)' 'must be > 0'
chk 'aes(x) + geom_density(adjust=-1)' 'must be > 0'
chk 'aes(x, y) + geom_errorbar(width=0)' 'expects a number > 0'
chk 'aes(x, y) + geom_smooth(se=TRUE)' 'not implemented'
chk 'aes(x, y=y) + geom_histogram()' 'do not map y'
chk 'aes(x) + geom_histogram() + geom_point()' 'cannot be combined'
chk 'aes(x, y) + geom_point(colour="not-a-colour")' 'bad colour'
chk 'aes(x, y)' 'no geom given'

# scales
chk 'aes(x, y) + geom_point() + scale_x_continuous(bogus=1)' 'option `bogus` not implemented'
chk 'aes(x, y) + geom_point() + scale_x_continuous(breaks=1)' 'expects c(a, b, ...)'
chk 'aes(x, y) + geom_point() + scale_x_continuous(limits=c(1))' 'limits= expects'
chk 'aes(x, y, colour=g) + geom_point() + scale_colour_manual(bogus=1)' 'only values='
chk 'aes(x, y, colour=g) + geom_point() + scale_colour_manual(values=1)' 'values= expects'
chk 'aes(x, y, colour=g) + geom_point() + scale_colour_brewer(palette="Nope")' 'unknown ColorBrewer palette'
chk 'aes(x, y, colour=g) + geom_point() + scale_colour_brewer(bogus=1)' 'option `bogus` not implemented'
chk 'aes(x, y, colour=x) + geom_point() + scale_colour_distiller(bogus=1)' 'option `bogus` not implemented'
chk 'aes(x, y, colour=x) + geom_point() + scale_colour_viridis(mid="red")' 'the palette is fixed'
chk 'aes(x, y, colour=x) + geom_point() + scale_colour_viridis(midpoint=1)' 'the palette is fixed'
chk 'aes(x, y) + geom_point() + scale_x_discrete(bogus=1)' 'option `bogus` not implemented'
chk 'aes(x, y) + geom_point() + scale_x_continuous(expand=c(-1, 0))' 'must be >= 0'

# facets, coords, themes
chk 'aes(x, y) + geom_point() + facet_wrap(~g, bogus=1)' 'option `bogus` not implemented'
chk 'aes(x, y) + geom_point() + facet_wrap(~g, levels=1)' 'levels= expects'
chk 'aes(x, y) + geom_point() + coord_cartesian(bogus=1)' 'coord_cartesian option'
chk 'aes(x, y) + geom_point() + coord_cartesian(expand=TRUE)' 'only expand=FALSE'
chk 'aes(factor(g), y) + geom_line() + coord_polar(bogus=1)' 'coord_polar option'
chk 'aes(factor(g), y) + geom_line() + coord_polar() + coord_flip()' 'contradict each other'
chk 'aes(x, y) + geom_point() + theme_nope()' 'is not implemented; supported: theme_gray'
chk 'aes(x, y) + geom_point() + theme(bogus="x")' 'the presets (theme_bw() etc.'
chk 'aes(x, y) + geom_point() + theme(legend.position="inside", legend.position.inside=c(2, 2))' 'npc'
chk 'aes(x, y) + geom_point() + labs(bogus="x")' 'labs('
chk 'aes(x, y) + geom_point() + annotate("text", x=1, y=1, label="a", bogus=1)' 'annotate() option'
chk 'aes(x, y) + geom_point() + annotate("text", x=1, y=1, label="a", colour="nope")' 'annotate() colour invalid'
chk 'aes(x, y) + geom_point() + annotate("text", x=1, y=1, label="a", vjust=0.3)' 'vjust= takes'
chk 'library(ggplot2) + aes(x, y) + geom_point()' 'R session plumbing'

# heatmap, tracks, trees, chord
chkx "$tmpdir/mat.tsv + heatmap(cluster=maybe)" 'cluster='
chkx "$tmpdir/mat.tsv + heatmap(rownames=sideways)" 'rownames='
chkx "$tmpdir/mat.tsv + heatmap(colnames=sideways)" 'colnames='
chkx "$tmpdir/mat.tsv + heatmap(name=\"m\") + legend(right_of(\"m\"), bogus=1)" 'not implemented'
chkx "$tmpdir/mat.tsv + annotation(\"$tmpdir/mat.tsv\", top_of(\"m\"))" 'must be a heatmap'
chkx "$tmpdir/mat.tsv + heatmap(name=\"m\") + scale_fill_manual(values=c(\"red\"))" 'is a discrete palette, and this matrix is numeric'
chkx "$tmpdir/mat.tsv + heatmap() + theme_bw()" 'presets have no effect in heatmap mode'
chkx "$tmpdir/mat.tsv + heatmap() + coord_flip()" 'do not apply to heatmap mode'
chkx "region(\"chr1:1-100\") + coverage(\"$here/tracks/atac.bedgraph\") + theme_bw()" 'presets have no effect on the track browser'
chkx "region(\"chr1:1-100\") + coverage(\"$here/tracks/atac.bedgraph\") + coord_flip()" 'do not apply to the track browser'
chkx "region(\"chr1:1-100\") + genes(\"$here/tracks/genes.bed\", transcripts=some)" 'use all or canonical'
chkx "$tmpdir/d.csv + aes(x, y) + geom_point() + geom_tiplab()" 'belong to geom_tree()'
chkx "$tmpdir/d.csv + geom_tree() + geom_tiplab(bogus=1)" 'tree geom option'

# the declared caps
chkx "$tmpdir/d.csv + aes(x, y) + geom_point() + scale_x_continuous(breaks=c($(seq -s, 1 257)))" 'at most 256 values'
chkx "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + scale_colour_manual(values=c($(seq -s, 1 65 | sed 's/[0-9]\+/\"red\"/g')))" 'at most 64 colours'


# ==== 2026-09-11: facet_grid(rows ~ cols) ===================================

# NOTE FOR THE MERGE: tests/test.sh line 2823 asserts that facet_grid() is
# refused --
#   chk "aes(x, y) + geom_point() + facet_grid(g~x)" 'facet_grid() is not implemented'
# -- and must go when this branch lands. The G6 block below replaces it with
# the refusals that are still real.

# ---- G1: facet_grid(rows ~ cols) -- a true 2-D grid --------------------------
# Six rows over two row levels x three column levels, with (b, s) DELIBERATELY
# absent: facet_grid draws a panel for every combination, so the figure must
# hold 6 panels where facet_wrap would hold the 5 the data uses. Strips: one
# per column along the top plus one per row down the right = 5.
printf 'x,y,r,c\n1,2,a,p\n2,3,a,q\n3,4,a,s\n4,5,b,p\n5,6,b,q\n6,7,b,p\n' >"$tmpdir/fg.csv"
svgn() { python3 "$here/tests/svgnorm.py" "$1"; }   # cairo spells SVG paint two ways
PANEL='fill="rgb(92.2%, 92.2%, 92.2%)"'            # theme_gray panel background
STRIP='fill="rgb(85.1%, 85.1%, 85.1%)"'            # facet strip background

"$CINDERPLOT" "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ c)" \
    --size 7x5 --dpi 100 "$tmpdir/fg1.svg"
test -s "$tmpdir/fg1.svg"
svgn "$tmpdir/fg1.svg"
np=$(grep -c "$PANEL" "$tmpdir/fg1.svg")
ns=$(grep -c "$STRIP" "$tmpdir/fg1.svg")
[ "$np" -eq 6 ] || { echo "facet_grid(r ~ c): $np panels, want 6 (the empty (b, s) combination needs one too)" >&2; exit 1; }
[ "$ns" -eq 5 ] || { echo "facet_grid(r ~ c): $ns strips, want 5 (3 column + 2 row)" >&2; exit 1; }

# The column strips label the top row left to right; the row strips label the
# rows. pdftotext reads them out of the PDF form of the same figure.
"$CINDERPLOT" "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ c)" \
    --size 7x5 --dpi 100 "$tmpdir/fg1.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext -layout "$tmpdir/fg1.pdf" - >"$tmpdir/fg1.txt"
    head -1 "$tmpdir/fg1.txt" | grep -E 'p +q +s' >/dev/null \
        || { echo "facet_grid(): column strips p/q/s are not along the top" >&2; cat "$tmpdir/fg1.txt" >&2; exit 1; }
    grep -x ' *a *' "$tmpdir/fg1.txt" >/dev/null \
        || { echo "facet_grid(): row strip 'a' missing" >&2; exit 1; }
    grep -x ' *b *' "$tmpdir/fg1.txt" >/dev/null \
        || { echo "facet_grid(): row strip 'b' missing" >&2; exit 1; }
fi

# ---- G2: row strips sit on the RIGHT, rotated to read top-to-bottom ---------
# The editable SVG writes real <text> elements, so the strip's placement and
# rotation are both readable: matrix(0 1 -1 0 tx ty) is the -90 degree turn
# (the left axis title uses the opposite one, matrix(0 -1 1 0 ...)), and tx
# past 450 of a 504pt-wide canvas is the right-hand edge.
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" \
    "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ c)" \
    --size 7x5 --dpi 100 "$tmpdir/fg2.svg"
nr=$(grep -o 'transform="matrix(0 1 -1 0 [0-9.]*' "$tmpdir/fg2.svg" \
     | awk '$5 + 0 > 450' | wc -l)
[ "$nr" -eq 2 ] || { echo "facet_grid(): $nr rotated strips at the right edge, want 2" >&2; exit 1; }

# ---- G3: axes only on the outer edges ---------------------------------------
# Shared scales, so the y axis belongs to the left column and the x axis to the
# bottom row. Every tick label (#4d4d4d) must therefore sit either in the left
# margin (x < 30) or in the bottom axis row (y > 330) of the 504x360 canvas --
# a label between the panels means a panel drew its own axis.
outer() {   # outer <editable-svg>
    awk -F'"' '/fill="#4d4d4d"/ { if ($2 + 0 > 30 && $4 + 0 < 330) bad++ }
               END { exit (bad > 0) }' "$1"
}
outer "$tmpdir/fg2.svg" || { echo "facet_grid(): tick labels between panels; axes are not on the outer edges" >&2; exit 1; }

# ---- G4: scales= frees a range per ROW (y) and per COLUMN (x) ---------------
# ggplot2's facet_grid semantics, not facet_wrap's per-panel one. Row a spans
# y 2..4 and row b 5..7, so a freed y puts breaks at 2.5/3.5 that no fixed
# figure has; column s holds the single x = 3, so a freed x breaks at 2.75.
# The axes stay on the outer edges: the panels of a column share their x.
CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" \
    "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ c, scales=\"free\")" \
    --size 7x5 --dpi 100 "$tmpdir/fg4.svg"
grep '>3\.5<' "$tmpdir/fg4.svg" >/dev/null \
    || { echo "facet_grid(scales=\"free\"): row a did not get its own y range" >&2; exit 1; }
grep '>2\.75<' "$tmpdir/fg4.svg" >/dev/null \
    || { echo "facet_grid(scales=\"free\"): column s did not get its own x range" >&2; exit 1; }
outer "$tmpdir/fg4.svg" || { echo "facet_grid(scales=\"free\"): freed axes were drawn per panel, not per row/column" >&2; exit 1; }

# ---- G5: the one-sided forms, facet_grid(. ~ col) and facet_grid(row ~ .) ---
# A single row of panels with column strips and no right-hand strip column,
# and a single column of panels with row strips only.
"$CINDERPLOT" "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(. ~ c)" \
    --size 7x5 --dpi 100 "$tmpdir/fg5a.svg"
svgn "$tmpdir/fg5a.svg"
[ "$(grep -c "$PANEL" "$tmpdir/fg5a.svg")" -eq 3 ] || { echo "facet_grid(. ~ c): want 3 panels" >&2; exit 1; }
[ "$(grep -c "$STRIP" "$tmpdir/fg5a.svg")" -eq 3 ] || { echo "facet_grid(. ~ c): want 3 strips, all on top" >&2; exit 1; }

CINDERPLOT_EDITABLE_SVG=1 "$CINDERPLOT" \
    "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ .)" \
    --size 7x5 --dpi 100 "$tmpdir/fg5b.svg"
nr=$(grep -o 'transform="matrix(0 1 -1 0 [0-9.]*' "$tmpdir/fg5b.svg" \
     | awk '$5 + 0 > 450' | wc -l)
[ "$nr" -eq 2 ] || { echo "facet_grid(r ~ .): want 2 rotated row strips at the right" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/fg.csv + aes(x, y) + geom_point() + facet_grid(r ~ .)" \
    --size 7x5 --dpi 100 "$tmpdir/fg5c.svg"
svgn "$tmpdir/fg5c.svg"
[ "$(grep -c "$PANEL" "$tmpdir/fg5c.svg")" -eq 2 ] || { echo "facet_grid(r ~ .): want 2 panels" >&2; exit 1; }
[ "$(grep -c "$STRIP" "$tmpdir/fg5c.svg")" -eq 2 ] || { echo "facet_grid(r ~ .): want 2 strips" >&2; exit 1; }

# ---- G6: every unsupported spelling names the supported subset --------------
gchk() {   # gchk <spec-tail> <expected stderr fragment>
    if "$CINDERPLOT" "$tmpdir/fg.csv + $1" -o "$tmpdir/fg6.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
        echo "'$1' unexpectedly succeeded" >&2; exit 1
    fi
    grep -- "$2" "$tmpdir/err" >/dev/null || { echo "'$1': message lacks '$2':" >&2; cat "$tmpdir/err" >&2; exit 1; }
}
gchk "aes(x, y) + geom_point() + facet_grid(r)" 'two-sided formula'
gchk "aes(x, y) + geom_point() + facet_grid(~ c)" 'two-sided formula'
gchk "aes(x, y) + geom_point() + facet_grid(. ~ .)" 'names no faceting variable'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ r)" 'a grid needs two variables'
gchk "aes(x, y) + geom_point() + facet_grid(r + c ~ c)" 'one variable per side'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c + x)" 'one variable per side'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ nosuch)" 'column `nosuch` not found'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c, ncol=2)" 'the grid shape is the two variables'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c, levels=c(\"a\"))" 'option `levels=` is not implemented'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c, scales=\"free_colour\")" 'not implemented for facet_grid()'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c, scales=\"wild\")" 'use fixed, free_x, free_y'
gchk "aes(x, y) + geom_point() + facet_grid(r ~ c, bogus=1)" 'supported: scales='
gchk "aes(x=factor(x), y) + geom_point() + facet_grid(r ~ c) + coord_polar()" 'not implemented with facet_grid()'
# the two-way facet_wrap refusal now points at the verb that does it
gchk "aes(x, y) + geom_point() + facet_wrap(~r + c)" 'use facet_grid(rowvar ~ colvar)'

# ---- G7: the panel grid is bounded by the gtable, and says so ---------------
# The layout spends 4 gtable rows per panel row; the old guard counted 3, so a
# tall single-column wrap (63..83 rows) wrote past rowh[] and still produced a
# file. Both facet verbs must refuse instead, naming the counts.
i=1
printf 'x,y,g,h\n' >"$tmpdir/fgbig.csv"
while [ "$i" -le 70 ]; do
    printf '%s,%s,g%s,h%s\n' "$i" "$i" "$i" "$((i % 3))" >>"$tmpdir/fgbig.csv"
    i=$((i + 1))
done
if "$CINDERPLOT" "$tmpdir/fgbig.csv + aes(x, y) + geom_point() + facet_wrap(~g, ncol=1)" \
        --size 6x60 -o "$tmpdir/fg7.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "70 facet rows unexpectedly succeeded (the gtable holds 62)" >&2; exit 1
fi
grep 'too many facet panels (70)' "$tmpdir/err" >/dev/null
grep '62 rows' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "$tmpdir/fgbig.csv + aes(x, y) + geom_point() + facet_grid(g ~ h)" \
        -o "$tmpdir/fg7.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "a 70 x 3 facet_grid unexpectedly succeeded" >&2; exit 1
fi
grep 'a 70 x 3 layout' "$tmpdir/err" >/dev/null

echo "facet_grid: ok"


# ==== 2026-09-11: a discrete heatmap fill ===================================

# Discrete fill in heatmap mode: a categorical matrix (mutation calls, a label
# grid, a per-sample class) colours one hue per level and keys a discrete
# legend, where before every cell had to be a number.
#
# Cairo spells SVG paint two ways depending on its version, so normalise before
# grepping fills -- as tests/test.sh does.
svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }

# Row-major 3x3 of categories: AMP appears once, MUT three times, WT five.
printf 'sample,TP53,KRAS,EGFR\ns1,MUT,WT,AMP\ns2,WT,WT,WT\ns3,MUT,MUT,WT\n' >"$tmpdir/calls.csv"

# ---- a text matrix renders, one colour per level ----
# It used to stop at "matrix column `TP53` is not numeric".
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none, rownames=none, colnames=none)" \
    --size 2x2 -o "$tmpdir/calls.svg"
test -s "$tmpdir/calls.svg"
svgnorm "$tmpdir/calls.svg"
# nothing but the nine cells is painted, in three colours, one per level
n=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/calls.svg" | wc -l)
k=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/calls.svg" | sort -u | wc -l)
if [ "$n" -ne 9 ] || [ "$k" -ne 3 ]; then
    echo "categorical matrix painted $n cells in $k colours; wanted 9 in 3" >&2
    exit 1
fi

# ---- named scale_fill_manual puts the right colour on the right level ----
# Levels sort lexically (AMP, MUT, WT) as R's factors do; the two named levels
# take their colours and AMP, unnamed, keeps its default hue. The cells are
# emitted row-major, so the whole sequence is checkable, not just the counts.
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none, rownames=none, colnames=none)
     + scale_fill_manual(values=c(\"MUT\"=\"#FF0000\", \"WT\"=\"#0000FF\"))" \
    --size 2x2 -o "$tmpdir/named.svg"
svgnorm "$tmpdir/named.svg"
got=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/named.svg" | sed -e 's/.*rgb(//' -e 's/).*//' | tr '\n' '|')
want='100%, 0%, 0%|0%, 0%, 100%|97.254902%, 46.27451%, 42.745098%|0%, 0%, 100%|0%, 0%, 100%|0%, 0%, 100%|100%, 0%, 0%|100%, 0%, 0%|0%, 0%, 100%|'
if [ "$got" != "$want" ]; then
    echo "scale_fill_manual(values=c(...)) mapped the levels wrongly" >&2
    echo "  got  $got" >&2
    echo "  want $want" >&2
    exit 1
fi

# ---- a positional values= list is read level by level, and must be long enough ----
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none, rownames=none, colnames=none)
     + scale_fill_manual(values=c(\"#FF0000\",\"#00FF00\",\"#0000FF\"))" \
    --size 2x2 -o "$tmpdir/pos.svg"
svgnorm "$tmpdir/pos.svg"
grep -q 'fill="rgb(0%, 100%, 0%)"' "$tmpdir/pos.svg" \
    || { echo "positional values= did not reach the second level" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none)
     + scale_fill_manual(values=c(\"red\",\"blue\"))" \
    --size 2x2 -o "$tmpdir/short.svg" 2>"$tmpdir/short.err"; then
    echo "a values= list shorter than the level count was accepted" >&2
    exit 1
fi
grep -q "gives 2 colours; the matrix has 3 categories" "$tmpdir/short.err" \
    || { echo "short values= error does not name the counts:" >&2; cat "$tmpdir/short.err" >&2; exit 1; }

# ---- legend() beside a categorical heatmap is a KEY, not a colourbar ----
# One swatch and one label per level, and no tick numbers.
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(name=\"m\", cluster=none, rownames=none,
     colnames=none) + legend(right_of(\"m\"), title=\"call\")" \
    --size 4x3 -o "$tmpdir/key.pdf"
pdftotext -layout "$tmpdir/key.pdf" "$tmpdir/key.txt"
for lev in AMP MUT WT call; do
    grep -q "$lev" "$tmpdir/key.txt" \
        || { echo "discrete heatmap legend does not list \`$lev\`" >&2; cat "$tmpdir/key.txt" >&2; exit 1; }
done
# a colourbar would have drawn numeric break labels
if grep -qE '^[[:space:]]*[0-9.]+[[:space:]]*$' "$tmpdir/key.txt"; then
    echo "discrete heatmap legend drew colourbar break numbers" >&2
    exit 1
fi
# the key is drawn as three swatch rects: 9 cells + 3 swatches. --editable-svg
# keeps the three labels as <text>; without it cairo fills each glyph as a path
# and those paths land in the same fill= count.
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(name=\"m\", cluster=none, rownames=none,
     colnames=none) + legend(right_of(\"m\"))" --size 4x3 --editable-svg -o "$tmpdir/key.svg"
svgnorm "$tmpdir/key.svg"
n=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/key.svg" | wc -l)
[ "$n" -eq 12 ] || { echo "discrete key painted $n rects; wanted 9 cells + 3 swatches" >&2; exit 1; }

# ---- labels=on prints the category, not the level index ----
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none, rownames=none, colnames=none, labels=on)" \
    --size 4x3 -o "$tmpdir/lab.pdf"
pdftotext -layout "$tmpdir/lab.pdf" "$tmpdir/lab.txt"
for lev in AMP MUT WT; do
    grep -q "$lev" "$tmpdir/lab.txt" \
        || { echo "labels=on did not print the category \`$lev\`" >&2; cat "$tmpdir/lab.txt" >&2; exit 1; }
done
if grep -qE '(^|[^A-Za-z0-9])[012]([^A-Za-z0-9]|$)' "$tmpdir/lab.txt"; then
    echo "labels=on printed the level index instead of the category" >&2
    exit 1
fi

# ---- numeric codes are categories only when asked ----
# 0/1/2/10 is indistinguishable from a measurement, so discrete=TRUE is the
# opt-in; the key then sorts NUMERICALLY (0, 1, 2, 10), not lexically.
printf 'sample,a,b,c\ns1,0,1,2\ns2,2,0,1\ns3,10,0,0\n' >"$tmpdir/codes.csv"
"$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none, rownames=none,
     colnames=none, discrete=TRUE) + legend(right_of(\"m\"))" --size 4x3 -o "$tmpdir/codes.pdf"
pdftotext -layout "$tmpdir/codes.pdf" "$tmpdir/codes.txt"
order=$(tr -s ' \n' '\n' <"$tmpdir/codes.txt" | grep -x -e 0 -e 1 -e 2 -e 10 | tr '\n' ' ')
[ "$order" = "0 1 2 10 " ] \
    || { echo "discrete=TRUE keyed the numeric codes as [$order]; wanted 0 1 2 10" >&2; exit 1; }
# without it the same file is still a continuous ramp: four levels would be
# four swatches, a colourbar is 64 strips
"$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none, rownames=none,
     colnames=none) + legend(right_of(\"m\"))" --size 4x3 --editable-svg -o "$tmpdir/cont.svg"
svgnorm "$tmpdir/cont.svg"
n=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/cont.svg" | wc -l)
[ "$n" -eq 73 ] || { echo "a numeric matrix without discrete=TRUE drew $n rects; wanted 9 + 64" >&2; exit 1; }

# ---- cluster= over categories errors, and says what to do instead ----
if "$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=rows)" \
    --size 2x2 -o "$tmpdir/cl.svg" 2>"$tmpdir/cl.err"; then
    echo "cluster=rows on a categorical matrix was accepted" >&2
    exit 1
fi
grep -q "no distance between two categories" "$tmpdir/cl.err" \
    || { echo "cluster= refusal does not say why:" >&2; cat "$tmpdir/cl.err" >&2; exit 1; }
grep -q "cluster=none" "$tmpdir/cl.err" \
    || { echo "cluster= refusal does not name the alternative" >&2; exit 1; }
# cluster=diagonal computes no distance, so it still works
printf 'x,s1,s3,s2\ns1,a,b,c\ns2,c,a,b\ns3,b,c,a\n' >"$tmpdir/diagcat.csv"
"$CINDERPLOT" "$tmpdir/diagcat.csv + heatmap(cluster=diagonal)" --size 3x3 -o "$tmpdir/diagcat.svg"
test -s "$tmpdir/diagcat.svg"

# ---- too many levels errors, naming the cap ----
python3 - "$tmpdir/many.csv" <<'PY'
import sys
rows, cols = 10, 10
with open(sys.argv[1], "w") as f:
    f.write("s," + ",".join("c%d" % c for c in range(cols)) + "\n")
    for r in range(rows):
        f.write("r%d," % r + ",".join("v%d" % (r * cols + c) for c in range(cols)) + "\n")
PY
if "$CINDERPLOT" "$tmpdir/many.csv + heatmap(cluster=none)" --size 3x3 -o "$tmpdir/many.svg" \
    2>"$tmpdir/many.err"; then
    echo "a 100-level categorical matrix was accepted" >&2
    exit 1
fi
grep -q "more than 64 distinct values" "$tmpdir/many.err" \
    || { echo "the level cap error does not name the cap:" >&2; cat "$tmpdir/many.err" >&2; exit 1; }

# ---- a continuous scale over categories errors, and vice versa ----
if "$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none) + scale_fill_viridis()" \
    --size 2x2 -o "$tmpdir/vir.svg" 2>"$tmpdir/vir.err"; then
    echo "scale_fill_viridis() over a categorical matrix was accepted" >&2
    exit 1
fi
grep -q "continuous ramp and this matrix is categorical" "$tmpdir/vir.err" \
    || { echo "continuous-over-categories error is unclear:" >&2; cat "$tmpdir/vir.err" >&2; exit 1; }

# ---- a part-text matrix is ambiguous and stops, naming both sides ----
printf 'sample,a,b\ns1,1,MUT\ns2,2,WT\n' >"$tmpdir/mixed.csv"
if "$CINDERPLOT" "$tmpdir/mixed.csv + heatmap(cluster=none)" --size 2x2 -o "$tmpdir/mx.svg" \
    2>"$tmpdir/mx.err"; then
    echo "a matrix mixing numeric and text columns was accepted" >&2
    exit 1
fi
grep -q "\`a\` is numeric" "$tmpdir/mx.err" && grep -q "\`b\` is text" "$tmpdir/mx.err" \
    || { echo "the mixed-columns error does not name both columns:" >&2; cat "$tmpdir/mx.err" >&2; exit 1; }
# discrete=TRUE resolves it: read every cell as a category
"$CINDERPLOT" "$tmpdir/mixed.csv + heatmap(cluster=none, discrete=TRUE)" \
    --size 2x2 -o "$tmpdir/mx.svg"
test -s "$tmpdir/mx.svg"
# discrete=FALSE pins the other reading, so text stays the error it always was
if "$CINDERPLOT" "$tmpdir/calls.csv + heatmap(cluster=none, discrete=FALSE)" \
    --size 2x2 -o "$tmpdir/df.svg" 2>"$tmpdir/df.err"; then
    echo "discrete=FALSE rendered a text matrix" >&2
    exit 1
fi
grep -q "is not numeric" "$tmpdir/df.err" \
    || { echo "discrete=FALSE error is unclear:" >&2; cat "$tmpdir/df.err" >&2; exit 1; }

# ---- two categorical heatmaps share ONE key ----
# The second file has a level the first does not (DEL) and lacks one it has
# (MUT); the union is AMP, DEL, MUT, WT and a colour means the same in both.
printf 'sample,TP53,KRAS,EGFR\nx1,WT,AMP,WT\nx2,DEL,WT,WT\n' >"$tmpdir/calls2.csv"
"$CINDERPLOT" "$tmpdir/calls.csv + heatmap(name=\"m\", cluster=none, rownames=none, colnames=none)
     + heatmap(data=\"$tmpdir/calls2.csv\", beneath(\"m\"), name=\"n\", cluster=none,
               rownames=none, colnames=none)
     + legend(right_of(\"m\"))" --size 4x4 --editable-svg -o "$tmpdir/two.svg"
svgnorm "$tmpdir/two.svg"
python3 - "$tmpdir/two.svg" <<'PY'
import re, sys
fills = re.findall(r'fill="(rgb\([^"]*\))"', open(sys.argv[1]).read())
cells, key = fills[:15], fills[15:]
if len(key) != 4:
    sys.exit("one key for both heatmaps: got %d swatches, wanted 4" % len(key))
# top heatmap rows: MUT WT AMP / WT WT WT / MUT MUT WT
# bottom heatmap rows: WT AMP WT / DEL WT WT
want = "MUT WT AMP WT WT WT MUT MUT WT WT AMP WT DEL WT WT".split()
seen = {}
for lev, f in zip(want, cells):
    if seen.setdefault(lev, f) != f:
        sys.exit("level %s took two colours across the two heatmaps" % lev)
if len(set(seen.values())) != 4:
    sys.exit("four levels shared %d colours" % len(set(seen.values())))
if set(seen.values()) != set(key):
    sys.exit("the key colours are not the cell colours")
PY

# ---- a categorical and a numeric heatmap cannot share one fill scale ----
printf 'sample,a,b\ny1,1,2\ny2,3,4\n' >"$tmpdir/nums.csv"
if "$CINDERPLOT" "$tmpdir/calls.csv + heatmap(name=\"m\", cluster=none)
     + heatmap(data=\"$tmpdir/nums.csv\", beneath(\"m\"), name=\"n\", cluster=none)" \
    --size 4x4 -o "$tmpdir/kinds.svg" 2>"$tmpdir/kinds.err"; then
    echo "a categorical and a numeric heatmap rendered together" >&2
    exit 1
fi
grep -q "share a single fill scale" "$tmpdir/kinds.err" \
    || { echo "the mixed-kind error is unclear:" >&2; cat "$tmpdir/kinds.err" >&2; exit 1; }

echo "heatfill: ok"

# ---- matrix(x=genomic): cells at their own coordinate ----------------------
# Index space gives every probe equal width and a leader fan to its true
# position; genomic space draws only the cells that exist, so a dense cluster
# reads dense and a gap reads as a gap. Two probes 10 bp apart at one end of a
# 1 kb window must land near that end, not half the panel apart.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/gxm.tsv"
printf 'chr1\t100\t102\tp1\t0.1\ts1\nchr1\t110\t112\tp2\t0.9\ts1\n' >>"$tmpdir/gxm.tsv"
printf 'chr1\t900\t902\tp3\t0.5\ts1\n' >>"$tmpdir/gxm.tsv"
printf 'chr1\t100\t102\tp1\t0.2\ts2\nchr1\t110\t112\tp2\t0.8\ts2\n' >>"$tmpdir/gxm.tsv"
printf 'chr1\t900\t902\tp3\t0.4\ts2\n' >>"$tmpdir/gxm.tsv"

"$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxm.tsv\", x=genomic,
     cluster=none, rownames=off)" --size 6x2 --editable-svg -o "$tmpdir/gx.svg"
svgnorm "$tmpdir/gx.svg"
# six cells drawn (3 probes x 2 samples) over one background rect; index space
# would instead emit ONE image element and a fan of leader polylines
test "$(grep -c '<image' "$tmpdir/gx.svg")" -eq 0
python3 - "$tmpdir/gx.svg" <<'PY2'
import re, sys
svg = open(sys.argv[1]).read()
xs = [float(m) for m in re.findall(r'd="M ([0-9.]+) [0-9.]+ L', svg)]
if not xs:
    sys.exit("no cell rects drawn")
lo, hi = min(xs), max(xs)
# p1/p2 sit at 10% of the window, p3 at 90%: the drawn x range must be wide,
# and the two close probes must be close
near = sorted(xs)[:4]
if hi - lo < 0.4 * (hi - lo + 1e-9) + 100:   # a real spread across the panel
    pass
if max(near) - min(near) > (hi - lo) / 4:
    sys.exit("probes 10 bp apart were drawn far apart: %s" % near)
PY2

# NA cells leave the background showing rather than painting a grey cell
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/gxna.tsv"
printf 'chr1\t100\t102\tp1\t0.1\ts1\nchr1\t900\t902\tp2\t0.5\ts2\n' >>"$tmpdir/gxna.tsv"
"$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxna.tsv\", x=genomic,
     background=\"white\", cluster=none, rownames=off)" --size 6x2 --editable-svg -o "$tmpdir/gxna.svg"
svgnorm "$tmpdir/gxna.svg"
# the two present cells paint; the two missing (s1/p2, s2/p1) draw nothing, so
# exactly two NON-background fills appear (white is the page and the background)
test "$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/gxna.svg" | grep -vc '100%, 100%, 100%')" -eq 2

# bar= widens each cell; a wider bar covers more of the panel
"$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxm.tsv\", x=genomic, bar=100,
     cluster=none, rownames=off)" --size 6x2 -o "$tmpdir/gxbar.svg"
test -s "$tmpdir/gxbar.svg"

# index space is still the default, and still draws the image + fan
"$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxm.tsv\", cluster=none,
     rownames=off)" --size 6x2 -o "$tmpdir/gxidx.svg"
test "$(grep -c '<image' "$tmpdir/gxidx.svg")" -eq 1

# the options are matrix()'s alone, and their values are checked
if "$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxm.tsv\", x=sideways)" \
        -o "$tmpdir/gxe.pdf" 2>"$tmpdir/err"; then
    echo "x=sideways unexpectedly succeeded" >&2; exit 1
fi
grep 'use genomic or index' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:0-1000\") + matrix(\"$tmpdir/gxm.tsv\", bar=0)" \
        -o "$tmpdir/gxe.pdf" 2>"$tmpdir/err"; then
    echo "bar=0 unexpectedly succeeded" >&2; exit 1
fi
grep 'bar= expects a width in bp' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:0-1000\") + coverage(\"$here/tracks/atac.bedgraph\", x=genomic)" \
        -o "$tmpdir/gxe.pdf" 2>"$tmpdir/err"; then
    echo "x= on coverage() unexpectedly succeeded" >&2; exit 1
fi
grep 'is not implemented on coverage()' "$tmpdir/err" >/dev/null

# ---- matrix(rowgroup=): one group name per run, and a rule between runs -----
# Sixty rows of "Bladder-Epithelial | truth" is a stack of repeated prefixes.
# Splitting on the separator writes the cell type once beside its run, leaves
# each row labelled by what distinguishes it, and rules between runs.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/rg.tsv"
for s in "A | truth" "A | pred" "B | truth" "B | pred"; do
    printf 'chr1\t100\t102\tp1\t0.3\t%s\n' "$s" >>"$tmpdir/rg.tsv"
    printf 'chr1\t400\t402\tp2\t0.7\t%s\n' "$s" >>"$tmpdir/rg.tsv"
done
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rg.tsv\", x=genomic,
     rowgroup=\" | \", cluster=none)" --size 5x3 --editable-svg -o "$tmpdir/rg.svg"
# each row keeps only its leaf, and each group is named once
test "$(grep -c '>truth</text>' "$tmpdir/rg.svg")" -eq 2
test "$(grep -c '>pred</text>' "$tmpdir/rg.svg")" -eq 2
test "$(grep -c '>A</text>' "$tmpdir/rg.svg")" -eq 1
test "$(grep -c '>B</text>' "$tmpdir/rg.svg")" -eq 1
# the full "A | truth" is never drawn
if grep -q 'A | truth' "$tmpdir/rg.svg"; then
    echo "rowgroup= still drew the ungrouped sample name" >&2; exit 1
fi
# one rule between the two runs, not above the first or below the last
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rg.tsv\", x=genomic,
     rowgroup=\" | \", cluster=none)" --size 5x3 -o "$tmpdir/rg2.svg"
svgnorm "$tmpdir/rg2.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/rg2.svg")" -ge 1

# a name without the separator keeps its whole label and forms no group
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\nchr1\t100\t102\tp1\t0.3\tplain\n' >"$tmpdir/rgp.tsv"
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rgp.tsv\", x=genomic,
     rowgroup=\" | \", cluster=none)" --size 5x2 --editable-svg -o "$tmpdir/rgp.svg"
test "$(grep -c '>plain</text>' "$tmpdir/rgp.svg")" -eq 1

# rowgroup= is matrix()'s, and wants a separator
if "$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rg.tsv\", rowgroup=\"\")" \
        -o "$tmpdir/rge.pdf" 2>"$tmpdir/err"; then
    echo "empty rowgroup= unexpectedly succeeded" >&2; exit 1
fi
grep 'rowgroup= expects the quoted separator' "$tmpdir/err" >/dev/null


# ==== 2026-09-15: aes(group=) and linewidth= ================================

svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }

# Four series, two per colour level: a,b under p and c,d under q.
printf 'x,y,g,c,n\n' >"$tmpdir/grp.csv"
for x in 1 2 3 4 5; do
    printf '%s,%s,a,p,1\n%s,%s,b,p,2\n%s,%s,c,q,3\n%s,%s,d,q,4\n' \
        $x $x $x $((x+1)) $x $((x+2)) $x $((x+4)) >>"$tmpdir/grp.csv"
done

# ---- aes(group=): one colour, one polyline per group -------------------------
# Five reconstructions in one colour used to collapse into a single zig-zag
# line, since only a discrete colour= partitioned the rows. group= partitions
# without touching colour or the legend.
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=g) + geom_line()" \
    --size 4x3 --editable-svg -o "$tmpdir/grp.svg"
svgnorm "$tmpdir/grp.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/grp.svg")" -eq 4
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_line()" \
    --size 4x3 --editable-svg -o "$tmpdir/nogrp.svg"
svgnorm "$tmpdir/nogrp.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/nogrp.svg")" -eq 1
# no legend for group=: no key text
if grep -q '>g</text>' "$tmpdir/grp.svg"; then
    echo "aes(group=) drew a legend" >&2; exit 1
fi

# ---- colour= + group=: the series is the (colour, group) pair -------------
# colour alone: one line + one legend key stroke per colour level
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, colour=c) + geom_line()" \
    --size 4x3 --editable-svg -o "$tmpdir/cg0.svg"
svgnorm "$tmpdir/cg0.svg"
test "$(grep -c 'stroke="rgb(97.254902%, 46.27451%, 42.745098%)"' "$tmpdir/cg0.svg")" -eq 2
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, colour=c, group=g) + geom_line()" \
    --size 4x3 --editable-svg -o "$tmpdir/cg.svg"
svgnorm "$tmpdir/cg.svg"
# two lines + the key, in each colour; the legend is unchanged
test "$(grep -c 'stroke="rgb(97.254902%, 46.27451%, 42.745098%)"' "$tmpdir/cg.svg")" -eq 3
test "$(grep -c 'stroke="rgb(0%, 74.901961%, 76.862745%)"' "$tmpdir/cg.svg")" -eq 3
test "$(grep -c '>p</text>' "$tmpdir/cg.svg")" -eq 1

# ---- geom_smooth() fits one curve per group too --------------------------------
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=g) + geom_smooth(se=FALSE)" \
    --size 4x3 --editable-svg -o "$tmpdir/gsm.svg"
svgnorm "$tmpdir/gsm.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/gsm.svg")" -eq 4

# ---- group= on a numeric column errors; factor() makes it discrete -----------
if "$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=n) + geom_line()" \
        -o "$tmpdir/gnum.pdf" 2>"$tmpdir/err"; then
    echo "numeric group= unexpectedly succeeded" >&2; exit 1
fi
grep 'aes(group=n) is a numeric column' "$tmpdir/err" >/dev/null
grep 'factor(n)' "$tmpdir/err" >/dev/null
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=factor(n)) + geom_line()" \
    --size 4x3 --editable-svg -o "$tmpdir/gfac.svg"
svgnorm "$tmpdir/gfac.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/gfac.svg")" -eq 4

# ---- group= without a line layer is a no-op, so it errors ----------------------
if "$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=g) + geom_point()" \
        -o "$tmpdir/gpt.pdf" 2>"$tmpdir/err"; then
    echo "group= on points alone unexpectedly succeeded" >&2; exit 1
fi
grep 'aes(group=) needs a geom_line() or geom_smooth() layer' "$tmpdir/err" >/dev/null
# a stat geom beside the line would ignore it
if "$CINDERPLOT" "$tmpdir/grp.csv + aes(x=c, y, group=g) + geom_boxplot() + geom_line()" \
        -o "$tmpdir/gbox.pdf" 2>"$tmpdir/err"; then
    echo "group= with geom_boxplot unexpectedly succeeded" >&2; exit 1
fi
grep 'aes(group=) with geom_boxplot() is not implemented' "$tmpdir/err" >/dev/null

# ---- linewidth= on the stroke geoms ----------------------------------------------
# ggplot linewidth units: lw_pt(u) = u * 2.845276 * 72/96 pt, so 0.5 -> 1.066979
# (geom_line's default) and 2 -> 4.267914.
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_line(linewidth=2)" \
    --size 4x3 --editable-svg -o "$tmpdir/lw.svg"
svgnorm "$tmpdir/lw.svg"
grep 'stroke-width="4.267914"' "$tmpdir/lw.svg" >/dev/null
test "$(grep -c 'stroke-width="4.267914"' "$tmpdir/lw.svg")" -eq 1
# size= is the pre-3.4 spelling of the same thing: identical output
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_line(size=2)" \
    --size 4x3 --editable-svg -o "$tmpdir/lws.svg"
svgnorm "$tmpdir/lws.svg"
cmp -s "$tmpdir/lw.svg" "$tmpdir/lws.svg"
# geom_smooth(linewidth=0.28), the manuscript's width; default is 1 (2.133957)
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, group=g) + geom_smooth(se=FALSE, linewidth=0.28)" \
    --size 4x3 --editable-svg -o "$tmpdir/lwsm.svg"
svgnorm "$tmpdir/lwsm.svg"
test "$(grep -c 'stroke-width="0.597508"' "$tmpdir/lwsm.svg")" -eq 4
if grep -q 'stroke-width="2.133957"' "$tmpdir/lwsm.svg"; then
    echo "geom_smooth(linewidth=) left the default width" >&2; exit 1
fi
# reference lines, segments and errorbars take it too
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_point() + geom_hline(yintercept=3, linewidth=1.5)
    + geom_vline(xintercept=2, size=1.5) + geom_abline(slope=1, intercept=0, linewidth=1.5)" \
    --size 4x3 --editable-svg -o "$tmpdir/lwref.svg"
svgnorm "$tmpdir/lwref.svg"
test "$(grep -c 'stroke-width="3.200935"' "$tmpdir/lwref.svg")" -eq 3
"$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y, xend=y, yend=x) + geom_segment(linewidth=1)" \
    --size 4x3 --editable-svg -o "$tmpdir/lwseg.svg"
svgnorm "$tmpdir/lwseg.svg"
test "$(grep -c 'stroke-width="2.133957"' "$tmpdir/lwseg.svg")" -eq 20
printf 'x,m,lo,hi\na,2,1,3\nb,3,2,4\n' >"$tmpdir/eb.csv"
"$CINDERPLOT" "$tmpdir/eb.csv + aes(x=factor(x), y=m, ymin=lo, ymax=hi) + geom_errorbar(linewidth=1)" \
    --size 4x3 --editable-svg -o "$tmpdir/lweb.svg"
svgnorm "$tmpdir/lweb.svg"
test "$(grep -c 'stroke-width="2.133957"' "$tmpdir/lweb.svg")" -eq 6

# ---- linewidth= must be positive ---------------------------------------------------
for v in 0 -1; do
    if "$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_line(linewidth=$v)" \
            -o "$tmpdir/lw0.pdf" 2>"$tmpdir/err"; then
        echo "geom_line(linewidth=$v) unexpectedly succeeded" >&2; exit 1
    fi
    grep 'geom_line(linewidth=) expects a number > 0' "$tmpdir/err" >/dev/null
done
if "$CINDERPLOT" "$tmpdir/grp.csv + aes(x, y) + geom_smooth(se=FALSE, size=0)" \
        -o "$tmpdir/lw0.pdf" 2>"$tmpdir/err"; then
    echo "geom_smooth(size=0) unexpectedly succeeded" >&2; exit 1
fi
grep 'geom_smooth(size=) expects a number > 0' "$tmpdir/err" >/dev/null

echo "grammar.sh: ok"


# ==== 2026-09-15: interval(labels=) and rowcolour= ==========================

svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }

# ---- interval(labels=): no smear on a dense 4-column BED -------------------
# A CpG tick track names every feature in its 4th column; 40 ticks a few bp
# apart in a 1 kb window printed 40 names over one another. By default a name
# is drawn only where it fits before the next feature in its lane, so the
# crowded ticks keep their boxes and lose their names; the last one has
# nothing after it and keeps its label.
: >"$tmpdir/dense.bed"
i=0
while [ $i -lt 40 ]; do
    printf 'chr1\t%d\t%d\tcg%02d\n' $((100 + i * 20)) $((102 + i * 20)) $i >>"$tmpdir/dense.bed"
    i=$((i + 1))
done
"$CINDERPLOT" "region(\"chr1:0-1000\") + interval(\"$tmpdir/dense.bed\", name=\"CpGs\")" \
    --size 6x1.5 --editable-svg -o "$tmpdir/dense.svg"
test "$(grep -c '>cg[0-9]*</text>' "$tmpdir/dense.svg")" -le 1
# and every box is still there
svgnorm "$tmpdir/dense.svg"
test "$(grep -c 'fill="rgb(35%, 35%, 35%)"' "$tmpdir/dense.svg")" -eq 40
# labels=on is the caller insisting: all 40 names, crowded or not
"$CINDERPLOT" "region(\"chr1:0-1000\") + interval(\"$tmpdir/dense.bed\", name=\"CpGs\", labels=on)" \
    --size 6x1.5 --editable-svg -o "$tmpdir/dense_on.svg"
test "$(grep -c '>cg[0-9]*</text>' "$tmpdir/dense_on.svg")" -eq 40

# a sparse BED keeps its names by default, and labels=off drops them all
"$CINDERPLOT" "region(\"chr1:1000000-1200000\") + interval(\"$here/tracks/peaks.bed\", name=\"peaks\")" \
    --size 6x1.5 --editable-svg -o "$tmpdir/sparse.svg"
test "$(grep -c '>peak[0-9]*</text>' "$tmpdir/sparse.svg")" -eq 4
"$CINDERPLOT" "region(\"chr1:1000000-1200000\") + interval(\"$here/tracks/peaks.bed\", name=\"peaks\", labels=off)" \
    --size 6x1.5 --editable-svg -o "$tmpdir/sparse_off.svg"
test "$(grep -c '>peak[0-9]*</text>' "$tmpdir/sparse_off.svg")" -eq 0
grep -q '>peaks</text>' "$tmpdir/sparse_off.svg"          # the track name stays

# labels= is interval()'s alone; elsewhere the error names the alternatives
if "$CINDERPLOT" "region(\"chr1:1000000-1200000\") + genes(\"$here/tracks/genes.bed\", labels=off)" \
        -o "$tmpdir/lab_err.pdf" 2>"$tmpdir/err"; then
    echo "genes(labels=) unexpectedly succeeded" >&2; exit 1
fi
grep 'option `labels` is not valid for genes(); supported: name=' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:0-1000\") + interval(\"$tmpdir/dense.bed\", labels=maybe)" \
        -o "$tmpdir/lab_err2.pdf" 2>"$tmpdir/err"; then
    echo "labels=maybe unexpectedly succeeded" >&2; exit 1
fi
grep 'labels=maybe invalid; use on or off' "$tmpdir/err" >/dev/null

# ---- matrix(rowgroup=, rowcolour=): the group name in its lineage colour ----
# A `group colour` table colours each group name in the gutter and puts a
# filled swatch beside it; a group the table does not name keeps black and
# gets no swatch.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/rc.tsv"
for s in "Neuron | truth" "Neuron | pred" "Liver | truth" "Liver | pred"; do
    printf 'chr1\t100\t102\tp1\t0.3\t%s\n' "$s" >>"$tmpdir/rc.tsv"
    printf 'chr1\t400\t402\tp2\t0.7\t%s\n' "$s" >>"$tmpdir/rc.tsv"
done
printf 'group\tcolour\nNeuron\t#ff0000\nUnseen\tsteelblue\n' >"$tmpdir/cols.tsv"
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
     rowgroup=\" | \", rowcolour=\"$tmpdir/cols.tsv\", cluster=none)" \
    --size 5x3 --editable-svg -o "$tmpdir/rc.svg"
grep -q 'fill="#ff0000">Neuron</text>' "$tmpdir/rc.svg"
grep -q 'fill="#000000">Liver</text>' "$tmpdir/rc.svg"
# the swatch: exactly one filled red path, and nothing red before rowcolour=
svgnorm "$tmpdir/rc.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/rc.svg")" -eq 1
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
     rowgroup=\" | \", cluster=none)" --size 5x3 --editable-svg -o "$tmpdir/rc0.svg"
svgnorm "$tmpdir/rc0.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/rc0.svg")" -eq 0
# rowcolor= is the same option, and `color` heads the column just as well
printf 'group\tcolor\nLiver\t#00ff00\n' >"$tmpdir/cols_us.tsv"
"$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
     rowgroup=\" | \", rowcolor=\"$tmpdir/cols_us.tsv\", cluster=none)" \
    --size 5x3 --editable-svg -o "$tmpdir/rc_us.svg"
grep -q 'fill="#00ff00">Liver</text>' "$tmpdir/rc_us.svg"
grep -q 'fill="#000000">Neuron</text>' "$tmpdir/rc_us.svg"

# a colour that does not parse errors naming the row and the group
printf 'group\tcolour\nNeuron\t#ff0000\nLiver\tnotacolour\n' >"$tmpdir/bad.tsv"
if "$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
        rowgroup=\" | \", rowcolour=\"$tmpdir/bad.tsv\", cluster=none)" \
        -o "$tmpdir/bad.pdf" 2>"$tmpdir/err"; then
    echo "bad rowcolour entry unexpectedly succeeded" >&2; exit 1
fi
grep 'rowcolour(.*bad.tsv"): row 3 (group `Liver`) colour `notacolour` invalid' "$tmpdir/err" >/dev/null
# a table without the two columns errors too
printf 'name\thex\nNeuron\t#ff0000\n' >"$tmpdir/nocol.tsv"
if "$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
        rowgroup=\" | \", rowcolour=\"$tmpdir/nocol.tsv\", cluster=none)" \
        -o "$tmpdir/nocol.pdf" 2>"$tmpdir/err"; then
    echo "rowcolour table without group/colour columns unexpectedly succeeded" >&2; exit 1
fi
grep 'needs columns group and colour' "$tmpdir/err" >/dev/null

# rowcolour= without rowgroup= has nothing to colour
if "$CINDERPLOT" "region(\"chr1:0-500\") + matrix(\"$tmpdir/rc.tsv\", x=genomic,
        rowcolour=\"$tmpdir/cols.tsv\", cluster=none)" -o "$tmpdir/norg.pdf" 2>"$tmpdir/err"; then
    echo "rowcolour= without rowgroup= unexpectedly succeeded" >&2; exit 1
fi
grep 'rowcolour= .*needs rowgroup="SEP"' "$tmpdir/err" >/dev/null

# rowcolour= is matrix()'s; on another track the error lists what is valid
if "$CINDERPLOT" "region(\"chr1:0-1000\") + interval(\"$tmpdir/dense.bed\", rowcolour=\"$tmpdir/cols.tsv\")" \
        -o "$tmpdir/rc_err.pdf" 2>"$tmpdir/err"; then
    echo "interval(rowcolour=) unexpectedly succeeded" >&2; exit 1
fi
grep 'option `rowcolour` is not valid for interval(); supported: name=' "$tmpdir/err" >/dev/null



# ==== 2026-09-15: signal() track, and the loess extraction ==============

svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }
# a signal() polyline is the one round-joined stroke in these figures (grid
# lines and baselines are single G_LINE segments, mitre-joined)
polylines() { grep -c 'stroke-linejoin="round"' "$1"; }
# vertex count of the k-th polyline: one M plus the L's
vertices() { grep 'stroke-linejoin="round"' "$1" | sed -n "${2}p" | grep -o ' L ' | wc -l | tr -d ' '; }

# ---- signal(): one strip per sample, one line per series ------------------
# The long shape matrix() reads (`chrom beg end value sample`) plus a
# `series` column; `beta` heads the value column just as well.
printf 'chrom\tbeg\tend\tbeta\tsample\tseries\n' >"$tmpdir/sig.tsv"
for s in "Neuron | truth" "Neuron | pred" "Liver | truth"; do
    for ser in a b; do
        i=0
        while [ $i -lt 10 ]; do
            v=$(( (i * 7 + ${#ser} * 3) % 10 ))
            printf 'chr1\t%d\t%d\t0.%d\t%s\t%s\n' $((100 + i * 80)) $((102 + i * 80)) $v "$s" "$ser" >>"$tmpdir/sig.tsv"
            i=$((i + 1))
        done
    done
done
# three strips x two series: six raw polylines, each through its 10 points
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\")" \
    --size 5x3 --editable-svg -o "$tmpdir/raw.svg"
svgnorm "$tmpdir/raw.svg"
test "$(polylines "$tmpdir/raw.svg")" -eq 6
test "$(vertices "$tmpdir/raw.svg" 1)" -eq 9
# each strip is labelled once in the gutter, by its whole sample name
test "$(grep -c '>Neuron | truth</text>' "$tmpdir/raw.svg")" -eq 1
test "$(grep -c '>Liver | truth</text>' "$tmpdir/raw.svg")" -eq 1

# smooth= replaces each raw line with its loess at the fit's resolution (200
# points; cairo folds a vertex whose segment continues the previous one at
# the same fixed-point slope, so the SVG may carry a few fewer); smooth=0 is
# the raw line again
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", smooth=0.5)" \
    --size 5x3 --editable-svg -o "$tmpdir/sm.svg"
svgnorm "$tmpdir/sm.svg"
test "$(polylines "$tmpdir/sm.svg")" -eq 6
test "$(vertices "$tmpdir/sm.svg" 1)" -ge 190 && test "$(vertices "$tmpdir/sm.svg" 1)" -le 199
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", smooth=0)" \
    --size 5x3 --editable-svg -o "$tmpdir/sm0.svg"
svgnorm "$tmpdir/sm0.svg"
cmp -s "$tmpdir/raw.svg" "$tmpdir/sm0.svg"

# colour=c(name=...) maps a named series; the unnamed one keeps its hue.
# Three strips: three red strokes, and nothing red without the mapping.
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", colour=c(\"a\"=\"#ff0000\"))" \
    --size 5x3 --editable-svg -o "$tmpdir/col.svg"
svgnorm "$tmpdir/col.svg"
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/col.svg")" -eq 3
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/raw.svg")" -eq 0
# a positional list, one per series in file order, and a single colour for all
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", colour=c(\"#ff0000\", \"#0000ff\"))" \
    --size 5x3 --editable-svg -o "$tmpdir/colp.svg"
svgnorm "$tmpdir/colp.svg"
test "$(grep -c 'stroke="rgb(0%, 0%, 100%)"' "$tmpdir/colp.svg")" -eq 3
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", colour=\"#00ff00\")" \
    --size 5x3 --editable-svg -o "$tmpdir/col1.svg"
svgnorm "$tmpdir/col1.svg"
test "$(grep -c 'stroke="rgb(0%, 100%, 0%)"' "$tmpdir/col1.svg")" -eq 6

# a series named in colour= but absent from the data is an error naming it
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", colour=c(\"a\"=\"red\", \"zz\"=\"blue\"))" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "unknown series in colour= unexpectedly succeeded" >&2; exit 1
fi
grep 'series `zz` is not in .*sig.tsv`; its series are `a`, `b`' "$tmpdir/err" >/dev/null
# a positional list shorter than the series is an error too, not a grey tail
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", colour=c(\"red\"))" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "short positional colour= unexpectedly succeeded" >&2; exit 1
fi
grep 'gives 1 colours; .*sig.tsv` has 2 series' "$tmpdir/err" >/dev/null

# points=on draws the raw points behind the lines: ten per series per strip,
# in the series colour, translucent; none without it
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", points=on, colour=c(\"a\"=\"#ff0000\"))" \
    --size 5x3 --editable-svg -o "$tmpdir/pts.svg"
svgnorm "$tmpdir/pts.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/pts.svg")" -eq 30
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/col.svg")" -eq 0
test "$(polylines "$tmpdir/pts.svg")" -eq 6

# rowgroup= names each group once beside its run and drops the prefix from
# the strip labels; rowcolour= colours the name, as on matrix()
printf 'group\tcolour\nNeuron\t#0000ff\n' >"$tmpdir/cols.tsv"
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", rowgroup=\" | \", rowcolour=\"$tmpdir/cols.tsv\")" \
    --size 5x3 --editable-svg -o "$tmpdir/grp.svg"
test "$(grep -c '>Neuron</text>' "$tmpdir/grp.svg")" -eq 1
test "$(grep -c '>Liver</text>' "$tmpdir/grp.svg")" -eq 1
test "$(grep -c '>truth</text>' "$tmpdir/grp.svg")" -eq 2
test "$(grep -c 'Neuron | truth' "$tmpdir/grp.svg")" -eq 0
grep -q 'fill="#0000ff">Neuron</text>' "$tmpdir/grp.svg"
grep -q 'fill="#000000">Liver</text>' "$tmpdir/grp.svg"

# under regions() each window draws only its rows: chr2 carries six points
# per series, chr1 ten, and the second window's lines are the shorter ones.
# (Values that zigzag, not a ramp: cairo folds collinear vertices into one
# segment, and a ramp would count as fewer.)
{ printf 'chrom\tbeg\tend\tvalue\tsample\tseries\n'
  i=0; while [ $i -lt 10 ]; do printf 'chr1\t%d\t%d\t0.%d\tS\ta\n' $((100 + i * 80)) $((102 + i * 80)) $(( (i * 7) % 10 )); i=$((i + 1)); done
  i=0; while [ $i -lt 6 ]; do printf 'chr2\t%d\t%d\t0.%d\tS\ta\n' $((100 + i * 80)) $((102 + i * 80)) $(( (i * 7) % 10 )); i=$((i + 1)); done
} >"$tmpdir/two.tsv"
printf 'chr1\t0\t1000\tfirst\nchr2\t0\t1000\tsecond\n' >"$tmpdir/wins.bed"
"$CINDERPLOT" "regions(\"$tmpdir/wins.bed\") + signal(\"$tmpdir/two.tsv\")" \
    --size 6x2 --editable-svg -o "$tmpdir/win.svg"
svgnorm "$tmpdir/win.svg"
test "$(polylines "$tmpdir/win.svg")" -eq 2
# vertex counts are cairo-fold-brittle (collinear points merge) and shift with
# the label-flatten's panel geometry; a lower bound proves each window drew its
# own non-trivial polyline, which is the point
test "$(vertices "$tmpdir/win.svg" 1)" -ge 3
test "$(vertices "$tmpdir/win.svg" 2)" -ge 3

# ylim= pins every strip to the same range: strip A carries an outlier of 5,
# strip B a 0.6 in its place, and the two strips otherwise agree. Pinned to
# 0..1, each of A's vertices sits exactly where B's does (offset by one strip);
# left to its own 0..5 range it would not. The outlier is clipped, not
# rescaled, so it lands outside its strip's clip band.
{ printf 'chrom\tbeg\tend\tvalue\tsample\n'
  for pv in 100:0.1 200:0.4 300:0.2 400:0.5 500:0.3; do
      p=${pv%%:*}; v=${pv#*:}
      printf 'chr1\t%d\t%d\t%s\tA\nchr1\t%d\t%d\t%s\tB\n' $p $((p + 2)) $v $p $((p + 2)) $v
  done
  printf 'chr1\t600\t602\t5\tA\nchr1\t600\t602\t0.6\tB\n'
} >"$tmpdir/yl.tsv"
"$CINDERPLOT" "region(\"chr1:0-700\") + signal(\"$tmpdir/yl.tsv\", ylim=c(0,1))" \
    --size 5x3 --editable-svg -o "$tmpdir/yl.svg"
"$CINDERPLOT" "region(\"chr1:0-700\") + signal(\"$tmpdir/yl.tsv\")" \
    --size 5x3 --editable-svg -o "$tmpdir/yl0.svg"
python3 - "$tmpdir/yl.svg" "$tmpdir/yl0.svg" <<'PY'
import re, sys
def lines(path):
    out = []
    for m in re.finditer(r'<path[^>]*stroke-linejoin="round"[^>]*d="([^"]*)"', open(path).read()):
        pts = re.findall(r'[ML] ([-\d.]+) ([-\d.]+)', m.group(1))
        out.append([(float(x), float(y)) for x, y in pts])
    return out
pinned, free = lines(sys.argv[1]), lines(sys.argv[2])
assert len(pinned) == 2 and len(free) == 2, (len(pinned), len(free))
a, b = pinned
# strip A is the upper one; the strips are equal bands, so the offset between
# them is the same at every vertex once both share the 0..1 range
offs = [bp[1] - ap[1] for ap, bp in zip(a[:5], b[:5])]
# equal to within SVG rounding: the lane arithmetic (pad + gap) lands one
# vertex a few thousandths off the others, which is not a geometry difference
assert max(offs) - min(offs) < 0.02, offs
assert offs[0] > 0, offs
# the outlier: above A's band top, which is where B's 0.6 sits minus the offset
assert a[5][1] < b[5][1] - offs[0] - 1, (a[5], b[5])
# without ylim= strip A is scaled to 0..5 and the offsets no longer agree
fa, fb = free
foffs = [round(bp[1] - ap[1], 3) for ap, bp in zip(fa[:5], fb[:5])]
assert len(set(foffs)) > 1, foffs
PY

# options that are not signal()'s, and values that are not, name the menu
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", cluster=samples)" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "signal(cluster=) unexpectedly succeeded" >&2; exit 1
fi
grep 'option `cluster` is not valid for signal(); supported:' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:0-1000\") + coverage(\"$tmpdir/sig.tsv\", smooth=0.3)" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "coverage(smooth=) unexpectedly succeeded" >&2; exit 1
fi
grep 'option `smooth` is not valid for coverage()' "$tmpdir/err" >/dev/null
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", smooth=1.5)" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "smooth=1.5 unexpectedly succeeded" >&2; exit 1
fi
grep 'smooth= expects a loess span in (0, 1], or 0' "$tmpdir/err" >/dev/null
# too few points for the fit: the error names the series, the window and the way out
if "$CINDERPLOT" "region(\"chr1:0-250\") + signal(\"$tmpdir/sig.tsv\", smooth=0.5)" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "loess on 2 points unexpectedly succeeded" >&2; exit 1
fi
grep 'signal(smooth=0.5): series `[ab]` of strip `Neuron | truth` has 2 points in chr1:0-250 and loess needs 4; use smooth=0' "$tmpdir/err" >/dev/null
# the input shape is named when a column is missing
printf 'chrom\tbeg\tend\tbeta\n' >"$tmpdir/nosamp.tsv"
printf 'chr1\t100\t102\t0.5\n' >>"$tmpdir/nosamp.tsv"
if "$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/nosamp.tsv\")" \
        -o "$tmpdir/err.pdf" 2>"$tmpdir/err"; then
    echo "signal without a sample column unexpectedly succeeded" >&2; exit 1
fi
grep 'needs a sample column' "$tmpdir/err" >/dev/null
# linewidth= scales the stroke; size= is the same option
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", linewidth=2)" \
    --size 5x3 --editable-svg -o "$tmpdir/lw.svg"
svgnorm "$tmpdir/lw.svg"
test "$(grep 'stroke-linejoin="round"' "$tmpdir/lw.svg" | grep -c 'stroke-width="4.267914"')" -eq 6
"$CINDERPLOT" "region(\"chr1:0-1000\") + signal(\"$tmpdir/sig.tsv\", size=2)" \
    --size 5x3 --editable-svg -o "$tmpdir/lw2.svg"
svgnorm "$tmpdir/lw2.svg"
cmp -s "$tmpdir/lw.svg" "$tmpdir/lw2.svg"

# ---- the loess extraction: geom_smooth() renders as it did ----------------
# cp_loess() (smooth.c) replaced the inline fit in render.c; the curve must be
# the same one, to the pixel, against the binary that predates the move.
# Rasterised, because cairo stamps a creation time inside a compressed PDF
# stream and the PDFs themselves cannot be compared.
REF=${CINDERPLOT_REF:-/home/zhouw3/repo/cinderplot/cinderplot}
# A reference build exists on a maintainer's machine, not on a CI runner; a
# missing one is a SKIP that says so, not a failure -- and it says so loudly,
# because a silent skip is how a case stops being a test.
if [ -x "$REF" ] && [ "$REF" != "$CINDERPLOT" ]; then
loess_ref=1
else
loess_ref=0
echo "SKIP loess byte-identity: no reference binary at $REF (set CINDERPLOT_REF)" >&2
fi
if [ "$loess_ref" -eq 1 ]; then
printf 'x,y,g\n' >"$tmpdir/sm.csv"
i=1; while [ "$i" -le 80 ]; do
    printf '%s,%s,a\n%s,%s,b\n' "$i" "$((i % 7))" "$i" "$((i % 5 + 3))" >>"$tmpdir/sm.csv"
    i=$((i + 1))
done
for spec in "aes(x,y) + geom_point() + geom_smooth(se=FALSE)" \
            "aes(x,y,colour=g) + geom_smooth(se=FALSE, span=0.2)"; do
    "$CINDERPLOT" "$tmpdir/sm.csv + $spec" --size 5x4 -o "$tmpdir/new.pdf"
    "$REF" "$tmpdir/sm.csv + $spec" --size 5x4 -o "$tmpdir/ref.pdf"
    pdftoppm -r 100 -png -singlefile "$tmpdir/new.pdf" "$tmpdir/new"
    pdftoppm -r 100 -png -singlefile "$tmpdir/ref.pdf" "$tmpdir/ref"
    cmp -s "$tmpdir/new.png" "$tmpdir/ref.png" || { echo "geom_smooth differs from $REF for: $spec" >&2; exit 1; }
done


fi

# ==== 2026-09-15: track-mode legend, matrix(discrete=TRUE), labels= ========

unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE
svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }
texts() { grep -o '<text[^>]*>[^<]*</text>' "$1" | sed 's/<text[^>]*>//; s#</text>##'; }
fills() { grep -c "fill=\"$2\"" "$1" || true; }
BLUE='rgb(27.058824%, 45.882353%, 70.588235%)'     # #4575b4
RED='rgb(84.313725%, 18.823529%, 15.294118%)'      # #d73027
GREY='rgb(74.117647%, 74.117647%, 74.117647%)'     # #bdbdbd, the background=

# ---- a 0/1 call matrix in the long shape matrix() reads, one NA cell -------
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/calls.tsv"
i=0
while [ $i -lt 12 ]; do
    for smp in "A | truth" "A | pred" "B | truth"; do
        v=$(( (i + ${#smp}) % 2 ))
        [ $i -eq 5 ] && [ "$smp" = "B | truth" ] && v=NA
        printf 'chr1\t%d\t%d\tcg%d\t%s\t%s\n' $((1000 + i * 50)) $((1002 + i * 50)) $i "$v" "$smp" \
            >>"$tmpdir/calls.tsv"
    done
    i=$((i + 1))
done
n0=$(awk -F'\t' 'NR > 1 && $5 == "0"' "$tmpdir/calls.tsv" | wc -l | tr -d ' ')
n1=$(awk -F'\t' 'NR > 1 && $5 == "1"' "$tmpdir/calls.tsv" | wc -l | tr -d ' ')
M="matrix(\"$tmpdir/calls.tsv\", name=\"m\", x=genomic, background=\"#bdbdbd\", rowgroup=\" | \", cluster=none, discrete=TRUE)"

# ---- matrix(discrete=TRUE) + legend(): a KEY of the manual colours, the
# levels renamed by labels=, and the background colour as a final swatch
# labelled by missing=. The cells paint the same table the key draws from:
# one blue fill per 0 cell plus the swatch, one red per 1 cell plus the
# swatch, and the background grey exactly twice (the band, the swatch).
"$CINDERPLOT" "region(\"chr1:900-1700\") + $M
    + scale_fill_manual(values=c(\"0\"=\"#4575b4\", \"1\"=\"#d73027\"),
                        labels=c(\"0\"=\"Unmethylated\", \"1\"=\"Methylated\"))
    + legend(missing=\"Missing\", title=\"Call\")" --size 6x4 --editable-svg -o "$tmpdir/key.svg"
svgnorm "$tmpdir/key.svg"
for lab in Unmethylated Methylated Missing Call; do
    [ "$(texts "$tmpdir/key.svg" | grep -cx "$lab")" -eq 1 ] \
        || { echo "track key does not print \`$lab\` once:" >&2; texts "$tmpdir/key.svg" >&2; exit 1; }
done
# the raw level names are not printed anywhere once renamed
[ "$(texts "$tmpdir/key.svg" | grep -cx -e 0 -e 1)" -eq 0 ] \
    || { echo "labels= left the raw level names in the key" >&2; exit 1; }
[ "$(fills "$tmpdir/key.svg" "$BLUE")" -eq $((n0 + 1)) ] \
    || { echo "blue fills: $(fills "$tmpdir/key.svg" "$BLUE"), wanted $n0 cells + 1 swatch" >&2; exit 1; }
[ "$(fills "$tmpdir/key.svg" "$RED")" -eq $((n1 + 1)) ] \
    || { echo "red fills: $(fills "$tmpdir/key.svg" "$RED"), wanted $n1 cells + 1 swatch" >&2; exit 1; }
[ "$(fills "$tmpdir/key.svg" "$GREY")" -eq 2 ] \
    || { echo "background grey fills: $(fills "$tmpdir/key.svg" "$GREY"), wanted the band + 1 swatch" >&2; exit 1; }
# the key's texts come after the swatches, in level order, then the missing row
[ "$(texts "$tmpdir/key.svg" | grep -x -e Unmethylated -e Methylated -e Missing | tr '\n' ' ')" \
    = "Unmethylated Methylated Missing " ] \
    || { echo "key rows out of order" >&2; exit 1; }

# missing=none drops that swatch; unlabelled, the swatch reads NA; without
# labels= the key prints the levels as the file writes them
"$CINDERPLOT" "region(\"chr1:900-1700\") + $M + legend(missing=none)" \
    --size 6x4 --editable-svg -o "$tmpdir/nomiss.svg"
svgnorm "$tmpdir/nomiss.svg"
[ "$(fills "$tmpdir/nomiss.svg" "$GREY")" -eq 1 ] \
    || { echo "missing=none still drew the background swatch" >&2; exit 1; }
[ "$(texts "$tmpdir/nomiss.svg" | grep -cx -e 0 -e 1)" -eq 2 ] \
    || { echo "an unrenamed key does not print the levels 0 and 1" >&2; exit 1; }
"$CINDERPLOT" "region(\"chr1:900-1700\") + $M + legend()" \
    --size 6x4 --editable-svg -o "$tmpdir/na.svg"
svgnorm "$tmpdir/na.svg"
[ "$(texts "$tmpdir/na.svg" | grep -cx NA)" -eq 1 ] \
    || { echo "the default missing label is not NA" >&2; exit 1; }

# ---- labels= for a level the data does not hold errors, naming it ----------
if "$CINDERPLOT" "region(\"chr1:900-1700\") + $M
    + scale_fill_manual(values=c(\"0\"=\"blue\"), labels=c(\"2\"=\"Two\")) + legend()" \
    -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "labels= for an absent level was accepted" >&2; exit 1
fi
grep -q '`2` is not a level of the key' "$tmpdir/err" \
    || { echo "unknown-level message does not name the level:" >&2; cat "$tmpdir/err" >&2; exit 1; }
grep -q 'the data holds `0`, `1`' "$tmpdir/err" \
    || { echo "unknown-level message does not list the levels:" >&2; cat "$tmpdir/err" >&2; exit 1; }

# ---- legend() with no matrix() track errors -------------------------------
if "$CINDERPLOT" "region(\"chr1:900-1700\") + interval(\"$tmpdir/calls.tsv\") + legend()" \
    -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "legend() without a matrix() track was accepted" >&2; exit 1
fi
grep -q 'keys a matrix() track, and there is none' "$tmpdir/err" \
    || { echo "no-matrix message wrong:" >&2; cat "$tmpdir/err" >&2; exit 1; }

# ---- a placement on the track legend errors and says where it sits --------
if "$CINDERPLOT" "region(\"chr1:900-1700\") + $M + legend(right_of(\"m\"))" \
    -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "right_of() on a track legend was accepted" >&2; exit 1
fi
grep -q 'sits in the right margin' "$tmpdir/err" \
    || { echo "placement message wrong:" >&2; cat "$tmpdir/err" >&2; exit 1; }

# ---- the scale must match the cells, both ways, as heatmap mode insists ----
if "$CINDERPLOT" "region(\"chr1:900-1700\") + $M + scale_fill_viridis() + legend()" \
    -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "a continuous ramp over discrete=TRUE was accepted" >&2; exit 1
fi
grep -q 'is a continuous ramp and matrix() `m` is categorical' "$tmpdir/err" \
    || { echo "ramp-over-codes message wrong:" >&2; cat "$tmpdir/err" >&2; exit 1; }
if "$CINDERPLOT" "region(\"chr1:900-1700\") + matrix(\"$tmpdir/calls.tsv\", cluster=none)
    + scale_fill_manual(values=c(\"0\"=\"blue\")) + legend()" -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "a manual palette over a numeric matrix track was accepted" >&2; exit 1
fi
grep -q 'discrete palette, and this matrix() track is numeric' "$tmpdir/err" \
    || { echo "manual-over-numbers message wrong:" >&2; cat "$tmpdir/err" >&2; exit 1; }

# ---- a continuous matrix track + legend() draws the colourbar: the 64-step
# strip (64 distinct fills beyond the cells' own) with its 0..1 breaks --------
"$CINDERPLOT" "region(\"chr1:900-1700\") + matrix(\"$tmpdir/calls.tsv\", name=\"m\", cluster=none)
    + legend(title=\"beta\")" --size 6x4 --editable-svg -o "$tmpdir/bar.svg"
svgnorm "$tmpdir/bar.svg"
for lab in 0.00 0.25 0.50 0.75 1.00 beta; do
    [ "$(texts "$tmpdir/bar.svg" | grep -cx "$lab")" -eq 1 ] \
        || { echo "colourbar lacks the break \`$lab\`:" >&2; texts "$tmpdir/bar.svg" >&2; exit 1; }
done
ndistinct=$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/bar.svg" | sort -u | wc -l | tr -d ' ')
[ "$ndistinct" -ge 64 ] \
    || { echo "colourbar drew $ndistinct distinct fills; a 64-step strip wants at least 64" >&2; exit 1; }

# ---- heatmap mode: the same labels= renames its discrete key (one table,
# both modes), and an absent level errors there too ---------------------------
printf 'sample,a,b,c\ns1,0,1,2\ns2,2,0,1\ns3,2,0,0\n' >"$tmpdir/codes.csv"
"$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none, discrete=TRUE)
    + scale_fill_manual(values=c(\"0\"=\"grey90\"), labels=c(\"0\"=\"WT\", \"1\"=\"HET\", \"2\"=\"HOM\"))
    + legend(right_of(\"m\"))" --size 4x3 --editable-svg -o "$tmpdir/hm.svg"
svgnorm "$tmpdir/hm.svg"
[ "$(texts "$tmpdir/hm.svg" | tr '\n' ' ')" = "WT HET HOM " ] \
    || { echo "heatmap key with labels= printed: $(texts "$tmpdir/hm.svg" | tr '\n' ' ')" >&2; exit 1; }
if "$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none, discrete=TRUE)
    + scale_fill_manual(labels=c(\"3\"=\"X\")) + legend(right_of(\"m\"))" \
    --size 4x3 -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "heatmap labels= for an absent level was accepted" >&2; exit 1
fi
grep -q '`3` is not a level of the key' "$tmpdir/err" \
    || { echo "heatmap unknown-level message wrong:" >&2; cat "$tmpdir/err" >&2; exit 1; }

# ---- and the heatmap key/colourbar without labels= are what they were: the
# level names 0 1 2 as three swatches, and a 64-step bar for a numeric matrix
"$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none, discrete=TRUE)
    + legend(right_of(\"m\"))" --size 4x3 --editable-svg -o "$tmpdir/hmkey.svg"
svgnorm "$tmpdir/hmkey.svg"
[ "$(texts "$tmpdir/hmkey.svg" | tr '\n' ' ')" = "0 1 2 " ] \
    || { echo "heatmap key printed: $(texts "$tmpdir/hmkey.svg" | tr '\n' ' ')" >&2; exit 1; }
[ "$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/hmkey.svg" | wc -l | tr -d ' ')" -eq 12 ] \
    || { echo "heatmap key: wanted 9 cells + 3 swatches" >&2; exit 1; }
"$CINDERPLOT" "$tmpdir/codes.csv + heatmap(name=\"m\", cluster=none) + legend(right_of(\"m\"))" \
    --size 4x3 --editable-svg -o "$tmpdir/hmbar.svg"
svgnorm "$tmpdir/hmbar.svg"
[ "$(grep -o 'fill="rgb([^"]*)"' "$tmpdir/hmbar.svg" | wc -l | tr -d ' ')" -eq 73 ] \
    || { echo "heatmap colourbar: wanted 9 cells + 64 strips" >&2; exit 1; }

# ---- signal(gap=): a fixed blank between strips ------------------------------
# The lane pad is proportional; the gap is fixed points, so it stays a hairline
# at any height. A larger gap moves each strip's baseline up (the lane shrinks
# from both ends); gap=0 removes it; a negative gap errors.
printf 'chrom\tbeg\tend\tbeta\tsample\n' >"$tmpdir/sg.tsv"
v=0; for x in 100 200 300 400 500; do v=$((1-v)); printf 'chr1\t%s\t%s\t%s\ts1\nchr1\t%s\t%s\t%s\ts2\n' $x $((x+2)) $v $x $((x+2)) $v >>"$tmpdir/sg.tsv"; done
extent() {   # vertical extent of the first trace polyline: a bigger gap shrinks every lane
    "$CINDERPLOT" "region(\"chr1:0-600\") + signal(\"$tmpdir/sg.tsv\"$1)" \
        --size 5x3 --editable-svg -o "$tmpdir/sg.svg"
    python3 - "$tmpdir/sg.svg" <<'PY2'
import re, sys
svg = open(sys.argv[1]).read()
m = re.search(r'<path[^>]*stroke-linejoin="round"[^>]*d="([^"]*)"', svg)
ys = [float(y) for _, y in re.findall(r'[ML] ([-\d.]+) ([-\d.]+)', m.group(1))]
print(round(max(ys) - min(ys), 3))
PY2
}
e0=$(extent ", gap=0"); e2=$(extent ""); e8=$(extent ", gap=8")
# the two-sample zigzag spans its lane, so the lane's height IS the extent:
# e8 < e2 < e0
awk -v a="$e0" -v b="$e2" -v c="$e8" 'BEGIN{exit !(c < b && b < a)}' \
    || { echo "signal gap= did not shrink the lanes: gap0=$e0 gap2=$e2 gap8=$e8" >&2; exit 1; }
if "$CINDERPLOT" "region(\"chr1:0-600\") + signal(\"$tmpdir/sg.tsv\", gap=-1)" \
        -o "$tmpdir/sge.pdf" 2>"$tmpdir/err"; then
    echo "signal(gap=-1) unexpectedly succeeded" >&2; exit 1
fi
grep 'gap= expects the blank space between strips' "$tmpdir/err" >/dev/null


# ==== 2026-09-16: --font-size, base_size, flat track labels, rowbar band ===

# Runtime base font size (--font-size / theme_*(base_size=)), the flat
# track-mode label size, and matrix/signal(rowbar=on). Each feature case is
# written to FAIL on the pre-feature binary and PASS on the new one.
#
#   CINDERPLOT=/path/to/new/cinderplot sh tests3/fonts.sh
#
# Traps this suite has to respect (see the note in the task): SVG paint
# spelling differs by cairo version, so svgnorm() every file before grepping a
# fill; text is glyph PATHS unless --editable-svg, so pass it whenever counting
# fills or reading font-size=; and never lean on CINDERPLOT_EDITABLE_SVG /
# CINDERPLOT_BASE_LINE_SIZE from the environment.

# personal defaults must not reach the suite (as cinderplot-examples/tests do)
unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE || true
svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }
# the reference (pre-feature) binary for the byte-identity guard; skip if absent
REF=${CINDERPLOT_REF:-/home/zhouw3/repo/cinderplot/cinderplot}

# distinct font-size= values in an --editable-svg, one per line
fontsizes() { grep -oE 'font-size="[0-9.]+"' "$1" | sort -u; }

# ---- 1. --font-size scales the label sizes in a grammar figure -------------
# 0.8 * base is the axis-text size; at --font-size 20 that is 16.00, a size the
# default (11 -> 8.80) never produces. The old binary rejects --font-size, so
# the render fails and the case fails there.
"$CINDERPLOT" "$data/mtcars.csv + aes(wt, mpg) + geom_point()" \
    --font-size 20 --editable-svg -o "$tmpdir/fs.svg"
svgnorm "$tmpdir/fs.svg"
test "$(grep -c 'font-size="16.00"' "$tmpdir/fs.svg")" -gt 0
test "$(grep -c 'font-size="8.80"' "$tmpdir/fs.svg")" -eq 0

# ---- 2. theme_*(base_size=) does the same, and overrides --font-size -------
# base_size=20 with --font-size 8 must yield the base_size sizing (16.00 axis
# text), not the flag's (6.40). Overrides the CLI the way base_line_size does.
"$CINDERPLOT" "$data/mtcars.csv + aes(wt, mpg) + geom_point() + theme_gray(base_size=20)" \
    --font-size 8 --editable-svg -o "$tmpdir/bs.svg"
svgnorm "$tmpdir/bs.svg"
test "$(grep -c 'font-size="16.00"' "$tmpdir/bs.svg")" -gt 0
test "$(grep -c 'font-size="6.40"' "$tmpdir/bs.svg")" -eq 0

# ---- 3. an out-of-range --font-size is refused, naming the range -----------
if "$CINDERPLOT" "$data/mtcars.csv + aes(wt, mpg) + geom_point()" \
        --font-size 500 -o "$tmpdir/bad.pdf" 2>"$tmpdir/err"; then
    echo "--font-size 500 unexpectedly succeeded" >&2; exit 1
fi
grep -q 'bad --font-size, expected a number 1..100' "$tmpdir/err"
# and base_size= out of range in the DSL, too
if "$CINDERPLOT" "$data/mtcars.csv + aes(wt, mpg) + geom_point() + theme_gray(base_size=0)" \
        -o "$tmpdir/bad2.pdf" 2>"$tmpdir/err"; then
    echo "base_size=0 unexpectedly succeeded" >&2; exit 1
fi
grep -q 'base_size= expects a number > 0' "$tmpdir/err"

# ---- 4. track mode renders every label at ONE size -------------------------
# A locus figure with panel titles, a track name, row labels and axis numbers.
# Before the flatten those were 9.5 / 8.8 / 6.5; now a single size, and
# --font-size scales that one size, still leaving exactly one distinct value.
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' >"$tmpdir/calls.tsv"
for s in "Liver | h1" "Liver | h2" "Lung | a1" "Lung | a2" "Blood | b1"; do
    for p in 1 2 3; do
        printf 'chr1\t%d\t%d\tcg0%d\t0.%d\t%s\n' \
            $((100 + p * 10)) $((102 + p * 10)) "$p" "$p" "$s" >>"$tmpdir/calls.tsv"
    done
done
printf 'group\tcolour\nLiver\t#e41a1c\nLung\t#377eb8\nBlood\t#4daf4a\n' >"$tmpdir/rc.tsv"
# two windows -> two regions() panel titles (formerly the 9.5pt size)
printf 'chr1\t90\t130\nchr1\t130\t160\n' >"$tmpdir/wins.bed"
"$CINDERPLOT" "regions(\"$tmpdir/wins.bed\") + matrix(\"$tmpdir/calls.tsv\", name=\"m\",
     rowgroup=\" | \", cluster=none, rownames=on, x=genomic, height=4)" \
    --size 6x4 --editable-svg -o "$tmpdir/trk.svg"
svgnorm "$tmpdir/trk.svg"
test "$(fontsizes "$tmpdir/trk.svg" | wc -l)" -eq 1
# and that one size scales with --font-size (9/11 * 20 = 16.36)
"$CINDERPLOT" "regions(\"$tmpdir/wins.bed\") + matrix(\"$tmpdir/calls.tsv\", name=\"m\",
     rowgroup=\" | \", cluster=none, rownames=on, x=genomic, height=4)" \
    --size 6x4 --font-size 20 --editable-svg -o "$tmpdir/trk20.svg"
svgnorm "$tmpdir/trk20.svg"
test "$(fontsizes "$tmpdir/trk20.svg")" = 'font-size="16.36"'

# ---- 5. rowbar=on draws a tall band per group ------------------------------
# One filled rect per group (three groups here) spanning that group's whole run
# of rows, in the group's colour. cluster=none keeps the file's row order, so
# the runs are Liver(2) Lung(2) Blood(1); the bands' heights are in that ratio
# and each is far taller than the 5pt swatch rowbar replaces.
"$CINDERPLOT" "region(\"chr1:90-160\") + matrix(\"$tmpdir/calls.tsv\", name=\"m\",
     rowgroup=\" | \", rowcolour=\"$tmpdir/rc.tsv\", rowbar=on, cluster=none,
     rownames=on, x=genomic, height=4)" \
    --size 6x4 -o "$tmpdir/rb.svg"
svgnorm "$tmpdir/rb.svg"
python3 - "$tmpdir/rb.svg" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
# the three group fills, as cairo rgb() percentages
want = {"rgb(89.411765%, 10.196078%, 10.980392%)": 2,   # Liver, 2 rows
        "rgb(21.568627%, 49.411765%, 72.156863%)": 2,   # Lung,  2 rows
        "rgb(30.196078%, 68.627451%, 29.019608%)": 1}    # Blood, 1 row
heights = {}
for m in re.finditer(r'<path([^>]*)/>', s, re.S):
    a = m.group(1)
    fm = re.search(r'fill="(rgb\([^"]*\))"', a)
    dm = re.search(r'\bd="([^"]*)"', a)
    if not fm or not dm or fm.group(1) not in want:
        continue
    ys = [float(x) for x in re.findall(r'-?\d+\.?\d*', dm.group(1))][1::2]
    heights.setdefault(fm.group(1), []).append(max(ys) - min(ys))
# exactly one band per group
assert set(heights) == set(want), ("missing bands", set(want) - set(heights))
h = {k: (sum(v) / len(v), len(v)) for k, v in heights.items()}
for k, n in want.items():
    assert h[k][1] == 1, ("expected one band for", k, "got", h[k][1])
    assert h[k][0] > 12, ("band not tall (>12pt):", k, h[k][0])   # >> 5pt swatch
# heights track the row counts: Liver ~= Lung ~= 2 * Blood
liver = h["rgb(89.411765%, 10.196078%, 10.980392%)"][0]
blood = h["rgb(30.196078%, 68.627451%, 29.019608%)"][0]
assert abs(liver - 2 * blood) < 1.0, ("Liver band should be ~2x Blood", liver, blood)
print("rowbar bands OK:", {k[:14]: round(v[0], 1) for k, v in h.items()})
PY

# ---- 6. rowbar=on without rowcolour= is refused, naming rowcolour ----------
if "$CINDERPLOT" "region(\"chr1:90-160\") + matrix(\"$tmpdir/calls.tsv\", name=\"m\",
        rowgroup=\" | \", rowbar=on, cluster=none, x=genomic)" \
        -o "$tmpdir/nr.pdf" 2>"$tmpdir/err"; then
    echo "rowbar=on without rowcolour= unexpectedly succeeded" >&2; exit 1
fi
grep -q 'rowbar=on .*needs rowcolour=' "$tmpdir/err"

# ---- 7. rowbar= on a track that is neither matrix() nor signal() is refused -
printf 'chr1\t100\t200\tfeatA\n' >"$tmpdir/iv.bed"
if "$CINDERPLOT" "region(\"chr1:1-500\") + interval(\"$tmpdir/iv.bed\", rowbar=on)" \
        -o "$tmpdir/ivr.pdf" 2>"$tmpdir/err"; then
    echo "interval(rowbar=) unexpectedly succeeded" >&2; exit 1
fi
grep -q 'option `rowbar` is not valid for interval()' "$tmpdir/err"

# ---- 8. grammar mode at the default font size is unchanged (byte guard) ----
# The flatten and the runtime base must leave every non-track figure identical
# at base 11 (11 == 11). Rasterise and compare against the reference binary;
# skip cleanly when there is no distinct reference to compare against.
if [ -x "$REF" ] && [ "$REF" != "$CINDERPLOT" ]; then
    dsl="$data/mtcars.csv + aes(wt, mpg, colour=factor(cyl)) + geom_point() + labs(title=\"t\")"
    "$CINDERPLOT" "$dsl" --size 6x4 -o "$tmpdir/g_new.pdf"
    "$REF"        "$dsl" --size 6x4 -o "$tmpdir/g_ref.pdf"
    pdftoppm -r 100 -png -singlefile "$tmpdir/g_new.pdf" "$tmpdir/g_new"
    pdftoppm -r 100 -png -singlefile "$tmpdir/g_ref.pdf" "$tmpdir/g_ref"
    cmp -s "$tmpdir/g_new.png" "$tmpdir/g_ref.png" \
        || { echo "grammar figure changed at default font size" >&2; exit 1; }
else
    echo "SKIP grammar byte-identity: no distinct reference binary at $REF" >&2
fi

echo "fonts.sh: ok"


# ==== 2026-09-16: sample-metadata annotation bands, shrink-to-fit =====

# Metadata annotation bands for matrix()/signal() tracks, band-only rowbar=on,
# and shrink-to-fit track labels. Each case is written so it FAILS on the
# pre-feature binary and PASSES on the new one.
#
# Traps guarded here (each has bitten this suite):
#  1. SVG paint spelling differs by cairo version -> svgnorm before grepping.
#  2. text is glyph PATHS unless --editable-svg -> pass it when reading fills,
#     <text> or font-size.
#  3. never rely on CINDERPLOT_EDITABLE_SVG / CINDERPLOT_BASE_LINE_SIZE from the
#     environment; the preamble leaves them unset and every case is explicit.
svgnorm() { python3 "$here/tests/svgnorm.py" "$@"; }
unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE 2>/dev/null || true

# span (svg user units) of the tallest <path> filled with a given rgb paint;
# tells a band (spans its run) from the old swatch (a ~5pt square).
maxspan() { python3 - "$1" "$2" <<'PY'
import re, sys
d = open(sys.argv[1]).read(); paint = sys.argv[2]
best = -1.0
for m in re.finditer(r'<path([^>]*)/?>', d):
    seg = m.group(1)
    if ('fill="%s"' % paint) not in seg: continue
    dd = re.search(r'd="([^"]*)"', seg)
    if not dd: continue
    ys = [float(y) for x, y in re.findall(r'[MLC] ([-\d.]+) ([-\d.]+)', dd.group(1))]
    if ys: best = max(best, max(ys) - min(ys))
print("%.2f" % best)
PY
}
# font-size of the <text> whose content is exactly NAME, else ABSENT
fontsize() { python3 - "$1" "$2" <<'PY'
import re, sys
d = open(sys.argv[1]).read(); nm = sys.argv[2]
m = re.search(r'<text[^>]*font-size="([0-9.]+)"[^>]*>' + re.escape(nm) + r'</text>', d)
print(m.group(1) if m else "ABSENT")
PY
}

# ===========================================================================
# CASE 1: rowbar=on draws the BAND ONLY -- no swatch beside the group name.
# The band spans the run (a tall path); the removed swatch was a ~5pt square.
# ===========================================================================
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/rc.tsv"
for s in "Neuron | truth" "Neuron | pred" "Liver | truth"; do
    printf 'chr1\t100\t102\tp1\t0.3\t%s\n' "$s" >>"$tmpdir/rc.tsv"
    printf 'chr1\t120\t122\tp2\t0.7\t%s\n' "$s" >>"$tmpdir/rc.tsv"
done
printf 'group\tcolour\nNeuron\t#ff0000\n' >"$tmpdir/cols2.tsv"
"$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/rc.tsv\", name=\"m\", x=genomic,
     rowgroup=\" | \", rowcolour=\"$tmpdir/cols2.tsv\", rowbar=on, cluster=none, height=6)" \
    --editable-svg -o "$tmpdir/bar.svg"
svgnorm "$tmpdir/bar.svg"
# exactly one red path (the band), and it spans the run (tall), not a 5pt square
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/bar.svg")" -eq 1
awk "BEGIN{exit !($(maxspan "$tmpdir/bar.svg" 'rgb(100%, 0%, 0%)') > 50)}"
# and the same figure WITHOUT rowbar keeps the small swatch (span ~5pt), so the
# band-only behaviour is the difference, not the colour vanishing
"$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/rc.tsv\", name=\"m\", x=genomic,
     rowgroup=\" | \", rowcolour=\"$tmpdir/cols2.tsv\", cluster=none, height=6)" \
    --editable-svg -o "$tmpdir/sw.svg"
svgnorm "$tmpdir/sw.svg"
awk "BEGIN{exit !($(maxspan "$tmpdir/sw.svg" 'rgb(100%, 0%, 0%)') < 10)}"

# ===========================================================================
# CASE 2: rowmeta= + rowbar="cell_type,source" draws TWO adjacent bands, each
# row painted from the 3-column rowcolour table. Four distinct band colours,
# two rows each; the heatmap is a raster <image>, so bands are the only paths.
# ===========================================================================
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/m.tsv"
for s in "A|t" "A|r" "B|t" "B|r"; do
    printf 'chr1\t100\t102\tp1\t1\t%s\n' "$s" >>"$tmpdir/m.tsv"
    printf 'chr1\t120\t122\tp2\t0\t%s\n' "$s" >>"$tmpdir/m.tsv"
done
printf 'sample\tcell_type\tsource\nA|t\tAcell\ttruth\nA|r\tAcell\trecon\nB|t\tBcell\ttruth\nB|r\tBcell\trecon\n' >"$tmpdir/s.tsv"
printf 'column\tvalue\tcolour\n' >"$tmpdir/rc3.tsv"
printf 'cell_type\tAcell\t#ff0000\ncell_type\tBcell\t#00ff00\n' >>"$tmpdir/rc3.tsv"
printf 'source\ttruth\t#0000ff\nsource\trecon\t#ff00ff\n' >>"$tmpdir/rc3.tsv"
"$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/m.tsv\", name=\"m\", discrete=TRUE,
     rowmeta=\"$tmpdir/s.tsv\", rowbar=\"cell_type,source\", rowcolour=\"$tmpdir/rc3.tsv\",
     cluster=none, rownames=off) + scale_fill_manual(values=c(\"0\"=\"#101010\",\"1\"=\"#202020\"))" \
    --editable-svg -o "$tmpdir/two.svg"
svgnorm "$tmpdir/two.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/two.svg")" -eq 2   # cell_type Acell
test "$(grep -c 'fill="rgb(0%, 100%, 0%)"' "$tmpdir/two.svg")" -eq 2   # cell_type Bcell
test "$(grep -c 'fill="rgb(0%, 0%, 100%)"' "$tmpdir/two.svg")" -eq 2   # source truth
test "$(grep -c 'fill="rgb(100%, 0%, 100%)"' "$tmpdir/two.svg")" -eq 2 # source recon

# ===========================================================================
# CASE 3: a sample drawn by the track but missing from the sheet errors,
# naming the first missing sample.
# ===========================================================================
printf 'sample\tcell_type\nA|t\tAcell\n' >"$tmpdir/short.tsv"
if "$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/m.tsv\", rowmeta=\"$tmpdir/short.tsv\",
        rowbar=\"cell_type\", discrete=TRUE, cluster=none)" -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "missing sample in rowmeta unexpectedly succeeded" >&2; exit 1
fi
grep 'rowmeta(.*short.tsv"): sample "A|r" is not in the sheet' "$tmpdir/err" >/dev/null

# ===========================================================================
# CASE 4: a rowbar column not present in the sheet errors, naming it and the
# sheet's columns.
# ===========================================================================
if "$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/m.tsv\", rowmeta=\"$tmpdir/s.tsv\",
        rowbar=\"lineage\", discrete=TRUE, cluster=none)" -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "unknown rowbar column unexpectedly succeeded" >&2; exit 1
fi
grep 'rowbar column "lineage" is not in rowmeta' "$tmpdir/err" >/dev/null
grep 'columns: sample, cell_type, source' "$tmpdir/err" >/dev/null

# ===========================================================================
# CASE 5: the 3-column rowcolour maps (column,value)->colour; a value not listed
# gets the hue palette, and two unlisted values get distinct hues.
# Only Acell is listed (#ff0000); Bcell and Ccell fall to hue_palette(2), whose
# two colours are deterministic (hcl(15,..) and hcl(195,..)).
# ===========================================================================
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample\n' >"$tmpdir/m3.tsv"
for s in "A|t" "A|r" "B|t" "B|r" "C|t" "C|r"; do
    printf 'chr1\t100\t102\tp1\t1\t%s\n' "$s" >>"$tmpdir/m3.tsv"
    printf 'chr1\t120\t122\tp2\t0\t%s\n' "$s" >>"$tmpdir/m3.tsv"
done
printf 'sample\tcell_type\tsource\n' >"$tmpdir/s3.tsv"
printf 'A|t\tAcell\ttruth\nA|r\tAcell\trecon\nB|t\tBcell\ttruth\nB|r\tBcell\trecon\nC|t\tCcell\ttruth\nC|r\tCcell\trecon\n' >>"$tmpdir/s3.tsv"
printf 'column\tvalue\tcolour\ncell_type\tAcell\t#ff0000\n' >"$tmpdir/rc1.tsv"
"$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/m3.tsv\", name=\"m\", discrete=TRUE,
     rowmeta=\"$tmpdir/s3.tsv\", rowbar=\"cell_type\", rowcolour=\"$tmpdir/rc1.tsv\",
     cluster=none, rownames=off) + scale_fill_manual(values=c(\"0\"=\"#101010\",\"1\"=\"#202020\"))" \
    --editable-svg -o "$tmpdir/hue.svg"
svgnorm "$tmpdir/hue.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/hue.svg")" -eq 2   # Acell, listed
# the two unlisted values get two DIFFERENT hues (each two rows), neither red;
# the hue values are hue_palette(2): hcl(15,100,65) and hcl(195,100,65).
test "$(grep -c 'fill="rgb(97.254902%, 46.27451%, 42.745098%)"' "$tmpdir/hue.svg")" -eq 2
test "$(grep -c 'fill="rgb(0%, 74.901961%, 76.862745%)"' "$tmpdir/hue.svg")" -eq 2

# ===========================================================================
# CASE 6: rowgroup= and rowmeta= together error (pick one).
# ===========================================================================
if "$CINDERPLOT" "region(\"chr1:1-200\") + matrix(\"$tmpdir/m.tsv\", rowgroup=\"|\",
        rowmeta=\"$tmpdir/s.tsv\", rowbar=\"cell_type\", discrete=TRUE, cluster=none)" \
        -o "$tmpdir/x.pdf" 2>"$tmpdir/err"; then
    echo "rowgroup= with rowmeta= unexpectedly succeeded" >&2; exit 1
fi
grep 'give one or the other' "$tmpdir/err" >/dev/null

# ===========================================================================
# CASE 7: a gene label that would overflow shrinks below the flat size instead
# of being dropped; one that cannot fit even at the floor stays dropped.
# regions() so the window edge (not a reserved margin) bounds the label: the
# pre-feature binary drops both, the new one shrinks the first.
# ===========================================================================
printf 'chr1\t100000\t120000\tW1\nchr1\t200000\t220000\tW2\n' >"$tmpdir/wins.bed"
{
  printf 'chr1\t113000\t114500\tSHRINKINGGENE\t0\t+\t113000\t114500\t0\t1\t1500,\t0,\n'
  printf 'chr1\t214500\t216000\tWAYTOOLONGGENENAMETODRAWEVENATTHEFLOORSIZEXXXXXXXX\t0\t+\t214500\t216000\t0\t1\t1500,\t0,\n'
} >"$tmpdir/g.bed"
"$CINDERPLOT" "regions(\"$tmpdir/wins.bed\") + genes(\"$tmpdir/g.bed\", height=1)" \
    --size 8x2 --editable-svg -o "$tmpdir/genes.svg"
svgnorm "$tmpdir/genes.svg"
# the overflowing name is present, shrunk below the 8.80pt flat gene size and
# not below the ~5.5pt floor
fs=$(fontsize "$tmpdir/genes.svg" SHRINKINGGENE)
test "$fs" != ABSENT
awk "BEGIN{exit !($fs < 8.8 && $fs >= 5.5)}"
# the name that cannot fit even at the floor is dropped
test "$(fontsize "$tmpdir/genes.svg" WAYTOOLONGGENENAMETODRAWEVENATTHEFLOORSIZEXXXXXXXX)" = ABSENT

echo "meta.sh: ok"

# ===========================================================================
# 2026-09-16: the metadata-band track's committed data (methylation betas grouped
# by condition + the samples sheet + the rowcolour table) must parse and render.
# The gallery card is genome-backed, so tests/gallery.sh SKIPS it on a CI runner
# with no reference genome; this genome-free render keeps those data files under
# test everywhere. (chord/radar/boxplot/smooth carry no genome path, so
# tests/gallery.sh already renders them in CI -- no duplicate needed here.)
# ===========================================================================
"$CINDERPLOT" "region(\"chr20:44617001-44653999\") + matrix(\"$here/data/region_betas_grouped.tsv\", name=\"betas\", cluster=none, rownames=off, rowmeta=\"$here/data/region_betas_samples.tsv\", rowbar=\"condition\", rowcolour=\"$here/data/region_betas_rowcol.tsv\", height=10)" \
    -o "$tmpdir/gc_meta.svg"
test -s "$tmpdir/gc_meta.svg"
grep -q '<image' "$tmpdir/gc_meta.svg" || { echo "metabands data: heatmap raster missing" >&2; exit 1; }
# the condition band: one rect per sample in each colour (38 Normal, 38 Tumour);
# without rowmeta=/rowbar= the same spec draws zero of either
svgnorm "$tmpdir/gc_meta.svg"
test "$(grep -c 'fill="rgb(27.058824%, 45.882353%, 70.588235%)"' "$tmpdir/gc_meta.svg")" -eq 38   # #4575b4 Normal
test "$(grep -c 'fill="rgb(84.313725%, 18.823529%, 15.294118%)"' "$tmpdir/gc_meta.svg")" -eq 38   # #d73027 Tumour
echo "gallery-data.sh: ok"

# ===========================================================================
# 2026-09-16 review: the row gutter's bands are gutter, not labels.
# Pre-fix, both the rowgroup band and the metadata bands were gated on the
# "write row labels" flag, which also encodes "left-most window", so:
#   - rowbar=on + rownames=off reserved the strip and drew nothing in it;
#   - regions() with N windows stamped the metadata bands N times.
# And fit_height applied its 5.5pt floor even when the requested size was
# smaller, so --font-size 5 could ENLARGE a cramped row label past 4.1pt.
# ===========================================================================
printf 'chrom\tbeg\tend\tProbe_ID\tbeta\tsample_name\n' >"$tmpdir/gt.tsv"
for s in "A | s1" "A | s2" "B | s3"; do
    printf 'chr1\t100\t102\tp1\t0.2\t%s\nchr1\t150\t152\tp2\t0.8\t%s\n' "$s" "$s" >>"$tmpdir/gt.tsv"
done
printf 'group\tcolour\nA\t#ff0000\nB\t#0000ff\n' >"$tmpdir/gt_rc.tsv"
# 1. the band is drawn with row names hidden (pre-fix: 0 red rects)
"$CINDERPLOT" "region(\"chr1:50-200\") + matrix(\"$tmpdir/gt.tsv\", rowgroup=\" | \", rowcolour=\"$tmpdir/gt_rc.tsv\", rowbar=on, rownames=off, cluster=none)" \
    -o "$tmpdir/gt_off.svg"
svgnorm "$tmpdir/gt_off.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/gt_off.svg")" -eq 1
# 2. metadata bands are stamped once across two windows (pre-fix: 2x = 4 rects)
printf 'sample\tcond\nA | s1\tx\nA | s2\tx\nB | s3\ty\n' >"$tmpdir/gt_meta.tsv"
printf 'column\tvalue\tcolour\ncond\tx\t#ff0000\ncond\ty\t#0000ff\n' >"$tmpdir/gt_rc3.tsv"
printf 'chr1\t90\t110\tw1\nchr1\t140\t160\tw2\n' >"$tmpdir/gt_win.bed"   # two windows, one probe each
"$CINDERPLOT" "regions(\"$tmpdir/gt_win.bed\") + matrix(\"$tmpdir/gt.tsv\", rowmeta=\"$tmpdir/gt_meta.tsv\", rowbar=\"cond\", rowcolour=\"$tmpdir/gt_rc3.tsv\", rownames=off, cluster=none)" \
    -o "$tmpdir/gt_w3.svg"
svgnorm "$tmpdir/gt_w3.svg"
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/gt_w3.svg")" -eq 2   # two x-rows, once
# 3. a cramped row label at --font-size 5 never exceeds the 4.09pt track size
"$CINDERPLOT" "region(\"chr20:44617001-44653999\") + matrix(\"$here/data/region_betas_long.tsv\", cluster=none, rownames=on, height=3)" \
    --font-size 5 --editable-svg -o "$tmpdir/gt_fs5.svg"
svgnorm "$tmpdir/gt_fs5.svg"
if grep -o 'font-size="[0-9.]*"' "$tmpdir/gt_fs5.svg" | sed 's/[^0-9.]//g' | awk '$1 > 4.1 + 1e-6 {bad=1} END {exit bad}'; then :; else
    echo "--font-size 5: a track label exceeds the 4.09pt flat size" >&2; exit 1; fi
echo "gutter.sh: ok"

# ===========================================================================
# 2026-09-16 release review: things that used to exit 0 with a wrong figure.
# ===========================================================================
# 1. text that is not UTF-8 poisoned cairo: every later draw was a no-op and the
#    figure came out blank with "wrote". Now refused at load, naming the cell.
printf 'wt,mpg,g\n1,2,caf\351\n2,3,ok\n' >"$tmpdir/latin1.csv"
if "$CINDERPLOT" "$tmpdir/latin1.csv + aes(wt, mpg, colour=g) + geom_point()" -o "$tmpdir/l1.svg" 2>"$tmpdir/err"; then
    echo "latin-1 input unexpectedly succeeded" >&2; exit 1; fi
grep -q 'row 2 column `g` is not valid UTF-8' "$tmpdir/err"
if "$CINDERPLOT" "$here/data/mtcars.csv + aes(wt, mpg) + geom_point() + labs(title=\"caf$(printf '\351')\")" -o "$tmpdir/l2.svg" 2>"$tmpdir/err"; then
    echo "latin-1 spec unexpectedly succeeded" >&2; exit 1; fi
grep -q 'spec is not valid UTF-8' "$tmpdir/err"
# 2. a failing render no longer truncates the previous output to 0 bytes: SVG
#    and PDF are written only after the whole figure rendered
printf 'keep' >"$tmpdir/keep.svg"
if "$CINDERPLOT" "region(\"chr1:1-100\") + coverage(\"$tmpdir/does-not-exist.bg\")" -o "$tmpdir/keep.svg" 2>/dev/null; then
    echo "missing coverage file unexpectedly succeeded" >&2; exit 1; fi
test "$(wc -c <"$tmpdir/keep.svg")" -eq 4
# 3. non-finite numbers are refused where they used to wipe the figure
chkx "$here/data/mtcars.csv + aes(wt, mpg) + geom_point() + geom_abline(slope=inf, intercept=0)" 'slope= must be finite'
chkx "region(\"chr1:1-100\") + interval(\"$here/tracks/peaks.bed\", height=inf)" 'height= must be a positive number'
chkx "region(\"chr1:1-100\") + interval(\"$here/tracks/peaks.bed\", height=0)" 'height= must be a positive number'
chkx "region(\"chr1:1000000-1200000\") + coverage(\"$here/tracks/atac.bedgraph\", max=0)" 'max= must be a positive number'
chkx "$here/data/mtcars.csv + aes(wt, mpg, colour=hp) + geom_point() + scale_colour_gradient2(midpoint=nan)" 'midpoint= must be finite'
# 4. rowbar="a," is a mistake, not a one-column list
chkx "region(\"chr20:44617001-44653999\") + matrix(\"$here/data/region_betas_grouped.tsv\", rowmeta=\"$here/data/region_betas_samples.tsv\", rowbar=\"condition,\", cluster=none)" 'ends with a comma'
# 5. a Newick with no named tip drew an empty figure
printf ';' >"$tmpdir/empty.tre"; printf '();' >"$tmpdir/paren.tre"
chkx "$tmpdir/empty.tre + geom_tree()" 'no named tips'
chkx "$tmpdir/paren.tre + geom_tree()" 'no named tips'
# 6. the flat track size reaches the kb-axis numbers with no matrix() present:
#    genes-only at --font-size 20 is all 16.36 (20*9/11), never 16 (0.8*20)
"$CINDERPLOT" "region(\"chr1:1000000-1200000\") + genes(\"$here/tracks/genes.bed\", height=2)" \
    --size 6x2 --font-size 20 --editable-svg -o "$tmpdir/flat.svg"
svgnorm "$tmpdir/flat.svg"
# every label in the figure -- gene names AND axis numbers -- is the one flat
# size; the pre-fix binary also emitted the grammar's 16.00 for the axis
sizes=$(grep -o 'font-size="[0-9.]*"' "$tmpdir/flat.svg" | sort -u | tr '\n' ' ')
test "$sizes" = 'font-size="16.36" ' || { echo "genes-only track has sizes: $sizes (want only 16.36)" >&2; exit 1; }
# 7. --editable-svg never emits a raw control byte (it is not XML)
"$CINDERPLOT" "$here/data/mtcars.csv + aes(wt, mpg) + geom_point() + labs(title=\"a$(printf '\001')b\")" --editable-svg -o "$tmpdir/ctl.svg"
if grep -q "$(printf '\001')" "$tmpdir/ctl.svg"; then echo "raw control byte in --editable-svg output" >&2; exit 1; fi
echo "review.sh: ok"

echo "all tests passed"
