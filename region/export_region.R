#!/usr/bin/env Rscript
# Export a real "visualizeRegion" example (the ADA gene, HM450, hg38) for
# cinderplot to build an anchored heatmap track against:
#   region_betas.bed  chrom start end Probe_ID <sample1..N>  (BED4 + a beta-per-
#                        sample matrix; header row = sample names. BED-style so the
#                        locus browser region-filters it like any other track.)
#   region_genes.bed  BED12 transcript models (exon blocks, thick = CDS)
#   region.txt        the chrom:beg-end region string
suppressMessages({ library(sesame); library(sesameData); library(GenomicRanges) })

OUT <- commandArgs(trailingOnly = TRUE)[1]; if (is.na(OUT)) OUT <- "."
platform <- "HM450"; genome <- "hg38"

betas <- sesameDataGet("HM450.76.TCGA.matched")$betas          # 10042 x 76
gi    <- sesameData_getGenomeInfo(genome)
probes<- sesameData_getManifestGRanges(platform, genome = genome)

## region = ADA gene span + 3 kb padding
ada  <- gi$txns[mcols(gi$txns)$gene_name == "ADA"]
chrm <- as.character(seqnames(ada[[1]])[1])
beg  <- min(unlist(start(ada))) - 3000
end  <- max(unlist(end(ada)))   + 3000
reg  <- GRanges(chrm, IRanges(beg, end))
writeLines(sprintf("%s:%d-%d", chrm, beg, end), file.path(OUT, "region.txt"))

## probes in the region that are on the beta matrix, ordered by position ->
## BED4 + per-sample beta columns (0-based half-open; header names the samples)
pr <- IRanges::subsetByOverlaps(probes, reg)
pr <- pr[names(pr) %in% rownames(betas)]
pr <- pr[order(start(pr))]
bm <- betas[names(pr), , drop = FALSE]
df <- data.frame(chrom = as.character(seqnames(pr)),
                 start = start(pr) - 1L,
                 end   = end(pr),
                 Probe_ID = names(pr),
                 round(bm, 4), check.names = FALSE)
write.table(df, file.path(OUT, "region_betas.bed"), sep = "\t",
            quote = FALSE, row.names = FALSE)

## transcripts overlapping the region -> BED12 (exon blocks, thick = CDS)
tx <- IRanges::subsetByOverlaps(gi$txns, reg)
bed <- file(file.path(OUT, "region_genes.bed"), "w")
for (i in seq_along(tx)) {
    ex <- sort(tx[[i]]); m <- mcols(tx)[i, ]
    st <- start(ex) - 1L; en <- end(ex)                       # BED 0-based half-open
    tstart <- min(st); tend <- max(en)
    cds0 <- if (!is.na(m$cdsStart)) m$cdsStart else tend      # no CDS -> thick empty
    cds1 <- if (!is.na(m$cdsEnd))   m$cdsEnd   else tend
    cat(sprintf("%s\t%d\t%d\t%s\t0\t%s\t%d\t%d\t0\t%d\t%s\t%s\n",
        chrm, tstart, tend, m$transcript_name, m$transcript_strand,
        cds0, cds1, length(ex),
        paste0(en - st, collapse = ","), paste0(st - tstart, collapse = ",")),
        file = bed)
}
close(bed)
cat(sprintf("region %s:%d-%d  |  %d probes x %d samples  |  %d transcripts\n",
            chrm, beg, end, nrow(df), ncol(bm), length(tx)))
