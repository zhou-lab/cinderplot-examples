# Locus track-browser example

> **Synthetic placeholder data.** These files are hand-made to exercise the
> four track renderers, not real measurements. TODO: replace with a real
> locus — e.g. an ENCODE ATAC-seq bedGraph, RefSeq/GENCODE gene models
> (BED12, ideally from `zhou-lab/genomes`), and real Hi-C loops (BEDPE).

Renders a single-region browser view (coverage + genes + peaks + loops):

```sh
cinderplot --region chr1:1,000,000-1,200,000 \
  'coverage("tracks/atac.bedgraph", name="ATAC")
   + genes("tracks/genes.bed", name="genes")
   + interval("tracks/peaks.bed", name="peaks")
   + arcs("tracks/loops.bedpe", name="loops")' -o browser.pdf
```

## Files (tab-separated, BED-style 0-based half-open)

| file | format | track |
|---|---|---|
| `atac.bedgraph` | `chrom start end value` | coverage signal |
| `genes.bed` | BED12 (exon blocks, thick=CDS) | gene models |
| `peaks.bed` | BED (`chrom start end name score strand`) | interval blocks |
| `loops.bedpe` | BEDPE (`chrom1 s1 e1 chrom2 s2 e2 name score`) | arcs |

Only records overlapping the `--region` are loaded. Coverage y auto-scales to
its max (`max=` to fix it); tracks auto-stack (`height=` for relative sizes).
