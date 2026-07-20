# cinderplot-examples

Example datasets and the regression test suite for
[cinderplot](https://github.com/zhou-lab/cinderplot). Kept out of the code
repository so that stays small and buildable; the data lives here.

The documentation site and gallery HTML live in the code repo under `docs/`
(published to GitHub Pages at `zhou-lab.github.io/cinderplot/`). Its build
script reads the datasets here from a sibling checkout — see `docs/build.py` in
the cinderplot repo.

The **rendered gallery figures** are served from *this* repo's Pages site to
keep the code repo free of growing binary assets: `docs/figs/*.svg` (cinderplot)
and `docs/figs/*.png` (ggplot2 reference), published at
`zhou-lab.github.io/cinderplot-examples/figs/…` and linked by the gallery.
Enable it under *Settings → Pages → Deploy from a branch → `main` / `docs`*.

## Layout

| dir | what |
|---|---|
| `data/` | small CSV datasets (mtcars, expr, …) used by the tests and quick demos |
| `genome/` | whole-genome CNV example (K562): bins, segments, hg38 seqinfo + cytoband |
| `tracks/` | locus track-browser example (synthetic placeholder): coverage, genes, peaks, loops |
| `region/` | sesame `visualizeRegion` target (real ADA/HM450 data): a genome-anchored beta heatmap + gene models — see its README for the co-dev spec |
| `tests/` | regression suite (`test.sh`) + `cluster_check.c` |

Each subdirectory has its own README with the exact commands.

## Running the examples

These assume `cinderplot` is on your `PATH` (built from the code repo and
installed, or `make install`). Sample data lives in `data/`. Reference genome
annotation (cytoband, seqinfo, gene models) is read straight from a genome repo:
cinderplot decompresses gzip/bgzip and region-queries a tabix index in memory,
so point those arguments at your local copy (e.g. `~/repo/genomes/hg38`):

```sh
cinderplot data/k562.bins.tsv \
  '... + scale_x_genome("/path/to/genomes/hg38/seqinfo.tsv.gz")
       + ideogram("/path/to/genomes/hg38/cytoband.tsv.gz") ...' -o k562.pdf
```

## Running the tests

`tests/test.sh` needs the built binary. By default it looks for a sibling
checkout of the code repo at `../cinderplot/cinderplot`; override with
`CINDERPLOT`:

```sh
CINDERPLOT=/path/to/cinderplot sh tests/test.sh
```

`tests/cluster_check.c` is a standalone verifier that links against the
cinderplot sources; compile it from within the code repo (it needs
`include/cinderplot.h` and `cluster.c`/`csv.c`).
