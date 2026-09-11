#!/bin/sh
# tests/gallery.sh — the gallery cases, as a test.
#
# The 35 specs behind the published figures live in the CODE repo, in the
# SECTIONS list of docs/build.py, while their rendered output lives here in
# docs/figs/. They are nearly disjoint from test.sh: only one of the 35 appears
# there, and they reach 213 lines the suite never does. So they are worth
# running, not just publishing.
#
#   sh tests/gallery.sh                 every spec must render clean
#   sh tests/gallery.sh --compare REF   also require byte-identical output
#                                       against a second binary (release check)
#
# Why not compare against the committed docs/figs/? Because those are bytes
# from whichever cairo rendered them, and cairo versions rasterise differently
# -- the same source gives different files on this cluster, in CI and in the
# conda env. Byte-identity is only meaningful between two binaries on ONE
# machine, which is what --compare does.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CINDERPLOT=${CINDERPLOT:-"$here/../cinderplot/cinderplot"}
REPO=${CINDERPLOT_REPO:-"$here/../cinderplot"}
[ -x "$CINDERPLOT" ] || { echo "no binary at $CINDERPLOT" >&2; exit 2; }
[ -f "$REPO/docs/build.py" ] || { echo "no $REPO/docs/build.py (set CINDERPLOT_REPO)" >&2; exit 2; }

ref=""
[ "${1:-}" = "--compare" ] && { ref=${2:?--compare needs a reference binary}; [ -x "$ref" ] || { echo "no binary at $ref" >&2; exit 2; }; }

unset CINDERPLOT_EDITABLE_SVG CINDERPLOT_BASE_LINE_SIZE
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cinderplot-gallery.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
: "${CINDERPLOT_GENOMES:=$HOME/repo/genomes/hg38}"
export CINDERPLOT_GENOMES

python3 - "$REPO" >"$tmpdir/cases.tsv" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("b", os.path.join(sys.argv[1], "docs", "build.py"))
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
for _section, items in b.SECTIONS:
    for it in items:
        print(it[0] + "\t" + " ".join(it[2].split()))
PY
rm -rf "$REPO/docs/__pycache__"

# Two cases read a reference genome (gene models, cytoband) from
# $CINDERPLOT_GENOMES. That repo is not on a CI runner, so skip those rather
# than fail -- and say so, because a silent skip is how a case stops being a
# test without anyone noticing.
have_genomes=1
[ -d "$CINDERPLOT_GENOMES" ] || have_genomes=0

n=0; bad=0; skipped=0
while IFS="	" read -r slug dsl; do
    case "$dsl" in
      *"$CINDERPLOT_GENOMES"*)
        if [ "$have_genomes" -eq 0 ]; then
            skipped=$((skipped + 1)); continue
        fi ;;
    esac
    n=$((n + 1))
    if ! "$CINDERPLOT" "$dsl" -o "$tmpdir/$slug.pdf" --size 7x5 --dpi 100 \
            >"$tmpdir/$slug.out" 2>"$tmpdir/$slug.err"; then
        echo "gallery case '$slug' failed to render:" >&2; cat "$tmpdir/$slug.err" >&2; bad=1; continue
    fi
    [ -s "$tmpdir/$slug.pdf" ] || { echo "gallery case '$slug' wrote an empty file" >&2; bad=1; continue; }
    # stderr carries "wrote FILE" and the deliberate row-drop notes; a warning
    # in a PUBLISHED figure means the documentation shows a defect.
    if grep -v '^wrote \|rows with missing values\|non-positive values' "$tmpdir/$slug.err" | grep -q .; then
        echo "gallery case '$slug' warned:" >&2
        grep -v '^wrote ' "$tmpdir/$slug.err" >&2; bad=1
    fi
    if [ -n "$ref" ]; then
        "$ref" "$dsl" -o "$tmpdir/$slug.ref.pdf" --size 7x5 --dpi 100 >/dev/null 2>&1 || {
            echo "gallery case '$slug' rendered with the new binary but not the reference" >&2; bad=1; continue; }
        # rasterise: cairo stamps a creation time inside a compressed stream,
        # so the PDFs differ on the clock alone (see the repo notes)
        pdftoppm -r 100 -png -singlefile "$tmpdir/$slug.pdf" "$tmpdir/$slug.new"
        pdftoppm -r 100 -png -singlefile "$tmpdir/$slug.ref.pdf" "$tmpdir/$slug.old"
        cmp -s "$tmpdir/$slug.new.png" "$tmpdir/$slug.old.png" \
            || { echo "gallery case '$slug' renders differently from the reference" >&2; bad=1; }
    fi
done <"$tmpdir/cases.tsv"

[ "$n" -gt 0 ] || { echo "no gallery cases found in $REPO/docs/build.py" >&2; exit 1; }
[ "$bad" -eq 0 ] || exit 1
note=""
[ "$skipped" -gt 0 ] && note=" ($skipped skipped: no reference genome at $CINDERPLOT_GENOMES)"
if [ -n "$ref" ]; then echo "all $n gallery cases render, and match the reference$note"
else echo "all $n gallery cases render$note"; fi
