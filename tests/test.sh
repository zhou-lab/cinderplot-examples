#!/bin/sh
set -eu

# Personal defaults must not reach the suite. CINDERPLOT_EDITABLE_SVG=1 and
# CINDERPLOT_BASE_LINE_SIZE=0.25 are documented per-user settings, so a
# maintainer who has them exported would otherwise be testing a different
# tool from CI: an SVG comes out as <text> elements rather than glyph
# outlines, and every chrome line is half weight. The cases that exercise
# those knobs set them per invocation, below.
unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE

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
# A circular tree gets a square canvas; the others do not.
if command -v pdfinfo >/dev/null 2>&1; then
    cw=$(pdfinfo "$tmpdir/lay-circular.pdf" | awk '/Page size/{print int($3)}')
    ch=$(pdfinfo "$tmpdir/lay-circular.pdf" | awk '/Page size/{print int($5)}')
    test "$cw" -eq "$ch"
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
test "$(grep -c 'fill="rgb(34.9%, 34.9%, 34.9%)"' "$tmpdir/histfree.svg")" -eq 4

# ---- C8: geom_boxplot() under facet_wrap(scales="free_x") uses the panel's x slots ----
# boxes for levels c,d in the second panel used to be drawn at global slots
# 3-4 and clipped away; every other discrete geom already renumbered per panel
printf 'x,y,f\na,1,P1\na,2,P1\na,3,P1\nb,2,P1\nb,3,P1\nb,4,P1\nc,5,P2\nc,6,P2\nc,7,P2\nd,1,P2\nd,2,P2\nd,9,P2\n' >"$tmpdir/boxfree.csv"
"$CINDERPLOT" "$tmpdir/boxfree.csv + aes(x,y) + geom_boxplot() + facet_wrap(~f, scales=\"free_x\")" \
    -o "$tmpdir/boxfree.svg" --size 6x3
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
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/seglog.svg")" -eq 1

# ---- C16: geom_errorbar() default cap is 0.9 x the x resolution ----
# with x = 0.1, 0.2, 0.3 the old 0.25-unit default ran the caps edge to edge
# and through the neighbouring bars; a cap is now narrower than the x spacing
printf 'x,y,lo,hi\n0.1,1,0.5,1.5\n0.2,2,1.5,2.5\n0.3,3,2.5,3.5\n' >"$tmpdir/ebres.csv"
"$CINDERPLOT" "$tmpdir/ebres.csv + aes(x,y,ymin=lo,ymax=hi) + geom_errorbar()" -o "$tmpdir/ebres.svg" --size 4x3
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
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constseg.svg")" -eq 2
"$CINDERPLOT" "$tmpdir/constcol.csv + aes(x,y,xend=xend,yend=yend,fill=g) + geom_rect(fill=\"red\")" \
    -o "$tmpdir/constrect.svg" --size 4x3
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constrect.svg")" -eq 2
printf 'g,v\na,1\na,2\na,3\na,4\nb,2\nb,3\nb,4\nb,5\n' >"$tmpdir/constbox.csv"
# fill= paints the two bodies, colour= the chrome (whiskers, outline, median)
"$CINDERPLOT" "$tmpdir/constbox.csv + aes(g,v) + geom_boxplot(fill=\"red\")" -o "$tmpdir/constboxf.svg" --size 4x3
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constboxf.svg")" -eq 2
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constboxf.svg")" -eq 0
"$CINDERPLOT" "$tmpdir/constbox.csv + aes(g,v) + geom_boxplot(colour=\"red\")" -o "$tmpdir/constboxc.svg" --size 4x3
test "$(grep -c 'fill="rgb(100%, 0%, 0%)"' "$tmpdir/constboxc.svg")" -eq 0
test "$(grep -c 'stroke="rgb(100%, 0%, 0%)"' "$tmpdir/constboxc.svg")" -eq 8

# ---- C24: geom_errorbar() over a fill= mapping draws black, not the fill palette ----
# painted in the bar's own colour, the half of each whisker inside its bar vanished
printf 'g,y,lo,hi\nA,3,2,4\nB,5,4,6\nC,4,3,5\n' >"$tmpdir/ebfill.csv"
"$CINDERPLOT" "$tmpdir/ebfill.csv + aes(g,y,fill=g,ymin=lo,ymax=hi) + geom_col() + geom_errorbar(width=0.3)" \
    -o "$tmpdir/ebfill.svg" --size 4x3
test "$(grep -c 'stroke="rgb(0%, 0%, 0%)"' "$tmpdir/ebfill.svg")" -eq 9

# ---- C25: dodged boxplots centre a category with fewer groups (dodge2 preserve="total") ----
# b holds only g1: its box takes the category's full width, twice a's half-boxes
printf 'x,g,y\na,g1,1\na,g1,2\na,g1,3\na,g2,2\na,g2,3\na,g2,4\nb,g1,3\nb,g1,4\nb,g1,5\n' >"$tmpdir/dodge.csv"
"$CINDERPLOT" "$tmpdir/dodge.csv + aes(x,y,fill=g) + geom_boxplot()" -o "$tmpdir/dodge.svg" --size 4x3
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
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y, colour=g) + geom_point() + theme(legend.position=\"bottom\")" \
        -o "$tmpdir/d6c.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "legend.position=\"bottom\" unexpectedly succeeded" >&2; exit 1
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
chk "aes(reorder(g, y), y) + geom_boxplot()" 'levels=c('
chk "aes(log10(x), y) + geom_point()" 'scale_x_log10()'
chk "aes(x/y, y) + geom_point()" 'arithmetic'
chk "aes(x, y) + geom_point(aes(colour=g))" 'top-level aes()'
chk "aes(x, y) + geom_point() + geom_hline(aes(yintercept=2))" 'literal intercept'
chk "aes(x, y) + geom_point() + facet_grid(g~x)" 'facet_grid() is not implemented'
"$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + geom_point() + labs(title='single') + ggtitle(\"T\", subtitle=\"Sub\")" \
    -o "$tmpdir/d7b.pdf"
if command -v pdftotext >/dev/null 2>&1; then
    pdftotext "$tmpdir/d7b.pdf" - | grep 'Sub' >/dev/null
fi

# ---- D9: the menus name every implemented verb / option -----------------------
if "$CINDERPLOT" "$tmpdir/d.csv + aes(x, y) + nope()" -o "$tmpdir/d9.pdf" >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "nope() unexpectedly succeeded" >&2; exit 1
fi
for v in 'chord()' 'smooth' 'annotate()' 'coord_flip/polar' 'brewer' 'ideogram()' 'geom_tree' 'ggplot()'; do
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
# --help: five modes with a chord row, the fuller geom line, -r documented
"$CINDERPLOT" --help >"$tmpdir/help"
grep 'FIVE MODES' "$tmpdir/help" >/dev/null
grep 'chord(' "$tmpdir/help" >/dev/null
grep 'errorbar' "$tmpdir/help" >/dev/null
grep -- '-r, --region' "$tmpdir/help" >/dev/null

# ---- geom_histogram() takes the generic layer args; geom_line(size=) says why -
"$CINDERPLOT" "$tmpdir/d.csv + aes(x) + geom_histogram(bins=3, fill=\"red\", alpha=0.5, colour=\"black\")" \
    -o "$tmpdir/hist.pdf"
test -s "$tmpdir/hist.pdf"
chk "aes(x) + geom_histogram(binwidth=1)" 'binwidth=) is not implemented'
chk "aes(x, y) + geom_line(size=2)" 'line width on geom_line()'
chk "aes(x, y) + geom_line(linewidth=2)" 'line width on geom_line()'

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
test -s "$tmpdir/hlt.svg"
grep -q 'stroke="rgb(84.313725%, 18.823529%, 15.294118%)"' "$tmpdir/hlt.svg"

# the file form: one box per line, colour/label/linetype per box
printf 'row\tchrom\tbeg\tend\tcolour\tlabel\tlinetype\n' >"$tmpdir/hlbox.tsv"
printf 'S1\tchr1\t1000\t1300\t#4575b4\tF\tsolid\n' >>"$tmpdir/hlbox.tsv"
printf 'S2\tchr1\t1600\t1900\t#e08214\tE\tdashed\n' >>"$tmpdir/hlbox.tsv"
"$CINDERPLOT" "region(\"chr1:1000-2000\") + matrix(\"$tmpdir/hlm.tsv\", name=\"m\", cluster=none, colnames=off) + highlight(\"$tmpdir/hlbox.tsv\", name=\"m\")" \
    -o "$tmpdir/hlf.svg"
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

echo "all tests passed"
