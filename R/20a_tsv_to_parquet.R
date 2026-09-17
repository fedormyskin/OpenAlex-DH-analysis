# =============================================================================
# 20a_tsv_to_parquet.R
# -----------------------------------------------------------------------------
# Convert the big works_index.tsv (from script 19) into a compressed Parquet file
# with a pre-computed normalised-title column. Parquet is columnar + compressed
# (~3x smaller) and supports LAZY, memory-light reads — so the downstream index
# build and matching work on an 8 GB machine, and run even faster on Habrok.
#
# This step is MEMORY-SAFE: it streams the TSV through arrow in row-group chunks,
# so it does NOT load all ~7M rows into RAM at once (which is what crashed the
# original script 20).
#
# INPUT  : $OA_INDEX_DIR/works_index.tsv
# OUTPUT : $OA_INDEX_DIR/works_index_parquet/   (a DIRECTORY of part-*.parquet;
#          read transparently as one table by DuckDB/arrow. Chunked for memory.)
#
# Run:  Rscript R/20a_tsv_to_parquet.R
#       OA_INDEX_DIR=/scratch/$USER/openalex_index Rscript R/20a_tsv_to_parquet.R
# =============================================================================

suppressPackageStartupMessages({
  library(arrow)        # parquet writer
  library(data.table)   # tolerant TSV reader (arrow's CSV parser desyncs on
                        # titles containing stray quotes/newlines)
  library(stringi)
})

index_dir <- Sys.getenv(
  "OA_INDEX_DIR",
  unset = "/Users/fedor/Library/CloudStorage/SynologyDrive-sync/openalex_index")
tsv <- file.path(index_dir, "works_index.tsv")
parquet_out <- file.path(index_dir, "works_index.parquet")
stopifnot(file.exists(tsv))

# Fast index-side title normalisation (identical output to the reference-side
# norm_title() on clean titles; OpenAlex titles have no URLs to strip).
norm_title <- function(x) {
  x <- stringi::stri_trans_tolower(x)
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- stringi::stri_replace_all_regex(x, "[^a-z0-9 ]", " ")
  stringi::stri_trim_both(stringi::stri_replace_all_regex(x, "\\s+", " "))
}

# MEMORY-SAFE CHUNKED CONVERSION.
# Loading the whole ~250M-row TSV into R at once OOM-killed even at 180 GB. We
# therefore stream the TSV through a text connection in fixed row-chunks, process
# each chunk (normalise titles, drop unusable rows), and write it as ONE Parquet
# file into an output DIRECTORY (a Parquet "dataset"). arrow and DuckDB read a
# directory of part-*.parquet files transparently as a single table, so nothing
# downstream changes. Peak memory = one chunk (~a few GB), independent of TSV size.
#
# We use data.table::fread on each chunk's text (quote="" tolerance preserved).
expected <- c("id", "doi", "title", "year", "countries", "subfield")
CHUNK <- 2000000L   # rows per chunk (~a few hundred MB of text); tune if needed

# Output is a DIRECTORY of parquet parts (read transparently as one table).
# RESUMABLE: each CHUNK maps to a fixed part name by its sequence position, so a
# re-run SKIPS chunks whose part file already exists and does NOT wipe the dir.
# This is keyed on CHUNK size — do not change CHUNK between resumed runs, or the
# chunk->part alignment shifts. A chunk that yields zero valid rows writes a tiny
# empty marker so it is still counted as done.
parquet_dir <- sub("[.]parquet$", "_parquet", parquet_out)
dir.create(parquet_dir, recursive = TRUE, showWarnings = FALSE)

con <- file(tsv, "r", encoding = "UTF-8")
on.exit(close(con), add = TRUE)
header <- readLines(con, n = 1)                    # consume + check header
hcols <- strsplit(header, "\t")[[1]]
if (!all(expected %in% hcols)) {
  stop("Unexpected TSV header: ", header)
}

cat("Converting TSV -> Parquet dataset in chunks of", CHUNK, "rows (resumable)...\n")
total_in <- 0L; total_out <- 0L; chunk <- 0L; skipped <- 0L
repeat {
  lines <- readLines(con, n = CHUNK)
  if (length(lines) == 0) break
  chunk <- chunk + 1L
  total_in <- total_in + length(lines)
  part_file <- file.path(parquet_dir, sprintf("part-%05d.parquet", chunk))
  done_marker <- file.path(parquet_dir, sprintf(".part-%05d.empty", chunk))
  # RESUME: if this chunk was already written (or marked empty), skip it.
  if (file.exists(part_file) || file.exists(done_marker)) {
    skipped <- skipped + 1L
    if (chunk %% 25 == 0) cat(sprintf("  ...skipped through chunk %d\n", chunk))
    next
  }
  dt <- data.table::fread(text = lines, sep = "\t", header = FALSE,
                          quote = "", colClasses = "character",
                          col.names = hcols, showProgress = FALSE)
  dt <- dt[, ..expected]
  dt[, title_norm := norm_title(title)]
  dt <- dt[nchar(title_norm) >= 5]
  if (nrow(dt) > 0) {
    # write to a temp file then rename, so a kill mid-write can't leave a
    # truncated part that the resume logic would wrongly treat as complete.
    tmp <- paste0(part_file, ".tmp")
    arrow::write_parquet(as.data.frame(dt), tmp, compression = "zstd")
    file.rename(tmp, part_file)
    total_out <- total_out + nrow(dt)
  } else {
    file.create(done_marker)                       # empty chunk, but mark done
  }
  cat(sprintf("  chunk %d: %d read, %d written total\n", chunk, total_in, total_out))
  rm(dt); gc(FALSE)
}
part <- length(list.files(parquet_dir, pattern = "[.]parquet$"))
if (skipped > 0) cat(sprintf("Resumed: skipped %d already-done chunks.\n", skipped))

tsv_gb <- file.info(tsv)$size / 1e9
pq_gb  <- sum(file.info(list.files(parquet_dir, full.names = TRUE))$size) / 1e9
cat(sprintf("\n=== done. %d rows in -> %d rows out across %d parquet parts. ===\n",
            total_in, total_out, part))
cat(sprintf("TSV %.1f GB -> Parquet dir %.1f GB (%.1fx smaller)\n",
            tsv_gb, pq_gb, tsv_gb / pq_gb))
cat("Output dir:", parquet_dir, "\n")
cat("NOTE: the matcher must read this as a DIRECTORY of parquet files.\n")
