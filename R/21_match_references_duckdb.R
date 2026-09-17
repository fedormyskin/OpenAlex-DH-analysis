# =============================================================================
# 21_match_references_duckdb.R   (scales to the ALL-WORKS index, ~250M titles)
# -----------------------------------------------------------------------------
# Match conference references to OpenAlex works ENTIRELY OFFLINE and at scale,
# using DuckDB over the Parquet index (from script 20a). DuckDB streams from disk
# and spills when memory is tight, so this works on a ~250M-row index where the
# in-RAM data.table approach (old scripts 20/21) would OOM.
#
# It replaces BOTH the old 20 (build rds) and 21 (match) for the all-works case:
# there is no giant in-memory index — DuckDB queries the Parquet directly.
#
# MATCH TIERS (mirroring thresholds elsewhere in the project):
#   1. DOI join                  -> confidence 1.00
#   2. exact normalised title    -> confidence 1.00
#   3. fuzzy: candidate works that SHARE A TITLE WORD with the reference, scored
#      with DuckDB's built-in jaro_winkler_similarity; ACCEPT >= 0.93,
#      review 0.85-0.93. All done in SQL — no millions of rows pulled into R.
#
# INPUT  : $OA_INDEX_DIR/works_index.parquet   (id, title, title_norm, doi, ...)
#          data/output/15_conf_references.csv  + 15b_parsed_references.csv
# OUTPUT : data/output/16_reference_matches.csv / _review.csv
#          data/output/21_offline_match_report.txt
#
# Run:  Rscript R/21_match_references_duckdb.R
# Habrok: request --mem=32G and TMPDIR on /scratch (DuckDB spills there).
# =============================================================================

suppressPackageStartupMessages({
  library(duckdb); library(DBI)
  library(tidyverse)
})

# Match-score thresholds. Now that scoring is on the TITLE ALONE (not
# title+author+year), genuine matches score higher, so the accept floor is
# reliable at >=0.95. We keep a WIDER review band (>=0.85) and WRITE it out so the
# 0.85-0.95 rows can be inspected/labelled manually rather than silently dropped.
#   >= ACCEPT_THRESHOLD -> auto-accept
#   MIN_REVIEW .. ACCEPT -> review file (manual check)
#   <  MIN_REVIEW         -> not recorded
ACCEPT_THRESHOLD <- 0.95
MIN_REVIEW       <- 0.85    # widened (was 0.93) to capture the band for review
MAX_TITLE_CHARS  <- 180
MAX_TITLE_WORDS  <- 25

out_dir   <- file.path("data", "output")
index_dir <- Sys.getenv(
  "OA_INDEX_DIR",
  unset = "/Users/fedor/Library/CloudStorage/SynologyDrive-sync/openalex_index")
# Script 20a writes a DIRECTORY of parquet parts (works_index_parquet/) for
# memory-safe chunked conversion; older runs may have a single works_index.parquet
# file. Support both: build a read_parquet() glob for DuckDB.
parquet_dir  <- file.path(index_dir, "works_index_parquet")
parquet_file <- file.path(index_dir, "works_index.parquet")
if (dir.exists(parquet_dir)) {
  parquet_glob <- file.path(parquet_dir, "*.parquet")
} else if (file.exists(parquet_file)) {
  parquet_glob <- parquet_file
} else {
  stop("No parquet index found: expected ", parquet_dir, "/ or ", parquet_file)
}
cat("Reading parquet index:", parquet_glob, "\n")

`%||%` <- function(x, y) if (is.null(x)) y else x
norm_title <- function(x) {
  x %>% str_to_lower() %>%
    str_replace_all("https?://\\S+|www\\.\\S+|\\b[a-z0-9.-]+\\.(?:htm|html|pdf|org|com|edu|net|gov)\\b", " ") %>%
    str_replace_all("published on the internet at|available (?:online )?at|retrieved from|accessed (?:on )?", " ") %>%
    stringi::stri_trans_general("Latin-ASCII") %>%
    str_replace_all("[^a-z0-9 ]", " ") %>% str_squish()
}
# bad-title guards (XML refs are full citations -> relaxed; see script 21 notes)
MIN_TITLE_WORDS <- 4   # AnyStyle fragments (<4 words) match by coincidence and
                       # flood the review band; drop them rather than match junk.
bad_txt <- function(raw) {
  if (is.na(raw)) return("missing")
  nw <- str_count(str_squish(raw), "\\S+"); nc <- nchar(raw)
  if (nc > MAX_TITLE_CHARS || nw > MAX_TITLE_WORDS) return("prose_too_long")
  if (nw < MIN_TITLE_WORDS) return("too_short_fragment")   # residual AnyStyle fragment
  if (grepl("^(the|a|an|of|on|for|in|and|with|to|by) ", raw)) return("fragment_lowercase_start")
  NA_character_
}
bad_xml <- function(raw) {
  if (is.na(raw) || nchar(str_squish(raw)) < 5) return("missing")
  if (nchar(raw) > 500) return("prose_too_long")
  NA_character_
}

# --- assemble references -----------------------------------------------------
# IMPORTANT: we score the fuzzy match on the TITLE ALONE, not on title+author+year.
# Appending the author/year tail to the query dragged genuine matches down into
# the review band (a perfect title match scored ~0.93 instead of ~0.98 because of
# the trailing "Smith 2012"). So:
#   ref_search    = the full reference string (kept for display / audit)
#   ref_title_only = the bare title used for fuzzy scoring (AnyStyle: ref_title;
#                    XML: the full citation, since it has no separate title field)
refs_xml <- readr::read_csv(file.path(out_dir, "15_conf_references.csv"),
                            show_col_types = FALSE) %>%
  filter(str_starts(ref_quality, "xml")) %>%
  transmute(ref_id, work_id, ref_doi,
            ref_search = ref_text, ref_title_only = ref_text,
            ref_quality, is_xml = TRUE)
refs_txt <- readr::read_csv(file.path(out_dir, "15b_parsed_references.csv"),
                            show_col_types = FALSE,
                            col_types = cols(ref_title = col_character(),
                                             ref_authors = col_character(),
                                             ref_year = col_character(),
                                             ref_doi = col_character())) %>%
  transmute(ref_id, work_id, ref_doi,
            ref_search = str_squish(paste(coalesce(ref_title, ""),
                                          coalesce(ref_authors, ""),
                                          coalesce(ref_year, ""))),
            ref_title_only = coalesce(ref_title, ""),   # title only -> cleaner score
            ref_quality, is_xml = FALSE)
refs <- bind_rows(refs_xml, refs_txt) %>%
  mutate(ref_doi = str_to_lower(ref_doi),
         # fuzzy/exact scoring uses the TITLE-ONLY normalised form
         title_norm = norm_title(ref_title_only),
         # bad-title guard still looks at the full string (catches prose/fragments)
         bad = ifelse(is_xml, vapply(ref_search, bad_xml, character(1)),
                              vapply(ref_search, bad_txt, character(1))),
         first_word = sub(" .*$", "", title_norm))
cat("References:", nrow(refs), "| with usable title:",
    sum(is.na(refs$bad) & nchar(refs$title_norm) >= 10), "\n")

# --- DuckDB: load refs + query the parquet index -----------------------------
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
# Memory safety: cap DuckDB well BELOW the SLURM --mem so R + OS overhead fit too,
# force spilling to scratch, and limit threads (each parallel pipeline holds its
# own buffers, so fewer threads = lower peak RAM). Override via DUCKDB_MEM_LIMIT.
dbExecute(con, sprintf("PRAGMA memory_limit='%s'",
                       Sys.getenv("DUCKDB_MEM_LIMIT", unset = "40GB")))
dbExecute(con, "PRAGMA threads=4")
dbExecute(con, sprintf("PRAGMA temp_directory='%s'",
                       Sys.getenv("TMPDIR", unset = tempdir())))

duckdb::duckdb_register(con, "refs", refs)
dbExecute(con, sprintf(
  "CREATE VIEW works AS SELECT id, title, title_norm, lower(doi) AS doi
   FROM read_parquet('%s')", parquet_glob))

# 1. DOI matches ------------------------------------------------------------
cat("DOI join...\n")
m_doi <- dbGetQuery(con, "
  SELECT r.ref_id, w.id AS openalex_id, w.title AS oa_title,
         'offline_doi' AS match_method, 1.0 AS confidence
  FROM refs r JOIN works w ON r.ref_doi = w.doi
  WHERE r.ref_doi IS NOT NULL AND r.ref_doi <> ''")

# 2. exact normalised-title (only refs not already DOI-matched, with good title)
cat("Exact-title join...\n")
m_exact <- dbGetQuery(con, "
  SELECT r.ref_id, w.id AS openalex_id, w.title AS oa_title,
         'offline_title_exact' AS match_method, 1.0 AS confidence
  FROM refs r JOIN works w ON r.title_norm = w.title_norm
  WHERE r.bad IS NULL AND length(r.title_norm) >= 10
    AND r.ref_id NOT IN (SELECT ref_id FROM refs WHERE ref_doi IN (SELECT doi FROM works))")

# 3. fuzzy: candidate works sharing a BLOCKING KEY with the reference, scored by
#    Jaro-Winkler. Memory-safety at ~459M rows is the whole game here:
#    * Block on the FIRST TWO WORDS (the first ~24 chars of the normalised title),
#      not just the first word — this shrinks candidate sets by orders of
#      magnitude vs blocking on "the"/"a"/"study".
#    * Filter sim >= threshold INSIDE the join and keep only the best per ref via
#      QUALIFY, so DuckDB streams and never materialises the full cross product.
#    * No CREATE TABLE copy of `works` — compute the blocking key inline so DuckDB
#      reads the parquet in a streaming scan.
#    * Only fuzzy-match refs not already matched and with a usable title.
cat("Fuzzy match (DuckDB jaro_winkler, 2-word blocked, streaming)...\n")
matched_ids <- c(m_doi$ref_id, m_exact$ref_id)
duckdb::duckdb_register(con, "matched", data.frame(ref_id = matched_ids))

# refs eligible for fuzzy, with a 2-word blocking key (first up-to-24 chars)
dbExecute(con, "CREATE TEMP VIEW refs_fz AS
  SELECT ref_id, title_norm,
         substr(title_norm, 1, 24) AS bk
  FROM refs
  WHERE bad IS NULL AND length(title_norm) >= 10
    AND ref_id NOT IN (SELECT ref_id FROM matched)")

m_fuzzy <- dbGetQuery(con, sprintf("
  SELECT r.ref_id, w.id AS openalex_id, w.title AS oa_title,
         'offline_title_fuzzy' AS match_method,
         jaro_winkler_similarity(r.title_norm, w.title_norm) AS confidence
  FROM refs_fz r
  JOIN works w
    ON substr(w.title_norm, 1, 24) = r.bk
  WHERE jaro_winkler_similarity(r.title_norm, w.title_norm) >= %f
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY r.ref_id
    ORDER BY jaro_winkler_similarity(r.title_norm, w.title_norm) DESC) = 1",
  MIN_REVIEW))

# --- consolidate -------------------------------------------------------------
all_m <- bind_rows(m_doi, m_exact, m_fuzzy) %>%
  group_by(ref_id) %>% slice_max(confidence, n = 1, with_ties = FALSE) %>% ungroup()

results <- refs %>%
  left_join(all_m, by = "ref_id") %>%
  mutate(
    match_method = coalesce(match_method,
                            ifelse(!is.na(bad), paste0("bad_title:", bad), "none")),
    confidence = coalesce(confidence, 0),
    decision = case_when(
      startsWith(match_method, "bad_title")              ~ "bad_title",
      match_method %in% c("offline_doi","offline_title_exact") ~ "accept",
      confidence >= ACCEPT_THRESHOLD                     ~ "accept",
      confidence >= MIN_REVIEW                           ~ "review",
      TRUE                                               ~ "none"))

# Keep oa_title (the matched OpenAlex title) so each row shows BOTH the reference
# query (ref_search) and what it matched to — essential for reviewing matches.
keep <- c("ref_id","work_id","ref_doi","ref_search","ref_quality",
          "openalex_id","oa_title","match_method","confidence")
accepted <- results %>% filter(decision == "accept") %>% select(any_of(keep))
# review sorted by confidence DESC so the most-likely-correct are at the top
# (easier to label top-down and stop when matches stop being good).
review   <- results %>% filter(decision == "review") %>%
  arrange(desc(confidence)) %>% select(any_of(keep))
readr::write_csv(accepted, file.path(out_dir, "16_reference_matches.csv"))
readr::write_csv(review,   file.path(out_dir, "16_reference_matches_review.csv"))

report <- c(
  "=== 21_match_references_duckdb.R report ===",
  sprintf("Generated: %s", Sys.time()),
  sprintf("References in:        %d", nrow(refs)),
  sprintf("  ACCEPTED:           %d (%.1f%%)", nrow(accepted), 100*nrow(accepted)/nrow(refs)),
  sprintf("    via DOI:          %d", sum(results$match_method=="offline_doi")),
  sprintf("    via exact title:  %d", sum(results$match_method=="offline_title_exact")),
  sprintf("    via fuzzy title:  %d", sum(results$match_method=="offline_title_fuzzy" & results$decision=="accept")),
  sprintf("  REVIEW (0.85-0.93): %d", nrow(review)),
  sprintf("  BAD TITLE:          %d", sum(results$decision=="bad_title")),
  sprintf("  No match:           %d", sum(results$decision=="none")))
writeLines(report, file.path(out_dir, "21_offline_match_report.txt"))
cat(paste(report, collapse = "\n"), "\n")
