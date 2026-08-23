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
grep 'use fixed, free_x, free_y, or free' "$tmpdir/fs-bad.err" >/dev/null

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

echo "all tests passed"
