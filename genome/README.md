# Genome / CNV example data

A real copy-number dataset (the **K562** leukemia line, EPICv2 array — lots of
genuine amplifications and deletions) plus the hg38 genome scaffold, for
developing cinderplot's genomic plotting (a genome coordinate system + ideogram,
reusable for CNV / Manhattan / karyotype plots).

Produced by [`sesame`](https://github.com/zwdzwd/sesame-cli): the data files are
`sesame cnv --bins` / `--segments` output; the scaffold files are what
`sesame fetch genome hg38` pulls from `zhou-lab/genomes`.

## Files

| file | what | schema (TSV, header row) |
|---|---|---|
| `k562.bins.tsv` | per-bin log2 ratios — the **scatter cloud** | `sample chrom start end nprobes log2ratio` |
| `k562.segments.tsv` | CBS segments — the **level lines** | `sample chrom start end nbin seg.mean` |
| `hg38.seqinfo.tsv` | chromosome lengths — the **x-axis scaffold** | `chrom length` |
| `hg38.cytoband.tsv` | cytobands — the **ideogram track** | `chrom start end band stain` |

`chrom/start/end` are hg38 genomic coordinates. `log2ratio` (bins) and `seg.mean`
(segments) are log2 copy-number ratios: 0 = normal (2 copies), positive =
amplification, negative = deletion. K562 ranges roughly −5..+8 (e.g. the chr9p21
`CDKN2A` homozygous deletion shows as a deep chr9 dip).

## The one piece of genome math: a linear whole-genome x-axis

Both data files carry **per-chromosome** coordinates. To lay them on one axis you
concatenate the chromosomes in `seqinfo` order and map

```
x(chrom, pos) = offset[chrom] + pos
offset[chrom] = sum of lengths of all chromosomes before `chrom`  (seqinfo order)
genome_length = sum of all chromosome lengths
```

Everything else falls out of that:

- **plot a bin** at `x = offset[chrom] + (start+end)/2`, `y = log2ratio`
- **plot a segment** as a horizontal line from `offset[chrom] + start` to
  `offset[chrom] + end` at `y = seg.mean`
- **chromosome boundaries**: vertical lines at each `offset[chrom]` (and at
  `genome_length`)
- **chromosome tick labels**: `chrom` centered at `offset[chrom] + length/2`

(sesame normalizes `x` by `genome_length` to [0,1]; using raw bp and letting the
scale handle the range is equivalent.) This offset table is exactly the state a
`scale_x_genome(seqinfo)` / `coord_genome` would own — compute it once from
`hg38.seqinfo.tsv`, reuse for every layer.

## Ideogram track (`hg38.cytoband.tsv`)

Draw each cytoband as a rectangle spanning `[offset[chrom]+start, offset[chrom]+end]`
in x, at a fixed thin y-band (sesame parks it just below the data, e.g.
`ymin = min(data)-0.6`), filled by `stain`. Centromeres (`acen`) are the red
notches. Conventional gieStain → color:

| stain | color | meaning |
|---|---|---|
| `gneg` | `#FFFFFF` (or very light gray) | light band |
| `gpos25` | `#C0C0C0` | |
| `gpos50` | `#909090` | Giemsa-positive, |
| `gpos75` | `#606060` | increasingly dark |
| `gpos100` | `#000000` | darkest band |
| `acen` | `#E00000` | centromere (red) |
| `gvar` | `#808080` | variable region |
| `stalk` | `#808080` | acrocentric stalk |

(sesame uses `pals::ocean.gray` for the gpos ramp; any light→dark gray ramp reads
correctly. Centromere red is the one color that must stand out.)

## The target: what a CNV plot looks like

sesame's `visualizeSegments` is a single panel composed of these layers, all in
whole-genome x:

1. `geom_point` — bins, colored by `log2ratio` on a **diverging** scale
   (red↓ / grey0 / green↑), squished to about ±0.3 so extreme CNVs don't wash out
   the mid-range;
2. `geom_segment` — segment means as horizontal lines (sesame draws them blue) on
   top of the cloud;
3. `geom_vline` — dotted chromosome boundaries;
4. `geom_rect` — the ideogram track below the data;
5. custom x-axis: chromosome names at chromosome midpoints (rotated).

So there's no bespoke "CNV geom" — it's ordinary point/segment/rect/vline layers
over a genome coordinate transform plus a diverging, squished color scale. The
genomics module's job is that transform (from `seqinfo`) and the ideogram helper
(from `cytoband`); the rest is generic grammar.

## Cinderplot recipes

TSV is auto-sniffed, so the files feed in directly. These two render with the
grammar as it stands today (`scale_x_genome` + `aes(chrom=)` already apply the
per-chromosome offset to `x` and `xend`):

```sh
# (a) the CNV point cloud — bins colored on a diverging, squished scale
cinderplot 'genome/k562.bins.tsv
  + aes(chrom=chrom, x=start, y=log2ratio, colour=log2ratio)
  + geom_point()
  + scale_x_genome("genome/hg38.seqinfo.tsv")
  + scale_colour_gradient2(low="red", mid="grey", high="green", midpoint=0, limits=c(-0.3,0.3))
  + labs(title="K562 copy number", y="log2 ratio")' -o k562_bins.pdf

# (b) the segment level lines on their own
cinderplot 'genome/k562.segments.tsv
  + aes(chrom=chrom, x=start, xend=end, y=seg.mean, yend=seg.mean)
  + geom_segment()
  + scale_x_genome("genome/hg38.seqinfo.tsv")' -o k562_segments.pdf
```

The **canonical CNV figure** — cloud + segment lines in one panel, with the
ideogram — now renders in a single command:

```sh
cinderplot 'genome/k562.bins.tsv
  + aes(chrom=chrom, x=start, xend=end, y=log2ratio, colour=log2ratio)
  + geom_point()
  + geom_segment(data="genome/k562.segments.tsv", y=seg.mean, color="blue")
  + scale_x_genome("genome/hg38.seqinfo.tsv")
  + scale_colour_gradient2(low="red", mid="grey", high="green", midpoint=0, limits=c(-0.3,0.3))
  + ideogram("genome/hg38.cytoband.tsv")
  + labs(title="K562 copy number", y="log2 ratio")' -o k562_cnv.pdf
```

The three features the overlay needs all landed in milestone M1:

1. **per-layer `data=` / `y=`** on `geom_segment`, so bins and segments (different
   files, different columns) coexist — the top-level `aes(chrom=, x=, xend=)`
   supplies the shared genomic coordinates; `y=` overrides per layer;
2. **a per-layer constant colour** — `geom_segment(..., color="blue")`;
3. **`ideogram("cytoband.tsv")`** — a thin gieStain band reserved at the panel
   bottom (grey ramp + red centromeres; see the color table above).

Notes: the genome scale reads `aes(chrom=)` + `scale_x_genome(seqinfo)`, so `x`
and `xend` are within-chromosome positions offset per chromosome; the continuous
`colour` is squished by `limits=`. (Not yet: a colour-bar legend for the
continuous scale, and a general `geom_rect` — the ideogram is its own helper.)

## Regenerating / other samples

```sh
# scaffold (any build published in zhou-lab/genomes: hg38, mm10, mm39)
sesame fetch genome hg38          # -> <store>/genome/hg38/{seqinfo,cytoband}.tsv.gz

# data, from an IDAT prefix
sesame preprocess --prep "" --raw-signal --output total_intensity --out t/ <prefix>
sesame cnv --bins     --target t/total_intensity.cg --platform EPICv2 > bins.tsv
sesame cnv --segments --target t/total_intensity.cg --platform EPICv2 > segments.tsv
```
