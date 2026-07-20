# Region view (sesame `visualizeRegion`) — co-development target

Data + spec for building sesame's **`visualizeRegion` / `visualizeProbes`** in
cinderplot. That figure is a **locus browser with a genome-anchored heatmap**:
over one genomic region, stack a cytoband strip, a gene/transcript track, and —
the new part — a **beta-value heatmap whose columns are the probes, anchored to
their genomic positions by map lines** (samples on the rows).

```
  cytoband:   ▔▔▔▔▔▔▔▔▔█▔▔▔▔▔▔   chr20  (region highlighted)
  genes:      ──■─■■─────■──►     ADA / PKIG transcript models (exons)
  map lines:   \   |   |    /     probe genomic position → heatmap column
  heatmap:    ┌─┬─┬─┬───┬─┬─┐     rows = samples, cols = probes, fill = beta
              └─┴─┴─┴───┴─┴─┘
```

**Reference:** `region-ref.png` / `region-ref.pdf` are the actual R
`visualizeRegion("chr20", 44616522, 44655233, betas, "HM450", cluster.samples=TRUE)`
output — the figure to reproduce. It shows the four stacked pieces: cytoband
(region marked in red), ADA/PKIG transcript models (exon boxes, strand arrows,
transcript labels), the diagonal map lines from each probe position to its column,
and the 76×10 beta heatmap (sample labels on the left, probe IDs below). Match the
layout, not the exact palette (R uses a jet colormap; a 0..1 diverging fill is fine).

## The example (ADA gene, HM450, hg38)

`region.txt` = `chr20:44616522-44655233`. Real data — the 76-sample
`HM450.76.TCGA.matched` set from sesame, exported from R.

| file | format | role |
|---|---|---|
| `region_betas_long.tsv` | `chrom  beg  end  Probe_ID  beta  sample_name` (tidy long-form; one row per probe×sample) | **the matrix feed** — exactly what `sesame region` emits |
| `region_betas.bed` | `chrom  start  end  Probe_ID  <sample1..76>` (wide: BED4 + a beta column per sample) | same data, wide form (kept for reference) |
| `region_genes.bed` | BED12 (exon blocks, thick = CDS) | gene/transcript track — same format as `tracks/genes.bed` |
| cytoband | `../genome/hg38.cytoband.tsv` | ideogram strip |

**`region_betas_long.tsv` is the canonical feed** and is exactly the output of the
`sesame region` subcommand (implemented): long-form, one row per (probe, sample),
`beg`/`end` the CpG's genomic interval (2 bp), `beta` in [0,1] or `NA`. The genomic
interval anchors each probe on the region ruler for the map lines; `sample_name`
gives the heatmap rows, `Probe_ID` the columns. It is region-scoped here (small),
but the format is the same genome-wide — `sesame region chr:beg-end` selects the
probes, so one array-wide `.cg` serves any locus. 10 probes × 76 samples (760 rows)
here; HM450 is sparse, so a denser locus or EPICv2 gives more columns. The wide
`region_betas.bed` carries the identical data if a track prefers columns.

## Proposed grammar (builds on the locus browser)

```sh
cinderplot --region chr20:44616522-44655233 \
  'cytoband("../genome/hg38.cytoband.tsv")
   + genes("region_genes.bed", name="genes")
   + matrix("region_betas_long.tsv", name="betas", cluster=samples)' -o region.pdf
```

`genes(...)` already exists (TRK_GENES / BED12). The two pieces to add:

1. **`matrix()` track — the anchored heatmap (the real new feature).** A
   locus-browser track that reads the long-form `chrom beg end Probe_ID beta
   sample_name` (pivot internally: rows = `sample_name`, cols = `Probe_ID`), lays
   the columns out **evenly** (like a normal heatmap), and draws **map lines** from
   each probe's genomic `beg` on the region ruler down to its column center —
   the "linked matrix." Rows = the sample columns; fill = the diverging
   0..1 beta scale (reuse `scale_fill_gradient2` / the heatmap renderer).
   `cluster=samples` reuses the existing heatmap row clustering. This is the fusion
   of track mode (genomic x) and matrix mode (the heatmap) that doesn't exist yet.
2. **`cytoband()` track (small).** A one-row ideogram strip for the region's
   chromosome with the region highlighted — the genome module already has the
   cytoband coloring; this just renders it as a thin top track.

## Division of labor

**cinderplot agent** (plotting):
- the `matrix()` anchored-heatmap track + map lines (novel);
- the `cytoband()` strip track;
- confirm `genes()` renders multi-exon models with strand + labels.

**sesame-cli agent** (data / the methylation side):
- this example data (done);
- the `sesame region chr:beg-end --betas beta.cg --platform <P>` command that emits
  `region_betas_long.tsv` (long-form) from a real cohort's `.cg` — so users get the
  figure without R (**done**; coords auto-resolve from the platform store, or pass
  `--coords coord.tsv.gz`);
- gene models as a fetchable annotation: `region_genes.bed` here is extracted
  from sesameData's `genomeInfo$txns`, but BED12 gene models per build belong in
  `zhou-lab/genomes` alongside seqinfo/cytoband (planned, shared with `cnv`).

## Regenerating

`export_region.R` (needs R + sesame + sesameData) pulls
`HM450.76.TCGA.matched` + hg38 `genomeInfo` and writes the three files. Swap the
gene name / platform there for other loci.
